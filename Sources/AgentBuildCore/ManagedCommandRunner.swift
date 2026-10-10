import AgentLeaseCore
import Darwin
import Dispatch
import Foundation
import Subprocess

/// Owns each structured command until Subprocess has reaped its direct child.
/// AgentLease closes its references without unlocking inheriting descendants.
public struct ManagedCommandRunner: Sendable {
    public init() {}

    public func run(
        _ command: ManagedCommand,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        receivedSignal: @escaping @Sendable () -> Int32? = { nil },
        onStart: @escaping @Sendable (Int32) async throws -> Void = { _ in }
    ) async throws -> ManagedExecutionReport {
        guard !ChildEnvironment.isNested(environment: environment) else {
            throw ManagedExecutionError.nestedExecution
        }
        let paths = try command.leaseHome.map { try AgentLeasePaths.open(selectedRoot: $0) }
            ?? AgentLeasePaths.open(environment: environment)
        let runID = UUID().uuidString
        let artifacts = try SessionArtifacts(root: command.artifactsRoot, runID: runID)
        let context = MetadataContext(command: command, runID: runID)
        let journal = ExecutionJournal(command: command, context: context, paths: paths, artifacts: artifacts)
        let acquisitionStarted = DispatchTime.now().uptimeNanoseconds
        var lease: LeaseSet?
        let result: SupervisedProcessResult
        // On every path, release follows awaited subprocess teardown and publication.
        defer { lease?.release() }
        do {
            let admission = try await RegistryGate.shared(paths: paths, waitSeconds: command.waitSeconds)
            defer { admission.release() }
            try await journal.publishInitial()
            let remainingWait = try remainingAcquisitionWait(
                command.waitSeconds,
                elapsed: Double(DispatchTime.now().uptimeNanoseconds - acquisitionStarted) / 1_000_000_000
            )
            let acquired = try await LeaseSet.acquire(
                command.resources,
                paths: paths,
                waitSeconds: remainingWait,
                initialMetadata: { context.value($0, state: .acquiring, childPID: nil) }
            )
            lease = acquired
            admission.release()
            try Task.checkCancellation()
            let childEnvironment = try ChildEnvironment.addingLeaseDescriptorManifest(
                acquired.inheritedLeaseDescriptors,
                to: ChildEnvironment.build(
                    inherited: environment, stateRoot: paths.rootPath, runID: runID,
                    resources: command.resources, bead: nil
                )
            )
            result = try await SupervisedSubprocess.run(
                executablePath: command.executable,
                arguments: [command.executable] + command.arguments,
                environment: childEnvironment,
                inheritedDescriptors: acquired.inheritedDescriptors,
                workingDirectory: command.workingDirectory,
                standardOutputDescriptor: artifacts.stdoutDescriptor,
                standardErrorDescriptor: artifacts.stderrDescriptor,
                teardownSequence: [.send(signal: .kill, toProcessGroup: true, allowedDurationToNextStep: .zero)]
            ) { childPID in
                try await journal.running(childPID: childPID)
                acquired.updateMetadata { context.value($0, state: .running, childPID: childPID) }
                try await onStart(childPID)
            }
        } catch {
            return try await finishFailure(error, lease: lease, journal: journal, context: context,
                                           receivedSignal: receivedSignal())
        }
        let termination: RunTermination = switch result.termination {
        case .exited(let code): RunTermination(kind: .exit, value: code)
        case .signaled(let signal): RunTermination(kind: .signal, value: signal)
        }
        lease?.updateMetadata {
            context.value($0, state: termination.kind == .exit ? .exited : .signalled,
                          childPID: result.processIdentifier)
        }
        // Only this final publication may carry this command's observed native result.
        // Callback errors pass through lifecycle finalization above, even when they
        // happen to use the same public evidencePublication error case.
        return try await journal.finish(
            state: .completed, termination: termination, failure: nil, receivedSignal: nil,
            metadataFailures: lease?.takeMetadataWriteIssues().map(\.failure) ?? []
        )
    }

    private func finishFailure(
        _ error: any Error, lease: LeaseSet?, journal: ExecutionJournal, context: MetadataContext,
        receivedSignal: Int32?
    ) async throws -> ManagedExecutionReport {
        let snapshot = await journal.snapshot()
        let cancelled = error is CancellationError || Task.isCancelled
        let failure: AgentLeaseFailure
        if cancelled {
            failure = AgentLeaseFailure(kind: .cancelled, operation: "run", message: "command cancelled")
        } else if let error = error as? LeaseSetError {
            failure = error.failure
        } else if let error = error as? FileLockError {
            failure = error.failure
        } else if let error = error as? AtomicJSONStoreError {
            failure = error.failure
        } else if error is ManagedExecutionError {
            failure = AgentLeaseFailure(kind: .recordPublication, operation: "artifacts",
                                        message: String(describing: error))
        } else if snapshot.childPID == nil {
            failure = SupervisedSubprocess.classifyLaunchError(error).failure
        } else {
            failure = AgentLeaseFailure(kind: .internal, operation: "runningCommand",
                                        message: String(describing: error))
        }
        lease?.updateMetadata {
            context.value($0, state: receivedSignal == nil ? .failed : .signalled, childPID: snapshot.childPID)
        }
        return try await journal.finish(
            state: cancelled ? .cancelled : .failed, termination: nil, failure: failure,
            receivedSignal: receivedSignal,
            metadataFailures: lease?.takeMetadataWriteIssues().map(\.failure) ?? []
        )
    }
}

