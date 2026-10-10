@testable import AgentBuildCore
import AgentLeaseCore
import Darwin
import Foundation
import Testing

@Suite("Notika result custody and observed test counts")
struct NotikaResultBundleTests {
    @Test(arguments: NotikaMakeRoute.allCases.filter(\.expectsResultBundle))
    func everyResultProducingRouteBindsItsExactRuntimeAndDestination(route: NotikaMakeRoute) throws {
        let file = route.acceptsTestFile ? "ActualTests" : route.acceptsCoverageFile ? "Sources/Actual.swift" : ""
        let selectors = route == .testUnitFocused ? ["ActualTests/parameterized(_:)"] : []
        let fixture = try ResultFixture(route: route, unitSelectors: selectors, testFile: file,
                                         platform: route.requiredPlatform ?? .macOS)
        defer { fixture.remove() }
        let reservation = try fixture.reserve()
        try fixture.createResult()
        let result = try fixture.admit(reservation)
        #expect(result.custody.actionRequest == fixture.request)
        #expect(result.custody.invocationOrdinal == fixture.invocation.ordinal)
        #expect(result.custody.phaseOrdinal == fixture.phase.phaseOrdinal)
        #expect(result.custody.physicalArgumentsSHA256 == fixture.phase.argumentCommitment)
        #expect(result.custody.destination == fixture.invocation.destination)
        if [.buildAndTest, .test, .testShowOnlyErrors].contains(route.canonicalRoute) {
            #expect(result.custody.invocationOrdinal == 1)
            #expect(result.custody.physicalOrdinal == 2)
        }
        try result.revalidateForPublication()
    }

    @Test(arguments: [NotikaMakeRoute.testUIFile, .testUnit, .coverageJSON, .buildAndTest])
    func iPadResultReservationPreservesTheConcreteLeasedDestination(route: NotikaMakeRoute) throws {
        let fixture = try ResultFixture(route: route, testFile: route.acceptsTestFile ? "ActualTests" : "",
                                         platform: .iPadSimulator)
        defer { fixture.remove() }
        let reservation = try fixture.reserve()
        try fixture.createResult()
        let result = try fixture.admit(reservation)
        #expect(result.custody.actionRequest.platform == .iPadSimulator)
        #expect(result.custody.destination == "platform=iOS Simulator,id=fixture-ipad")
        #expect(result.custody.logicalArgumentsSHA256 == ArgumentCommitment.digest(arguments: fixture.invocation.arguments))
    }

    @Test func reservationLeavesAbsentFixedResultPathAndSealsBoundReceipt() throws {
        let fixture = try ResultFixture()
        defer { fixture.remove() }
        let reservation = try fixture.reserve()
        #expect(reservation.path == fixture.result.path)
        #expect(!FileManager.default.fileExists(atPath: fixture.result.path))
        try fixture.createResult()
        let bundle = try fixture.admit(reservation)
        try bundle.revalidateForPublication()
        let custody = bundle.custody
        #expect(custody.sessionID == fixture.runID)
        #expect(custody.sourceBeforeHash == fixture.sourceHash)
        #expect(custody.actionRequest == fixture.request)
        #expect(custody.invocationOrdinal == fixture.invocation.ordinal)
        #expect(custody.phaseOrdinal == fixture.phase.phaseOrdinal)
        #expect(custody.physicalOrdinal == fixture.phase.physicalOrdinal)
        #expect(custody.physicalArgumentsSHA256 == fixture.phase.argumentCommitment)
        #expect(custody.logicalArgumentsSHA256 == ArgumentCommitment.digest(arguments: fixture.invocation.arguments))
        #expect(custody.destination == fixture.invocation.destination)
        #expect(custody.cacheDirectory == fixture.invocation.cacheDirectory)
        #expect(custody.resultPath == fixture.result.path)
        #expect(custody.contentBytes == 6)
        #expect(custody.contentSHA256.count == 64)
        #expect(custody.nativeTermination == RunTermination(kind: .exit, value: 0))
        var metadata = stat()
        #expect(lstat(bundle.receiptPath, &metadata) == 0)
        #expect(metadata.st_mode & 0o7777 == 0o400)
        #expect(metadata.st_nlink == 1)
        let receipt = try Data(contentsOf: URL(fileURLWithPath: bundle.receiptPath))
        #expect(CanonicalJSONDigest.digest(receipt) == bundle.receiptSHA256)
        #expect(try JSONDecoder().decode(NotikaResultCustody.self, from: receipt) == custody)
        #expect(throws: NotikaResultBundleFailure.self) { try fixture.admit(reservation) }
    }

