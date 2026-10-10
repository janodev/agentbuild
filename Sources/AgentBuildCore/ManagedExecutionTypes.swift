import AgentLeaseCore
import Foundation

public struct ManagedCommand: Sendable {
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: String
    public let artifactsRoot: String
    public let leaseHome: String?
    public let label: String
    public let waitSeconds: Double?
    let resources: ResourceSet

    public init(
        executable: String,
        arguments: [String] = [],
        workingDirectory: String,
        artifactsRoot: String,
        exclusiveResources: [String],
        sharedResources: [String] = [],
        leaseHome: String? = nil,
        label: String = "agentbuild command",
        waitSeconds: Double? = nil
    ) throws {
        for path in [executable, workingDirectory, artifactsRoot] + (leaseHome.map { [$0] } ?? []) {
            guard path.hasPrefix("/"), !path.utf8.contains(0) else {
                throw ManagedExecutionError.invalidRequest("paths must be absolute and contain no NUL")
            }
        }
        guard !arguments.contains(where: { $0.utf8.contains(0) }),
              !label.utf8.contains(0), (1...256).contains(label.utf8.count) else {
            throw ManagedExecutionError.invalidRequest("invalid arguments or label")
        }
        if let waitSeconds, !waitSeconds.isFinite || waitSeconds < 0 {
            throw ManagedExecutionError.invalidRequest("wait duration must be finite and nonnegative")
        }
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.artifactsRoot = artifactsRoot
        self.leaseHome = leaseHome
        self.label = label
        self.waitSeconds = waitSeconds
        resources = try ResourceSet(exclusive: exclusiveResources, shared: sharedResources)
    }
}

public enum ManagedExecutionState: String, Codable, Sendable {
    case acquiring
    case running
    case completed
    case cancelled
    case failed
}

public struct ManagedExecutionReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let toolVersion: String
    public let runID: String
    public var state: ManagedExecutionState
    public let executable: String
    public let argumentCommitment: String
    public let workingDirectory: String
    public let resources: [ResourceLease]
    public let label: String
    public let coordinatorPID: Int32
    public var childPID: Int32?
    public let startedAt: String
    public var finishedAt: String?
    public var receivedSignal: Int32?
    public var termination: RunTermination?
    public var failure: AgentLeaseFailure?
    public var metadataFailures: [AgentLeaseFailure]
    public let standardOutputPath: String
    public let standardErrorPath: String
    public var standardOutputBytes: Int64
    public var standardErrorBytes: Int64

    public var exitCode: Int32 {
        if state == .cancelled { return 128 + (receivedSignal ?? 2) }
        if let termination {
            return termination.kind == .exit ? termination.value : 128 + termination.value
        }
        if failure?.kind == .acquisitionTimeout { return 75 }
        if failure?.kind == .executableNotFound { return 127 }
        if failure?.kind == .executableNotRunnable { return 126 }
        return 70
    }
}

public enum ManagedExecutionError: Error, Sendable {
    case invalidRequest(String)
    case nestedExecution
    case artifactIO(operation: String, code: Int32)
    case evidencePublication(report: ManagedExecutionReport, detail: String)
}
