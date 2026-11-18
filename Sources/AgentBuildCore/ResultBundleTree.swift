import CryptoKit
import Darwin
import Foundation

public struct ResultNodeIdentity: Equatable, Sendable {
    public let device: Int64
    public let inode: UInt64
    public let size: Int64
    public let mode: UInt16
    public let owner: UInt32
    package let group: UInt32
    public let links: UInt64
    package let modifiedSeconds: Int64
    package let modifiedNanoseconds: Int64
    package let changedSeconds: Int64
    package let changedNanoseconds: Int64
    package let flags: UInt32
    package let generation: UInt32
    package let birthSeconds: Int64
    package let birthNanoseconds: Int64

    public init(_ status: stat) {
        device = Int64(status.st_dev); inode = UInt64(status.st_ino); size = Int64(status.st_size)
        mode = UInt16(status.st_mode); owner = UInt32(status.st_uid); group = UInt32(status.st_gid)
        links = UInt64(status.st_nlink)
        modifiedSeconds = Int64(status.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
        changedSeconds = Int64(status.st_ctimespec.tv_sec); changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
        flags = status.st_flags; generation = status.st_gen
        birthSeconds = Int64(status.st_birthtimespec.tv_sec); birthNanoseconds = Int64(status.st_birthtimespec.tv_nsec)
    }

    public var directory: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFDIR) }
    public var regular: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFREG) }
    public var safe: Bool { owner == UInt32(geteuid()) && mode & 0o7022 == 0 && (directory || (regular && links == 1)) }

    public func sameDirectoryBinding(_ other: Self) -> Bool {
        directory && other.directory && device == other.device && inode == other.inode
            && mode == other.mode && owner == other.owner && group == other.group
    }
}

/// Watch descriptors remain open through terminal sealing. Events are sticky;
/// replacing bytes and restoring them cannot erase a recorded mutation.
public final class ResultMutationWatch {
    package let descriptor: Int32
    private var failure: ResultBundleFailure?
    private var labels: [UInt: String] = [:]
    private var retainedNodes: [RetainedResultNode] = []
    private var allowsRootSQLitePreparation = false

    /// Only retained trees opt in. Other users keep strict vnode admission.
    fileprivate func admitAccessTimeNotifications(
        nodes: [RetainedResultNode], allowsRootSQLitePreparation: Bool
    ) {
        retainedNodes = nodes
        self.allowsRootSQLitePreparation = allowsRootSQLitePreparation
    }

    public init() throws {
        let queue = kqueue()
        guard queue >= 0 else { throw resultFailure("create result watch") }
        guard fcntl(queue, F_SETFD, FD_CLOEXEC) == 0 else {
            let failure = resultFailure("result watch close-on-exec")
            _ = Darwin.close(queue)
            throw failure
        }
        descriptor = queue
    }

    deinit { _ = Darwin.close(descriptor) }

    public func arm(_ file: Int32, writes: Bool, label: String? = nil) throws {
        var event = kevent()
        event.ident = UInt(file)
        event.filter = Int16(EVFILT_VNODE)
        event.flags = UInt16(EV_ADD | EV_ENABLE | EV_CLEAR)
        event.fflags = UInt32(NOTE_DELETE | NOTE_RENAME | NOTE_ATTRIB | NOTE_REVOKE)
        if writes { event.fflags |= UInt32(NOTE_LINK | NOTE_WRITE | NOTE_EXTEND) }
        guard resultKevent(descriptor, &event, 1, nil, 0, nil) >= 0 else { throw resultFailure("arm result watch") }
        if let label { labels[event.ident] = label }
    }

