import AgentBuildCore
import CryptoKit
import Darwin
import Foundation
import Synchronization

/// Content identity of one bounded, user-owned, link-free DocC tree. This
/// value carries no filesystem authority; its retained reader does.
public struct NotikaDocumentationTreeCommitment: Codable, Equatable, Sendable {
    public let algorithm: String
    public let sha256: String
    public let entries: Int
    public let bytes: Int64
    public let maximumEntries: Int
    public let maximumBytes: Int64
    public let maximumDepth: Int
}

/// DocC's narrow tree copier/renderer overlay. Roots retain their complete
/// no-follow ancestry; every child is opened relative to its retained parent.
/// No links, hardlinked files, foreign owners, devices, or special entries are
/// admitted. Accounting and hashing stream file bytes rather than loading an
/// archive into memory. Partial private snapshots remain diagnostic artifacts.
internal final class NotikaDocumentationTree: Sendable {
    static let maximumEntries = 250_000
    static let maximumBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    static let maximumDepth = 64
    let path: String
    let custody: RetainedArtifactDirectory
    let descriptor: DocumentationDescriptor
    private struct ServingSeal: Sendable { let root: stat; let entries: [Data: stat] }
    private let servingSeal = Mutex<ServingSeal?>(nil)

    init(path: String, privateRoot: Bool = false) throws {
        self.path = path
        custody = try RetainedArtifactDirectory(path: path, requiredPermissions: privateRoot ? 0o700 : nil)
        let opened = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard opened >= 0 else { throw documentationIO("open DocC tree") }
        descriptor = DocumentationDescriptor(opened)
        let observed = try documentationStatus(opened)
        guard observed.st_dev == custody.fingerprint.device, observed.st_ino == custody.fingerprint.inode else {
            throw NotikaDocumentationDriverError.artifactChanged
        }
        try revalidate()
    }

    func revalidate() throws {
        try custody.revalidate()
        let observed = try documentationStatus(descriptor.value)
        try documentationSafeDirectory(observed)
        guard observed.st_dev == custody.fingerprint.device, observed.st_ino == custody.fingerprint.inode,
              observed.st_uid == custody.fingerprint.owner, observed.st_mode == custody.fingerprint.mode else {
            throw NotikaDocumentationDriverError.artifactChanged
        }
    }

    func commitment(checkCancellation: Bool = true, retainingEntries: Bool = false) throws -> NotikaDocumentationTreeCommitment {
        try revalidate()
        let sealedRoot = try documentationStatus(descriptor.value)
        var sealedEntries: [Data: stat] = [:]
        var count = 0
        var total: Int64 = 0
        var aggregate = SHA256()
        aggregate.update(data: Data("[".utf8))
        func record(_ value: CanonicalJSONValue) throws {
            if count > 0 { aggregate.update(data: Data(",".utf8)) }
            aggregate.update(data: try CanonicalJSONDigest.encode(value))
            count += 1
        }
        func walk(_ directory: Int32, relative: String, depth: Int) throws {
            if checkCancellation { try Task.checkCancellation() }
            guard depth <= Self.maximumDepth else { throw NotikaDocumentationDriverError.treeBoundExceeded }
            let before = try documentationStatus(directory)
            try documentationSafeDirectory(before)
            guard before.st_dev == custody.fingerprint.device else { throw NotikaDocumentationDriverError.unsafeArtifact }
            let names = try documentationNames(directory)
            for name in names {
                guard count < Self.maximumEntries else { throw NotikaDocumentationDriverError.treeBoundExceeded }
                let display = relative.isEmpty ? name : relative + "/" + name
                let observed = try documentationStatus(at: name, parent: directory)
                if retainingEntries { sealedEntries[Data(display.utf8)] = observed }
                guard Int64(observed.st_dev) == custody.fingerprint.device else { throw NotikaDocumentationDriverError.unsafeArtifact }
                if observed.st_mode & S_IFMT == S_IFDIR {
                    let child = try documentationOpenChild(name, parent: directory, expected: observed, directory: true)
                    try record(.object(["path": .string(display), "kind": .string("directory")]))
                    try walk(child.value, relative: display, depth: depth + 1)
                    try documentationCheckChild(name, parent: directory, descriptor: child.value, expected: observed)
                } else {
                    let child = try documentationOpenChild(name, parent: directory, expected: observed, directory: false)
                    let remaining = Self.maximumBytes - total
                    let file = try documentationRead(child.value, expected: observed, maximum: remaining, checkCancellation: checkCancellation)
                    try documentationCheckChild(name, parent: directory, descriptor: child.value, expected: observed)
                    total += file.bytes
                    try record(.object(["path": .string(display), "kind": .string("regular"),
                        "bytes": .integer(file.bytes), "sha256": .string(file.digest)]))
                }
            }
            guard try documentationNames(directory) == names,
                  documentationSameFile(try documentationStatus(directory), before) else {
                throw NotikaDocumentationDriverError.artifactChanged
            }
        }
        try walk(descriptor.value, relative: "", depth: 0)
        aggregate.update(data: Data("]".utf8))
        try revalidate()
        if retainingEntries {
            guard documentationSameFile(try documentationStatus(descriptor.value), sealedRoot) else { throw NotikaDocumentationDriverError.artifactChanged }
            servingSeal.withLock { $0 = ServingSeal(root: sealedRoot, entries: sealedEntries) }
        }
        return NotikaDocumentationTreeCommitment(algorithm: "notika.docc-owned-tree.sha256.v1",
            sha256: documentationHex(aggregate.finalize()), entries: count, bytes: total,
            maximumEntries: Self.maximumEntries, maximumBytes: Self.maximumBytes, maximumDepth: Self.maximumDepth)
    }

