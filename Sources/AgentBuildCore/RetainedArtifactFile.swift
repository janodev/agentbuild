import Darwin
import Foundation

public enum RetainedArtifactError: Error, Equatable, Sendable {
    case invalidPath
    case invalidPolicy
    case unsafeDirectory
    case unsafeFile
    case directoryChanged
    case fileChanged
    case truncated
    case grew
    case closed
    case systemCall(String, Int32)
}

/// Times retain their separate seconds/nanoseconds fields without a potentially
/// overflowing conversion to a single epoch-nanosecond integer.
public struct ArtifactFileFingerprint: Equatable, Sendable {
    public let device: Int64
    public let inode: UInt64
    public let size: Int64
    public let mode: UInt16
    public let owner: UInt32
    public let group: UInt32
    public let linkCount: UInt64
    public let modificationSeconds: Int64
    public let modificationNanoseconds: Int64
    public let changeSeconds: Int64
    public let changeNanoseconds: Int64

    fileprivate init(_ metadata: stat) {
        device = Int64(metadata.st_dev)
        inode = UInt64(metadata.st_ino)
        size = Int64(metadata.st_size)
        mode = UInt16(metadata.st_mode)
        owner = UInt32(metadata.st_uid)
        group = UInt32(metadata.st_gid)
        linkCount = UInt64(metadata.st_nlink)
        modificationSeconds = Int64(metadata.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
        changeSeconds = Int64(metadata.st_ctimespec.tv_sec)
        changeNanoseconds = Int64(metadata.st_ctimespec.tv_nsec)
    }

    fileprivate func sameDirectoryBinding(as other: Self) -> Bool {
        device == other.device && inode == other.inode && mode == other.mode
            && owner == other.owner && group == other.group
    }
}

/// Single-link, effective-user-owned regular files are the only admitted files.
/// Exact permissions may be 0600 for mutable metadata or 0400 for sealed JSON.
/// Empty files are valid at this generic layer; JSON/schema admission is separate.
public struct ArtifactFilePolicy: Equatable, Sendable {
    public static let standard = Self(minimum: 0, maximum: 256 * 1_024, permissions: 0o600)
    public let minimumBytes: Int
    public let maximumBytes: Int
    public let requiredPermissions: UInt16

    public init(
        minimumBytes: Int = 0,
        maximumBytes: Int = 256 * 1_024,
        requiredPermissions: UInt16 = 0o600
    ) throws {
        guard (1...(16 * 1_024 * 1_024)).contains(maximumBytes),
              (0...maximumBytes).contains(minimumBytes),
              requiredPermissions & 0o400 != 0,
              requiredPermissions & 0o7022 == 0,
              requiredPermissions <= 0o777 else {
            throw RetainedArtifactError.invalidPolicy
        }
        self.init(minimum: minimumBytes, maximum: maximumBytes, permissions: requiredPermissions)
    }

    private init(minimum: Int, maximum: Int, permissions: UInt16) {
        minimumBytes = minimum
        maximumBytes = maximum
        requiredPermissions = permissions
    }

    fileprivate func validate(_ metadata: ArtifactFileFingerprint) throws {
        guard metadata.mode & UInt16(S_IFMT) == UInt16(S_IFREG),
              metadata.owner == UInt32(geteuid()), metadata.linkCount == 1,
              metadata.mode & 0o7777 == requiredPermissions,
              metadata.size >= Int64(minimumBytes), metadata.size <= Int64(maximumBytes) else {
            throw RetainedArtifactError.unsafeFile
        }
    }
}

/// Holds every directory edge from the filesystem root through an already
/// selected absolute path. No component is followed through a symbolic link.
/// The final directory must be owned by the effective user and cannot be
/// writable by group/other. Ancestor paths are caller-selected trusted roots.
///
/// Directory entry churn does not freeze size/mtime: only inode, owner, group,
/// and mode bind directory custody. Revalidation detects current rename/path
/// replacement, but this capability does not claim a continuous vnode watch.
public final class RetainedArtifactDirectory: @unchecked Sendable {
    public let path: String
    public let fingerprint: ArtifactFileFingerprint
    private let lock = NSLock()
    private var links: [RetainedDirectoryLink]

