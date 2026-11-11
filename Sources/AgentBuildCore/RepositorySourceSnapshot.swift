import CryptoKit
import Darwin
import Foundation

package enum RepositorySourceSnapshotError: Error, Sendable {
    case invalidRequest(String)
    case changedInput(String)
    case evidence(String)
    case io(String, Int32)
}

/// Sequential source observations. Allowances affect the comparison used for
/// the outcome, while raw observations and allowed-file hashes remain evidence.
package struct RepositorySourceSnapshot: Sendable {
    package let raw: [String: String]
    package let comparison: [String: String]
    package let allowedFileHashes: [String: String]

    package static func validatedAllowedPaths(_ paths: [String]) throws -> [String] {
        for path in paths {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.isEmpty, !path.hasPrefix("/"),
                  !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" }) else {
                throw RepositorySourceSnapshotError.invalidRequest("allowed source changes require exact repository-relative file paths")
            }
            // These files control which other changes Git reports. Allowing
            // their contents to change could hide unrelated source drift.
            // Check nested names and filesystem case aliases as well.
            if let name = components.last?.lowercased(),
               [".gitignore", ".gitattributes", ".gitmodules"].contains(name) {
                throw RepositorySourceSnapshotError.invalidRequest("allowed source changes cannot include Git observation-policy files")
            }
        }
        var result: [String] = []
        for path in paths.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            if result.last.map({ $0.utf8.elementsEqual(path.utf8) }) != true { result.append(path) }
        }
        return result
    }

    package static func capture(
        repository: String, allowedPaths: [String], environment: [String: String],
        projectFiles: [String] = []
    ) async throws -> RepositorySourceSnapshot {
        let allowed = try validatedAllowedPaths(allowedPaths)
        let capture = try RepositoryCommandCapture()
        var raw: [String: String] = [:]
        var comparison: [String: String] = [:]
        var allowedFileHashes: [String: String] = [:]
        var allowedModes: [CanonicalJSONValue] = []
        for path in allowed {
            let observation = try observeAllowedFile(repository: repository, path: path)
            allowedFileHashes[path] = observation.digest
            allowedModes.append(.object(["path": .string(path), "mode": .integer(Int64(observation.mode))]))
        }
        let gitObservations: [(String, [String])] = [
            ("head", ["git", "rev-parse", "HEAD"]),
            ("status", ["git", "status", "--porcelain=v1", "-z", "--untracked-files=all"]),
            ("diff", ["git", "diff", "--binary", "--no-ext-diff", "HEAD"]),
            ("submodules", ["git", "submodule", "status", "--recursive"]),
        ]
        for (name, arguments) in gitObservations {
            raw[name] = CanonicalJSONDigest.digest(try await capture.capture(
                arguments: arguments, workingDirectory: repository, environment: environment))
        }
        comparison = raw
        if !allowed.isEmpty {
            // The literal modifier treats all user characters as filename data.
            // Every allowed path must name a regular file, so this cannot grant
            // a directory-wide exception. Ignore pathspec environment overrides.
            var literalEnvironment = environment
            for key in ["GIT_LITERAL_PATHSPECS", "GIT_GLOB_PATHSPECS", "GIT_NOGLOB_PATHSPECS", "GIT_ICASE_PATHSPECS"] {
                literalEnvironment.removeValue(forKey: key)
            }
            let exclusions = ["--", ":/"] + allowed.map { ":(top,literal,exclude)" + $0 }
            for (name, arguments) in gitObservations where name == "status" || name == "diff" {
                comparison[name] = CanonicalJSONDigest.digest(try await capture.capture(
                    arguments: arguments + exclusions, workingDirectory: repository, environment: literalEnvironment))
            }
            // Allowances authorize working-file changes, not index edits. These
            // semantic listings avoid treating Git's stat-cache refresh as drift.
            for (name, arguments) in [
                ("index", ["git", "ls-files", "--stage", "-z"]),
                ("indexFlags", ["git", "ls-files", "-v", "-z"]),
            ] {
                let digest = CanonicalJSONDigest.digest(try await capture.capture(
                    arguments: arguments, workingDirectory: repository, environment: environment))
                raw[name] = digest
                comparison[name] = digest
            }
            let modeDigest = try CanonicalJSONDigest.sha256(.array(allowedModes))
            raw["allowedFileModes"] = modeDigest
            comparison["allowedFileModes"] = modeDigest
            raw["allowedFiles"] = try CanonicalJSONDigest.sha256(.array(allowed.map { path in
                .object(["path": .string(path), "sha256": .string(allowedFileHashes[path]!)])
            }))
        }

        let untracked = try await capture.capture(
            arguments: ["git", "ls-files", "--others", "--exclude-standard", "-z"],
            workingDirectory: repository, environment: environment)
        var files: [CanonicalJSONValue] = [], comparedFiles: [CanonicalJSONValue] = []
        for bytes in untracked.split(separator: 0) {
            guard let name = String(bytes: bytes, encoding: .utf8), !name.hasPrefix("/"),
                  !name.split(separator: "/").contains("..") else {
                throw RepositorySourceSnapshotError.evidence("invalid Git path")
            }
            let value: CanonicalJSONValue = .object([
                "path": .string(name), "sha256": .string(try sourceFileDigest(repository + "/" + name)),
            ])
            files.append(value)
            if !allowed.contains(where: { $0.utf8.elementsEqual(name.utf8) }) { comparedFiles.append(value) }
        }
        raw["untracked"] = try CanonicalJSONDigest.sha256(.array(files))
        comparison["untracked"] = try CanonicalJSONDigest.sha256(.array(comparedFiles))
        for name in projectFiles {
            if FileManager.default.fileExists(atPath: repository + "/" + name) {
                let digest = try sourceFileDigest(repository + "/" + name)
                raw[name] = digest
                if !allowed.contains(where: { $0.utf8.elementsEqual(name.utf8) }) { comparison[name] = digest }
            }
        }
        return RepositorySourceSnapshot(raw: raw, comparison: comparison, allowedFileHashes: allowedFileHashes)
    }
}

