import Darwin
import Foundation

/// Descriptors, rather than mutable paths, own the session's evidence. Callers
/// borrow the log descriptors; this object closes them only when it is released.
internal final class SessionArtifacts: Sendable {
    let directoryPath: String
    let standardOutputPath: String
    let standardErrorPath: String
    let stdoutDescriptor: Int32
    let stderrDescriptor: Int32

    private let directoryDescriptor: Int32

    init(root: String, runID: String) throws {
        guard root.hasPrefix("/"), !root.utf8.contains(0),
              let identifier = UUID(uuidString: runID),
              identifier.uuidString.lowercased() == runID.lowercased() else {
            throw ManagedExecutionError.invalidRequest("artifact root must be absolute and run ID must be a UUID")
        }

        let components = root.split(separator: "/")
        guard !components.contains("."), !components.contains("..") else {
            throw ManagedExecutionError.invalidRequest("artifact root must not contain relative path components")
        }
        let rootPath = "/" + components.joined(separator: "/")
        try Self.createRoot(rootPath)
        let rootDescriptor = Darwin.open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootDescriptor >= 0 else { throw Self.failure("open artifact root") }
        defer { Darwin.close(rootDescriptor) }
        try Self.validateDirectory(rootDescriptor, operation: "validate artifact root", privateMode: false)

        guard Darwin.mkdirat(rootDescriptor, runID, 0o700) == 0 else {
            throw Self.failure("create artifact session")
        }
        let sessionDescriptor = Darwin.openat(
            rootDescriptor, runID, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard sessionDescriptor >= 0 else {
            let failure = Self.failure("open artifact session")
            Darwin.unlinkat(rootDescriptor, runID, AT_REMOVEDIR)
            throw failure
        }

        var outputDescriptor: Int32 = -1
        var errorDescriptor: Int32 = -1
        do {
            guard Darwin.fchmod(sessionDescriptor, 0o700) == 0 else {
                throw Self.failure("set artifact session permissions")
            }
            try Self.validateDirectory(sessionDescriptor, operation: "validate artifact session", privateMode: true)
            outputDescriptor = try Self.openLog("stdout.log", directory: sessionDescriptor)
            errorDescriptor = try Self.openLog("stderr.log", directory: sessionDescriptor)
            try Self.synchronize(sessionDescriptor, operation: "synchronize artifact session")
            try Self.synchronize(rootDescriptor, operation: "synchronize artifact root")
        } catch {
            if outputDescriptor >= 0 { Darwin.close(outputDescriptor) }
            if errorDescriptor >= 0 { Darwin.close(errorDescriptor) }
            Darwin.unlinkat(sessionDescriptor, "stdout.log", 0)
            Darwin.unlinkat(sessionDescriptor, "stderr.log", 0)
            Darwin.close(sessionDescriptor)
            Darwin.unlinkat(rootDescriptor, runID, AT_REMOVEDIR)
            throw error
        }

        directoryPath = (rootPath as NSString).appendingPathComponent(runID)
        standardOutputPath = (directoryPath as NSString).appendingPathComponent("stdout.log")
        standardErrorPath = (directoryPath as NSString).appendingPathComponent("stderr.log")
        stdoutDescriptor = outputDescriptor
        stderrDescriptor = errorDescriptor
        directoryDescriptor = sessionDescriptor
    }

    deinit {
        Darwin.close(stdoutDescriptor)
        Darwin.close(stderrDescriptor)
        Darwin.close(directoryDescriptor)
    }

    func publish(_ report: ManagedExecutionReport) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes: Data
        do {
            bytes = try encoder.encode(report)
        } catch {
            throw ManagedExecutionError.artifactIO(operation: "encode session manifest", code: EINVAL)
        }

        let temporaryName = ".manifest-\(UUID().uuidString).tmp"
        var descriptor = Darwin.openat(
            directoryDescriptor, temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600
        )
        guard descriptor >= 0 else { throw Self.failure("create session manifest") }
        var temporaryExists = true
        defer {
            if descriptor >= 0 { Darwin.close(descriptor) }
            if temporaryExists { Darwin.unlinkat(directoryDescriptor, temporaryName, 0) }
        }
        guard Darwin.fchmod(descriptor, 0o600) == 0 else {
            throw Self.failure("set manifest permissions")
        }
        try Self.write(bytes, descriptor: descriptor)
        try Self.synchronize(descriptor, operation: "synchronize session manifest")
        let closeResult = Darwin.close(descriptor)
        descriptor = -1
        guard closeResult == 0 else { throw Self.failure("close session manifest") }
        guard Darwin.renameat(directoryDescriptor, temporaryName, directoryDescriptor, "manifest.json") == 0 else {
            throw Self.failure("publish session manifest")
        }
        temporaryExists = false
        try Self.synchronize(directoryDescriptor, operation: "synchronize manifest directory")
    }

    func logSizes() throws -> (standardOutput: Int64, standardError: Int64) {
        (
            try Self.size(of: stdoutDescriptor, operation: "measure stdout log"),
            try Self.size(of: stderrDescriptor, operation: "measure stderr log")
        )
    }

    func synchronizeLogs() throws {
        try Self.synchronize(stdoutDescriptor, operation: "synchronize stdout log")
        try Self.synchronize(stderrDescriptor, operation: "synchronize stderr log")
    }

    private static func createRoot(_ path: String) throws {
        var componentPath = ""
        for component in path.split(separator: "/") {
            componentPath += "/\(component)"
            if Darwin.mkdir(componentPath, 0o700) != 0, errno != EEXIST {
                throw failure("create artifact root")
            }
        }
    }

    private static func validateDirectory(_ descriptor: Int32, operation: String, privateMode: Bool) throws {
        var attributes = stat()
        guard Darwin.fstat(descriptor, &attributes) == 0 else { throw failure(operation) }
        guard attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              attributes.st_uid == geteuid(),
              attributes.st_mode & 0o022 == 0,
              !privateMode || attributes.st_mode & 0o777 == 0o700 else {
            throw ManagedExecutionError.artifactIO(operation: operation, code: EPERM)
        }
    }

    private static func openLog(_ name: String, directory: Int32) throws -> Int32 {
        let descriptor = Darwin.openat(
            directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600
        )
        guard descriptor >= 0 else { throw failure("create \(name)") }
        guard Darwin.fchmod(descriptor, 0o600) == 0 else {
            let failure = failure("set \(name) permissions")
            Darwin.close(descriptor)
            throw failure
        }
        return descriptor
    }

    private static func size(of descriptor: Int32, operation: String) throws -> Int64 {
        var attributes = stat()
        guard Darwin.fstat(descriptor, &attributes) == 0 else { throw failure(operation) }
        return attributes.st_size
    }

    private static func synchronize(_ descriptor: Int32, operation: String) throws {
        while Darwin.fsync(descriptor) != 0 {
            if errno != EINTR { throw failure(operation) }
        }
    }

    private static func write(_ bytes: Data, descriptor: Int32) throws {
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw failure("write session manifest")
                }
                guard count > 0 else {
                    throw ManagedExecutionError.artifactIO(operation: "write session manifest", code: EIO)
                }
                offset += count
            }
        }
    }

    private static func failure(_ operation: String) -> ManagedExecutionError {
        .artifactIO(operation: operation, code: errno)
    }
}