    /// Destination must be the caller's retained, newly created private tree.
    /// Equal before/after commitments protect both source stability and copies.
    func copy(into destination: NotikaDocumentationTree, expected: NotikaDocumentationTreeCommitment? = nil) throws -> NotikaDocumentationTreeCommitment {
        let admitted = try commitment()
        if let expected, admitted != expected { throw NotikaDocumentationDriverError.artifactChanged }
        try destination.revalidate()
        guard try documentationNames(destination.descriptor.value).isEmpty,
              destination.custody.fingerprint.mode & 0o7777 == 0o700 else { throw NotikaDocumentationDriverError.unsafeArtifact }
        var state = DocumentationCopyBudget()
        try documentationCopy(source: descriptor.value, destination: destination.descriptor.value, depth: 0,
            device: custody.fingerprint.device, destinationDevice: destination.custody.fingerprint.device, merge: false, state: &state)
        guard try commitment() == admitted, try destination.commitment() == admitted else {
            throw NotikaDocumentationDriverError.artifactChanged
        }
        try revalidate(); try destination.revalidate()
        return admitted
    }

    /// Only the copied renderer is installed, never its mutable source path.
    /// Existing transform output is validated before any owner-only conversion.
    func merge(into destination: NotikaDocumentationTree) throws {
        let admitted = try commitment()
        _ = try destination.commitment()
        guard destination.custody.fingerprint.mode & 0o7777 == 0o700 else { throw NotikaDocumentationDriverError.unsafeArtifact }
        var ownerOnlyEntries = 0
        try documentationOwnerOnly(destination.descriptor.value, depth: 0, device: destination.custody.fingerprint.device, entries: &ownerOnlyEntries)
        var state = DocumentationCopyBudget()
        try documentationCopy(source: descriptor.value, destination: destination.descriptor.value, depth: 0,
            device: custody.fingerprint.device, destinationDevice: destination.custody.fingerprint.device, merge: true, state: &state)
        guard try commitment() == admitted else { throw NotikaDocumentationDriverError.artifactChanged }
        try revalidate(); try destination.revalidate()
        _ = try destination.commitment()
    }

