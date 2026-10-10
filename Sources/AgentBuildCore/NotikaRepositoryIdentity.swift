import CryptoKit
import Darwin
import Foundation

public enum NotikaRepositoryIdentityError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidRepository
    case invalidEnvironment
    case invalidUTF8Path
    case fileSystem(String)
    case invalidGraphInput(String)
    case invalidFileType(String)
    case unavailableSubmodule(path: String, diagnostic: String)
    case escapedSubmodule(String)
    case nestedSubmodule(String)

    public var description: String {
        switch self {
        case .invalidRepository: "identity repository must resolve to an absolute directory"
        case .invalidEnvironment: "identity environment contains invalid key or value bytes"
        case .invalidUTF8Path: "identity filesystem paths must be valid UTF-8"
        case .fileSystem(let diagnostic): diagnostic
        case .invalidGraphInput(let path): "identity input must resolve to a repository file: \(path)"
        case .invalidFileType(let path): "identity input must be a regular file: \(path)"
        case .unavailableSubmodule(let path, let diagnostic): "submodule worktree is unavailable: \(path): \(diagnostic)"
        case .escapedSubmodule(let path): "submodule worktree escaped the repository: \(path)"
        case .nestedSubmodule(let path): "nested submodule worktrees are not supported: \(path)"
        }
    }
}

/// Immutable observations with exact Python JSON key material. These values are
/// gathered sequentially; they prove neither custody nor an atomic snapshot.
public struct NotikaSourceIdentity: Sendable {
    public let canonicalWorktree: String
    public let head: String
    public let gitlinks: [CacheGitlink]
    public let statusDigest: String
    public let stagedDiffDigest: String
    public let unstagedDiffDigest: String
    public let submoduleStatusDigest: String
    public let submoduleWorktreeDigest: String
    public let projectGraphDigest: String
    public let generatedGraphDigest: String
    public let resolvedDependenciesDigest: String
    public let keyMaterial: CanonicalJSONValue

    public func digest() throws -> String { try CanonicalJSONDigest.sha256(keyMaterial) }
}

public struct NotikaToolchainIdentity: Sendable {
    public let keyMaterial: CanonicalJSONValue
    public func digest() throws -> String { try CanonicalJSONDigest.sha256(keyMaterial) }
}

/// Notika's source/toolchain adapter, independent of command admission. The
/// environment is sampled once at construction and capability names are removed
/// before probes. Binary lookup intentionally uses the original PATH, matching
/// the reference's shutil.which rather than a leased child's environment.
public struct NotikaRepositoryIdentity: Sendable {
    public let repository: String
    private let capture: any RepositoryCommandCapturing
    private let environment: [String: String]
    private static let reviewExclusion = ":(glob,exclude)GPT-Pro/reviews/*.md"
    private static let graphInputs = ["Project.swift", "Tuist.swift", "Tuist/Package.swift",
                                      "Tuist/Package.resolved", ".mise.toml", ".xcode-version"]

