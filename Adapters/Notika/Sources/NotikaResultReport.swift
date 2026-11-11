import AgentBuildCore
import CryptoKit
import Darwin
import Foundation

public struct NotikaResultReportMetadata: Codable, Equatable, Sendable {
    public let name: String
    public let path: String
    public let kind: String
    public let device: Int64
    public let inode: UInt64
    public let owner: UInt32
    public let mode: UInt16
    public let bytes: Int64
    public let sha256: String
    public let entries: [ResultTreeRecord]
}

/// A reserved report never lends its writer to a child. Retired, admitted raw
/// stdout is copied through the original descriptor, then retained and watched.
internal final class NotikaResultReportFile: @unchecked Sendable {
    let name: String
    let path: String
    private let bundle: NotikaRetainedResultBundle
    private let parent: Int32
    private let descriptor: Int32
    private let original: ResultNodeIdentity
    private let watch: ResultMutationWatch
    private let lock = NSLock()
    private var sealed: NotikaResultReportMetadata?
    private var sealedIdentity: ResultNodeIdentity?
    private var attempted = false

    init(bundle: NotikaRetainedResultBundle, name: String) throws {
        guard ["summary.json", "coverage-summary.txt", "coverage.json", "coverage.lcov"].contains(name) else {
            throw ResultBundleFailure(operation: "invalid result report name", code: EINVAL)
        }
        try bundle.revalidateForPublication()
        let parent = fcntl(bundle.sessionDirectoryDescriptor, F_DUPFD_CLOEXEC, 3)
        guard parent >= 3 else { throw resultFailure("retain report session") }
        var transferred = false
        defer { if !transferred { _ = Darwin.close(parent) } }
        let descriptor = openat(parent, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 3 else { throw resultFailure("reserve result report", detail: name) }
        defer { if !transferred { _ = Darwin.close(descriptor) } }
        guard fchmod(descriptor, 0o600) == 0 else { throw resultFailure("set result report privacy") }
        let identity = try resultDescriptorIdentity(descriptor)
        guard identity.regular, identity.owner == UInt32(geteuid()), identity.links == 1,
              identity.mode & 0o7777 == 0o600, identity.size == 0,
              try resultEntryIdentity(parent, name) == identity else {
            throw ResultBundleFailure(operation: "unsafe result report reservation", code: ESTALE)
        }
        let watch = try ResultMutationWatch()
        try watch.arm(parent, writes: false)
        try watch.arm(descriptor, writes: false)
        try bundle.revalidateForPublication()
        self.bundle = bundle; self.parent = parent; self.descriptor = descriptor
        self.name = name; path = bundle.sessionDirectory + "/" + name
        original = identity; self.watch = watch
        transferred = true
    }

    deinit { _ = Darwin.close(descriptor); _ = Darwin.close(parent) }

    var metadata: NotikaResultReportMetadata? {
        lock.lock(); defer { lock.unlock() }
        return sealed
    }

    func write(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard !attempted, data.count <= 64 * 1_024 * 1_024 else {
            throw ResultBundleFailure(operation: "invalid result report write", code: EFBIG)
        }
        attempted = true
        try watch.check()
        try bundle.revalidateForPublication()
        guard try resultDescriptorIdentity(descriptor) == original,
              try resultEntryIdentity(parent, name) == original else {
            throw ResultBundleFailure(operation: "result report reservation changed", code: ESTALE)
        }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), $0.count - offset)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw resultFailure("write reserved result report", code: count < 0 ? errno : EIO) }
            offset += count
        }
        guard fsync(descriptor) == 0, fsync(parent) == 0 else { throw resultFailure("synchronize result report") }
        try watch.arm(descriptor, writes: true)
        let identity = try resultDescriptorIdentity(descriptor)
        let digest = CanonicalJSONDigest.digest(data)
        guard identity.regular, identity.device == original.device, identity.inode == original.inode,
              identity.owner == original.owner, identity.mode == original.mode, identity.links == 1,
              identity.size == Int64(data.count), try resultEntryIdentity(parent, name) == identity,
              try resultReportDigest(descriptor, size: identity.size) == digest else {
            throw ResultBundleFailure(operation: "result report publication changed", code: ESTALE)
        }
        try watch.check()
        try bundle.revalidateForPublication()
        sealedIdentity = identity
        sealed = .init(name: name, path: path, kind: "file", device: identity.device, inode: identity.inode,
                       owner: identity.owner, mode: identity.mode, bytes: identity.size,
                       sha256: digest, entries: [])
    }

    func revalidate() throws {
        lock.lock(); defer { lock.unlock() }
        try watch.check()
        try bundle.revalidateForPublication()
        if let sealed, let identity = sealedIdentity {
            guard try resultDescriptorIdentity(descriptor) == identity,
                  try resultEntryIdentity(parent, name) == identity,
                  try resultReportDigest(descriptor, size: identity.size) == sealed.sha256 else {
                throw ResultBundleFailure(operation: "result report changed", code: ESTALE, detail: name)
            }
        } else if !attempted {
            guard try resultDescriptorIdentity(descriptor) == original,
                  try resultEntryIdentity(parent, name) == original else {
                throw ResultBundleFailure(operation: "result report reservation changed", code: ESTALE)
            }
        } else {
            throw ResultBundleFailure(operation: "result report is incomplete", code: EPROTO, detail: name)
        }
        try watch.check()
    }
}

