import Darwin
import Foundation

/// Regular-file activity for one completed reconciliation.
public struct BuildSlotSyncSummary: Sendable {
    public fileprivate(set) var clonedFiles = 0
    public fileprivate(set) var copiedFiles = 0
    public fileprivate(set) var unchangedFiles = 0
}

/// A source-only mirror. Reconcile against the actual destination so a later
/// lease holder can finish an interrupted sync without trusting a journal.
struct BuildSlotMirror {
    let device: Int64
    let worktree: String
    let symlinkPolicy: BuildSlotSymlinkPolicy
    private var linksToValidate: [String] = []
    private var latestAdvancedSecond: Int?

    private(set) var summary = BuildSlotSyncSummary()

    init(device: Int64, worktree: String, symlinkPolicy: BuildSlotSymlinkPolicy) {
        self.device = device
        self.worktree = worktree
        self.symlinkPolicy = symlinkPolicy
    }

    mutating func sync(from source: Int32, to target: Int32, prefix: String,
                       including: (String) throws -> Bool) throws {
        try Task.checkCancellation()
        let before = try fingerprint(source)
        let names = try directoryNames(source).filter { name in
            guard name.lowercased() != ".git" else { return false }
            return try including(prefix + name)
        }
        let desired = Set(names.map { Data($0.utf8) })
        for name in try directoryNames(target) where !desired.contains(Data(name.utf8)) {
            try remove(name, from: target)
        }
        for name in names {
            try Task.checkCancellation()
            let path = prefix + name
            let input = try requiredEntry(name, at: source)
            let kind = input.mode & S_IFMT
            let existing = try Self.prepareEntry(name, at: target, device: device)
            if let existing, existing.mode & S_IFMT != kind {
                try remove(name, from: target)
            }
            switch kind {
            case S_IFDIR:
                if existing.map({ $0.mode & S_IFMT }) != S_IFDIR {
                    guard mkdirat(target, name, 0o700) == 0 else { throw systemError("mkdir " + path) }
                }
                try withDirectory(source, name) { child in
                    try withDirectory(target, name) { destination in
                        try sync(from: child, to: destination, prefix: path + "/", including: including)
                    }
                }
            case S_IFREG:
                try syncFile(name, source: source, target: target, input: input, existing: existing)
            case S_IFLNK:
                let link = try mirroredLink(linkTarget(name, at: source), path: path)
                if existing.map({ $0.mode & S_IFMT == S_IFLNK }) == true {
                    if try linkTarget(name, at: target).utf8.elementsEqual(link.utf8) { break }
                    try remove(name, from: target)
                }
                guard symlinkat(link, target, name) == 0 else { throw systemError("symlink " + path) }
            default:
                throw BuildSlotError.unsupportedEntry(path)
            }
            guard try requiredEntry(name, at: source) == input else { throw BuildSlotError.changedInput(path) }
        }
        guard try fingerprint(source) == before else { throw BuildSlotError.changedInput(prefix) }
        guard try Set(directoryNames(target).map { Data($0.utf8) }) == desired else {
            throw BuildSlotError.incompatibleNames(prefix)
        }
    }

    private mutating func mirroredLink(_ link: String, path: String) throws -> String {
        guard symlinkPolicy == .withinSource else { return link }
        linksToValidate.append(path)
        guard link.hasPrefix("/") else { return link }
        let root = worktree + "/"
        let suffix: String
        if link.utf8.elementsEqual(worktree.utf8) {
            suffix = "."
        } else if link.utf8.starts(with: root.utf8) {
            suffix = String(decoding: link.utf8.dropFirst(root.utf8.count).drop(while: { $0 == 0x2F }), as: UTF8.self)
        } else {
            throw BuildSlotError.unresolvedSlotLink(path)
        }
        let ascent = String(repeating: "../", count: path.split(separator: "/").count - 1)
        return ascent + (suffix.isEmpty ? "." : suffix)
    }

    func validateLinks(in root: Int32) throws {
        // Validate after forward references and entire chains have been mirrored.
        for path in linksToValidate {
            try Task.checkCancellation()
            var info = stat()
            guard fstatat(root, path, &info, AT_RESOLVE_BENEATH) == 0 else {
                throw BuildSlotError.unresolvedSlotLink(path)
            }
        }
    }