    @Test func reservationRefusesExistingResultOrReceiptAndForeignPhase() throws {
        let fixture = try ResultFixture()
        defer { fixture.remove() }
        try FileManager.default.createSymbolicLink(atPath: fixture.result.path, withDestinationPath: fixture.repository.path)
        #expect(throws: NotikaResultBundleFailure.self) { try fixture.reserve() }
        try FileManager.default.removeItem(at: fixture.result)
        try Data().write(to: fixture.session.appendingPathComponent("result-custody.json"))
        #expect(throws: NotikaResultBundleFailure.self) { try fixture.reserve() }
        try FileManager.default.removeItem(at: fixture.session.appendingPathComponent("result-custody.json"))
        let wrongPhase = NativeInvocationPhase(ordinal: fixture.phase.ordinal, phaseOrdinal: fixture.phase.phaseOrdinal,
            physicalOrdinal: fixture.phase.physicalOrdinal, segment: fixture.phase.segment,
            arguments: fixture.phase.arguments + ["-only-testing:Wrong"], requiresCompilation: false,
            argumentCommitment: fixture.phase.argumentCommitment)
        #expect(throws: NotikaResultBundleFailure.self) { try fixture.reserve(phase: wrongPhase) }
    }

    @Test func admissionRejectsSymlinksHardLinksAndIncompleteNativeCapture() throws {
        let symlink = try ResultFixture()
        defer { symlink.remove() }
        let reserved = try symlink.reserve()
        try FileManager.default.createSymbolicLink(atPath: symlink.result.path, withDestinationPath: symlink.repository.path)
        #expect(throws: NotikaResultBundleFailure.self) { try symlink.admit(reserved) }
        let hardlink = try ResultFixture()
        defer { hardlink.remove() }
        let hardReserved = try hardlink.reserve()
        try hardlink.createResult()
        #expect(link(hardlink.evidence.path, hardlink.result.appendingPathComponent("copy").path) == 0)
        #expect(throws: NotikaResultBundleFailure.self) { try hardlink.admit(hardReserved) }
        let incomplete = try ResultFixture()
        defer { incomplete.remove() }
        let incompleteReserved = try incomplete.reserve()
        try incomplete.createResult()
        #expect(throws: NotikaResultBundleFailure.self) { try incomplete.admit(incompleteReserved, complete: false) }
        #expect(!FileManager.default.fileExists(atPath: incomplete.session.appendingPathComponent("result-custody.json").path))
    }

    @Test func nestedRewriteRestoreIsStickyAndDirectoryReplacementIsRejected() throws {
        let fixture = try ResultFixture()
        defer { fixture.remove() }
        let reservation = try fixture.reserve()
        try fixture.createResult()
        let bundle = try fixture.admit(reservation)
        let original = try Data(contentsOf: fixture.evidence)
        try Data("changed".utf8).write(to: fixture.evidence)
        try original.write(to: fixture.evidence)
        #expect(throws: NotikaResultBundleFailure.self) { try bundle.revalidateForPublication() }
        #expect(throws: NotikaResultBundleFailure.self) { try bundle.revalidateForPublication() }
        let other = try ResultFixture()
        defer { other.remove() }
        let otherReserved = try other.reserve()
        try other.createResult()
        let retained = try other.admit(otherReserved)
        try FileManager.default.moveItem(at: other.result, to: other.session.appendingPathComponent("old.xcresult"))
        try other.createResult()
        #expect(throws: NotikaResultBundleFailure.self) { try retained.revalidateForPublication() }
    }