    /// HTTP callers receive only an already opened regular file within this
    /// exact retained site. Direct names and each ancestor remain no-follow.
    func openFile(components: [String]) throws -> DocumentationOpenedFile {
        try revalidate()
        guard !components.isEmpty, components.count <= Self.maximumDepth + 1,
              components.allSatisfy(documentationSafeName) else { throw NotikaDocumentationDriverError.unsafeArtifact }
        var directory = descriptor
        var pins: [(DocumentationDescriptor, Int32, String, stat)] = []
        let seal = servingSeal.withLock { $0 }
        if let seal, !documentationSameFile(try documentationStatus(descriptor.value), seal.root) { throw NotikaDocumentationDriverError.artifactChanged }
        var prefix: [String] = []
        for name in components.dropLast() {
            let observed = try documentationStatus(at: name, parent: directory.value)
            prefix.append(name)
            if let seal {
                guard let admitted = seal.entries[Data(prefix.joined(separator: "/").utf8)], documentationSameFile(observed, admitted) else {
                    throw NotikaDocumentationDriverError.artifactChanged
                }
            }
            guard Int64(observed.st_dev) == custody.fingerprint.device else { throw NotikaDocumentationDriverError.unsafeArtifact }
            let child = try documentationOpenChild(name, parent: directory.value, expected: observed, directory: true)
            pins.append((child, directory.value, name, observed)); directory = child
        }
        let name = components.last!
        let observed = try documentationStatus(at: name, parent: directory.value)
        if let seal {
            guard let admitted = seal.entries[Data(components.joined(separator: "/").utf8)], documentationSameFile(observed, admitted) else {
                throw NotikaDocumentationDriverError.artifactChanged
            }
        }
        guard Int64(observed.st_dev) == custody.fingerprint.device else { throw NotikaDocumentationDriverError.unsafeArtifact }
        if observed.st_mode & S_IFMT == S_IFDIR { throw NotikaDocumentationDriverError.artifactIO("DocC requested directory", EISDIR) }
        let file = try documentationOpenChild(name, parent: directory.value, expected: observed, directory: false)
        guard observed.st_size >= 0, observed.st_size <= Self.maximumBytes else { throw NotikaDocumentationDriverError.treeBoundExceeded }
        let retainedPins = pins, retainedDirectory = directory
        return DocumentationOpenedFile(descriptor: file, size: observed.st_size, revalidate: {
            try self.revalidate()
            if let seal, !documentationSameFile(try documentationStatus(self.descriptor.value), seal.root) { throw NotikaDocumentationDriverError.artifactChanged }
            for (pin, parent, name, identity) in retainedPins { try documentationCheckChild(name, parent: parent, descriptor: pin.value, expected: identity) }
            try documentationCheckChild(name, parent: retainedDirectory.value, descriptor: file.value, expected: observed)
        })
    }
}

internal final class DocumentationDescriptor: Sendable {
    let value: Int32
    init(_ value: Int32) { self.value = value }
    deinit { _ = close(value) }
}

internal struct DocumentationOpenedFile: Sendable {
    let descriptor: DocumentationDescriptor
    let size: Int64
    let revalidate: @Sendable () throws -> Void
}

private struct DocumentationCopyBudget { var entries = 0; var bytes: Int64 = 0 }

