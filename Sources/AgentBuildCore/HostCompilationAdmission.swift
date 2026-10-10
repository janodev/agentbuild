import AgentLeaseCore
import Darwin
import Foundation

public enum CompilationAdmissionError: Error, Equatable, Sendable {
    case invalidOverride
    case accountHomeUnavailable(Int32)
    case invalidLabel
    case expiredLease
}

/// Account-wide compilation admission is independent of the checkout registry.
public struct HostCompilationAdmission: Sendable {
    public static let homeEnvironmentKey = "AGENTLEASE_COMPILE_HOME"
    public static let resource = "host:compile"

    public init() {}

    public static func selectedRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        if let selected = environment[homeEnvironmentKey] {
            guard selected.hasPrefix("/"), !selected.utf8.contains(0) else {
                throw CompilationAdmissionError.invalidOverride
            }
            return selected
        }
        // getpwuid_r uses the effective account, never the mutable HOME variable.
        let size = sysconf(_SC_GETPW_R_SIZE_MAX)
        var buffer = [CChar](repeating: 0, count: max(size > 0 ? Int(size) : 16_384, 1_024))
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        let code = getpwuid_r(geteuid(), &entry, &buffer, buffer.count, &result)
        guard code == 0, let result, let home = result.pointee.pw_dir else {
            throw CompilationAdmissionError.accountHomeUnavailable(code == 0 ? ENOENT : code)
        }
        let accountHome = String(cString: home)
        guard accountHome.hasPrefix("/") else {
            throw CompilationAdmissionError.accountHomeUnavailable(EINVAL)
        }
        return accountHome + "/.agentlease"
    }

    /// The caller must acquire its graph/cache ownership before entering this scope.
    /// Await the complete compilation child lifecycle inside `operation`.
    public func withLease<Result: Sendable>(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        label: String = "agentbuild compilation",
        waitSeconds: Double? = nil,
        onContention: @Sendable (BoundedMetadataRead) -> Void = { _ in },
        operation: @Sendable (CompilationLease) async throws -> Result
    ) async throws -> Result {
        guard (1...256).contains(label.utf8.count), !label.utf8.contains(0) else {
            throw CompilationAdmissionError.invalidLabel
        }
        let paths = try AgentLeasePaths.open(selectedRoot: Self.selectedRoot(environment: environment))
        let resources = try ResourceSet([Self.resource])
        let runID = UUID().uuidString
        let acquiredAt = RunRecord.timestamp()
        let coordinatorPID = getpid()
        let ownership = try await LeaseSet.acquire(
            resources, paths: paths, waitSeconds: waitSeconds,
            initialMetadata: { lease in
                LockMetadata(resourceName: lease.resource.value, leaseMode: lease.mode,
                             runID: runID, coordinatorPID: coordinatorPID, childPID: nil,
                             mode: .run, state: .acquired, label: label, bead: nil,
                             acquiredAt: acquiredAt)
            },
            onContention: { _, metadata in onContention(metadata) }
        )
        defer { ownership.release() }
        try Task.checkCancellation()
        return try await operation(CompilationLease(ownership: ownership, paths: paths, runID: runID))
    }
}

/// A borrowed capability valid only inside HostCompilationAdmission.withLease.
/// No unlock API escapes; scope exit closes references, never LOCK_UN.
public final class CompilationLease: Sendable {
    private let ownership: LeaseSet
    private let paths: AgentLeasePaths
    public let runID: String

    fileprivate init(ownership: LeaseSet, paths: AgentLeasePaths, runID: String) {
        self.ownership = ownership
        self.paths = paths
        self.runID = runID
    }

    public var registryRoot: String { paths.rootPath }
    public var metadataWriteIssues: [MetadataWriteIssue] { ownership.metadataWriteIssues }

    public func inheritedDescriptors() throws -> [Int32] {
        let descriptors = ownership.inheritedDescriptors
        guard descriptors.count == 1 else { throw CompilationAdmissionError.expiredLease }
        return descriptors
    }

    public func inheritedLeaseDescriptors() throws -> [InheritedLeaseDescriptor] {
        let descriptors = ownership.inheritedLeaseDescriptors
        guard descriptors.count == 1 else { throw CompilationAdmissionError.expiredLease }
        return descriptors
    }
}