    public init(repository: String, capture: (any RepositoryCommandCapturing)? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") &&
            !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) }) else {
            throw NotikaRepositoryIdentityError.invalidEnvironment
        }
        guard repository.hasPrefix("/"), !repository.utf8.contains(0),
              let canonical = try identityCanonicalPath(repository),
              try identityMetadata(canonical).map({ identityIsDirectory($0) }) == true else {
            throw NotikaRepositoryIdentityError.invalidRepository
        }
        self.repository = canonical
        self.capture = try capture ?? RepositoryCommandCapture()
        self.environment = environment
    }

    public func sourceIdentity() async throws -> NotikaSourceIdentity {
        let head = repositoryDecodedText(try await command(["git", "rev-parse", "HEAD"]))
        let canonical = repositoryDecodedText(try await command(["git", "rev-parse", "--show-toplevel"]))
        let status = try await command(["git", "status", "--porcelain=v2", "-z", "--untracked-files=all", "--", ".",
                                        ":(exclude)Artifacts/AgentSessions/**", ":(exclude)DerivedData/**", Self.reviewExclusion])
        let staged = try await command(["git", "diff", "--cached", "--binary", "--no-ext-diff", "--", ".", Self.reviewExclusion])
        let unstaged = try await command(["git", "diff", "--binary", "--no-ext-diff", "--", ".", Self.reviewExclusion])
        let index = try await command(["git", "ls-files", "--stage", "-z", "--", ".", Self.reviewExclusion])
        let submodules = try await command(["git", "submodule", "status", "--recursive"])
        let gitlinks = try parseGitlinks(index)
        let submoduleRecords = try await submoduleIdentities(gitlinks)
        let submoduleDigest = try CanonicalJSONDigest.sha256(.array(submoduleRecords))
        let graph = try filesDigest(Self.graphInputs)
        let resolved = try filesDigest(["Notika.xcworkspace/xcshareddata/swiftpm/Package.resolved"])
        let generated = try filesDigest(generatedGraphPaths())
        let statusDigest = CanonicalJSONDigest.digest(status)
        let stagedDigest = CanonicalJSONDigest.digest(staged)
        let unstagedDigest = CanonicalJSONDigest.digest(unstaged)
        let submoduleStatusDigest = CanonicalJSONDigest.digest(submodules)
        let material = CanonicalJSONValue.object([
            "canonicalWorktree": .string(canonical), "head": .string(head),
            "statusDigest": .string(statusDigest), "stagedDiffDigest": .string(stagedDigest),
            "unstagedDiffDigest": .string(unstagedDigest), "untrackedInputs": .array(try untrackedInputs(status, root: repository)),
            "gitlinks": .array(gitlinks.map(\.keyMaterial)), "submoduleStatusDigest": .string(submoduleStatusDigest),
            "submoduleWorktreeDigest": .string(submoduleDigest), "submoduleWorktrees": .array(submoduleRecords),
            "projectGraphDigest": .string(graph.digest), "projectGraphFiles": .array(graph.records),
            "generatedGraphDigest": .string(generated.digest), "generatedGraphFiles": .array(generated.records),
            "resolvedDependenciesDigest": .string(resolved.digest), "resolvedDependencyFiles": .array(resolved.records),
        ])
        return NotikaSourceIdentity(canonicalWorktree: canonical, head: head, gitlinks: gitlinks,
                                    statusDigest: statusDigest, stagedDiffDigest: stagedDigest, unstagedDiffDigest: unstagedDigest,
                                    submoduleStatusDigest: submoduleStatusDigest, submoduleWorktreeDigest: submoduleDigest,
                                    projectGraphDigest: graph.digest, generatedGraphDigest: generated.digest,
                                    resolvedDependenciesDigest: resolved.digest, keyMaterial: material)
    }

    public func toolchainIdentity() async throws -> NotikaToolchainIdentity {
        let probes = [("xcode", ["xcodebuild", "-version"]), ("swift", ["swift", "--version"]),
                      ("sdk", ["xcrun", "--sdk", "macosx", "--show-sdk-version"]),
                      ("tuist", [repository + "/Scripts/tuist", "version"])]
        var versions: [String: CanonicalJSONValue] = [:]
        for (name, arguments) in probes {
            do { versions[name] = .string(repositoryDecodedText(try await command(arguments))) }
            catch let error as RepositoryCaptureError {
                try Task.checkCancellation()
                switch error {
                case .commandFailed, .launchFailed: versions[name] = .object(["unavailable": .string(error.description)])
                default: throw error
                }
            }
        }
        var binaries: [String: CanonicalJSONValue] = [:]
        for name in ["agentlease", "simlease", "simslim", "sim-use", "xcbeautify"] {
            try Task.checkCancellation()
            guard let executable = try findExecutable(name) else {
                binaries[name] = .object(["unavailable": .bool(true)])
                continue
            }
            binaries[name] = .object(["path": .string(executable), "sha256": .string(try identityFileDigest(executable))])
        }
        return NotikaToolchainIdentity(keyMaterial: .object(["versions": .object(versions), "binaries": .object(binaries)]))
    }

    private func command(_ arguments: [String], root: String? = nil) async throws -> Data {
        try Task.checkCancellation()
        return try await capture.capture(arguments: arguments, workingDirectory: root ?? repository,
                                         environment: environment.filter { !Self.capabilityNames.contains($0.key) })
    }

    private func filesDigest(_ paths: [String]) throws -> (digest: String, records: [CanonicalJSONValue]) {
        var aggregate = SHA256()
        var records: [CanonicalJSONValue] = []
        for relative in paths {
            try Task.checkCancellation()
            guard let canonical = try identityCanonicalPath(repository + "/" + relative) else { continue }
            guard try identityMetadata(canonical).map({ identityIsRegular($0) }) == true,
                  identityIsWithin(canonical, root: repository) else {
                throw NotikaRepositoryIdentityError.invalidGraphInput(relative)
            }
            let digest = try identityFileDigest(canonical)
            records.append(.object(["path": .string(relative), "sha256": .string(digest)]))
            aggregate.update(data: Data(relative.utf8))
            aggregate.update(data: Data([0]))
            aggregate.update(data: Data(digest.utf8))
            aggregate.update(data: Data([0]))
        }
        return (identityHex(aggregate.finalize()), records)
    }

    private func generatedGraphPaths() throws -> [String] {
        var paths: [String] = []
        func visit(_ relative: String) throws {
            try Task.checkCancellation()
            for name in try identityDirectoryNames(repository + "/" + relative) {
                let child = relative + "/" + name
                guard !child.split(separator: "/").contains("xcuserdata") else { continue }
                let path = repository + "/" + child
                let direct = try identityMetadata(path, follow: false)
                let followed = try identityMetadata(path)
                if direct.map(identityIsDirectory) == true { try visit(child) }
                else if followed.map(identityIsDirectory) != true { paths.append(child) }
                // Directory symlinks are neither admitted nor traversed.
            }
        }
        for root in ["Notika.xcodeproj", "Notika.xcworkspace"] {
            if try identityMetadata(repository + "/" + root, follow: false).map(identityIsDirectory) == true { try visit(root) }
        }
        return paths.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    private func submoduleIdentities(_ links: [CacheGitlink]) async throws -> [CanonicalJSONValue] {
        var records: [CanonicalJSONValue] = []
        for link in links {
            let candidate = repository + "/" + link.path
            guard let canonical = try identityCanonicalPath(candidate) else {
                let diagnostic = errno == ELOOP ? "Symlink loop from '\(candidate)'" : identityPOSIXDiagnostic(ENOENT, path: candidate)
                throw NotikaRepositoryIdentityError.unavailableSubmodule(path: link.path, diagnostic: diagnostic)
            }
            guard try identityMetadata(canonical).map(identityIsDirectory) == true, identityIsWithin(canonical, root: repository) else {
                throw NotikaRepositoryIdentityError.escapedSubmodule(link.path)
            }
            let index = try await command(["git", "ls-files", "--stage", "-z"], root: canonical)
            guard try parseGitlinks(index).isEmpty else { throw NotikaRepositoryIdentityError.nestedSubmodule(link.path) }
            let status = try await command(["git", "status", "--porcelain=v2", "-z", "--untracked-files=all"], root: canonical)
            let staged = try await command(["git", "diff", "--cached", "--binary", "--no-ext-diff"], root: canonical)
            let unstaged = try await command(["git", "diff", "--binary", "--no-ext-diff"], root: canonical)
            records.append(.object([
                "path": .string(link.path), "commit": .string(link.commit),
                "statusDigest": .string(CanonicalJSONDigest.digest(status)),
                "stagedDiffDigest": .string(CanonicalJSONDigest.digest(staged)),
                "unstagedDiffDigest": .string(CanonicalJSONDigest.digest(unstaged)),
                "untrackedInputs": .array(try untrackedInputs(status, root: canonical, prefix: link.path)),
            ]))
        }
        return records
    }

    private func parseGitlinks(_ index: Data) throws -> [CacheGitlink] {
        try index.split(separator: 0).compactMap { record in
            guard let tab = record.firstIndex(of: 9) else { return nil }
            let metadata = String(decoding: record[..<tab], as: UTF8.self).split(whereSeparator: { $0.isWhitespace })
            guard metadata.count >= 2, metadata[0] == "160000" else { return nil }
            let path = try identityUTF8(record[record.index(after: tab)...])
            return try CacheGitlink(path: path, commit: String(metadata[1]))
        }
    }

    private func untrackedInputs(_ status: Data, root: String, prefix: String? = nil) throws -> [CanonicalJSONValue] {
        var records: [CanonicalJSONValue] = []
        for record in status.split(separator: 0) where record.starts(with: [63, 32]) {
            try Task.checkCancellation()
            let relative = try identityUTF8(record.dropFirst(2))
            let path = root + "/" + relative
            let display = prefix.map { $0 + "/" + relative } ?? relative
            let metadata: stat
            do {
                guard let value = try identityMetadata(path, follow: false, missingIsNil: false) else { continue }
                metadata = value
            } catch let error as NotikaRepositoryIdentityError {
                records.append(.object(["path": .string(display), "unreadable": .string(error.description)]))
                continue
            }
            if identityIsSymlink(metadata) {
                let target: String
                do { target = try identityReadlink(path) }
                catch let error as NotikaRepositoryIdentityError {
                    if error == .invalidUTF8Path { throw error }
                    target = "unreadable: \(error.description)"
                }
                records.append(.object(["path": .string(display), "kind": .string("symbolic-link"),
                                        "linkTarget": .string(target), "contentOmitted": .bool(true)]))
            } else if identityIsRegular(metadata) {
                records.append(.object(["path": .string(display), "bytes": .integer(metadata.st_size),
                                        "sha256": .string(try identityFileDigest(path))]))
            } else { records.append(.object(["path": .string(display), "unreadable": .bool(true)])) }
        }
        return records
    }

    private func findExecutable(_ name: String) throws -> String? {
        for directory in (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":", omittingEmptySubsequences: false) {
            let component = directory.isEmpty ? "." : String(directory)
            // shutil.which resolves relative PATH entries against process cwd.
            let path = component + "/" + name
            guard path.withCString({ access($0, X_OK) }) == 0,
                  try identityMetadata(path).map(identityIsDirectory) != true else { continue }
            return try identityCanonicalPath(path)
        }
        return nil
    }

    private static let capabilityNames: Set<String> = [
        "NOTIKA_ROUTE_AUTHORITY_FD", "NOTIKA_REPORT_HANDOFF_FD", "NOTIKA_TEXT_PERFORMANCE_TREE_HANDOFF_FD",
        "NOTIKA_TEXT_PERFORMANCE_TREE_HANDOFF_KEY", "NOTIKA_TEXT_INPUT_PERFORMANCE_ROOT_DEVICE_ID",
        "NOTIKA_TEXT_INPUT_PERFORMANCE_ROOT_INODE", "NOTIKA_ROUTE_AUTHORITY_SHA256", "NOTIKA_ROUTE_GRAPH_IDENTITY_FD",
        "NOTIKA_ROUTE_CACHE_IDENTITY_FD", "NOTIKA_ROUTE_GRAPH_CUSTODIAN_FD", "NOTIKA_ROUTE_CACHE_CUSTODIAN_FD",
        "NOTIKA_ROUTE_RAW_COMMITMENT_FD", "NOTIKA_ROUTE_GRAPH_LOCK_FD", "NOTIKA_ROUTE_CACHE_LOCK_FD",
        "NOTIKA_ROUTE_AUTHORITY_TICKET", "NOTIKA_ROUTE_AUTHORITY_NONCE", "NOTIKA_INTERACTIVE_HOST_CUSTODY_FD",
        "NOTIKA_INTERACTIVE_SIGNAL_RELAY_READ_FD", "NOTIKA_INTERACTIVE_SIGNAL_RELAY_WRITE_FD",
        "NOTIKA_INTERACTIVE_RELAY_READY_READ_FD", "NOTIKA_INTERACTIVE_RELAY_READY_WRITE_FD",
        "NOTIKA_INTERACTIVE_RELAY_ACK_READ_FD", "NOTIKA_INTERACTIVE_RELAY_ACK_WRITE_FD",
    ]
}

