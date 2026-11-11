import Darwin
import Foundation
import Synchronization

package enum ControllerSessionArtifactError: Error, Equatable, Sendable {
    case invalidArgument
    case changed
    case io(String, Int32)
}

/// Checked artifact descriptors only. The actual outer session-writer lease is
/// held by the controller; this class never mints ownership from a report/path.
private final class ControllerSessionOwnedDescriptor: Sendable { let value: Int32; init(_ value: Int32) { self.value = value }; deinit { _ = close(value) } }
package final class ControllerSessionArtifacts: Sendable {
    package let path: String
    package let identity: stat
    package let repositoryDescriptor: Int32
    private let directory: ControllerSessionOwnedDescriptor
    private let root: ControllerSessionOwnedDescriptor
    private let repository: RetainedArtifactDirectory
    private let custody: RetainedArtifactDirectory
    private let sealed = Mutex<[RetainedArtifactFile]>([])
    package convenience init(repository: String, runID: String) throws {
        try self.init(repository: repository, runID: runID, createSession: true)
    }
    package convenience init(borrowingSessionPath: String, repository: String) throws {
        let prefix = repository + "/Artifacts/AgentSessions/"
        guard borrowingSessionPath.utf8.starts(with: prefix.utf8) else { throw ControllerSessionArtifactError.invalidArgument }
        let runID = String(borrowingSessionPath.dropFirst(prefix.count))
        guard UUID(uuidString: runID)?.uuidString == runID else { throw ControllerSessionArtifactError.invalidArgument }
        try self.init(repository: repository, runID: runID, createSession: false)
    }
    private init(repository path: String, runID: String, createSession: Bool) throws {
        guard UUID(uuidString: runID)?.uuidString == runID else { throw ControllerSessionArtifactError.invalidArgument }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), !path.utf8.contains(0), path == "/" ||
              (!path.hasSuffix("/") && !components.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })) else {
            throw ControllerSessionArtifactError.invalidArgument
        }
        let repository = try RetainedArtifactDirectory(path: path)
        let opened = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard opened >= 0 else { throw controllerSessionIO("open generation repository") }
        let root = ControllerSessionOwnedDescriptor(opened)
        let rootStat = try controllerSessionStat(opened)
        guard Int64(rootStat.st_dev) == repository.fingerprint.device, UInt64(rootStat.st_ino) == repository.fingerprint.inode else { throw ControllerSessionArtifactError.changed }
        var pins = [root]
        for (name, exclusive) in [("Artifacts", false), ("AgentSessions", false), (runID, true)] {
            let parent = pins.last!.value
            let created = createSession ? mkdirat(parent, name, 0o700) : -1
            if createSession, created != 0, errno != EEXIST || exclusive { throw controllerSessionIO("create generation session") }
            let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw controllerSessionIO("open generation session") }
            let owner = ControllerSessionOwnedDescriptor(descriptor), metadata = try controllerSessionStat(descriptor)
            var named = stat()
            guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == geteuid(), metadata.st_mode & 0o7022 == 0,
                  !exclusive || metadata.st_mode & 0o7777 == 0o700,
                  named.st_dev == metadata.st_dev, named.st_ino == metadata.st_ino else { throw ControllerSessionArtifactError.changed }
            if created == 0, fsync(parent) != 0 { throw controllerSessionIO("sync generation session parent") }
            pins.append(owner)
        }
        let sessionPath = path + "/Artifacts/AgentSessions/" + runID
        let custody = try RetainedArtifactDirectory(path: sessionPath, requiredPermissions: 0o700)
        let directory = pins.last!, identity = try controllerSessionStat(directory.value)
        guard custody.fingerprint.device == Int64(identity.st_dev), custody.fingerprint.inode == UInt64(identity.st_ino) else { throw ControllerSessionArtifactError.changed }
        try repository.revalidate()
        self.path = sessionPath; self.identity = identity; self.repositoryDescriptor = opened
        self.root = root; self.directory = directory; self.repository = repository; self.custody = custody
    }
    package func revalidate() throws {
        try repository.revalidate(); try custody.revalidate()
        let metadata = try controllerSessionStat(directory.value)
        guard metadata.st_dev == identity.st_dev, metadata.st_ino == identity.st_ino, metadata.st_mode & 0o7777 == 0o700 else { throw ControllerSessionArtifactError.changed }
        for receipt in sealed.withLock({ $0 }) { try receipt.revalidate() }
    }
    package func createPrivateDirectory(named name: String, additionalAllowedNames: Set<String> = []) throws -> RetainedArtifactDirectory {
        guard !name.isEmpty, name.utf8.count <= 128, !name.hasPrefix("."),
              !name.contains("/"), !name.utf8.contains(0),
              (additionalAllowedNames.contains(name) || name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 })) else {
            throw ControllerSessionArtifactError.invalidArgument
        }
        try revalidate()
        let created = mkdirat(directory.value, name, 0o700)
        if created != 0, errno != EEXIST { throw controllerSessionIO("create private session directory") }
        let descriptor = openat(directory.value, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw controllerSessionIO("open private session directory") }
        defer { _ = close(descriptor) }
        let metadata = try controllerSessionStat(descriptor)
        guard metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == geteuid(), metadata.st_mode & 0o7777 == 0o700 else {
            throw ControllerSessionArtifactError.changed
        }
        let retained = try RetainedArtifactDirectory(path: path + "/" + name, requiredPermissions: 0o700)
        guard retained.fingerprint.device == Int64(metadata.st_dev), retained.fingerprint.inode == UInt64(metadata.st_ino) else {
            throw ControllerSessionArtifactError.changed
        }
        if created == 0, fsync(directory.value) != 0 { throw controllerSessionIO("sync private session parent") }
        try revalidate(); try retained.revalidate()
        return retained
    }
    package func publish(sealedData: Data, name: String, validating: () throws -> Void) throws {
        guard !sealedData.isEmpty, sealedData.count <= StrictJSONLimits.standard.maximumBytes,
              ["in-progress.json", "manifest.json", "preview-ready.json"].contains(name) else {
            throw ControllerSessionArtifactError.invalidArgument
        }
        try revalidate()
        let temporary = ".agentbuild-generation-" + UUID().uuidString + ".sealed"
        var writer = openat(directory.value, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard writer >= 0 else { throw controllerSessionIO("create generation report") }
        defer { if writer >= 0 { _ = close(writer) } }
        let created = try controllerSessionStat(writer)
        guard created.st_mode & S_IFMT == S_IFREG, created.st_uid == geteuid(), created.st_nlink == 1 else { throw ControllerSessionArtifactError.changed }
        try sealedData.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(writer, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw controllerSessionIO("write generation report") }
                offset += count
            }
        }
        guard fchmod(writer, 0o400) == 0, fsync(writer) == 0 else { throw controllerSessionIO("seal generation report") }
        let retiring = writer; writer = -1
        guard close(retiring) == 0 else { throw controllerSessionIO("retire generation report writer") }
        try revalidate(); try validating()
        guard linkat(directory.value, temporary, directory.value, name, 0) == 0 else { throw controllerSessionIO("publish generation report without overwrite") }
        guard unlinkat(directory.value, temporary, 0) == 0, fsync(directory.value) == 0 else { throw controllerSessionIO("sync generation report") }
        let retained = try custody.openFile(named: name, policy: ArtifactFilePolicy(minimumBytes: 1, requiredPermissions: 0o400))
        guard retained.fingerprint.device == Int64(created.st_dev), retained.fingerprint.inode == UInt64(created.st_ino),
              try retained.readBounded() == sealedData else { throw ControllerSessionArtifactError.changed }
        sealed.withLock { $0.append(retained) }
        try validating(); try revalidate()
    }
}

private func controllerSessionIO(_ operation: String) -> ControllerSessionArtifactError { .io(operation, errno) }
private func controllerSessionStat(_ descriptor: Int32) throws -> stat {
    var result = stat()
    guard fstat(descriptor, &result) == 0 else { throw controllerSessionIO("stat session inode") }
    return result
}
