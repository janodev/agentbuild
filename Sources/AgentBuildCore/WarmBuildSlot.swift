import AgentLeaseCore
import Darwin
import Foundation

/// Values are borrowed for the duration of withPreparedSlot's operation.
public struct PreparedBuildSlot: Sendable {
    public let sourceDirectory: String
    public let derivedDataDirectory: String
    public let sourceDirectoryDescriptor: Int32
    public let leaseDescriptors: [Int32]
    public let syncSummary: BuildSlotSyncSummary
}

public enum BuildSlotError: Error, Equatable, Sendable {
    case emptyKey
    case overlappingDirectories
    case unsupportedEntry(String)
    case changedInput(String)
    case incompatibleNames(String)
    case systemCall(String, Int32)
}

/// The adapter supplies a stable repository/profile key and a private storage directory.
/// Each key selects one persistent source mirror, DerivedData directory, and exclusive lease.
public struct WarmBuildSlot: Sendable {
    private let pool: RetainedArtifactDirectory
    private let name: String
    public let resource: String
    public let sourceDirectory: String
    public let derivedDataDirectory: String

    /// Observe the pool identity and derive the planned paths without creating a slot.
    public init(poolDirectory: String, key: String) throws {
        guard !key.isEmpty else { throw BuildSlotError.emptyKey }
        pool = try RetainedArtifactDirectory(path: poolDirectory, requiredPermissions: 0o700)
        name = "slot-" + CanonicalJSONDigest.digest(Data(key.utf8))
        resource = "build-slot:\(pool.fingerprint.device):\(pool.fingerprint.inode):\(name)"
        sourceDirectory = pool.path + "/" + name + "/src"
        derivedDataDirectory = pool.path + "/" + name + "/DerivedData"
    }

    public func withPreparedSlot<Result: Sendable>(
        worktree: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        waitSeconds: Double? = nil,
        including: @Sendable (String) throws -> Bool,
        operation: @Sendable (PreparedBuildSlot) async throws -> Result
    ) async throws -> Result {
        try pool.revalidate()
        let origin = try RetainedArtifactDirectory(path: worktree)
        guard !pool.containsDirectory(origin.fingerprint), !origin.containsDirectory(pool.fingerprint) else {
            throw BuildSlotError.overlappingDirectories
        }
        let registry = try AgentLeasePaths.open(selectedRoot: HostCompilationAdmission.selectedRoot(environment: environment))
        let runID = UUID().uuidString
        let ownership = try await LeaseSet.acquire(ResourceSet([resource]), paths: registry,
                                                   waitSeconds: waitSeconds) { lease in
            LockMetadata(resourceName: lease.resource.value, leaseMode: lease.mode, runID: runID,
                         coordinatorPID: getpid(), childPID: nil, mode: .run, state: .acquired,
                         label: "Prepare and use build slot", bead: nil, acquiredAt: RunRecord.timestamp())
        }
        defer { ownership.release() }
        try Task.checkCancellation()
        let slot = try Self.childDirectory(name, parent: pool)
        let source = try Self.childDirectory("src", parent: slot)
        let derived = try Self.childDirectory("DerivedData", parent: slot)
        var mirror = BuildSlotMirror(device: source.fingerprint.device)
        let cwd = try source.withDirectory { target in
            try origin.withDirectory { input in
                try mirror.sync(from: input, to: target, prefix: "", including: including)
            }
            let descriptor = fcntl(target, F_DUPFD_CLOEXEC, 3)
            guard descriptor >= 0 else { throw BuildSlotError.systemCall("duplicate slot directory", errno) }
            return descriptor
        }
        defer { _ = close(cwd) }
        try origin.revalidate()
        try source.revalidate()
        try derived.revalidate()
        try Task.checkCancellation()
        return try await operation(PreparedBuildSlot(
            sourceDirectory: source.path, derivedDataDirectory: derived.path, sourceDirectoryDescriptor: cwd,
            leaseDescriptors: ownership.inheritedDescriptors, syncSummary: mirror.summary))
    }

    private static func childDirectory(_ name: String, parent: RetainedArtifactDirectory) throws -> RetainedArtifactDirectory {
        try parent.withDirectory { descriptor in
            guard mkdirat(descriptor, name, 0o700) == 0 || errno == EEXIST else {
                throw BuildSlotError.systemCall("create " + name, errno)
            }
        }
        let child = try RetainedArtifactDirectory(path: parent.path + "/" + name, requiredPermissions: 0o700)
        try parent.revalidate()
        guard child.fingerprint.device == parent.fingerprint.device else { throw BuildSlotError.unsupportedEntry(child.path) }
        return child
    }
}