    /// Only called for destination entries under exclusive slot ownership.
    static func prepareEntry(_ name: String, at parent: Int32, device: Int64,
                             directoryOnly: Bool = false) throws -> ArtifactFileFingerprint? {
        guard let info = try entryStatus(name, at: parent) else { return nil }
        let directory = info.st_mode & S_IFMT == S_IFDIR
        guard Int64(info.st_dev) == device else { throw BuildSlotError.unsupportedEntry(name) }
        if directoryOnly {
            guard directory, info.st_uid == geteuid(), info.st_mode & 0o7022 == 0 else {
                throw RetainedArtifactError.unsafeDirectory
            }
        }
        let blockingFlags = UInt32(UF_IMMUTABLE | UF_APPEND)
        if info.st_flags & blockingFlags != 0 {
            // Changing flags on a hard-linked file would affect all its names.
            guard info.st_uid == geteuid(), directory || info.st_nlink == 1 else {
                throw BuildSlotError.unsupportedEntry(name)
            }
            guard fchflagsat(parent, name, info.st_flags & ~blockingFlags, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw systemError("clear slot file flags " + name)
            }
        }
        if directory, info.st_mode & 0o700 != 0o700 {
            guard info.st_uid == geteuid() else { throw BuildSlotError.unsupportedEntry(name) }
            guard fchmodat(parent, name, 0o700, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw systemError("restore slot directory permissions " + name)
            }
        }
        return ArtifactFileFingerprint(info)
    }