internal final class NotikaResultReportDirectory: @unchecked Sendable {
    let path: String
    private let bundle: NotikaRetainedResultBundle
    private let parent: Int32
    private let descriptor: Int32
    private let original: ResultNodeIdentity
    private let watch: ResultMutationWatch
    private let lock = NSLock()
    private var retained: ResultBundleTree?

    init(bundle: NotikaRetainedResultBundle) throws {
        try bundle.revalidateForPublication()
        let parent = fcntl(bundle.sessionDirectoryDescriptor, F_DUPFD_CLOEXEC, 3)
        guard parent >= 3 else { throw resultFailure("retain coverage directory session") }
        var transferred = false
        defer { if !transferred { _ = Darwin.close(parent) } }
        guard mkdirat(parent, "coverage-html", 0o700) == 0 else { throw resultFailure("reserve coverage HTML") }
        let descriptor = openat(parent, "coverage-html", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 3 else { throw resultFailure("retain coverage HTML") }
        defer { if !transferred { _ = Darwin.close(descriptor) } }
        guard fchmod(descriptor, 0o700) == 0 else { throw resultFailure("set coverage HTML privacy") }
        let identity = try resultDescriptorIdentity(descriptor)
        guard identity.directory, identity.owner == UInt32(geteuid()), identity.mode & 0o7777 == 0o700,
              try resultEntryIdentity(parent, "coverage-html") == identity else {
            throw ResultBundleFailure(operation: "unsafe coverage HTML reservation", code: ESTALE)
        }
        let watch = try ResultMutationWatch()
        try watch.arm(parent, writes: false)
        try watch.arm(descriptor, writes: false)
        self.bundle = bundle; self.parent = parent; self.descriptor = descriptor
        original = identity; self.watch = watch; path = bundle.sessionDirectory + "/coverage-html"
        transferred = true
    }

    deinit { _ = Darwin.close(descriptor); _ = Darwin.close(parent) }

    func admitAfterRetirement() throws -> NotikaResultReportMetadata {
        lock.lock(); defer { lock.unlock() }
        guard retained == nil else { throw ResultBundleFailure(operation: "coverage HTML already admitted", code: EALREADY) }
        try validateReservation()
        let tree = try ResultBundleTree(parent: parent, name: "coverage-html",
            maximumBytes: 64 * 1_024 * 1_024, privatePermissions: true, requiredRootFile: "index.html")
        let identity = try resultDescriptorIdentity(tree.root)
        guard original.sameDirectoryBinding(identity) else {
            throw ResultBundleFailure(operation: "coverage HTML reservation replaced", code: ESTALE)
        }
        try validateReservation()
        retained = tree
        return .init(name: "coverage-html", path: path, kind: "directory", device: identity.device,
                     inode: identity.inode, owner: identity.owner, mode: identity.mode,
                     bytes: tree.byteCount, sha256: tree.commitment, entries: tree.records)
    }

    func revalidate() throws {
        lock.lock(); defer { lock.unlock() }
        try validateReservation()
        try retained?.revalidate()
        try validateReservation()
    }

    private func validateReservation() throws {
        try watch.check()
        try bundle.revalidateForPublication()
        guard original.sameDirectoryBinding(try resultDescriptorIdentity(descriptor)),
              original.sameDirectoryBinding(try resultEntryIdentity(parent, "coverage-html")) else {
            throw ResultBundleFailure(operation: "coverage HTML directory changed", code: ESTALE)
        }
        try watch.check()
    }
}

private func resultReportDigest(_ descriptor: Int32, size: Int64) throws -> String {
    var hash = SHA256()
    var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
    var offset: Int64 = 0
    while offset < size {
        let count = bytes.withUnsafeMutableBytes {
            pread(descriptor, $0.baseAddress, Int(min(Int64($0.count), size - offset)), off_t(offset))
        }
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw resultFailure("hash retained result report", code: count < 0 ? errno : EIO) }
        hash.update(data: Data(bytes.prefix(count)))
        offset += Int64(count)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
