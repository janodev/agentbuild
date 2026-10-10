import AgentLeaseCore
import Darwin
import Foundation

public enum NativeInvocationLedgerError: Error, Equatable, Sendable {
    case invalidPlan
    case phaseAlreadyActive
    case planFinished
    case ledgerStopped
    case unexpectedPhase(expectedOrdinal: Int, expectedPhaseOrdinal: Int)
    case argumentsMismatch
    case foreignClaim
    case inactiveClaim
    case invalidTermination
    case missingObservation
}

/// An immutable physical phase derived from the closed Notika logical plan.
public struct NativeInvocationPhase: Equatable, Sendable {
    public let ordinal: Int
    public let phaseOrdinal: Int
    public let physicalOrdinal: Int
    public let segment: String
    public let arguments: [String]
    public let requiresCompilation: Bool
    public let argumentCommitment: String

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.ordinal == rhs.ordinal && lhs.phaseOrdinal == rhs.phaseOrdinal
            && lhs.physicalOrdinal == rhs.physicalOrdinal
            && Array(lhs.segment.utf8) == Array(rhs.segment.utf8)
            && lhs.requiresCompilation == rhs.requiresCompilation
            && Array(lhs.argumentCommitment.utf8) == Array(rhs.argumentCommitment.utf8)
            && ledgerArgumentsEqual(lhs.arguments, rhs.arguments)
    }
}

/// Only its owning ledger can construct a token. Copying a token grants no
/// additional admission: completion consumes the one currently active claim.
public struct NativeInvocationClaim: Sendable {
    public let phase: NativeInvocationPhase
    fileprivate let ledgerIdentity: UUID
    fileprivate let claimIdentity: UUID

    fileprivate init(phase: NativeInvocationPhase, ledgerIdentity: UUID, claimIdentity: UUID) {
        self.phase = phase
        self.ledgerIdentity = ledgerIdentity
        self.claimIdentity = claimIdentity
    }
}

public struct NativeInvocationCompletion: Equatable, Sendable {
    public let phase: NativeInvocationPhase
    /// Nil means the executor did not observe a child termination.
    public let termination: RunTermination?
    public let ancillaryFailure: String?
    public let cancelled: Bool

    public var nativeExitCode: Int32? {
        termination.map { $0.kind == .exit ? $0.value : 128 + $0.value }
    }
}

public enum NativeInvocationLedgerState: String, Equatable, Sendable {
    case ready
    case running
    case completed
    case stopped
}

/// Native failure takes precedence without discarding other observations from
/// the completion. A driver failure never becomes a synthetic native result.
public enum NativeInvocationStopReason: Equatable, Sendable {
    case nativeFailure(RunTermination)
    case cancelled
    case driverFailure(String)
}

public struct NativeInvocationLedgerSnapshot: Equatable, Sendable {
    public let state: NativeInvocationLedgerState
    public let plannedPhaseCount: Int
    public let completedPhaseCount: Int
    public let activePhase: NativeInvocationPhase?
    public let nextPhase: NativeInvocationPhase?
    public let completions: [NativeInvocationCompletion]
    public let stopReason: NativeInvocationStopReason?
}