    public func check() throws {
        if let failure { throw failure }
        while true {
            var event = kevent()
            var timeout = timespec(tv_sec: 0, tv_nsec: 0)
            var count: Int32
            repeat { count = resultKevent(descriptor, nil, 0, &event, 1, &timeout) } while count < 0 && errno == EINTR
            if count < 0 {
                let failure = resultFailure("poll result watch")
                self.failure = failure
                throw failure
            }
            guard count > 0 else { return }
            if event.flags & UInt16(EV_ERROR) == 0, event.fflags == UInt32(NOTE_ATTRIB),
               retainedNodes.contains(where: { UInt($0.descriptor) == event.ident && $0.identity.regular }) {
                do {
                    // Darwin access-time-only setattrlist emits NOTE_ATTRIB
                    // without changing ctime. Freeze every other identity field
                    // and every pinned name; restored chmod still changes ctime.
                    try ResultBundleTree.validateBindings(retainedNodes,
                        allowsRootSQLitePreparation: allowsRootSQLitePreparation)
                } catch let failure as ResultBundleFailure {
                    self.failure = failure
                    throw failure
                }
                continue
            }
            let failure = ResultBundleFailure(operation: "result artifact mutated", code: ESTALE,
                detail: "vnode event \(event.fflags) on \(labels[event.ident] ?? "descriptor \(event.ident)")")
            self.failure = failure
            throw failure
        }
    }
}

struct RetainedResultNode {
    let path: String
    let descriptor: Int32
    let parent: Int32
    let name: String
    let identity: ResultNodeIdentity
    let sha256: String?
}

public struct ResultTreeRecord: Codable, Equatable, Sendable {
    public let path: String
    public let type: String
    public let device: Int64
    public let inode: UInt64
    public let mode: UInt16
    public let owner: UInt32
    public let bytes: Int64
    public let sha256: String?
}

/// A deliberately bounded ordinary-test bundle. Refusing an oversized tree is
/// an evidence failure, never permission to publish unchecked content.
public final class ResultBundleTree {
    public static let maximumEntries = 4_096
    public static let maximumBytes: Int64 = 1_024 * 1_024 * 1_024
    // Index preparation retains the original tree while sealing the final one.
    // This is capacity, not a reservation against unrelated descriptor users.
    public static let minimumDescriptorLimit: rlim_t = rlim_t(2 * maximumEntries + 256)
    private static let descriptorLimitLock = NSLock()
    public let root: Int32
    public let watch: ResultMutationWatch
    public let commitment: String
    public let byteCount: Int64
    private let nodes: [RetainedResultNode]
    private let allowsRootSQLitePreparation: Bool

    public static func descriptorLimitPlan(_ current: rlimit) throws -> rlimit {
        guard current.rlim_cur <= current.rlim_max else {
            throw ResultBundleFailure(operation: "invalid result descriptor limit", code: EINVAL)
        }
        guard current.rlim_max >= minimumDescriptorLimit else {
            throw ResultBundleFailure(operation: "result descriptor budget unavailable", code: EMFILE,
                                            detail: "requires \(minimumDescriptorLimit); hard limit \(current.rlim_max)")
        }
        return rlimit(rlim_cur: max(current.rlim_cur, minimumDescriptorLimit), rlim_max: current.rlim_max)
    }