    private mutating func syncFile(_ name: String, source: Int32, target: Int32, input: ArtifactFileFingerprint,
                          existing: ArtifactFileFingerprint?) throws {
        let file = openat(source, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { throw systemError("open " + name) }
        defer { _ = close(file) }
        guard try fingerprint(file) == input else { throw BuildSlotError.changedInput(name) }
        if let existing, existing.mode & S_IFMT == S_IFREG {
            if existing.linkCount == 1, existing.mode & 0o777 == input.mode & 0o777, existing.size == input.size {
                let other = openat(target, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard other >= 0 else { throw systemError("open mirror " + name) }
                defer { _ = close(other) }
                if try sameBytes(file, other, size: input.size) {
                    summary.unchangedFiles += 1
                    return
                }
            }
        }
        let temp = ".agentbuild-" + UUID().uuidString
        // A clone receives the origin's timestamps. Stamp replacements so an
        // equal-sized edit with the same original mtime invalidates Xcode's record.
        var ownsTemporaryName = false
        defer { if ownsTemporaryName { _ = unlinkat(target, temp, 0) } }
        let staged: Int32
        if fclonefileat(file, target, temp, UInt32(CLONE_NOOWNERCOPY)) == 0 {
            ownsTemporaryName = true
            _ = try Self.prepareEntry(temp, at: target, device: device)
            summary.clonedFiles += 1
            staged = openat(target, temp, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        } else {
            guard errno == ENOTSUP || errno == EOPNOTSUPP || errno == EXDEV else { throw systemError("clone " + name) }
            summary.copiedFiles += 1
            staged = openat(target, temp, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            ownsTemporaryName = staged >= 0
            if staged >= 0 && fcopyfile(file, staged, nil, copyfile_flags_t(COPYFILE_DATA)) != 0 {
                let error = systemError("copy " + name)
                _ = close(staged)
                throw error
            }
        }
        guard staged >= 0 else { throw systemError("open staged " + name) }
        defer { _ = close(staged) }
        guard fchmod(staged, input.mode & 0o777) == 0, futimens(staged, nil) == 0 else {
            throw systemError("set attributes " + name)
        }
        if let existing {
            let stamped = try fingerprint(staged)
            let newTime = (stamped.modificationSeconds, stamped.modificationNanoseconds)
            let oldTime = (existing.modificationSeconds, existing.modificationNanoseconds)
            if newTime <= oldTime {
                let (second, overflow) = Int(existing.modificationSeconds).addingReportingOverflow(1)
                guard !overflow else { throw BuildSlotError.unsupportedEntry(name) }
                let time = timespec(tv_sec: second, tv_nsec: 0)
                guard futimens(staged, [time, time]) == 0 else { throw systemError("advance timestamp " + name) }
                guard try fingerprint(staged).modificationSeconds >= second else {
                    throw BuildSlotError.unsupportedEntry(name)
                }
                latestAdvancedSecond = max(latestAdvancedSecond ?? second, second)
            }
        }
        guard try fingerprint(file) == input else { throw BuildSlotError.changedInput(name) }
        guard renameat(target, temp, target, name) == 0 else { throw systemError("publish " + name) }
        ownsTemporaryName = false
    }

    func waitForTimestampIfNeeded() async throws {
        guard let latestAdvancedSecond else { return }
        // On a coarse volume a quick switch can consume the next clock tick.
        // Wait once per sync so ordinary rapid builds do not keep accumulating skew.
        let remaining = Double(latestAdvancedSecond) - Date().timeIntervalSince1970
        if remaining > 0, remaining <= 1 {
            try await Task.sleep(for: .seconds(remaining))
        }
    }

    private func sameBytes(_ lhs: Int32, _ rhs: Int32, size: Int64) throws -> Bool {
        guard size > 0 else { return true }
        var left = [UInt8](repeating: 0, count: Int(min(size, 64 * 1024)))
        var right = left
        var offset: Int64 = 0
        while offset < size {
            try Task.checkCancellation()
            let length = Int(min(Int64(left.count), size - offset))
            let a = pread(lhs, &left, length, offset)
            if a < 0 && errno == EINTR { continue }
            guard a >= 0 else { throw systemError("read source") }
            let b = pread(rhs, &right, length, offset)
            if b < 0 && errno == EINTR { continue }
            guard b >= 0 else { throw systemError("read mirror") }
            guard a > 0, a == b, memcmp(left, right, a) == 0 else { return false }
            offset += Int64(a)
        }
        return true
    }

    private func remove(_ name: String, from parent: Int32) throws {
        try Task.checkCancellation()
        guard let info = try Self.prepareEntry(name, at: parent, device: device) else {
            throw BuildSlotError.changedInput(name)
        }
        let directory = info.mode & S_IFMT == S_IFDIR
        if directory {
            try withDirectory(parent, name) { child in
                for entry in try directoryNames(child) { try remove(entry, from: child) }
            }
        }
        guard unlinkat(parent, name, directory ? AT_REMOVEDIR : 0) == 0 else { throw systemError("remove " + name) }
    }
}

private func systemError(_ operation: String) -> BuildSlotError { .systemCall(operation, errno) }

private func fingerprint(_ fd: Int32) throws -> ArtifactFileFingerprint {
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw systemError("fstat") }
    return ArtifactFileFingerprint(info)
}

private func entryStatus(_ name: String, at parent: Int32) throws -> stat? {
    var info = stat()
    if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return info }
    if errno == ENOENT { return nil }
    throw systemError("stat " + name)
}

private func requiredEntry(_ name: String, at parent: Int32) throws -> ArtifactFileFingerprint {
    guard let info = try entryStatus(name, at: parent) else { throw BuildSlotError.changedInput(name) }
    return ArtifactFileFingerprint(info)
}

private func withDirectory<T>(_ parent: Int32, _ name: String, _ body: (Int32) throws -> T) throws -> T {
    let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw systemError("open directory " + name) }
    defer { _ = close(fd) }
    return try body(fd)
}

private func directoryNames(_ fd: Int32) throws -> [String] {
    let scan = openat(fd, ".", O_DIRECTORY | O_RDONLY | O_CLOEXEC)
    guard scan >= 0 else { throw systemError("open directory for listing") }
    guard let stream = fdopendir(scan) else {
        let error = systemError("fdopendir")
        _ = close(scan)
        throw error
    }
    defer { _ = closedir(stream) }
    var names: [String] = []
    while true {
        errno = 0
        guard let entry = readdir(stream) else {
            guard errno == 0 else { throw systemError("readdir") }
            return names
        }
        let name = withUnsafeBytes(of: entry.pointee.d_name) {
            String(bytes: $0.prefix(Int(entry.pointee.d_namlen)), encoding: .utf8)
        }
        guard let name else { throw BuildSlotError.unsupportedEntry("non-UTF-8 filename") }
        if name != "." && name != ".." { names.append(name) }
    }
}

private func linkTarget(_ name: String, at parent: Int32) throws -> String {
    var bytes = [UInt8](repeating: 0, count: Int(PATH_MAX))
    let count = readlinkat(parent, name, &bytes, bytes.count)
    guard count >= 0 else { throw systemError("read link " + name) }
    guard count < bytes.count, let path = String(bytes: bytes.prefix(count), encoding: .utf8) else {
        throw BuildSlotError.unsupportedEntry(name)
    }
    return path
}