    @Test func receiptRewriteAndSessionSymlinkReplacementInvalidateSealing() throws {
        let fixture = try ResultFixture()
        defer { fixture.remove() }
        let reservation = try fixture.reserve()
        try fixture.createResult()
        let bundle = try fixture.admit(reservation)
        #expect(chmod(bundle.receiptPath, 0o600) == 0)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: bundle.receiptPath))
        #expect(chmod(bundle.receiptPath, 0o400) == 0)
        #expect(throws: NotikaResultBundleFailure.self) { try bundle.revalidateForPublication() }
        let other = try ResultFixture()
        defer { other.remove() }
        let otherReserved = try other.reserve()
        try other.createResult()
        let retained = try other.admit(otherReserved)
        let moved = other.session.path + "-moved"
        try FileManager.default.moveItem(atPath: other.session.path, toPath: moved)
        try FileManager.default.createSymbolicLink(atPath: other.session.path, withDestinationPath: moved)
        #expect(throws: (any Error).self) { try retained.revalidateForPublication() }
    }

    @Test func probeReceivesExactPinnedCommandAndFailureDoesNotEraseNativeFailure() async throws {
        let fixture = try ResultFixture()
        defer { fixture.remove() }
        let reservation = try fixture.reserve()
        try fixture.createResult()
        let bundle = try fixture.admit(reservation, nativeExit: 65)
        let evidence = await bundle.observeSummary(environment: ["PATH": "/usr/bin:/bin"]) { command, descriptor in
            #expect(command.executable == "/usr/bin/xcrun")
            #expect(command.arguments == ["xcresulttool", "get", "test-results", "summary", "--path", ".", "--compact"])
            #expect(command.workingDirectory == fixture.result.path)
            var status = stat()
            #expect(fstat(descriptor, &status) == 0)
            #expect(UInt64(status.st_ino) == bundle.custody.resultInode)
            #expect(status.st_mode & S_IFMT == S_IFDIR)
            throw NotikaResultBundleFailure(operation: "fixture probe unavailable", code: ENOENT)
        }
        #expect(evidence.nativeObservation.termination == RunTermination(kind: .exit, value: 65))
        #expect(evidence.probe == nil)
        #expect(evidence.tests == nil)
        #expect(evidence.failures == [.init(operation: "fixture probe unavailable", code: ENOENT)])
        #expect(!evidence.provesPassingRun)
        try evidence.revalidateForPublication()
    }

    @Test func foreignNativeAndProbeCapsulesPreserveOutcomesButCannotSupplyCounts() async throws {
        let fixture = try ResultFixture()
        defer { fixture.remove() }
        let reservation = try fixture.reserve()
        try fixture.createResult()
        let shell = try DarwinWorkloadCommand(executable: "/bin/sh", arguments: ["-c", "printf fixture; exit 41"],
                                                workingDirectory: fixture.repository.path,
                                                environment: ["PATH": "/usr/bin:/bin"])
        let native = try await CapturedNativePhaseRunner().run(helperExecutable: fixture.helper, command: shell,
            retainedLockDescriptors: [], artifactRoot: fixture.repository.appendingPathComponent("native-logs").path)
        #expect(throws: NotikaResultBundleFailure.self) { try reservation.admitAfterRetirement(native) }
        #expect(!FileManager.default.fileExists(atPath: fixture.session.appendingPathComponent("result-custody.json").path))
        let retained = try fixture.admit(reservation, nativeExit: 65)
        let evidence = await retained.observeSummary(environment: ["PATH": "/usr/bin:/bin"]) { requested, directory in
            let command = try DarwinWorkloadCommand(executable: "/bin/sh", arguments: ["-c", "printf 'foreign JSON'; exit 43"],
                                                    workingDirectory: requested.workingDirectory,
                                                    environment: requested.environment)
            return try await CapturedNativePhaseRunner().run(helperExecutable: fixture.helper, command: command,
                retainedLockDescriptors: [], nativeWorkingDirectoryDescriptor: directory,
                artifactRoot: fixture.repository.appendingPathComponent("probe-logs").path)
        }
        #expect(evidence.nativeObservation.termination == RunTermination(kind: .exit, value: 65))
        #expect(evidence.probe?.observation.termination == RunTermination(kind: .exit, value: 43))
        #expect(evidence.probe?.rawCapture.captureComplete == true)
        #expect(evidence.probe?.workingDirectoryIdentity?.inode == retained.custody.resultInode)
        #expect(evidence.tests == nil)
        #expect(evidence.failures.contains { $0.operation == "result probe command mismatch" })
        #expect(!evidence.provesPassingRun)
        try evidence.revalidateForPublication()
    }

