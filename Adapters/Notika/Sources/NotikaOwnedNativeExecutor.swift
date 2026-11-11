import AgentBuildCore
import AgentLeaseCore
import Foundation

public enum NotikaOwnedExecutionError: Error, Equatable, Sendable {
    case incompatibleOwnership
    case incompatibleProfile
}

public struct NotikaOwnedPhaseObservation: Sendable {
    public let phase: NativeInvocationPhase
    public let workload: NativeObservation
}

/// Native observations remain distinct from orchestration failures. This is a
/// returned in-memory outcome, not an admitted filesystem execution receipt.
public struct NotikaOwnedExecutionOutcome: Sendable {
    public let ledger: NativeInvocationLedgerSnapshot
    public let observations: [NotikaOwnedPhaseObservation]
    public let orchestrationFailure: String?
    public let cancelled: Bool

    public var nativeFailure: RunTermination? {
        ledger.completions.first { $0.nativeExitCode != nil && $0.nativeExitCode != 0 }?.termination
    }

    public var complete: Bool {
        ledger.state == .completed && orchestrationFailure == nil && !cancelled
    }
}

/// Consumes the immutable plan directly beneath an existing project owner.
/// The injected operation is a trusted executor: it must not throw or return
/// until all started work is retired, its direct child is reaped, and raw
/// capture is drained. The production helper adapter fulfills that obligation;
/// command plans and this owner alone do not establish process custody.
public struct NotikaOwnedNativeExecutor: Sendable {
    public init() {}

    public func run(
        _ plan: NotikaXcodeInvocationPlan,
        identity: CacheCompatibilityIdentity,
        ownership: ProjectOwnership,
        environment: [String: String],
        metalToolchain: String? = nil,
        compilationWaitSeconds: Double? = nil,
        execute: @escaping @Sendable (
            DarwinWorkloadCommand, NativeInvocationClaim, [Int32]
        ) async throws -> NativeObservation
    ) async throws -> NotikaOwnedExecutionOutcome {
        let admitted = try NotikaProjectOwnershipPlan(
            identity: identity,
            admittedCacheKey: ownership.plan.cacheDirectory?.split(separator: "/").last.map(String.init)
        )
        guard admitted == ownership.plan, let cacheDirectory = admitted.cacheDirectory,
              plan.invocations.allSatisfy({ $0.cacheDirectory.utf8.elementsEqual(cacheDirectory.utf8) }) else {
            throw NotikaOwnedExecutionError.incompatibleOwnership
        }
        let profile = NotikaCacheProfile(request: plan.request)
        guard identity.purpose == nil,
              identity.scheme == profile.scheme,
              identity.configuration == profile.configuration,
              identity.destinationFamily == profile.destinationFamily,
              identity.buildFlags.map({ Data($0.utf8) }) == profile.buildFlags.map({ Data($0.utf8) }) else {
            throw NotikaOwnedExecutionError.incompatibleProfile
        }
        _ = try ownership.inheritedDescriptors()
        let ledger = try NativeInvocationLedger(plan: plan)
        var observations: [NotikaOwnedPhaseObservation] = []
        var failure: String?
        var wasCancelled = false
        for phase in ledger.phases {
            if Task.isCancelled {
                wasCancelled = true
                break
            }
            let snapshot = await ledger.snapshot()
            guard snapshot.state == .ready else { break }
            let claim = try await ledger.claim(
                ordinal: phase.ordinal, phaseOrdinal: phase.phaseOrdinal, arguments: phase.arguments
            )
            do {
                let nativeEnvironment = try NotikaChildEnvironmentPolicy.nativeEnvironment(
                    from: environment, bindings: NotikaNativeEnvironmentBindings(
                        repository: identity.canonicalWorktree,
                        toolSearchPath: environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
                        derivedData: cacheDirectory, metalToolchain: metalToolchain
                    )
                )
                let command = try DarwinWorkloadCommand(
                    executable: "/usr/bin/xcodebuild", arguments: phase.arguments,
                    workingDirectory: identity.canonicalWorktree, environment: nativeEnvironment
                )
                let operation: @Sendable (CompilationLease?) async throws -> NativeObservation = { lease in
                    let descriptors = try ownership.inheritedDescriptors() + (lease?.inheritedDescriptors() ?? [])
                    return try await execute(command, claim, descriptors)
                }
                let result: NativeObservation
                if phase.requiresCompilation {
                    result = try await HostCompilationAdmission().withLease(
                        environment: environment, label: "Notika \(phase.segment) compilation",
                        waitSeconds: compilationWaitSeconds
                    ) { lease in try await operation(lease) }
                } else {
                    result = try await operation(nil)
                }
                observations.append(NotikaOwnedPhaseObservation(phase: phase, workload: result))
                let ancillary = result.failures.isEmpty ? nil : result.failures.map {
                    "\($0.operation): \($0.detail ?? $0.code.map(String.init) ?? "failure")"
                }.joined(separator: "; ")
                let cancelled = result.cancelled || Task.isCancelled
                try await ledger.complete(
                    claim, termination: result.termination,
                    ancillaryFailure: ancillary, cancelled: cancelled
                )
                wasCancelled = wasCancelled || cancelled
            } catch {
                let cancelled = error is CancellationError || Task.isCancelled
                let detail = String(describing: error)
                try await ledger.complete(
                    claim, termination: nil, ancillaryFailure: detail, cancelled: cancelled
                )
                failure = detail
                wasCancelled = wasCancelled || cancelled
                break
            }
        }
        return NotikaOwnedExecutionOutcome(
            ledger: await ledger.snapshot(), observations: observations,
            orchestrationFailure: failure, cancelled: wasCancelled
        )
    }
}
