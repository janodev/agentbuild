import AgentBuildCore
import AgentLeaseCore
import Foundation
import Testing

@Suite("Native invocation ledger")
struct NativeInvocationLedgerTests {
    @Test func successfulSequenceRetainsLogicalSegmentsAndPhysicalPhases() async throws {
        let plan = try ledgerPlan(route: .test)
        let ledger = try NativeInvocationLedger(plan: plan)
        #expect(ledger.phases.map(\.ordinal) == [0, 1, 1])
        #expect(ledger.phases.map(\.phaseOrdinal) == [0, 0, 1])
        #expect(ledger.phases.map(\.physicalOrdinal) == [0, 1, 2])
        #expect(ledger.phases.map(\.segment) == ["build", "test", "test"])
        #expect(ledger.phases.map(\.requiresCompilation) == [true, true, false])
        #expect(ledger.phases[0].arguments == plan.invocations[0].arguments)
        #expect(!ledger.phases[1].arguments.contains("-resultBundlePath"))
        #expect(ledger.phases[2].arguments.contains("-resultBundlePath"))
        #expect(await ledger.snapshot().completions.isEmpty)

        for phase in ledger.phases {
            #expect(phase.argumentCommitment == ArgumentCommitment.digest(arguments: phase.arguments))
            let claim = try await ledger.claim(ordinal: phase.ordinal, phaseOrdinal: phase.phaseOrdinal,
                                               arguments: phase.arguments)
            #expect(claim.phase == phase)
            #expect(await ledger.snapshot().state == .running)
            try await ledger.complete(claim, termination: RunTermination(kind: .exit, value: 0))
        }
        let snapshot = await ledger.snapshot()
        #expect(snapshot.state == .completed)
        #expect(snapshot.plannedPhaseCount == 3)
        #expect(snapshot.completedPhaseCount == 3)
        #expect(snapshot.activePhase == nil)
        #expect(snapshot.nextPhase == nil)
        #expect(snapshot.stopReason == nil)
        #expect(snapshot.completions.map(\.phase) == ledger.phases)
        #expect(snapshot.completions.map(\.nativeExitCode) == [0, 0, 0])
        await #expect(throws: NativeInvocationLedgerError.planFinished) {
            try await ledger.claim(ordinal: 0, phaseOrdinal: 0, arguments: ledger.phases[0].arguments)
        }
    }

    @Test func substitutedSkippedAndReplayedRequestsCannotAdvanceThePlan() async throws {
        let ledger = try NativeInvocationLedger(plan: ledgerPlan(route: .testUnit))
        let first = ledger.phases[0]
        let runtime = ledger.phases[1]
        let initial = await ledger.snapshot()
        await #expect(throws: NativeInvocationLedgerError.unexpectedPhase(expectedOrdinal: 0, expectedPhaseOrdinal: 0)) {
            try await ledger.claim(ordinal: runtime.ordinal, phaseOrdinal: runtime.phaseOrdinal, arguments: runtime.arguments)
        }
        var substituted = first.arguments
        let schemePosition = try #require(substituted.firstIndex(of: "Notika"))
        substituted[schemePosition] = "DifferentScheme"
        await #expect(throws: NativeInvocationLedgerError.argumentsMismatch) {
            try await ledger.claim(ordinal: first.ordinal, phaseOrdinal: first.phaseOrdinal, arguments: substituted)
        }
        await #expect(throws: NativeInvocationLedgerError.argumentsMismatch) {
            try await ledger.claim(ordinal: first.ordinal, phaseOrdinal: first.phaseOrdinal,
                                   arguments: first.arguments + ["SWIFT_OPTIMIZATION_LEVEL=-O"])
        }
        #expect(await ledger.snapshot() == initial)
        let claim = try await ledger.claim(ordinal: first.ordinal, phaseOrdinal: first.phaseOrdinal, arguments: first.arguments)
        let active = await ledger.snapshot()
        await #expect(throws: NativeInvocationLedgerError.phaseAlreadyActive) {
            try await ledger.claim(ordinal: first.ordinal, phaseOrdinal: first.phaseOrdinal, arguments: first.arguments)
        }
        #expect(await ledger.snapshot() == active)
        try await ledger.complete(claim, termination: RunTermination(kind: .exit, value: 0))
        await #expect(throws: NativeInvocationLedgerError.unexpectedPhase(expectedOrdinal: 0, expectedPhaseOrdinal: 1)) {
            try await ledger.claim(ordinal: first.ordinal, phaseOrdinal: first.phaseOrdinal, arguments: first.arguments)
        }
        let runtimeClaim = try await ledger.claim(ordinal: runtime.ordinal, phaseOrdinal: runtime.phaseOrdinal,
                                                  arguments: runtime.arguments)
        let runtimeActive = await ledger.snapshot()
        await #expect(throws: NativeInvocationLedgerError.inactiveClaim) {
            try await ledger.complete(claim, termination: RunTermination(kind: .exit, value: 0))
        }
        #expect(await ledger.snapshot() == runtimeActive)
        try await ledger.complete(runtimeClaim, termination: RunTermination(kind: .exit, value: 0))
    }

    @Test func racingClaimsGrantExactlyOneCapability() async throws {
        let ledger = try NativeInvocationLedger(plan: ledgerPlan(route: .build))
        let phase = ledger.phases[0]
        let attempts = await withTaskGroup(of: Result<NativeInvocationClaim, any Error>.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do {
                        return .success(try await ledger.claim(ordinal: phase.ordinal,
                                                               phaseOrdinal: phase.phaseOrdinal,
                                                               arguments: phase.arguments))
                    } catch { return .failure(error) }
                }
            }
            var results: [Result<NativeInvocationClaim, any Error>] = []
            for await result in group { results.append(result) }
            return results
        }
        let granted = attempts.compactMap { try? $0.get() }
        let rejected = attempts.compactMap { attempt -> NativeInvocationLedgerError? in
            if case .failure(let error) = attempt { return error as? NativeInvocationLedgerError }
            return nil
        }
        #expect(granted.count == 1)
        #expect(rejected == [.phaseAlreadyActive])
        #expect(await ledger.snapshot().completions.isEmpty)
        let claim = try #require(granted.first)
        try await ledger.complete(claim, termination: RunTermination(kind: .exit, value: 0))
        #expect(await ledger.snapshot().state == .completed)
    }

    @Test func foreignClaimsCannotReplaceAnActiveCapability() async throws {
        let plan = try ledgerPlan(route: .build)
        let firstLedger = try NativeInvocationLedger(plan: plan)
        let secondLedger = try NativeInvocationLedger(plan: plan)
        let phase = firstLedger.phases[0]
        let firstClaim = try await firstLedger.claim(ordinal: 0, phaseOrdinal: 0, arguments: phase.arguments)
        let foreignClaim = try await secondLedger.claim(ordinal: 0, phaseOrdinal: 0, arguments: phase.arguments)
        let before = await firstLedger.snapshot()
        await #expect(throws: NativeInvocationLedgerError.foreignClaim) {
            try await firstLedger.complete(foreignClaim, termination: RunTermination(kind: .exit, value: 0))
        }
        #expect(await firstLedger.snapshot() == before)
        try await firstLedger.complete(firstClaim, termination: RunTermination(kind: .exit, value: 0))
        await #expect(throws: NativeInvocationLedgerError.inactiveClaim) {
            try await firstLedger.complete(firstClaim, termination: RunTermination(kind: .exit, value: 0))
        }
        try await secondLedger.complete(foreignClaim, termination: nil, cancelled: true)
    }

    @Test func buildFailurePreventsRuntimeAndRetainsAncillaryObservations() async throws {
        let ledger = try NativeInvocationLedger(plan: ledgerPlan(route: .testUnit))
        let first = ledger.phases[0]
        let runtime = ledger.phases[1]
        let claim = try await ledger.claim(ordinal: first.ordinal, phaseOrdinal: first.phaseOrdinal, arguments: first.arguments)
        let nativeFailure = RunTermination(kind: .exit, value: 65)
        try await ledger.complete(claim, termination: nativeFailure,
                                  ancillaryFailure: "manifest publication failed", cancelled: true)
        let snapshot = await ledger.snapshot()
        #expect(snapshot.state == .stopped)
        #expect(snapshot.stopReason == .nativeFailure(nativeFailure))
        #expect(snapshot.completedPhaseCount == 1)
        #expect(snapshot.completions[0].termination == nativeFailure)
        #expect(snapshot.completions[0].nativeExitCode == 65)
        #expect(snapshot.completions[0].ancillaryFailure == "manifest publication failed")
        #expect(snapshot.completions[0].cancelled)
        #expect(snapshot.nextPhase == nil)
        await #expect(throws: NativeInvocationLedgerError.ledgerStopped) {
            try await ledger.claim(ordinal: runtime.ordinal, phaseOrdinal: runtime.phaseOrdinal, arguments: runtime.arguments)
        }
    }

    @Test func unobservedNativeTerminationRemainsAbsentForCancellationOrDriverFailure() async throws {
        for cancelled in [true, false] {
            let ledger = try NativeInvocationLedger(plan: ledgerPlan(route: .testUnit))
            let phase = ledger.phases[0]
            let claim = try await ledger.claim(ordinal: phase.ordinal, phaseOrdinal: phase.phaseOrdinal, arguments: phase.arguments)
            await #expect(throws: NativeInvocationLedgerError.missingObservation) {
                try await ledger.complete(claim, termination: nil)
            }
            #expect(await ledger.snapshot().state == .running)
            #expect(await ledger.snapshot().completions.isEmpty)
            try await ledger.complete(claim, termination: nil,
                                      ancillaryFailure: cancelled ? nil : "spawn failed", cancelled: cancelled)
            let snapshot = await ledger.snapshot()
            #expect(snapshot.state == .stopped)
            #expect(snapshot.stopReason == (cancelled ? .cancelled : .driverFailure("spawn failed")))
            #expect(snapshot.completions[0].termination == nil)
            #expect(snapshot.completions[0].nativeExitCode == nil)
            await #expect(throws: NativeInvocationLedgerError.ledgerStopped) {
                try await ledger.claim(ordinal: 0, phaseOrdinal: 1, arguments: ledger.phases[1].arguments)
            }
        }
    }

    @Test func ancillaryFailureAfterNativeSuccessStillStopsFurtherClaims() async throws {
        let ledger = try NativeInvocationLedger(plan: ledgerPlan(route: .testUnit))
        let phase = ledger.phases[0]
        let claim = try await ledger.claim(ordinal: phase.ordinal, phaseOrdinal: phase.phaseOrdinal, arguments: phase.arguments)
        try await ledger.complete(claim, termination: RunTermination(kind: .exit, value: 0),
                                  ancillaryFailure: "source observation failed")
        let snapshot = await ledger.snapshot()
        #expect(snapshot.stopReason == .driverFailure("source observation failed"))
        #expect(snapshot.completions[0].nativeExitCode == 0)
        await #expect(throws: NativeInvocationLedgerError.ledgerStopped) {
            try await ledger.claim(ordinal: 0, phaseOrdinal: 1, arguments: ledger.phases[1].arguments)
        }
    }

    @Test func canonicalUnicodeEqualityCannotSubstituteDifferentArgumentBytes() async throws {
        let composed = "/tmp/caf\u{00E9}"
        let decomposed = "/tmp/cafe\u{0301}"
        #expect(composed == decomposed)
        #expect(Array(composed.utf8) != Array(decomposed.utf8))
        let ledger = try NativeInvocationLedger(plan: ledgerPlan(route: .build, cache: composed))
        let phase = ledger.phases[0]
        var different = phase.arguments
        different[1] = decomposed
        #expect(different == phase.arguments)
        #expect(ArgumentCommitment.digest(arguments: different) != phase.argumentCommitment)
        await #expect(throws: NativeInvocationLedgerError.argumentsMismatch) {
            try await ledger.claim(ordinal: 0, phaseOrdinal: 0, arguments: different)
        }
        #expect(await ledger.snapshot().state == .ready)
        let claim = try await ledger.claim(ordinal: 0, phaseOrdinal: 0, arguments: phase.arguments)
        try await ledger.complete(claim, termination: RunTermination(kind: .exit, value: 0))
    }
}

private func ledgerPlan(route: NotikaMakeRoute, cache: String = "/tmp/cache $(literal) `value`") throws -> NotikaXcodeInvocationPlan {
    try NotikaXcodeInvocationPlan(request: NotikaActionRequest(makeRoute: route),
                                  destination: "platform=macOS,arch=arm64", cacheDirectory: cache,
                                  resultBundle: "/tmp/session/result.xcresult")
}