/// An explicit zero permits one immediate attempt; an expired positive budget does not.
private func remainingAcquisitionWait(_ seconds: Double?, elapsed: Double) throws -> Double? {
    guard let seconds else { return nil }
    if seconds == 0 { return 0 }
    let remaining = seconds - elapsed
    guard remaining > 0 else { throw LeaseSetError.timedOut("registry") }
    return remaining
}

private struct MetadataContext: Sendable {
    let command: ManagedCommand
    let runID: String
    let startedAt = RunRecord.timestamp()
    let coordinatorPID = getpid()

    func value(_ lease: ResourceLease, state: RunState, childPID: Int32?) -> LockMetadata {
        LockMetadata(resourceName: lease.resource.value, leaseMode: lease.mode, runID: runID,
                     coordinatorPID: coordinatorPID, childPID: childPID, mode: .run, state: state,
                     label: command.label, bead: nil, acquiredAt: startedAt)
    }
}

private actor ExecutionJournal {
    private var report: ManagedExecutionReport
    private var record: RunRecord
    private let store: AtomicJSONStore
    private let artifacts: SessionArtifacts

    init(command: ManagedCommand, context: MetadataContext, paths: AgentLeasePaths, artifacts: SessionArtifacts) {
        let commitment = ArgumentCommitment.digest(arguments: [command.executable] + command.arguments)
        report = ManagedExecutionReport(
            schemaVersion: 1, toolVersion: AgentBuild.version, runID: context.runID, state: .acquiring,
            executable: command.executable, argumentCommitment: commitment,
            workingDirectory: command.workingDirectory, resources: command.resources.leases,
            label: command.label, coordinatorPID: context.coordinatorPID, childPID: nil,
            startedAt: context.startedAt, finishedAt: nil, receivedSignal: nil, termination: nil, failure: nil,
            metadataFailures: [], standardOutputPath: artifacts.standardOutputPath,
            standardErrorPath: artifacts.standardErrorPath, standardOutputBytes: 0, standardErrorBytes: 0
        )
        record = RunRecord(
            runID: context.runID, mode: .run, state: .acquiring,
            resources: command.resources.resources.map(\.value), resourceLeases: command.resources.leases,
            label: command.label, bead: nil, coordinatorPID: context.coordinatorPID, childPID: nil,
            workingDirectory: command.workingDirectory, executable: command.executable,
            resolvedExecutable: command.executable, argumentCommitment: commitment, arguments: nil,
            startedAt: context.startedAt, finishedAt: nil, receivedSignal: nil, termination: nil, failure: nil
        )
        store = AtomicJSONStore(paths: paths)
        self.artifacts = artifacts
    }

    func publishInitial() throws { try publish() }

    func running(childPID: Int32) throws {
        report.childPID = childPID
        report.state = .running
        record.childPID = childPID
        record.state = .running
        try publish()
    }

    func snapshot() -> ManagedExecutionReport { report }

    func finish(
        state: ManagedExecutionState, termination: RunTermination?, failure: AgentLeaseFailure?, receivedSignal: Int32?,
        metadataFailures: [AgentLeaseFailure]
    ) throws -> ManagedExecutionReport {
        report.state = state
        report.finishedAt = RunRecord.timestamp()
        report.termination = termination
        report.receivedSignal = receivedSignal
        report.failure = failure
        report.metadataFailures = metadataFailures
        record.finishedAt = report.finishedAt
        record.termination = termination
        record.receivedSignal = receivedSignal
        record.failure = failure
        record.state = termination.map { $0.kind == .exit ? .exited : .signalled }
            ?? (receivedSignal == nil ? .failed : .signalled)
        do {
            try artifacts.synchronizeLogs()
            let sizes = try artifacts.logSizes()
            report.standardOutputBytes = sizes.standardOutput
            report.standardErrorBytes = sizes.standardError
            try publish()
            return report
        } catch {
            throw ManagedExecutionError.evidencePublication(report: report, detail: String(describing: error))
        }
    }

    private func publish() throws {
        try store.replace(record, named: "\(record.runID).json")
        try artifacts.publish(report)
    }
}
