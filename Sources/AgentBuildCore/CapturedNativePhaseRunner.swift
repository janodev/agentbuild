import AgentLeaseCore
import Foundation

public enum NativeRetirementEvidence: String, Codable, Sendable {
    case notStarted
    case workerReaped
    case groupQuiescentWithoutReceipt
}

/// Missing helper receipts remain missing native observations, even after
/// independent group quiescence permits releasing the retained lock references.
public struct NativeObservation: Sendable {
    public let processIdentifier: Int32?
    public let termination: RunTermination?
    public let retirement: NativeRetirementEvidence
    public let cancelled: Bool
    public let failures: [DarwinWorkloadFailure]
    public let worker: DarwinWorkloadResult?
    public let helperTermination: RunTermination?

    public init(worker: DarwinWorkloadResult) {
        processIdentifier = worker.processIdentifier
        termination = worker.termination
        retirement = worker.retirement == .notStarted ? .notStarted : .workerReaped
        cancelled = worker.stopReason == .cancelled || worker.stopReason == .ownerEOF
        failures = worker.failures
        self.worker = worker
        helperTermination = nil
    }

    fileprivate init(helper: NativePhaseResult, capture: NativeLogCaptureResult, cancelled: Bool) {
        processIdentifier = helper.workload?.processIdentifier ?? helper.quarantine?.nativePID
        termination = helper.workload?.termination
        if let worker = helper.workload {
            retirement = worker.retirement == .notStarted ? .notStarted : .workerReaped
        } else {
            retirement = helper.retirement == .notStarted ? .notStarted : .groupQuiescentWithoutReceipt
        }
        self.cancelled = helper.cancellationRequested || cancelled
        var failures = helper.workload?.failures ?? []
        failures += helper.failures
        failures += capture.failures.map {
            DarwinWorkloadFailure(operation: "rawLog.\($0.operation)", code: $0.code,
                                  detail: $0.detail ?? $0.stream?.rawValue)
        }
        if !capture.captureComplete && capture.failures.isEmpty {
            failures.append(.init(operation: "raw log incomplete"))
        }
        if helper.workload == nil && helper.retirement != .notStarted {
            failures.append(.init(operation: "native result unobserved"))
        }
        self.failures = failures
        worker = helper.workload
        helperTermination = helper.helperTermination
    }
}

/// Keeps raw evidence descriptors and final mutation watches alive until the
/// session publisher has validated/sealed its references. Paths alone do not
/// carry this ownership. Holding this object does not own project leases.
public final class CapturedNativePhase: Sendable {
    public let command: DarwinWorkloadCommand
    public let workingDirectoryIdentity: NativeWorkingDirectoryIdentity?
    public let observation: NativeObservation
    public let rawCapture: NativeLogCaptureResult
    private let retainedCapture: NativeLogCapture

    fileprivate init(command: DarwinWorkloadCommand, helper: NativePhaseResult, capture: NativeLogCapture, result: NativeLogCaptureResult) {
        self.command = command
        workingDirectoryIdentity = helper.workingDirectoryIdentity
        observation = NativeObservation(helper: helper, capture: result, cancelled: Task.isCancelled)
        rawCapture = result
        retainedCapture = capture
    }

    public func revalidateForPublication() throws {
        try retainedCapture.revalidateForPublication(rawCapture)
    }
}

/// Couples helper retirement with complete raw-pipe draining. The caller holds
/// session/project/compilation ownership until this method returns, and retains
/// the returned evidence capsule through terminal publication.
public struct CapturedNativePhaseRunner: Sendable {
    public init() {}

    public func run(
        helperExecutable: String,
        command: DarwinWorkloadCommand,
        retainedLockDescriptors: [Int32],
        nativeWorkingDirectoryDescriptor: Int32? = nil,
        artifactRoot: String,
        runID: String = UUID().uuidString,
        onHelperStart: @escaping @Sendable (Int32) throws -> Void = { _ in },
        onNativeStart: @escaping @Sendable (Int32) throws -> Void = { _ in }
    ) async throws -> CapturedNativePhase {
        let capture = try NativeLogCapture(root: artifactRoot, runID: runID)
        let helper = await NativePhaseSupervisor().run(
            helperExecutable: helperExecutable, command: command,
            retainedLockDescriptors: retainedLockDescriptors,
            nativeWorkingDirectoryDescriptor: nativeWorkingDirectoryDescriptor,
            standardOutputDescriptor: capture.standardOutputDescriptor,
            standardErrorDescriptor: capture.standardErrorDescriptor,
            onHelperStart: onHelperStart, onNativeStart: onNativeStart,
            observeFailure: { capture.supervisorFailure() }
        )
        // This uncancellable wait also covers helper failure. Returning early
        // would let scope teardown drop locks while unknown descendants run.
        if let quarantine = helper.quarantine { await quarantine.waitUntilProvenQuiescent() }
        let raw = await capture.finishAfterWorkerRetirement()
        return CapturedNativePhase(command: command, helper: helper, capture: capture, result: raw)
    }
}