private func identityUTF8(_ bytes: some Collection<UInt8>) throws -> String {
    guard let text = String(bytes: bytes, encoding: .utf8) else { throw NotikaRepositoryIdentityError.invalidUTF8Path }
    return text
}

private func identityCanonicalPath(_ path: String) throws -> String? {
    guard !path.utf8.contains(0) else { throw NotikaRepositoryIdentityError.invalidUTF8Path }
    guard let pointer = path.withCString({ realpath($0, nil) }) else {
        let code = errno
        if code == ENOENT || code == ELOOP { return nil }
        throw NotikaRepositoryIdentityError.fileSystem(identityPOSIXDiagnostic(code, path: path))
    }
    defer { free(pointer) }
    guard let value = String(validatingCString: pointer) else { throw NotikaRepositoryIdentityError.invalidUTF8Path }
    return value
}

private func identityMetadata(_ path: String, follow: Bool = true, missingIsNil: Bool = true) throws -> stat? {
    guard !path.utf8.contains(0) else { throw NotikaRepositoryIdentityError.invalidUTF8Path }
    var metadata = stat()
    let result = path.withCString { follow ? stat($0, &metadata) : lstat($0, &metadata) }
    guard result == 0 else {
        let code = errno
        if missingIsNil && (code == ENOENT || code == ENOTDIR || code == ELOOP) { return nil }
        throw NotikaRepositoryIdentityError.fileSystem(identityPOSIXDiagnostic(code, path: path))
    }
    return metadata
}

