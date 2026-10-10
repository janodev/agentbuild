import Darwin
import Foundation

internal enum ArtifactAllocatedSizeError: Error {
    case unsafeEntry, evidenceChanged, traversalBoundExceeded
    case systemCall(String, Int32)
}

/// Accounts an admitted directory using retained, nofollow descriptors. The
/// explicit DFS stack keeps nesting off the thread stack and owns at most one
/// descriptor per admitted depth. Symlinks are entries, never traversal roots.
internal func artifactAllocatedSize(_ descriptor: Int32, maximumDepth: Int, maximumNodes: Int) throws -> UInt64 {
    guard maximumDepth >= 0, maximumNodes > 0 else { throw ArtifactAllocatedSizeError.traversalBoundExceeded }
    let original = try artifactSizeStatus(descriptor)
    guard original.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw ArtifactAllocatedSizeError.unsafeEntry }
    let device = Int64(original.st_dev)
    var seen: Set<ArtifactSizeInode> = []
    var total: UInt64 = 0
    func account(_ status: stat) throws -> Bool {
        guard Int64(status.st_dev) == device else { throw ArtifactAllocatedSizeError.unsafeEntry }
        guard seen.insert(ArtifactSizeInode(device: device, inode: status.st_ino)).inserted else { return false }
        guard seen.count <= maximumNodes else { throw ArtifactAllocatedSizeError.traversalBoundExceeded }
        guard let blocks = UInt64(exactly: status.st_blocks) else { throw ArtifactAllocatedSizeError.unsafeEntry }
        let bytes = blocks.multipliedReportingOverflow(by: 512)
        guard !bytes.overflow else { throw ArtifactAllocatedSizeError.traversalBoundExceeded }
        let sum = total.addingReportingOverflow(bytes.partialValue)
        guard !sum.overflow else { throw ArtifactAllocatedSizeError.traversalBoundExceeded }
        total = sum.partialValue
        return true
    }
    _ = try account(original)
    var stack = [ArtifactSizeFrame(descriptor: descriptor, retained: nil, original: original,
        parentName: nil, names: try artifactSizeNames(descriptor, maximum: maximumNodes))]
    while let current = stack.last {
        if current.nextIndex == current.names.count {
            let final = try artifactSizeStatus(current.descriptor)
            guard artifactSizeIdentity(final) == artifactSizeIdentity(current.original),
                  final.st_mtimespec.tv_sec == current.original.st_mtimespec.tv_sec,
                  final.st_mtimespec.tv_nsec == current.original.st_mtimespec.tv_nsec,
                  final.st_ctimespec.tv_sec == current.original.st_ctimespec.tv_sec,
                  final.st_ctimespec.tv_nsec == current.original.st_ctimespec.tv_nsec else {
                throw ArtifactAllocatedSizeError.evidenceChanged
            }
            if let name = current.parentName {
                let parent = stack[stack.count - 2]
                guard try artifactSizeIdentity(artifactSizeStatus(at: name, directory: parent.descriptor))
                    == artifactSizeIdentity(current.original) else { throw ArtifactAllocatedSizeError.evidenceChanged }
            }
            stack.removeLast()
            continue
        }
        let name = current.names[current.nextIndex]
        current.nextIndex += 1
        let observed = try artifactSizeStatus(at: name, directory: current.descriptor)
        if observed.st_mode & mode_t(S_IFMT) != mode_t(S_IFDIR) {
            _ = try account(observed)
            continue
        }
        // Root depth is zero; the prospective child's depth is stack.count.
        guard stack.count <= maximumDepth else { throw ArtifactAllocatedSizeError.traversalBoundExceeded }
        let child = Darwin.openat(current.descriptor, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard child >= 0 else { throw artifactSizeFailure("open cache sizing child") }
        let retained = ArtifactSizeDescriptor(child)
        let opened = try artifactSizeStatus(child)
        guard artifactSizeIdentity(opened) == artifactSizeIdentity(observed) else { throw ArtifactAllocatedSizeError.evidenceChanged }
        if try account(opened) {
            stack.append(ArtifactSizeFrame(descriptor: child, retained: retained, original: opened,
                parentName: name, names: try artifactSizeNames(child, maximum: maximumNodes)))
        } else {
            guard try artifactSizeIdentity(artifactSizeStatus(at: name, directory: current.descriptor))
                == artifactSizeIdentity(observed) else { throw ArtifactAllocatedSizeError.evidenceChanged }
        }
    }
    return total
}

private struct ArtifactSizeInode: Hashable { let device: Int64; let inode: UInt64 }
private struct ArtifactSizeIdentity: Equatable {
    let device: Int64; let inode: UInt64; let owner: uid_t; let group: gid_t; let mode: mode_t
}
private func artifactSizeIdentity(_ status: stat) -> ArtifactSizeIdentity {
    ArtifactSizeIdentity(device: Int64(status.st_dev), inode: status.st_ino, owner: status.st_uid,
        group: status.st_gid, mode: status.st_mode)
}
private final class ArtifactSizeDescriptor {
    let value: Int32
    init(_ value: Int32) { self.value = value }
    deinit { _ = Darwin.close(value) }
}
private final class ArtifactSizeFrame {
    let descriptor: Int32
    let retained: ArtifactSizeDescriptor?
    let original: stat
    let parentName: String?
    let names: [String]
    var nextIndex = 0
    init(descriptor: Int32, retained: ArtifactSizeDescriptor?, original: stat, parentName: String?, names: [String]) {
        self.descriptor = descriptor; self.retained = retained; self.original = original
        self.parentName = parentName; self.names = names
    }
}
private func artifactSizeFailure(_ operation: String) -> ArtifactAllocatedSizeError { .systemCall(operation, errno) }
private func artifactSizeStatus(_ descriptor: Int32) throws -> stat {
    var value = stat()
    guard Darwin.fstat(descriptor, &value) == 0 else { throw artifactSizeFailure("fstat cache sizing entry") }
    return value
}
private func artifactSizeStatus(at name: String, directory: Int32) throws -> stat {
    var value = stat()
    guard Darwin.fstatat(directory, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw artifactSizeFailure("fstatat cache sizing entry")
    }
    return value
}
private func artifactSizeNames(_ directory: Int32, maximum: Int) throws -> [String] {
    let scan = Darwin.openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard scan >= 0 else { throw artifactSizeFailure("open cache sizing scan") }
    guard let stream = Darwin.fdopendir(scan) else {
        let failure = artifactSizeFailure("fdopendir cache sizing scan")
        _ = Darwin.close(scan)
        throw failure
    }
    defer { _ = Darwin.closedir(stream) }
    var names: [String] = []
    while true {
        errno = 0
        guard let entry = Darwin.readdir(stream) else {
            guard errno == 0 else { throw artifactSizeFailure("readdir cache sizing scan") }
            return names
        }
        var raw = entry.pointee.d_name
        let name = withUnsafeBytes(of: &raw) { bytes -> String? in
            guard let end = bytes.firstIndex(of: 0) else { return nil }
            return String(bytes: bytes.prefix(end), encoding: .utf8)
        }
        guard let name else { throw ArtifactAllocatedSizeError.unsafeEntry }
        if name == "." || name == ".." { continue }
        names.append(name)
        guard names.count <= maximum else { throw ArtifactAllocatedSizeError.traversalBoundExceeded }
    }
}