    @Test func trustedCoordinatorFixtureRetainsNativeProbeAndParameterizedUnitCounts() async throws {
        let fixture = try ResultFixture(route: .testUnitFocused, unitSelectors: ["ParameterizedTests/cases(_:)"])
        defer { fixture.remove() }
        let reservation = try fixture.reserve()
        try fixture.createResult()
        let native = try await fixture.captureShell("exit 0", workingDirectory: fixture.repository.path,
                                                     artifactName: "native-logs")
        let retained = try reservation.admitAfterRetirementForTrustedFixture(native)
        let evidence = await retained.observeSummaryForTrustedFixture(environment: ["PATH": "/usr/bin:/bin"]) { requested, directory in
            try await fixture.captureShell(#"printf '%s' "$1""#,
                arguments: [String(decoding: summary(passed: 5, failed: 0, skipped: 2, total: 7), as: UTF8.self)],
                workingDirectory: requested.workingDirectory, environment: requested.environment,
                workingDirectoryDescriptor: directory, artifactName: "probe-logs")
        }
        #expect(evidence.resultBundle === retained)
        #expect(evidence.provesPassingRun)
        #expect(!evidence.focusedMethod)
        #expect(evidence.tests?.passed == 5)
        #expect(evidence.tests?.executed == 5)
        #expect(evidence.tests?.skipped == 2)
        #expect(evidence.failures.isEmpty)
        try evidence.revalidateForPublication()
        try Data("replaced native raw".utf8).write(to: URL(fileURLWithPath: native.rawCapture.standardOutput.path))
        #expect(throws: (any Error).self) { try evidence.revalidateForPublication() }
        #expect(throws: (any Error).self) { try evidence.revalidateForPublication() }
    }

