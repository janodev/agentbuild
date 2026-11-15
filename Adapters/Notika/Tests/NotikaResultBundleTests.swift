@testable import AgentBuildCore
import AgentBuildTestSupport
import AgentLeaseCore
import Darwin
import Foundation
@testable import NotikaAdapter
import Testing

@Suite("Notika result custody and observed test counts")
struct NotikaResultBundleTests {
    @Test func retainedPayloadAdmitsRealAccessTimeEventsButStandaloneWatchesStayStrict() throws {
        let fixture = try ResultFixture()
        defer { fixture.remove() }
        let reservation = try fixture.reserve()
        try fixture.createResult()
        let bundle = try fixture.admit(reservation)
        let descriptor = open(fixture.evidence.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        try #require(descriptor >= 0)
        defer { _ = Darwin.close(descriptor) }
        let strictWatch = try ResultMutationWatch()
        try strictWatch.arm(descriptor, writes: true)
        let before = try resultDescriptorIdentity(descriptor)
        try resultSetAccessTime(fixture.evidence.path)
        #expect(try resultDescriptorIdentity(descriptor) == before)
        // Prove this real syscall emitted an event; an ordinary read alone
        // could pass without exercising the access-time notification policy.
        #expect(throws: ResultBundleFailure.self) { try strictWatch.check() }
        try bundle.revalidateForPublication()
        try bundle.revalidateForPublication()
    }

    @Test(arguments: ["chmod", "flags", "write", "replace", "directory"])
    func accessTimeNotificationsNeverMaskSubstantiveOrRestoredChanges(_ mutation: String) throws {
        let fixture = try ResultFixture()
        defer { fixture.remove() }
        let reservation = try fixture.reserve()
        try fixture.createResult()
        let bundle = try fixture.admit(reservation)
        let bytes = try Data(contentsOf: fixture.evidence)
        try resultSetAccessTime(fixture.evidence.path)
        switch mutation {
        case "chmod":
            try #require(chmod(fixture.evidence.path, 0o640) == 0)
            try #require(chmod(fixture.evidence.path, 0o600) == 0)
        case "flags":
            try #require(chflags(fixture.evidence.path, UInt32(UF_HIDDEN)) == 0)
            try #require(chflags(fixture.evidence.path, 0) == 0)
        case "write":
            try Data("changed".utf8).write(to: fixture.evidence)
            try bytes.write(to: fixture.evidence)
        case "replace":
            try FileManager.default.moveItem(at: fixture.evidence, to: fixture.result.appendingPathComponent("Data/old"))
            try bytes.write(to: fixture.evidence)
            try #require(chmod(fixture.evidence.path, 0o600) == 0)
        case "directory": try resultSetAccessTime(fixture.result.appendingPathComponent("Data").path)
        default: Issue.record("Unknown mutation")
        }
        #expect(throws: ResultBundleFailure.self) { try bundle.revalidateForPublication() }
        #expect(throws: ResultBundleFailure.self) { try bundle.revalidateForPublication() }
    }

    @Suite("Large retained result trees", .serialized)
    struct DescriptorCapacity {
        @Test func descriptorBudgetPreservesHardLimitsAndNeverLowersCapacity() throws {
            let required = ResultBundleTree.minimumDescriptorLimit
            let exact = try ResultBundleTree.descriptorLimitPlan(rlimit(rlim_cur: required, rlim_max: required))
            #expect(exact.rlim_cur == required)
            #expect(exact.rlim_max == required)
            let raised = try ResultBundleTree.descriptorLimitPlan(rlimit(rlim_cur: 4_096, rlim_max: required))
            #expect(raised.rlim_cur == required)
            #expect(raised.rlim_max == required)
            // Darwin's RLIM_INFINITY expression macro is not imported into Swift.
            let unlimited = rlim_t(Int64.max)
            let high = try ResultBundleTree.descriptorLimitPlan(rlimit(rlim_cur: 16_384, rlim_max: unlimited))
            #expect(high.rlim_cur == 16_384)
            #expect(high.rlim_max == unlimited)
            let unlimitedHard = try ResultBundleTree.descriptorLimitPlan(rlimit(rlim_cur: 4_096, rlim_max: unlimited))
            #expect(unlimitedHard.rlim_cur == required)
            #expect(unlimitedHard.rlim_max == unlimited)
            #expect(throws: ResultBundleFailure(operation: "result descriptor budget unavailable", code: EMFILE,
                                                    detail: "requires \(required); hard limit 4096")) {
                try ResultBundleTree.descriptorLimitPlan(rlimit(rlim_cur: 4_096, rlim_max: 4_096))
            }
            #expect(throws: ResultBundleFailure(operation: "invalid result descriptor limit", code: EINVAL)) {
                try ResultBundleTree.descriptorLimitPlan(rlimit(rlim_cur: 9_000, rlim_max: 4_096))
            }
        }

        @Test func largeColdIndexKeepsCompleteCustodyAndStickyPayloadMutation() async throws {
            let fixture = try ResultFixture(route: .testUnitFocused, unitSelectors: ["ParameterizedTests/cases(_:)"])
            defer { fixture.remove() }
            let reservation = try fixture.reserve()
            let native = try await fixture.captureShell("exit 0", workingDirectory: fixture.repository.path,
                                                         artifactName: "unused", artifactRoot: fixture.session.path)
            try fixture.createResult()
            let leaf = Data("retained payload".utf8)
            for index in 0..<2_946 {
                let path = fixture.result.appendingPathComponent("Data/payload-\(index)")
                try leaf.write(to: path)
                #expect(chmod(path.path, 0o600) == 0)
            }
            let bundle = try await reservation.admitAfterRetirementForTrustedFixture(native,
                environment: ["PATH": "/usr/bin:/bin"]) { requested, directory in
                try await fixture.captureShell(#"printf sqlite > database.sqlite3; chmod 600 database.sqlite3; printf '%s' "$1""#,
                    arguments: [String(decoding: summary(passed: 118, failed: 0, skipped: 0, total: 118), as: UTF8.self)],
                    workingDirectory: requested.workingDirectory, environment: requested.environment,
                    workingDirectoryDescriptor: directory, artifactName: "unused", artifactRoot: fixture.session.path)
            }
            #expect(bundle.custody.contentBytes == Int64(6 + 2_946 * leaf.count + 6))
            let evidence = await bundle.observeSummaryForTrustedFixture(environment: ["PATH": "/usr/bin:/bin"]) { _, _ in
                Issue.record("The prepared summary must be reused")
                throw ResultBundleFailure(operation: "unexpected second summary")
            }
            #expect(evidence.provesPassingRun)
            #expect(evidence.tests?.executed == 118)
            try evidence.revalidateForPublication()
            var limits = rlimit()
            #expect(getrlimit(RLIMIT_NOFILE, &limits) == 0)
            #expect(limits.rlim_cur >= ResultBundleTree.minimumDescriptorLimit)
            let changed = fixture.result.appendingPathComponent("Data/payload-2945")
            try Data("changed".utf8).write(to: changed)
            try leaf.write(to: changed)
            #expect(throws: ResultBundleFailure.self) { try evidence.revalidateForPublication() }
            #expect(throws: ResultBundleFailure.self) { try evidence.revalidateForPublication() }
        }

        @Test(arguments: [false, true])
        func resultEntryBoundIncludesRootAndRejectsOverflow(overflow: Bool) throws {
            let fixture = try ResultFixture()
            defer { fixture.remove() }
            let reservation = try fixture.reserve()
            try fixture.createResult()
            // Root, Data and its existing evidence leaf are already three nodes.
            let extraCount = ResultBundleTree.maximumEntries - 3 + (overflow ? 1 : 0)
            for index in 0..<extraCount {
                let path = fixture.result.appendingPathComponent("Data/entry-\(index)")
                try Data([1]).write(to: path)
                #expect(chmod(path.path, 0o600) == 0)
            }
            if overflow {
                #expect(throws: ResultBundleFailure(operation: "result tree entry limit", code: EFBIG)) {
                    try fixture.admit(reservation)
                }
                #expect(!FileManager.default.fileExists(atPath: fixture.session.appendingPathComponent("result-custody.json").path))
            } else {
                let retained = try fixture.admit(reservation)
                #expect(retained.custody.contentBytes == Int64(6 + extraCount))
                try retained.revalidateForPublication()
            }
        }
    }

    @Test(arguments: ["missingCombined", "unknownCombinedField", "combinedWrongLeaf", "foreignCombinedCapture",
                      "shortCombined", "combinedMissingEOF", "invalidCombinedDigest", "inputCap", "overflowObserved", "foreignErrorCapture"])
    func currentCaptureAdmissionRejectsMissingOrMisboundCombinedEvidence(_ mutation: String) throws {
        let session = "/private/tmp/record/Artifacts/AgentSessions/" + UUID().uuidString
        let directory = UUID().uuidString
        func stream(_ leaf: String, bytes: Data) -> [String: CanonicalJSONValue] {
            ["path": .string(session + "/" + directory + "/" + leaf), "observedBytes": .integer(Int64(bytes.count)),
             "retainedBytes": .integer(Int64(bytes.count)), "sha256": .string(CanonicalJSONDigest.digest(bytes)), "reachedEOF": .bool(true)]
        }
        // Capture-observed interleaving differs from stdout followed by stderr.
        // Each digest commits its own bytes rather than a concatenated hash.
        let output = stream("stdout.log", bytes: Data("ac".utf8)), error = stream("stderr.log", bytes: Data("b".utf8))
        var combined = stream("combined.log", bytes: Data("abc".utf8))
        var fields: [String: CanonicalJSONValue] = ["standardOutput": .object(output), "standardError": .object(error),
            "combined": .object(combined), "maximumBytes": .integer(3), "captureComplete": .bool(true), "failures": .array([])]
        let original = try StrictJSONDocument(data: CanonicalJSONDigest.encode(.object(fields))).root
        #expect(try admitNativeLogCaptureRecord(original, sessionPath: session).combined?.observedBytes == 3)
        switch mutation {
        case "missingCombined": fields.removeValue(forKey: "combined")
        case "unknownCombinedField": combined["extra"] = .null
        case "combinedWrongLeaf": combined["path"] = .string(session + "/" + directory + "/stdout.log")
        case "foreignCombinedCapture": combined["path"] = .string(session + "/" + UUID().uuidString + "/combined.log")
        case "shortCombined": combined["retainedBytes"] = .integer(2)
        case "combinedMissingEOF": combined["reachedEOF"] = .bool(false)
        case "invalidCombinedDigest": combined["sha256"] = .string("invalid")
        case "inputCap": fields["maximumBytes"] = .integer(2)
        case "overflowObserved":
            var changed = output; changed["observedBytes"] = .integer(Int64.max)
            fields["standardOutput"] = .object(changed); fields["captureComplete"] = .bool(false)
        case "foreignErrorCapture":
            var changed = error; changed["path"] = .string(session + "/" + UUID().uuidString + "/stderr.log")
            fields["standardError"] = .object(changed)
        default: Issue.record("Unknown combined admission mutation")
        }
        if mutation != "missingCombined" { fields["combined"] = .object(combined) }
        let changed = try StrictJSONDocument(data: CanonicalJSONDigest.encode(.object(fields))).root
        #expect(throws: (any Error).self) { try admitNativeLogCaptureRecord(changed, sessionPath: session) }
        if mutation == "missingCombined" {
            let historical = try admitNativeLogCaptureRecord(changed, sessionPath: session, policy: .historicalRetention)
            #expect(historical.combined == nil)
            #expect(historical.captureComplete)
            #expect(historical.standardOutput.sha256 == CanonicalJSONDigest.digest(Data("ac".utf8)))
        } else {
            #expect(throws: (any Error).self) {
                try admitNativeLogCaptureRecord(changed, sessionPath: session, policy: .historicalRetention)
            }
        }
    }

    @Test func incompleteCaptureKeepsCombinedWriteFailureWithoutInventingCompleteBytes() throws {
        let session = "/private/tmp/record/Artifacts/AgentSessions/" + UUID().uuidString, directory = UUID().uuidString
        func stream(_ leaf: String, retained: Int64) -> CanonicalJSONValue {
            .object(["path": .string(session + "/" + directory + "/" + leaf), "observedBytes": .integer(2),
                     "retainedBytes": .integer(retained), "sha256": .string(CanonicalJSONDigest.digest(Data())), "reachedEOF": .bool(true)])
        }
        let combined = CanonicalJSONValue.object(["path": .string(session + "/" + directory + "/combined.log"),
            "observedBytes": .integer(4), "retainedBytes": .integer(1), "sha256": .string(CanonicalJSONDigest.digest(Data())), "reachedEOF": .bool(true)])
        let value = CanonicalJSONValue.object(["standardOutput": stream("stdout.log", retained: 2), "standardError": stream("stderr.log", retained: 2),
            "combined": combined, "maximumBytes": .integer(4), "captureComplete": .bool(false),
            "failures": .array([.object(["operation": .string("write"), "stream": .string("combined"), "code": .integer(Int64(ENOSPC))])])])
        let record = try admitNativeLogCaptureRecord(StrictJSONDocument(data: CanonicalJSONDigest.encode(value)).root, sessionPath: session)
        #expect(!record.captureComplete)
        #expect(record.combined?.retainedBytes == 1)
        #expect(record.standardOutput.retainedBytes + record.standardError.retainedBytes == 4)
    }

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
        #expect(throws: ResultBundleFailure.self) { try fixture.admit(reservation) }
    }

    @Test func reservationRefusesExistingResultOrReceiptAndForeignPhase() throws {
        let fixture = try ResultFixture()
        defer { fixture.remove() }
        try FileManager.default.createSymbolicLink(atPath: fixture.result.path, withDestinationPath: fixture.repository.path)
        #expect(throws: ResultBundleFailure.self) { try fixture.reserve() }
        try FileManager.default.removeItem(at: fixture.result)
        try Data().write(to: fixture.session.appendingPathComponent("result-custody.json"))
        #expect(throws: ResultBundleFailure.self) { try fixture.reserve() }
        try FileManager.default.removeItem(at: fixture.session.appendingPathComponent("result-custody.json"))
        let wrongPhase = NativeInvocationPhase(ordinal: fixture.phase.ordinal, phaseOrdinal: fixture.phase.phaseOrdinal,
            physicalOrdinal: fixture.phase.physicalOrdinal, segment: fixture.phase.segment,
            arguments: fixture.phase.arguments + ["-only-testing:Wrong"], requiresCompilation: false,
            argumentCommitment: fixture.phase.argumentCommitment)
        #expect(throws: ResultBundleFailure.self) { try fixture.reserve(phase: wrongPhase) }
    }

    @Test func admissionRejectsSymlinksHardLinksAndIncompleteNativeCapture() throws {
        let symlink = try ResultFixture()
        defer { symlink.remove() }
        let reserved = try symlink.reserve()
        try FileManager.default.createSymbolicLink(atPath: symlink.result.path, withDestinationPath: symlink.repository.path)
        #expect(throws: ResultBundleFailure.self) { try symlink.admit(reserved) }
        let hardlink = try ResultFixture()
        defer { hardlink.remove() }
        let hardReserved = try hardlink.reserve()
        try hardlink.createResult()
        #expect(link(hardlink.evidence.path, hardlink.result.appendingPathComponent("copy").path) == 0)
        #expect(throws: ResultBundleFailure.self) { try hardlink.admit(hardReserved) }
        let incomplete = try ResultFixture()
        defer { incomplete.remove() }
        let incompleteReserved = try incomplete.reserve()
        try incomplete.createResult()
        #expect(throws: ResultBundleFailure.self) { try incomplete.admit(incompleteReserved, complete: false) }
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
        #expect(throws: ResultBundleFailure.self) { try bundle.revalidateForPublication() }
        #expect(throws: ResultBundleFailure.self) { try bundle.revalidateForPublication() }
        let other = try ResultFixture()
        defer { other.remove() }
        let otherReserved = try other.reserve()
        try other.createResult()
        let retained = try other.admit(otherReserved)
        try FileManager.default.moveItem(at: other.result, to: other.session.appendingPathComponent("old.xcresult"))
        try other.createResult()
        #expect(throws: ResultBundleFailure.self) { try retained.revalidateForPublication() }
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
        #expect(throws: ResultBundleFailure.self) { try bundle.revalidateForPublication() }
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
            throw ResultBundleFailure(operation: "fixture probe unavailable", code: ENOENT)
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
        #expect(throws: ResultBundleFailure.self) { try reservation.admitAfterRetirement(native) }
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
            #expect(throws: ResultBundleFailure.self) { try fixture.admit(reservation) }
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
            throw ResultBundleFailure(operation: "unexpected second summary")
        }
        #expect(evidence.provesPassingRun)
        #expect(evidence.tests?.executed == 9)
        #expect(evidence.probe?.workingDirectoryIdentity?.inode == bundle.custody.resultInode)
        #expect(evidence.failures.isEmpty)
        try evidence.revalidateForPublication()
        let index = fixture.result.appendingPathComponent("database.sqlite3")
        try Data("changed".utf8).write(to: index)
        try Data("sqlite".utf8).write(to: index)
        #expect(throws: ResultBundleFailure.self) { try evidence.revalidateForPublication() }
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
        #expect(throws: ResultBundleFailure.self) { try fixture.admit(reservation) }
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
            throw ResultBundleFailure(operation: "unexpected second summary")
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
                throw ResultBundleFailure(operation: "fixture counts policy")
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
        #expect(throws: ResultBundleFailure.self) { try fixture.admit(reservation) }
        #expect(try Data(contentsOf: receipt) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.session.path).allSatisfy { !$0.hasPrefix(".result-custody-") })
    }

    @Test func oversizedSparseResultIsRefusedBeforeContentReading() throws {
        let fixture = try ResultFixture()
        defer { fixture.remove() }
        let reservation = try fixture.reserve()
        try fixture.createResult()
        let writer = Darwin.open(fixture.evidence.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        guard writer >= 3 else { throw ResultBundleFailure(operation: "fixture sparse file", code: errno) }
        defer { _ = Darwin.close(writer) }
        #expect(ftruncate(writer, off_t(ResultBundleTree.maximumBytes + 1)) == 0)
        #expect(throws: ResultBundleFailure.self) { try fixture.admit(reservation) }
        #expect(!FileManager.default.fileExists(atPath: fixture.session.appendingPathComponent("result-custody.json").path))
    }

    @Test func countsAreObservedExactlyAndEmptySkippedOrContradictoryRunsCannotPass() throws {
        let passed = try ExecutedTests.parse(summary(passed: 5, failed: 0, skipped: 2, total: 7))
        #expect(passed.executed == 5)
        #expect(passed.skipped == 2)
        #expect(passed.provesPassingNonemptyRun)
        #expect(passed.satisfiesExpectedRun(focusedMethod: false))
        #expect(!passed.satisfiesExpectedRun(focusedMethod: true))
        #expect(try ExecutedTests.parse(summary(passed: 1, failed: 0, skipped: 0, total: 1)).satisfiesExpectedRun(focusedMethod: true))
        #expect(try !ExecutedTests.parse(summary(passed: 1, failed: 0, skipped: 1, total: 2)).satisfiesExpectedRun(focusedMethod: true))
        #expect(try !ExecutedTests.parse(summary(passed: 0, failed: 0, skipped: 0, total: 0)).provesPassingNonemptyRun)
        #expect(try !ExecutedTests.parse(summary(passed: 0, failed: 0, skipped: 3, total: 3)).provesPassingNonemptyRun)
        let failed = try ExecutedTests.parse(summary(passed: 2, failed: 1, skipped: 4, total: 7, result: "Failed"))
        #expect(failed.executed == 3)
        #expect(!failed.provesPassingNonemptyRun)
        #expect(throws: ResultBundleFailure.self) { try ExecutedTests.parse(summary(passed: 2, failed: 0, skipped: 0, total: 1)) }
        #expect(throws: (any Error).self) { try ExecutedTests.parse(Data(#"{"result":"Passed","passedTests":true,"failedTests":0,"skippedTests":0,"totalTestCount":1}"#.utf8)) }
        #expect(throws: (any Error).self) { try ExecutedTests.parse(Data(#"{"result":"Passed","passedTests":1.0,"failedTests":0,"skippedTests":0,"totalTestCount":1}"#.utf8)) }
        #expect(throws: (any Error).self) { try ExecutedTests.parse(Data(#"{"result":"Passed","passedTests":1,"passedTests":2,"failedTests":0,"skippedTests":0,"totalTestCount":1}"#.utf8)) }
        #expect(throws: (any Error).self) { try ExecutedTests.parse(Data(#"{"result":"Passed","passedTests":9223372036854775807,"failedTests":1,"skippedTests":0,"totalTestCount":1}"#.utf8)) }
        #expect(throws: (any Error).self) { try ExecutedTests.parse(Data(#"{"result":"Passed","failedTests":0,"skippedTests":0,"totalTestCount":1}"#.utf8)) }
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
        AgentBuildTestPaths.packageRoot.appendingPathComponent(".build/debug/agentbuild").path
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
        let raw = NativeLogCaptureResult(standardOutput: stream, standardError: stream, combined: stream, maximumBytes: 0,
                                          captureComplete: complete, failures: [])
        return try reservation.admit(nativeObservation: NativeObservation(worker: worker), rawCapture: raw)
    }

    func remove() { try? FileManager.default.removeItem(at: repository) }
}

private func resultSetAccessTime(_ path: String) throws {
    var attributes = attrlist()
    attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    attributes.commonattr = attrgroup_t(ATTR_CMN_ACCTIME)
    var accessTime = timespec(tv_sec: 100, tv_nsec: 0)
    try #require(setattrlist(path, &attributes, &accessTime, MemoryLayout<timespec>.size, 0) == 0)
    var status = stat()
    try #require(lstat(path, &status) == 0)
    try #require(status.st_atimespec.tv_sec == 100)
}