private func identityIsRegular(_ metadata: stat) -> Bool { metadata.st_mode & S_IFMT == S_IFREG }
private func identityIsDirectory(_ metadata: stat) -> Bool { metadata.st_mode & S_IFMT == S_IFDIR }
private func identityIsSymlink(_ metadata: stat) -> Bool { metadata.st_mode & S_IFMT == S_IFLNK }

private func identityIsWithin(_ path: String, root: String) -> Bool {
    let bytes = Array(path.utf8)
    let rootBytes = Array(root.utf8)
    return bytes == rootBytes || bytes.starts(with: rootBytes + (root == "/" ? [] : [47]))
}

private func identityFileDigest(_ path: String) throws -> String {
    // A substituted FIFO must not block in open/read. Canonical graph and binary
    // paths have already followed admitted symlinks; their leaf may not change
    // into another link between resolution and opening. Ancestor custody is not
    // established here, and the observations still need an owning caller.
    let descriptor = path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
    guard descriptor >= 0 else { throw NotikaRepositoryIdentityError.fileSystem(identityPOSIXDiagnostic(errno, path: path)) }
    defer { close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else {
        throw NotikaRepositoryIdentityError.fileSystem(identityPOSIXDiagnostic(errno, path: path))
    }
    guard identityIsRegular(metadata) else { throw NotikaRepositoryIdentityError.invalidFileType(path) }
    var digest = SHA256()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
        try Task.checkCancellation()
        let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        if count == 0 { break }
        if count < 0 {
            if errno == EINTR { continue }
            throw NotikaRepositoryIdentityError.fileSystem(identityPOSIXDiagnostic(errno, path: path))
        }
        digest.update(data: Data(buffer.prefix(count)))
    }
    return identityHex(digest.finalize())
}

