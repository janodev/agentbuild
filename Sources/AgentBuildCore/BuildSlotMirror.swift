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

    private(set) var summary = BuildSlotSyncSummary()

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
            let existing = try entry(name, at: target)
            if let existing, existing.mode & S_IFMT != kind {
                try remove(name, from: target)
            }
            switch kind {
            case S_IFDIR:
                if let existing, existing.mode & S_IFMT == S_IFDIR {
                    try checkDevice(existing, name: path)
                } else {
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
                let link = try linkTarget(name, at: source)
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

    private mutating func syncFile(_ name: String, source: Int32, target: Int32, input: ArtifactFileFingerprint,
                          existing: ArtifactFileFingerprint?) throws {
        let file = openat(source, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { throw systemError("open " + name) }
        defer { _ = close(file) }
        guard try fingerprint(file) == input else { throw BuildSlotError.changedInput(name) }
        if let existing, existing.mode & S_IFMT == S_IFREG {
            try checkDevice(existing, name: name)
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
        let staged: Int32
        if fclonefileat(file, target, temp, UInt32(CLONE_NOOWNERCOPY)) == 0 {
            summary.clonedFiles += 1
            staged = openat(target, temp, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        } else {
            guard errno == ENOTSUP || errno == EXDEV else { throw systemError("clone " + name) }
            summary.copiedFiles += 1
            staged = openat(target, temp, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if staged >= 0 && fcopyfile(file, staged, nil, copyfile_flags_t(COPYFILE_DATA)) != 0 {
                let error = systemError("copy " + name)
                _ = close(staged)
                _ = unlinkat(target, temp, 0)
                throw error
            }
        }
        guard staged >= 0 else { throw systemError("open staged " + name) }
        defer { _ = close(staged); _ = unlinkat(target, temp, 0) }
        guard fchmod(staged, input.mode & 0o777) == 0, futimens(staged, nil) == 0 else {
            throw systemError("set attributes " + name)
        }
        if let existing {
            let stamped = try fingerprint(staged)
            if stamped.modificationSeconds == existing.modificationSeconds,
               stamped.modificationNanoseconds == existing.modificationNanoseconds {
                // Disambiguate two writes within the filesystem clock tick.
                let time = timespec(tv_sec: Int(stamped.modificationSeconds) + 1, tv_nsec: 0)
                guard futimens(staged, [time, time]) == 0 else { throw systemError("advance timestamp " + name) }
            }
        }
        guard try fingerprint(file) == input else { throw BuildSlotError.changedInput(name) }
        guard renameat(target, temp, target, name) == 0 else { throw systemError("publish " + name) }
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
        let info = try requiredEntry(name, at: parent)
        try checkDevice(info, name: name)
        let directory = info.mode & S_IFMT == S_IFDIR
        if directory {
            try withDirectory(parent, name) { child in
                for entry in try directoryNames(child) { try remove(entry, from: child) }
            }
        }
        guard unlinkat(parent, name, directory ? AT_REMOVEDIR : 0) == 0 else { throw systemError("remove " + name) }
    }

    private func checkDevice(_ entry: ArtifactFileFingerprint, name: String) throws {
        guard entry.device == device else { throw BuildSlotError.unsupportedEntry(name) }
    }
}

private func systemError(_ operation: String) -> BuildSlotError { .systemCall(operation, errno) }

private func fingerprint(_ fd: Int32) throws -> ArtifactFileFingerprint {
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw systemError("fstat") }
    return ArtifactFileFingerprint(info)
}

private func entry(_ name: String, at parent: Int32) throws -> ArtifactFileFingerprint? {
    var info = stat()
    if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return ArtifactFileFingerprint(info) }
    if errno == ENOENT { return nil }
    throw systemError("stat " + name)
}

private func requiredEntry(_ name: String, at parent: Int32) throws -> ArtifactFileFingerprint {
    guard let info = try entry(name, at: parent) else { throw BuildSlotError.changedInput(name) }
    return info
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