    @Test func actualSessionRootAllowsSiblingNativeAndPinnedProbeCaptureDirectories() async throws {
        let fixture = try ResultFixture(route: .testUnitFocused, unitSelectors: ["ParameterizedTests/cases(_:)"])
        defer { fixture.remove() }
        let reservation = try fixture.reserve()
        let native = try await fixture.captureShell("printf native", workingDirectory: fixture.repository.path,
                                                     artifactName: "unused", artifactRoot: fixture.session.path)
        try fixture.createResult()
        let retained = try reservation.admitAfterRetirementForTrustedFixture(native)
        let evidence = await retained.observeSummaryForTrustedFixture(environment: ["PATH": "/usr/bin:/bin"]) { requested, directory in
            try await fixture.captureShell(#"printf '%s' "$1""#,
                arguments: [String(decoding: summary(passed: 3, failed: 0, skipped: 0, total: 3), as: UTF8.self)],
                workingDirectory: requested.workingDirectory, environment: requested.environment,
                workingDirectoryDescriptor: directory, artifactName: "unused", artifactRoot: fixture.session.path)
        }
        #expect(evidence.provesPassingRun)
        #expect(evidence.tests?.executed == 3)
        #expect(evidence.failures.isEmpty)
        #expect(!evidence.focusedMethod)
        #expect(URL(fileURLWithPath: native.rawCapture.standardOutput.path).deletingLastPathComponent()
            .deletingLastPathComponent().path == fixture.session.path)
        let probe = try #require(evidence.probe)
        #expect(URL(fileURLWithPath: probe.rawCapture.standardOutput.path).deletingLastPathComponent()
            .deletingLastPathComponent().path == fixture.session.path)
        try evidence.revalidateForPublication()
    }

    @Test func coldResultIndexIsPreparedBeforeSealingAndTheFirstSummaryIsReused() async throws {
        let fixture = try ResultFixture(route: .testUnitFocused, unitSelectors: ["ParameterizedTests/cases(_:)"])
        defer { fixture.remove() }
        let reservation = try fixture.reserve()
        let native = try await fixture.captureShell("exit 0", workingDirectory: fixture.repository.path,
                                                     artifactName: "unused", artifactRoot: fixture.session.path)
        try fixture.createResult()
        let original = try Data(contentsOf: fixture.evidence)
        let bundle = try await reservation.admitAfterRetirementForTrustedFixture(native,
            environment: ["PATH": "/usr/bin:/bin"]) { requested, directory in
            #expect(requested.executable == "/usr/bin/xcrun")
            #expect(requested.arguments == ["xcresulttool", "get", "test-results", "summary", "--path", ".", "--compact"])
            #expect(requested.workingDirectory == fixture.result.path)
            #expect(!FileManager.default.fileExists(atPath: fixture.session.appendingPathComponent("result-custody.json").path))
            #expect(throws: NotikaResultBundleFailure.self) { try fixture.admit(reservation) }
            return try await fixture.captureShell(#"printf sqlite > database.sqlite3; chmod 600 database.sqlite3; printf '%s' "$1""#,
                arguments: [String(decoding: summary(passed: 9, failed: 0, skipped: 0, total: 9), as: UTF8.self)],
                workingDirectory: requested.workingDirectory, environment: requested.environment,
                workingDirectoryDescriptor: directory, artifactName: "unused", artifactRoot: fixture.session.path)
        }
        #expect(bundle.custody.contentBytes == Int64(original.count + 6))
        #expect(try Data(contentsOf: fixture.evidence) == original)
        #expect(try Data(contentsOf: fixture.result.appendingPathComponent("database.sqlite3")) == Data("sqlite".utf8))
        let evidence = await bundle.observeSummaryForTrustedFixture(environment: ["PATH": "/usr/bin:/bin"]) { _, _ in
            Issue.record("The prepared summary must be reused without a second native probe")
            throw NotikaResultBundleFailure(operation: "unexpected second summary")
        }
        #expect(evidence.provesPassingRun)
        #expect(evidence.tests?.executed == 9)
        #expect(evidence.probe?.workingDirectoryIdentity?.inode == bundle.custody.resultInode)
        #expect(evidence.failures.isEmpty)
        try evidence.revalidateForPublication()
        let index = fixture.result.appendingPathComponent("database.sqlite3")
        try Data("changed".utf8).write(to: index)
        try Data("sqlite".utf8).write(to: index)
        #expect(throws: NotikaResultBundleFailure.self) { try evidence.revalidateForPublication() }
    }

    @Test(arguments: [
        "printf unknown > unrelated",
        #"printf changed > Data/evidence; printf '\000\377\200\004\005\006' > Data/evidence"#,
        "ln -s Data/evidence database.sqlite3",
        "mv Data old-data; mkdir Data; printf replacement > Data/evidence",
    ])
    func indexPreparationCannotBlessUnknownEntriesOrOriginalPayloadMutation(script: String) async throws {
        let fixture = try ResultFixture()
        defer { fixture.remove() }
        let reservation = try fixture.reserve()
        let native = try await fixture.captureShell("exit 0", workingDirectory: fixture.repository.path,
                                                     artifactName: "unused", artifactRoot: fixture.session.path)
        try fixture.createResult()
        do {
            try await reservation.admitAfterRetirementForTrustedFixture(native,
                environment: ["PATH": "/usr/bin:/bin"]) { requested, directory in
                try await fixture.captureShell(script + #"; printf '%s' "$1""#,
                    arguments: [String(decoding: summary(passed: 9, failed: 0, skipped: 0, total: 9), as: UTF8.self)],
                    workingDirectory: requested.workingDirectory, environment: requested.environment,
                    workingDirectoryDescriptor: directory, artifactName: "unused", artifactRoot: fixture.session.path)
            }
            Issue.record("Changed result payload must not be admitted")
        } catch let failure as NotikaResultPreparationFailure {
            let probe = try #require(failure.probe)
            #expect(probe.observation.termination == RunTermination(kind: .exit, value: 0))
            #expect(probe.rawCapture.captureComplete)
            #expect(probe.workingDirectoryIdentity != nil)
            try failure.revalidateForPublication()
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.session.appendingPathComponent("result-custody.json").path))
        #expect(throws: NotikaResultBundleFailure.self) { try fixture.admit(reservation) }
    }

    @Test func retiredNonzeroIndexProbeIsRetainedAndCannotOverrideSuccessfulNativeTests() async throws {
        let fixture = try ResultFixture()
        defer { fixture.remove() }
        let reservation = try fixture.reserve()
        let native = try await fixture.captureShell("exit 0", workingDirectory: fixture.repository.path,
                                                     artifactName: "unused", artifactRoot: fixture.session.path)
        try fixture.createResult()
        let bundle = try await reservation.admitAfterRetirementForTrustedFixture(native,
            environment: ["PATH": "/usr/bin:/bin"]) { requested, directory in
            try await fixture.captureShell(#"printf sqlite > database.sqlite3; chmod 600 database.sqlite3; printf '%s' "$1"; exit 43"#,
                arguments: [String(decoding: summary(passed: 9, failed: 0, skipped: 0, total: 9), as: UTF8.self)],
                workingDirectory: requested.workingDirectory, environment: requested.environment,
                workingDirectoryDescriptor: directory, artifactName: "unused", artifactRoot: fixture.session.path)
        }
        let evidence = await bundle.observeSummaryForTrustedFixture(environment: ["PATH": "/usr/bin:/bin"]) { _, _ in
            throw NotikaResultBundleFailure(operation: "unexpected second summary")
        }
        #expect(evidence.nativeObservation.termination == RunTermination(kind: .exit, value: 0))
        #expect(evidence.probe?.observation.termination == RunTermination(kind: .exit, value: 43))
        #expect(evidence.tests == nil)
        #expect(evidence.failures.contains { $0.operation == "result consumer failed" })
        #expect(!evidence.provesPassingRun)
        try evidence.revalidateForPublication()
    }

    @Test func indexPreparationRequiresActualPinnedDirectoryBeforeItCanSeal() async throws {
        let fixture = try ResultFixture()
        defer { fixture.remove() }
        let reservation = try fixture.reserve()
        let native = try await fixture.captureShell("exit 0", workingDirectory: fixture.repository.path,
                                                     artifactName: "unused", artifactRoot: fixture.session.path)
        try fixture.createResult()
        do {
            try await reservation.admitAfterRetirementForTrustedFixture(native,
                environment: ["PATH": "/usr/bin:/bin"]) { requested, _ in
                try await fixture.captureShell(#"printf '%s' "$1""#,
                    arguments: [String(decoding: summary(passed: 9, failed: 0, skipped: 0, total: 9), as: UTF8.self)],
                    workingDirectory: requested.workingDirectory, environment: requested.environment,
                    artifactName: "unused", artifactRoot: fixture.session.path)
            }
            Issue.record("An unpinned indexing probe must not supply result admission")
        } catch let failure as NotikaResultPreparationFailure {
            let probe = try #require(failure.probe)
            #expect(probe.workingDirectoryIdentity == nil)
            #expect(failure.failure.operation == "result probe was not bound to retained directory")
            try failure.revalidateForPublication()
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.session.appendingPathComponent("result-custody.json").path))
    }

    @Test func trustedProbeStillRequiresActualDirectoryPinAndCompleteProcessEvidence() async throws {
        let fixture = try ResultFixture()
        defer { fixture.remove() }
        let reservation = try fixture.reserve()
        try fixture.createResult()
        let native = try await fixture.captureShell("exit 0", workingDirectory: fixture.repository.path,
                                                     artifactName: "native-logs")
        let retained = try reservation.admitAfterRetirementForTrustedFixture(native)
        let evidence = await retained.observeSummaryForTrustedFixture(environment: ["PATH": "/usr/bin:/bin"]) { requested, _ in
            try await fixture.captureShell(#"printf '%s' "$1""#,
                arguments: [String(decoding: summary(passed: 1, failed: 0, skipped: 0, total: 1), as: UTF8.self)],
                workingDirectory: requested.workingDirectory, environment: requested.environment,
                artifactName: "unpinned-probe-logs")
        }
        #expect(evidence.probe?.observation.termination == RunTermination(kind: .exit, value: 0))
        #expect(evidence.probe?.workingDirectoryIdentity == nil)
        #expect(evidence.failures.contains { $0.operation == "result probe was not bound to retained directory" })
        #expect(evidence.tests == nil)
        #expect(!evidence.provesPassingRun)
    }

    @Test func exactOnePolicyBelongsOnlyToFocusedUIRoutesAndAliases() async throws {
        let cases: [(NotikaMakeRoute, String, String, Bool)] = [
            (.testUnitFile, "ExampleTests", "", false),
            (.testXcodeFile, "ExampleTests", "", false),
            (.testUIOnlyFile, "ExampleUITests", "testSingle", true),
            (.testUIVisual, "", "", true),
            (.testCanvasFramePacingPerformance, "", "", true),
        ]
        for (route, file, method, expected) in cases {
            let fixture = try ResultFixture(route: route, testFile: file, testMethod: method)
            defer { fixture.remove() }
            let reservation = try fixture.reserve()
            try fixture.createResult()
            let retained = try fixture.admit(reservation)
            let evidence = await retained.observeSummary(environment: ["PATH": "/usr/bin:/bin"]) { _, _ in
                throw NotikaResultBundleFailure(operation: "fixture counts policy")
            }
            #expect(evidence.focusedMethod == expected)
        }
    }

    @Test func publicationRefusesAReplacementReceiptAndLeavesItsBytesUntouched() throws {
        let fixture = try ResultFixture()
        defer { fixture.remove() }
        let reservation = try fixture.reserve()
        try fixture.createResult()
        let receipt = fixture.session.appendingPathComponent("result-custody.json")
        let original = Data("other owner publication".utf8)
        try original.write(to: receipt)
        #expect(throws: NotikaResultBundleFailure.self) { try fixture.admit(reservation) }
        #expect(try Data(contentsOf: receipt) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.session.path).allSatisfy { !$0.hasPrefix(".result-custody-") })
    }

    @Test func oversizedSparseResultIsRefusedBeforeContentReading() throws {
        let fixture = try ResultFixture()
        defer { fixture.remove() }
        let reservation = try fixture.reserve()
        try fixture.createResult()
        let writer = Darwin.open(fixture.evidence.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        guard writer >= 3 else { throw NotikaResultBundleFailure(operation: "fixture sparse file", code: errno) }
        defer { _ = Darwin.close(writer) }
        #expect(ftruncate(writer, off_t(NotikaResultBundleTree.maximumBytes + 1)) == 0)
        #expect(throws: NotikaResultBundleFailure.self) { try fixture.admit(reservation) }
        #expect(!FileManager.default.fileExists(atPath: fixture.session.appendingPathComponent("result-custody.json").path))
    }

    @Test func countsAreObservedExactlyAndEmptySkippedOrContradictoryRunsCannotPass() throws {
        let passed = try NotikaExecutedTests.parse(summary(passed: 5, failed: 0, skipped: 2, total: 7))
        #expect(passed.executed == 5)
        #expect(passed.skipped == 2)
        #expect(passed.provesPassingNonemptyRun)
        #expect(passed.satisfiesExpectedRun(focusedMethod: false))
        #expect(!passed.satisfiesExpectedRun(focusedMethod: true))
        #expect(try NotikaExecutedTests.parse(summary(passed: 1, failed: 0, skipped: 0, total: 1)).satisfiesExpectedRun(focusedMethod: true))
        #expect(try !NotikaExecutedTests.parse(summary(passed: 1, failed: 0, skipped: 1, total: 2)).satisfiesExpectedRun(focusedMethod: true))
        #expect(try !NotikaExecutedTests.parse(summary(passed: 0, failed: 0, skipped: 0, total: 0)).provesPassingNonemptyRun)
        #expect(try !NotikaExecutedTests.parse(summary(passed: 0, failed: 0, skipped: 3, total: 3)).provesPassingNonemptyRun)
        let failed = try NotikaExecutedTests.parse(summary(passed: 2, failed: 1, skipped: 4, total: 7, result: "Failed"))
        #expect(failed.executed == 3)
        #expect(!failed.provesPassingNonemptyRun)
        #expect(throws: NotikaResultBundleFailure.self) { try NotikaExecutedTests.parse(summary(passed: 2, failed: 0, skipped: 0, total: 1)) }
        #expect(throws: (any Error).self) { try NotikaExecutedTests.parse(Data(#"{"result":"Passed","passedTests":true,"failedTests":0,"skippedTests":0,"totalTestCount":1}"#.utf8)) }
        #expect(throws: (any Error).self) { try NotikaExecutedTests.parse(Data(#"{"result":"Passed","passedTests":1.0,"failedTests":0,"skippedTests":0,"totalTestCount":1}"#.utf8)) }
        #expect(throws: (any Error).self) { try NotikaExecutedTests.parse(Data(#"{"result":"Passed","passedTests":1,"passedTests":2,"failedTests":0,"skippedTests":0,"totalTestCount":1}"#.utf8)) }
        #expect(throws: (any Error).self) { try NotikaExecutedTests.parse(Data(#"{"result":"Passed","passedTests":9223372036854775807,"failedTests":1,"skippedTests":0,"totalTestCount":1}"#.utf8)) }
        #expect(throws: (any Error).self) { try NotikaExecutedTests.parse(Data(#"{"result":"Passed","failedTests":0,"skippedTests":0,"totalTestCount":1}"#.utf8)) }
    }
}