    public init(path: String, requiredPermissions: UInt16? = nil) throws {
        let components = try artifactAbsoluteComponents(path)
        if let requiredPermissions {
            guard requiredPermissions <= 0o777, requiredPermissions & 0o500 == 0o500,
                  requiredPermissions & 0o022 == 0 else { throw RetainedArtifactError.invalidPolicy }
        }
        var opened: [RetainedDirectoryLink] = []
        var transferred = false
        defer {
            if !transferred {
                for entry in opened.reversed() { _ = Darwin.close(entry.descriptor) }
            }
        }
        let root = Darwin.open("/", artifactDirectoryFlags)
        guard root >= 0 else { throw artifactSystemError("open root") }
        do {
            opened.append(RetainedDirectoryLink(name: nil, descriptor: root,
                                               fingerprint: try artifactDescriptorMetadata(root)))
        } catch {
            _ = Darwin.close(root)
            throw error
        }
        for component in components {
            let parent = opened[opened.count - 1].descriptor
            let observed = try artifactEntryMetadata(parent, name: component)
            guard observed.mode & UInt16(S_IFMT) == UInt16(S_IFDIR) else {
                throw RetainedArtifactError.unsafeDirectory
            }
            let child = Darwin.openat(parent, component, artifactDirectoryFlags)
            guard child >= 0 else { throw artifactSystemError("open directory") }
            var childTransferred = false
            defer { if !childTransferred { _ = Darwin.close(child) } }
            let admitted = try artifactDescriptorMetadata(child)
            guard admitted.sameDirectoryBinding(as: observed) else {
                throw RetainedArtifactError.directoryChanged
            }
            opened.append(RetainedDirectoryLink(name: component, descriptor: child, fingerprint: admitted))
            childTransferred = true
        }
        guard let final = opened.last,
              final.fingerprint.owner == UInt32(geteuid()),
              final.fingerprint.mode & 0o7022 == 0,
              requiredPermissions.map({ final.fingerprint.mode & 0o7777 == $0 }) ?? true else {
            throw RetainedArtifactError.unsafeDirectory
        }
        try artifactValidateDirectoryLinks(opened)
        self.path = path
        fingerprint = final.fingerprint
        links = opened
        transferred = true
    }

    deinit { try? close() }

    public func openFile(named name: String, policy: ArtifactFilePolicy = .standard) throws -> RetainedArtifactFile {
        try RetainedArtifactFile(directory: self, name: name, policy: policy)
    }

    public func revalidate() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !links.isEmpty else { throw RetainedArtifactError.closed }
        try artifactValidateDirectoryLinks(links)
    }

    /// Ownership is emptied before the first close. A close error is ambiguous
    /// and never triggers a retry with a potentially recycled descriptor number.
    public func close() throws {
        lock.lock()
        defer { lock.unlock() }
        let retired = links
        links.removeAll()
        var failure: RetainedArtifactError?
        for entry in retired.reversed() where Darwin.close(entry.descriptor) != 0 {
            if failure == nil { failure = artifactSystemError("close directory") }
        }
        if let failure { throw failure }
    }

    fileprivate func withDirectory<T>(_ body: (Int32) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let directory = links.last else { throw RetainedArtifactError.closed }
        try artifactValidateDirectoryLinks(links)
        return try body(directory.descriptor)
    }

    fileprivate func revalidateLocked() throws {
        try artifactValidateDirectoryLinks(links)
    }
}

/// Read-only retained inode custody. All mutable descriptor ownership is
/// protected by locks; descriptors never escape this capability. The parent
/// directory stays retained and is checked alongside the file's entry.
public final class RetainedArtifactFile: @unchecked Sendable {
    public let name: String
    public let path: String
    public let fingerprint: ArtifactFileFingerprint
    public let policy: ArtifactFilePolicy
    private let directory: RetainedArtifactDirectory
    private let lock = NSLock()
    private var descriptor: Int32?

    public init(directory: RetainedArtifactDirectory, name: String, policy: ArtifactFilePolicy = .standard) throws {
        try artifactRequireDirectName(name)
        var ownedDescriptor: Int32?
        do {
            fingerprint = try directory.withDirectory { parent in
                let observed = try artifactEntryMetadata(parent, name: name)
                try policy.validate(observed)
                let opened = Darwin.openat(parent, name, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
                guard opened >= 0 else { throw artifactSystemError("open file") }
                ownedDescriptor = opened
                let admitted = try artifactDescriptorMetadata(opened)
                try policy.validate(admitted)
                guard admitted == observed else { throw RetainedArtifactError.fileChanged }
                try directory.revalidateLocked()
                guard try artifactEntryMetadata(parent, name: name) == admitted else {
                    throw RetainedArtifactError.fileChanged
                }
                return admitted
            }
        } catch {
            if let ownedDescriptor { _ = Darwin.close(ownedDescriptor) }
            throw error
        }
        self.directory = directory
        self.name = name
        self.policy = policy
        path = directory.path + (directory.path == "/" ? "" : "/") + name
        descriptor = ownedDescriptor
    }

    public convenience init(
        path: String,
        policy: ArtifactFilePolicy = .standard,
        directoryPermissions: UInt16? = nil
    ) throws {
        let components = try artifactAbsoluteComponents(path)
        guard let name = components.last else { throw RetainedArtifactError.invalidPath }
        let parent = components.dropLast().isEmpty ? "/" : "/" + components.dropLast().joined(separator: "/")
        try self.init(directory: RetainedArtifactDirectory(path: parent, requiredPermissions: directoryPermissions),
                      name: name, policy: policy)
    }

    deinit { try? close() }

    public func readBounded() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let descriptor else { throw RetainedArtifactError.closed }
        return try directory.withDirectory { parent in
            try validate(descriptor: descriptor, parent: parent)
            let expectedSize = Int(fingerprint.size)
            var encoded = Data()
            encoded.reserveCapacity(expectedSize)
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            while encoded.count < expectedSize {
                let maximum = min(buffer.count, expectedSize - encoded.count)
                let count = try buffer.withUnsafeMutableBytes {
                    try artifactRead(descriptor, buffer: $0.baseAddress, count: maximum, offset: encoded.count)
                }
                guard count > 0 else { throw RetainedArtifactError.truncated }
                encoded.append(contentsOf: buffer.prefix(count))
            }
            var extra: UInt8 = 0
            let trailing = try withUnsafeMutablePointer(to: &extra) {
                try artifactRead(descriptor, buffer: UnsafeMutableRawPointer($0), count: 1, offset: expectedSize)
            }
            guard trailing == 0 else { throw RetainedArtifactError.grew }
            try validate(descriptor: descriptor, parent: parent)
            try directory.revalidateLocked()
            return encoded
        }
    }