private func documentationCopy(source: Int32, destination: Int32, depth: Int, device: Int64, destinationDevice: Int64, merge: Bool, state: inout DocumentationCopyBudget) throws {
    try Task.checkCancellation()
    guard depth <= NotikaDocumentationTree.maximumDepth else { throw NotikaDocumentationDriverError.treeBoundExceeded }
    let before = try documentationStatus(source)
    try documentationSafeDirectory(before)
    guard before.st_dev == device else { throw NotikaDocumentationDriverError.unsafeArtifact }
    let targetDirectory = try documentationStatus(destination)
    try documentationSafeDirectory(targetDirectory)
    guard Int64(targetDirectory.st_dev) == destinationDevice else { throw NotikaDocumentationDriverError.unsafeArtifact }
    let names = try documentationNames(source)
    for name in names {
        state.entries += 1
        guard state.entries <= NotikaDocumentationTree.maximumEntries else { throw NotikaDocumentationDriverError.treeBoundExceeded }
        let observed = try documentationStatus(at: name, parent: source)
        guard Int64(observed.st_dev) == device else { throw NotikaDocumentationDriverError.unsafeArtifact }
        if observed.st_mode & S_IFMT == S_IFDIR {
            let input = try documentationOpenChild(name, parent: source, expected: observed, directory: true)
            let existing = try documentationStatusIfPresent(at: name, parent: destination)
            if let existing {
                guard merge else { throw NotikaDocumentationDriverError.unsafeArtifact }
                try documentationSafeDirectory(existing)
                guard Int64(existing.st_dev) == destinationDevice else { throw NotikaDocumentationDriverError.unsafeArtifact }
            } else if mkdirat(destination, name, 0o700) != 0 { throw documentationIO("create DocC snapshot directory") }
            let target = try documentationStatus(at: name, parent: destination)
            guard Int64(target.st_dev) == destinationDevice else { throw NotikaDocumentationDriverError.unsafeArtifact }
            let output = try documentationOpenChild(name, parent: destination, expected: target, directory: true)
            guard fchmod(output.value, 0o700) == 0 else { throw documentationIO("make DocC directory private") }
            try documentationCopy(source: input.value, destination: output.value, depth: depth + 1, device: device, destinationDevice: destinationDevice, merge: merge, state: &state)
            try documentationCheckChild(name, parent: source, descriptor: input.value, expected: observed)
            guard fsync(output.value) == 0 else { throw documentationIO("sync DocC snapshot directory") }
        } else {
            let input = try documentationOpenChild(name, parent: source, expected: observed, directory: false)
            let existing = try documentationStatusIfPresent(at: name, parent: destination)
            if let existing {
                guard merge, Int64(existing.st_dev) == destinationDevice else { throw NotikaDocumentationDriverError.unsafeArtifact }
                try documentationSafeFile(existing)
            }
            let temporary = ".agentbuild-docc-" + UUID().uuidString
            let opened = openat(destination, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            guard opened >= 0 else { throw documentationIO("create DocC snapshot file") }
            let output = DocumentationDescriptor(opened), created = try documentationStatus(opened)
            var published = false
            defer {
                if !published, let current = try? documentationStatus(at: temporary, parent: destination),
                   current.st_dev == created.st_dev, current.st_ino == created.st_ino { _ = unlinkat(destination, temporary, 0) }
            }
            let copied = try documentationRead(input.value, expected: observed, maximum: NotikaDocumentationTree.maximumBytes - state.bytes) { data in
                try documentationWrite(data, descriptor: output.value)
            }
            state.bytes += copied.bytes
            try documentationCheckChild(name, parent: source, descriptor: input.value, expected: observed)
            guard fchmod(output.value, 0o600) == 0, fsync(output.value) == 0 else { throw documentationIO("sync DocC snapshot file") }
            if let existing {
                guard documentationSameFile(try documentationStatus(at: name, parent: destination), existing) else { throw NotikaDocumentationDriverError.artifactChanged }
                guard renameat(destination, temporary, destination, name) == 0 else { throw documentationIO("install retained DocC renderer file") }
            } else {
                guard renameatx_np(destination, temporary, destination, name, UInt32(RENAME_EXCL)) == 0 else { throw documentationIO("publish DocC snapshot file") }
            }
            published = true
            guard fsync(destination) == 0 else { throw documentationIO("sync DocC publication") }
        }
    }
    guard try documentationNames(source) == names, documentationSameFile(try documentationStatus(source), before) else {
        throw NotikaDocumentationDriverError.artifactChanged
    }
}

private func documentationOwnerOnly(_ directory: Int32, depth: Int, device: Int64, entries: inout Int) throws {
    guard depth <= NotikaDocumentationTree.maximumDepth else { throw NotikaDocumentationDriverError.treeBoundExceeded }
    for name in try documentationNames(directory) {
        entries += 1
        guard entries <= NotikaDocumentationTree.maximumEntries else { throw NotikaDocumentationDriverError.treeBoundExceeded }
        let observed = try documentationStatus(at: name, parent: directory)
        guard Int64(observed.st_dev) == device else { throw NotikaDocumentationDriverError.unsafeArtifact }
        let isDirectory = observed.st_mode & S_IFMT == S_IFDIR
        let child = try documentationOpenChild(name, parent: directory, expected: observed, directory: isDirectory)
        guard fchmod(child.value, isDirectory ? 0o700 : 0o600) == 0 else { throw documentationIO("make DocC site private") }
        if isDirectory { try documentationOwnerOnly(child.value, depth: depth + 1, device: device, entries: &entries) }
        let current = try documentationStatus(at: name, parent: directory), pinned = try documentationStatus(child.value)
        guard current.st_dev == pinned.st_dev, current.st_ino == pinned.st_ino else { throw NotikaDocumentationDriverError.artifactChanged }
    }
}

internal func documentationIO(_ operation: String) -> NotikaDocumentationDriverError { .artifactIO(operation, errno) }
internal func documentationStatus(_ descriptor: Int32) throws -> stat {
    var result = stat()
    guard fstat(descriptor, &result) == 0 else { throw documentationIO("stat DocC custody") }
    return result
}
internal func documentationStatus(at name: String, parent: Int32) throws -> stat {
    guard let result = try documentationStatusIfPresent(at: name, parent: parent) else { throw NotikaDocumentationDriverError.artifactIO("stat DocC entry", ENOENT) }
    return result
}
private func documentationStatusIfPresent(at name: String, parent: Int32) throws -> stat? {
    var result = stat()
    if fstatat(parent, name, &result, AT_SYMLINK_NOFOLLOW) == 0 { return result }
    if errno == ENOENT { return nil }
    throw documentationIO("stat DocC entry")
}
internal func documentationSameFile(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_uid == rhs.st_uid && lhs.st_gid == rhs.st_gid
        && lhs.st_mode == rhs.st_mode && lhs.st_nlink == rhs.st_nlink && lhs.st_size == rhs.st_size
        && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
        && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
}
private func documentationSafeDirectory(_ value: stat) throws {
    guard value.st_mode & S_IFMT == S_IFDIR, value.st_uid == geteuid(), value.st_mode & 0o7022 == 0 else {
        throw NotikaDocumentationDriverError.unsafeArtifact
    }
}
private func documentationSafeFile(_ value: stat) throws {
    guard value.st_mode & S_IFMT == S_IFREG, value.st_uid == geteuid(), value.st_mode & 0o7022 == 0,
          value.st_nlink == 1, value.st_size >= 0 else { throw NotikaDocumentationDriverError.unsafeArtifact }
}
private func documentationOpenChild(_ name: String, parent: Int32, expected: stat, directory: Bool) throws -> DocumentationDescriptor {
    if directory { try documentationSafeDirectory(expected) } else { try documentationSafeFile(expected) }
    let opened = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (directory ? O_DIRECTORY : 0))
    guard opened >= 0 else { throw documentationIO("open DocC entry") }
    let result = DocumentationDescriptor(opened)
    guard documentationSameFile(try documentationStatus(opened), expected) else { throw NotikaDocumentationDriverError.artifactChanged }
    return result
}
private func documentationCheckChild(_ name: String, parent: Int32, descriptor: Int32, expected: stat) throws {
    guard documentationSameFile(try documentationStatus(descriptor), expected),
          documentationSameFile(try documentationStatus(at: name, parent: parent), expected) else { throw NotikaDocumentationDriverError.artifactChanged }
}
internal func documentationSafeName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.utf8.contains(0)
}
private func documentationNames(_ directory: Int32) throws -> [String] {
    let scan = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard scan >= 0 else { throw documentationIO("open DocC scan") }
    guard let stream = fdopendir(scan) else { let failure = documentationIO("open DocC scan stream"); _ = close(scan); throw failure }
    defer { _ = closedir(stream) }
    var result: [String] = []
    while true {
        errno = 0
        guard let entry = readdir(stream) else { guard errno == 0 else { throw documentationIO("read DocC scan") }; break }
        var name = entry.pointee.d_name
        let decoded = withUnsafeBytes(of: &name) { raw -> String? in
            guard let end = raw.firstIndex(of: 0) else { return nil }
            return String(bytes: raw.prefix(end), encoding: .utf8)
        }
        guard let decoded else { throw NotikaDocumentationDriverError.unsafeArtifact }
        if decoded == "." || decoded == ".." { continue }
        guard documentationSafeName(decoded), result.count < NotikaDocumentationTree.maximumEntries else { throw NotikaDocumentationDriverError.treeBoundExceeded }
        result.append(decoded)
    }
    return result.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
}
private func documentationRead(_ descriptor: Int32, expected: stat, maximum: Int64, checkCancellation: Bool = true,
    consume: (Data) throws -> Void = { _ in }) throws -> (bytes: Int64, digest: String) {
    guard expected.st_size <= maximum, maximum >= 0 else { throw NotikaDocumentationDriverError.treeBoundExceeded }
    let bufferSize = Int(min(Int64(128 * 1_024), max(1, expected.st_size)))
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    var total: Int64 = 0
    var hash = SHA256()
    while true {
        if checkCancellation { try Task.checkCancellation() }
        let count = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress!, $0.count, off_t(total)) }
        if count < 0, errno == EINTR { continue }
        guard count >= 0 else { throw documentationIO("read DocC file") }
        if count == 0 { break }
        guard Int64(count) <= maximum - total else { throw NotikaDocumentationDriverError.treeBoundExceeded }
        guard Int64(count) <= expected.st_size - total else { throw NotikaDocumentationDriverError.artifactChanged }
        let data = Data(buffer.prefix(count))
        hash.update(data: data); try consume(data); total += Int64(count)
    }
    guard total == expected.st_size, documentationSameFile(try documentationStatus(descriptor), expected) else { throw NotikaDocumentationDriverError.artifactChanged }
    return (total, documentationHex(hash.finalize()))
}
internal func documentationWrite(_ data: Data, descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw documentationIO("write DocC bytes") }
            offset += count
        }
    }
}
internal func documentationHex(_ value: SHA256.Digest) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var bytes = [UInt8](repeating: 0, count: 64)
    var offset = 0
    for byte in value {
        bytes[offset] = digits[Int(byte >> 4)]
        bytes[offset + 1] = digits[Int(byte & 0x0f)]
        offset += 2
    }
    return String(decoding: bytes, as: UTF8.self)
}