/// Serial admission for one immutable plan. This actor provides invocation
/// authority only; its executor still owns process, resource, and file custody.
public actor NativeInvocationLedger {
    public nonisolated let phases: [NativeInvocationPhase]

    private let identity = UUID()
    private var cursor = 0
    private var activeClaim: NativeInvocationClaim?
    private var completions: [NativeInvocationCompletion] = []
    private var stopReason: NativeInvocationStopReason?

    public init(plan: NotikaXcodeInvocationPlan) throws {
        guard !plan.invocations.isEmpty else { throw NativeInvocationLedgerError.invalidPlan }
        var expanded: [NativeInvocationPhase] = []
        for (ordinal, invocation) in plan.invocations.enumerated() {
            guard invocation.ordinal == ordinal else { throw NativeInvocationLedgerError.invalidPlan }
            let execution = try XcodeExecutionPlan(arguments: invocation.arguments)
            for (phaseOrdinal, phase) in execution.phases.enumerated() {
                expanded.append(NativeInvocationPhase(
                    ordinal: ordinal,
                    phaseOrdinal: phaseOrdinal,
                    physicalOrdinal: expanded.count,
                    segment: invocation.segment,
                    arguments: phase.arguments,
                    requiresCompilation: phase.requiresCompilation,
                    argumentCommitment: ArgumentCommitment.digest(arguments: phase.arguments)
                ))
            }
        }
        phases = expanded
    }

    public func claim(ordinal: Int, phaseOrdinal: Int, arguments: [String]) throws -> NativeInvocationClaim {
        guard stopReason == nil else { throw NativeInvocationLedgerError.ledgerStopped }
        guard activeClaim == nil else { throw NativeInvocationLedgerError.phaseAlreadyActive }
        guard cursor < phases.count else { throw NativeInvocationLedgerError.planFinished }
        let expected = phases[cursor]
        guard ordinal == expected.ordinal, phaseOrdinal == expected.phaseOrdinal else {
            throw NativeInvocationLedgerError.unexpectedPhase(
                expectedOrdinal: expected.ordinal, expectedPhaseOrdinal: expected.phaseOrdinal
            )
        }
        // Swift String equality treats composed and decomposed spellings as
        // equal. Invocation authority compares the literal bytes and boundaries.
        guard ledgerArgumentsEqual(arguments, expected.arguments) else {
            throw NativeInvocationLedgerError.argumentsMismatch
        }
        let claim = NativeInvocationClaim(phase: expected, ledgerIdentity: identity, claimIdentity: UUID())
        activeClaim = claim
        return claim
    }

    public func complete(
        _ claim: NativeInvocationClaim,
        termination: RunTermination?,
        ancillaryFailure: String? = nil,
        cancelled: Bool = false
    ) throws {
        guard claim.ledgerIdentity == identity else { throw NativeInvocationLedgerError.foreignClaim }
        guard let activeClaim, activeClaim.claimIdentity == claim.claimIdentity else {
            throw NativeInvocationLedgerError.inactiveClaim
        }
        if let termination {
            let valid = termination.kind == .exit
                ? (0...255).contains(termination.value) : (1..<NSIG).contains(termination.value)
            guard valid else { throw NativeInvocationLedgerError.invalidTermination }
        }
        guard termination != nil || ancillaryFailure != nil || cancelled else {
            throw NativeInvocationLedgerError.missingObservation
        }
        let completion = NativeInvocationCompletion(
            phase: activeClaim.phase, termination: termination,
            ancillaryFailure: ancillaryFailure, cancelled: cancelled
        )
        completions.append(completion)
        self.activeClaim = nil
        cursor += 1
        if let termination, completion.nativeExitCode != 0 {
            stopReason = .nativeFailure(termination)
        } else if cancelled {
            stopReason = .cancelled
        } else if let ancillaryFailure {
            stopReason = .driverFailure(ancillaryFailure)
        }
    }

    public func snapshot() -> NativeInvocationLedgerSnapshot {
        let state: NativeInvocationLedgerState = if stopReason != nil {
            .stopped
        } else if activeClaim != nil {
            .running
        } else if cursor == phases.count {
            .completed
        } else {
            .ready
        }
        return NativeInvocationLedgerSnapshot(
            state: state,
            plannedPhaseCount: phases.count,
            completedPhaseCount: completions.count,
            activePhase: activeClaim?.phase,
            nextPhase: state == .ready ? phases[cursor] : nil,
            completions: completions,
            stopReason: stopReason
        )
    }
}

private func ledgerArgumentsEqual(_ lhs: [String], _ rhs: [String]) -> Bool {
    lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { Array($0.utf8) == Array($1.utf8) }
}