private func identityHex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

private func identityDirectoryNames(_ path: String) throws -> [String] {
    guard let directory = path.withCString({ opendir($0) }) else {
        throw NotikaRepositoryIdentityError.fileSystem(identityPOSIXDiagnostic(errno, path: path))
    }
    defer { closedir(directory) }
    var names: [String] = []
    while true {
        errno = 0
        guard let entry = readdir(directory) else {
            if errno != 0 { throw NotikaRepositoryIdentityError.fileSystem(identityPOSIXDiagnostic(errno, path: path)) }
            break
        }
        let name = try withUnsafePointer(to: &entry.pointee.d_name) { tuple in
            try tuple.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { pointer in
                guard let value = String(validatingCString: pointer) else { throw NotikaRepositoryIdentityError.invalidUTF8Path }
                return value
            }
        }
        if name != "." && name != ".." { names.append(name) }
    }
    return names
}

private func identityReadlink(_ path: String) throws -> String {
    var size = 256
    while size <= 1_024 * 1_024 {
        var bytes = [UInt8](repeating: 0, count: size)
        let count = path.withCString { pointer in
            bytes.withUnsafeMutableBytes { readlink(pointer, $0.baseAddress!.assumingMemoryBound(to: CChar.self), size) }
        }
        guard count >= 0 else { throw NotikaRepositoryIdentityError.fileSystem(identityPOSIXDiagnostic(errno, path: path)) }
        if count < size { return try identityUTF8(bytes.prefix(count)) }
        size *= 2
    }
    throw NotikaRepositoryIdentityError.fileSystem("symbolic link target exceeds its observation budget: \(path)")
}

private func identityPOSIXDiagnostic(_ code: Int32, path: String) -> String {
    let quote = path.contains("'") && !path.contains("\"") ? "\"" : "'"
    var escaped = ""
    for scalar in path.unicodeScalars {
        switch scalar.value {
        case 92: escaped += "\\\\"
        case 9: escaped += "\\t"
        case 10: escaped += "\\n"
        case 13: escaped += "\\r"
        case 0...31, 127: escaped += String(format: "\\x%02x", scalar.value)
        default:
            let text = String(scalar)
            escaped += text == quote ? "\\" + text : text
        }
    }
    return "[Errno \(code)] \(String(cString: strerror(code))): \(quote)\(escaped)\(quote)"
}