    public static func ensureDescriptorBudget() throws {
        descriptorLimitLock.lock()
        defer { descriptorLimitLock.unlock() }
        var current = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &current) == 0 else {
            throw resultFailure("read result descriptor limit")
        }
        var requested = try descriptorLimitPlan(current)
        if requested.rlim_cur > current.rlim_cur {
            guard setrlimit(RLIMIT_NOFILE, &requested) == 0 else {
                throw resultFailure("raise result descriptor limit")
            }
        }
        var observed = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &observed) == 0 else {
            throw resultFailure("verify result descriptor limit")
        }
        guard observed.rlim_cur >= minimumDescriptorLimit, observed.rlim_max == current.rlim_max else {
            throw ResultBundleFailure(operation: "result descriptor limit changed", code: ESTALE)
        }
    }

    public var records: [ResultTreeRecord] {
        nodes.map { .init(path: $0.path, type: $0.identity.directory ? "directory" : "file",
                          device: $0.identity.device, inode: $0.identity.inode,
                          mode: $0.identity.mode, owner: $0.identity.owner,
                          bytes: $0.identity.regular ? $0.identity.size : 0, sha256: $0.sha256) }
    }

    public init(parent: Int32, name: String, maximumBytes: Int64 = ResultBundleTree.maximumBytes,
         maximumEntries: Int = ResultBundleTree.maximumEntries, privatePermissions: Bool = false,
         requiredFilePermissions: UInt16? = nil, requiredRootFile: String? = nil,
         allowsRootSQLitePreparation: Bool = false) throws {
        guard maximumBytes >= 0, maximumEntries > 0, maximumEntries <= Self.maximumEntries,
              requiredFilePermissions == nil || [UInt16(0o400), UInt16(0o600)].contains(requiredFilePermissions!) else {
            throw ResultBundleFailure(operation: "invalid result tree policy", code: EINVAL)
        }
        let watch = try ResultMutationWatch()
        var nodes: [RetainedResultNode] = []
        var byteCount: Int64 = 0
        do {
            try Self.admit(parent: parent, name: name, relative: ".", depth: 0,
                           nodes: &nodes, byteCount: &byteCount, watch: watch,
                           maximumBytes: maximumBytes, maximumEntries: maximumEntries,
                           privatePermissions: privatePermissions, requiredFilePermissions: requiredFilePermissions,
                           allowsRootSQLitePreparation: allowsRootSQLitePreparation)
            if let requiredRootFile {
                guard !requiredRootFile.isEmpty, !requiredRootFile.contains("/"),
                      requiredRootFile != ".", requiredRootFile != "..",
                      nodes.contains(where: { $0.path == requiredRootFile && $0.identity.regular && $0.identity.size > 0 }) else {
                    throw ResultBundleFailure(operation: "required result tree file missing", code: EINVAL,
                                                     detail: requiredRootFile)
                }
            }
            watch.admitAccessTimeNotifications(nodes: nodes, allowsRootSQLitePreparation: allowsRootSQLitePreparation)
            try watch.check()
            let digest = try Self.digest(nodes)
            self.root = nodes[0].descriptor
            self.watch = watch
            self.nodes = nodes
            self.byteCount = byteCount
            self.allowsRootSQLitePreparation = allowsRootSQLitePreparation
            commitment = digest
        } catch {
            for node in nodes.reversed() { _ = Darwin.close(node.descriptor) }
            throw error
        }
    }

    deinit { for node in nodes.reversed() { _ = Darwin.close(node.descriptor) } }

    public func revalidate() throws {
        try watch.check()
        try Self.validateBindings(nodes, allowsRootSQLitePreparation: allowsRootSQLitePreparation)
        for node in nodes {
            if let digest = node.sha256,
               try Self.hashFile(node.descriptor, identity: node.identity) != digest {
                throw ResultBundleFailure(operation: "result content changed", code: ESTALE, detail: node.path)
            }
        }
        try watch.check()
    }

    fileprivate static func validateBindings(
        _ nodes: [RetainedResultNode], allowsRootSQLitePreparation: Bool
    ) throws {
        for node in nodes {
            let status = try resultDescriptorIdentity(node.descriptor)
            let entry = try resultEntryIdentity(node.parent, node.name)
            let unchanged = node.path == "." && allowsRootSQLitePreparation
                ? node.identity.sameDirectoryBinding(status) && node.identity.sameDirectoryBinding(entry)
                : status == node.identity && entry == node.identity
            guard unchanged else {
                throw ResultBundleFailure(operation: "result entry changed", code: ESTALE, detail: node.path)
            }
        }
    }

    /// xcresulttool creates its SQLite index on its first read. During that
    /// one authenticated preparation phase only fixed root cache entries may
    /// appear; every original file and descendant directory remains immutable.
    public func validateSQLitePreparation() throws {
        guard allowsRootSQLitePreparation else {
            throw ResultBundleFailure(operation: "result indexing not admitted", code: EINVAL)
        }
        try revalidate()
        let original = Set(nodes.filter { $0.path != "." && !$0.path.contains("/") }.map(\.path))
        let current = Set(try Self.directoryNames(root, maximumEntries: Self.maximumEntries))
        let additions = current.subtracting(original)
        guard original.isSubset(of: current),
              additions.isSubset(of: ["database.sqlite3", "database.sqlite3-shm", "database.sqlite3-wal"]) else {
            throw ResultBundleFailure(operation: "unexpected result indexing entry", code: EPROTO)
        }
        for name in additions {
            let entry = try resultEntryIdentity(root, name)
            guard entry.regular, entry.safe, entry.size >= 0, entry.size <= Self.maximumBytes else {
                throw ResultBundleFailure(operation: "unsafe result index", code: EINVAL, detail: name)
            }
        }
        try revalidate()
    }

    public func readFile(relativePath: String, maximumBytes: Int64) throws -> Data {
        try revalidate()
        guard maximumBytes >= 0, let node = nodes.first(where: { $0.path.utf8.elementsEqual(relativePath.utf8) }),
              node.identity.regular, node.identity.size <= maximumBytes else {
            throw ResultBundleFailure(operation: "invalid retained result file", code: EINVAL, detail: relativePath)
        }
        var data = Data(count: Int(node.identity.size))
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeMutableBytes {
                pread(node.descriptor, $0.baseAddress!.advanced(by: offset), $0.count - offset, off_t(offset))
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw resultFailure("read retained result file", code: count < 0 ? errno : EIO) }
            offset += count
        }
        guard CanonicalJSONDigest.digest(data) == node.sha256 else {
            throw ResultBundleFailure(operation: "retained result file changed", code: ESTALE)
        }
        try revalidate()
        return data
    }

    private static func admit(parent: Int32, name: String, relative: String, depth: Int,
                              nodes: inout [RetainedResultNode], byteCount: inout Int64,
                              watch: ResultMutationWatch, maximumBytes: Int64, maximumEntries: Int,
                              privatePermissions: Bool, requiredFilePermissions: UInt16?,
                              allowsRootSQLitePreparation: Bool) throws {
        guard depth <= 64, nodes.count < maximumEntries else {
            throw ResultBundleFailure(operation: "result tree entry limit", code: EFBIG)
        }
        let entry = try resultEntryIdentity(parent, name)
        let privateMode = entry.mode & 0o7777
        guard entry.safe, relative != "." || entry.directory,
              !privatePermissions || (entry.directory ? privateMode == 0o700 : [0o400, 0o600].contains(privateMode)),
              !entry.regular || requiredFilePermissions == nil || privateMode == requiredFilePermissions else {
            throw ResultBundleFailure(operation: "unsafe result entry", code: EINVAL, detail: relative)
        }
        let descriptor = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC | (entry.directory ? O_DIRECTORY : 0))
        guard descriptor >= 0 else { throw resultFailure("open result entry", detail: relative) }
        var transferred = false
        defer { if !transferred { _ = Darwin.close(descriptor) } }
        let identity = try resultDescriptorIdentity(descriptor)
        guard identity == entry else { throw ResultBundleFailure(operation: "result admission changed", code: ESTALE) }
        try watch.arm(descriptor, writes: !(relative == "." && allowsRootSQLitePreparation), label: relative)
        let hash: String?
        if identity.regular {
            let sum = byteCount.addingReportingOverflow(identity.size)
            guard identity.size >= 0, !sum.overflow, sum.partialValue <= maximumBytes else {
                throw ResultBundleFailure(operation: "result tree byte limit", code: EFBIG)
            }
            byteCount = sum.partialValue
            hash = try hashFile(descriptor, identity: identity)
        } else { hash = nil }
        nodes.append(RetainedResultNode(path: relative, descriptor: descriptor, parent: parent,
                                        name: name, identity: identity, sha256: hash))
        transferred = true
        if identity.directory {
            for child in try directoryNames(descriptor, maximumEntries: maximumEntries) {
                try admit(parent: descriptor, name: child, relative: relative == "." ? child : relative + "/" + child,
                          depth: depth + 1, nodes: &nodes, byteCount: &byteCount, watch: watch,
                          maximumBytes: maximumBytes, maximumEntries: maximumEntries,
                          privatePermissions: privatePermissions, requiredFilePermissions: requiredFilePermissions,
                          allowsRootSQLitePreparation: allowsRootSQLitePreparation)
            }
        }
        guard try resultDescriptorIdentity(descriptor) == identity,
              try resultEntryIdentity(parent, name) == identity else {
            throw ResultBundleFailure(operation: "result changed during admission", code: ESTALE)
        }
    }

    private static func directoryNames(_ descriptor: Int32, maximumEntries: Int) throws -> [String] {
        let copy = fcntl(descriptor, F_DUPFD_CLOEXEC, 3)
        guard copy >= 3 else { throw resultFailure("duplicate result enumeration") }
        guard let stream = fdopendir(copy) else {
            let error = resultFailure("open result enumeration")
            _ = Darwin.close(copy)
            throw error
        }
        defer { _ = closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw resultFailure("read result enumeration") }
                break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(validatingCString: $0)
                }
            }
            guard let name else { throw ResultBundleFailure(operation: "invalid result entry name", code: EILSEQ) }
            if name == "." || name == ".." { continue }
            guard names.count < maximumEntries else { throw ResultBundleFailure(operation: "result tree entry limit", code: EFBIG) }
            names.append(name)
        }
        return names.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    private static func hashFile(_ descriptor: Int32, identity: ResultNodeIdentity) throws -> String {
        var hash = SHA256()
        var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
        var offset: Int64 = 0
        while offset < identity.size {
            let requested = Int(min(Int64(bytes.count), identity.size - offset))
            let count = bytes.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, requested, off_t(offset)) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw resultFailure("read result content", code: count < 0 ? errno : EIO) }
            hash.update(data: Data(bytes.prefix(count)))
            offset += Int64(count)
        }
        guard try resultDescriptorIdentity(descriptor) == identity else {
            throw ResultBundleFailure(operation: "result changed during read", code: ESTALE)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func digest(_ nodes: [RetainedResultNode]) throws -> String {
        try CanonicalJSONDigest.sha256(.array(nodes.map { node in
            .object(["path": .string(node.path), "device": .integer(node.identity.device),
                     "inode": .unsignedInteger(node.identity.inode), "mode": .integer(Int64(node.identity.mode)),
                     "owner": .integer(Int64(node.identity.owner)), "size": .integer(node.identity.size),
                     "sha256": node.sha256.map(CanonicalJSONValue.string) ?? .null])
        }))
    }
}

public func resultDescriptorIdentity(_ descriptor: Int32) throws -> ResultNodeIdentity {
    var status = stat()
    guard fstat(descriptor, &status) == 0 else { throw resultFailure("stat retained result") }
    return ResultNodeIdentity(status)
}

public func resultEntryIdentity(_ parent: Int32, _ name: String) throws -> ResultNodeIdentity {
    var status = stat()
    guard fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { throw resultFailure("stat result entry", detail: name) }
    return ResultNodeIdentity(status)
}

public func resultFailure(_ operation: String, code: Int32? = nil, detail: String? = nil) -> ResultBundleFailure {
    ResultBundleFailure(operation: operation, code: code ?? errno, detail: detail)
}

@_silgen_name("kevent")
private func resultKevent(_ descriptor: Int32, _ changes: UnsafePointer<kevent>?, _ changeCount: Int32,
                          _ events: UnsafeMutablePointer<kevent>?, _ eventCount: Int32,
                          _ timeout: UnsafePointer<timespec>?) -> Int32