private func summary(passed: Int, failed: Int, skipped: Int, total: Int, result: String = "Passed") -> Data {
    Data("{\"result\":\"\(result)\",\"passedTests\":\(passed),\"failedTests\":\(failed),\"skippedTests\":\(skipped),\"totalTestCount\":\(total)}".utf8)
}

private struct ResultFixture: Sendable {
    let repository: URL
    let session: URL
    let result: URL
    let evidence: URL
    let runID = UUID().uuidString
    let sourceHash = String(repeating: "b", count: 64)
    let request: NotikaActionRequest
    let invocation: NotikaXcodeInvocation
    let phase: NativeInvocationPhase
    var helper: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug/agentbuild").path
    }

    init(route: NotikaMakeRoute = .testUnit, unitSelectors: [String] = [],
         testFile: String = "", testMethod: String = "", platform: NotikaPlatform = .macOS) throws {
        repository = URL(fileURLWithPath: "/private/tmp/agentbuild-result-" + UUID().uuidString)
        session = repository.appendingPathComponent("Artifacts/AgentSessions/" + runID)
        result = session.appendingPathComponent("result.xcresult")
        evidence = result.appendingPathComponent("Data/evidence")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        request = try NotikaActionRequest(makeRoute: route, platform: platform, testFile: testFile, testMethod: testMethod,
                                          unitSelectors: unitSelectors)
        let destination = platform == .macOS ? "platform=macOS,arch=arm64" : "platform=iOS Simulator,id=fixture-ipad"
        let plan = try NotikaXcodeInvocationPlan(request: request, destination: destination,
                                                cacheDirectory: repository.appendingPathComponent("cache").path,
                                                resultBundle: result.path)
        invocation = try #require(plan.invocations.last)
        phase = try #require(NativeInvocationLedger(plan: plan).phases.last)
    }

    func reserve(phase: NativeInvocationPhase? = nil) throws -> NotikaResultBundle {
        try NotikaResultBundle(sessionDirectory: session.path, runID: runID, sourceBeforeHash: sourceHash,
                               request: request, invocation: invocation, phase: phase ?? self.phase)
    }

    func createResult() throws {
        try FileManager.default.createDirectory(at: result.appendingPathComponent("Data"), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try Data([0, 255, 128, 4, 5, 6]).write(to: evidence)
        #expect(chmod(evidence.path, 0o600) == 0)
    }

    func captureShell(_ script: String, arguments: [String] = [], workingDirectory: String,
                      environment: [String: String] = ["PATH": "/usr/bin:/bin"],
                      workingDirectoryDescriptor: Int32? = nil, artifactName: String,
                      artifactRoot: String? = nil) async throws -> CapturedNativePhase {
        let command = try DarwinWorkloadCommand(executable: "/bin/sh", arguments: ["-c", script, "result-fixture"] + arguments,
                                                workingDirectory: workingDirectory, environment: environment)
        return try await CapturedNativePhaseRunner().run(helperExecutable: helper, command: command,
            retainedLockDescriptors: [], nativeWorkingDirectoryDescriptor: workingDirectoryDescriptor,
            artifactRoot: artifactRoot ?? repository.appendingPathComponent(artifactName).path)
    }

    func admit(_ reservation: NotikaResultBundle, nativeExit: Int32 = 0, complete: Bool = true) throws -> NotikaRetainedResultBundle {
        let worker = DarwinWorkloadResult(processIdentifier: 42, termination: RunTermination(kind: .exit, value: nativeExit),
                                          stopReason: nil, retirement: .reaped, failures: [])
        let stream = NativeLogStreamResult(path: "/fixture/unused", observedBytes: 0, retainedBytes: 0,
                                            sha256: CanonicalJSONDigest.digest(Data()), reachedEOF: complete)
        let raw = NativeLogCaptureResult(standardOutput: stream, standardError: stream, maximumBytes: 0,
                                          captureComplete: complete, failures: [])
        return try reservation.admit(nativeObservation: NotikaNativeObservation(worker: worker), rawCapture: raw)
    }

    func remove() { try? FileManager.default.removeItem(at: repository) }
}