private func observeAllowedFile(repository: String, path: String) throws -> (digest: String, mode: mode_t) {
    // Resolve each component through an owned descriptor, never through a
    // symlink. A normal atomic file replacement between snapshots is permitted.
    var directory = open(repository, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 3 else { throw RepositorySourceSnapshotError.io("open allowed source repository", errno) }
    defer { _ = close(directory) }
    var root = stat()
    guard fstat(directory, &root) == 0 else {
        throw RepositorySourceSnapshotError.io("stat allowed source repository", errno)
    }
    let components = path.split(separator: "/").map(String.init)
    for component in components.dropLast() {
        let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard next >= 3 else { throw RepositorySourceSnapshotError.io("open allowed source directory: " + path, errno) }
        _ = close(directory)
        directory = next
    }
    let name = components.last!
    let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 3 else { throw RepositorySourceSnapshotError.io("open allowed source file: " + path, errno) }
    defer { _ = close(descriptor) }
    let observation = try sourceDescriptorDigest(descriptor, path: path) { metadata in
        fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW)
    }
    // A directory rename while reading must not detach the observation from
    // the path in this repository. Check the visible spelling without following
    // ancestor links, then compare the observed file identity.
    var namedRoot = stat()
    guard lstat(repository, &namedRoot) == 0, namedRoot.st_mode & S_IFMT == S_IFDIR,
          namedRoot.st_dev == root.st_dev, namedRoot.st_ino == root.st_ino else {
        throw RepositorySourceSnapshotError.changedInput(repository)
    }
    var current = repository
    for component in components.dropLast() {
        current += "/" + component
        var metadata = stat()
        guard lstat(current, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else {
            throw RepositorySourceSnapshotError.changedInput(path)
        }
    }
    var named = stat()
    guard lstat(repository + "/" + path, &named) == 0,
          named.st_dev == observation.metadata.st_dev, named.st_ino == observation.metadata.st_ino else {
        throw RepositorySourceSnapshotError.changedInput(path)
    }
    return (observation.digest, observation.metadata.st_mode)
}

private func sourceFileDigest(_ path: String) throws -> String {
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 3 else { throw RepositorySourceSnapshotError.io("open source input", errno) }
    defer { _ = close(descriptor) }
    return try sourceDescriptorDigest(descriptor, path: path) { metadata in lstat(path, &metadata) }.digest
}

private func sourceDescriptorDigest(
    _ descriptor: Int32, path: String, namedStat: (inout stat) -> Int32
) throws -> (digest: String, metadata: stat) {
    var before = stat()
    guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0 else {
        throw RepositorySourceSnapshotError.evidence("nonregular source input: " + path)
    }
    var digest = SHA256(), buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
        let count = read(descriptor, &buffer, buffer.count)
        if count < 0, errno == EINTR { continue }
        guard count >= 0 else { throw RepositorySourceSnapshotError.io("read source input", errno) }
        if count == 0 { break }
        digest.update(data: Data(buffer.prefix(count)))
    }
    var after = stat(), named = stat()
    guard fstat(descriptor, &after) == 0, namedStat(&named) == 0,
          before.st_dev == after.st_dev, before.st_ino == after.st_ino,
          after.st_dev == named.st_dev, after.st_ino == named.st_ino,
          before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
          before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
          before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
          before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
        throw RepositorySourceSnapshotError.changedInput(path)
    }
    return (digest.finalize().map { String(format: "%02x", $0) }.joined(), after)
}