    public func readJSON(limits: StrictJSONLimits = .standard) throws -> StrictJSONDocument {
        let document = try StrictJSONDocument(data: readBounded(), limits: limits)
        try revalidate()
        return document
    }

    public func revalidate() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let descriptor else { throw RetainedArtifactError.closed }
        try directory.withDirectory { parent in
            try validate(descriptor: descriptor, parent: parent)
            try directory.revalidateLocked()
        }
    }

    /// A gate for an independently owned mutation operation; it does not grant
    /// pathname-based mutation authority or itself perform any mutation.
    public func revalidateBeforeMutation() throws {
        try revalidate()
    }

    public func close() throws {
        lock.lock()
        defer { lock.unlock() }
        let retired = descriptor
        descriptor = nil
        if let retired, Darwin.close(retired) != 0 { throw artifactSystemError("close file") }
    }

    private func validate(descriptor: Int32, parent: Int32) throws {
        let current = try artifactDescriptorMetadata(descriptor)
        let entry = try artifactEntryMetadata(parent, name: name)
        try policy.validate(current)
        try policy.validate(entry)
        guard current == fingerprint, entry == fingerprint else { throw RetainedArtifactError.fileChanged }
    }
}

private struct RetainedDirectoryLink {
    let name: String?
    let descriptor: Int32
    let fingerprint: ArtifactFileFingerprint
}

private let artifactDirectoryFlags = O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_DIRECTORY | O_NOFOLLOW

private func artifactAbsoluteComponents(_ path: String) throws -> [String] {
    guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw RetainedArtifactError.invalidPath }
    if path == "/" { return [] }
    let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
        throw RetainedArtifactError.invalidPath
    }
    return components
}

private func artifactRequireDirectName(_ name: String) throws {
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else {
        throw RetainedArtifactError.invalidPath
    }
}

private func artifactDescriptorMetadata(_ descriptor: Int32) throws -> ArtifactFileFingerprint {
    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0 else { throw artifactSystemError("fstat") }
    return ArtifactFileFingerprint(metadata)
}

private func artifactEntryMetadata(_ parent: Int32, name: String) throws -> ArtifactFileFingerprint {
    var metadata = stat()
    guard Darwin.fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw artifactSystemError("fstatat")
    }
    return ArtifactFileFingerprint(metadata)
}

private func artifactValidateDirectoryLinks(_ links: [RetainedDirectoryLink]) throws {
    guard !links.isEmpty else { throw RetainedArtifactError.closed }
    for (index, link) in links.enumerated() {
        let retained = try artifactDescriptorMetadata(link.descriptor)
        guard retained.mode & UInt16(S_IFMT) == UInt16(S_IFDIR),
              retained.sameDirectoryBinding(as: link.fingerprint) else {
            throw RetainedArtifactError.directoryChanged
        }
        if let name = link.name {
            let entry = try artifactEntryMetadata(links[index - 1].descriptor, name: name)
            guard entry.sameDirectoryBinding(as: link.fingerprint) else {
                throw RetainedArtifactError.directoryChanged
            }
        }
    }
}

private func artifactRead(_ descriptor: Int32, buffer: UnsafeMutableRawPointer?, count: Int, offset: Int) throws -> Int {
    while true {
        let result = Darwin.pread(descriptor, buffer, count, off_t(offset))
        if result >= 0 { return result }
        if errno != EINTR { throw artifactSystemError("pread") }
    }
}

private func artifactSystemError(_ operation: String) -> RetainedArtifactError {
    .systemCall(operation, errno)
}
