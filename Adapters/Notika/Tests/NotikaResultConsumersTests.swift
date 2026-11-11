@testable import AgentBuildCore
import AgentBuildTestSupport
import Darwin
import Foundation
@testable import NotikaAdapter
import Synchronization
import Testing

@Suite("Owned result and coverage consumers")
struct NotikaResultConsumersTests {
    @Test func materializedReadsUseTheirOwnLimitWithoutInvalidatingCompleteRawCapture() async throws {
        let fixture = try ConsumerFixture(route: .coverageJSON)
        defer { fixture.remove() }
        let summary = try await fixture.summary()
        let probe = try #require(summary.probe)
        let expected = try Data(contentsOf: URL(fileURLWithPath: probe.rawCapture.standardOutput.path))
        // Requesting the larger raw-retention ceiling must still admit small
        // output through the reader's bounded policy instead of invalidPolicy.
        #expect(try summary.resultBundle.readCapturedStandardOutput(probe, maximumBytes: 64 * 1_024 * 1_024) == expected)
        #expect(throws: ResultBundleFailure.self) {
            try summary.resultBundle.readCapturedStandardOutput(probe, maximumBytes: Int64(expected.count - 1))
        }
        #expect(probe.rawCapture.captureComplete)
        #expect(probe.rawCapture.standardOutput.observedBytes == Int64(expected.count))
        try summary.revalidateForPublication()
    }

    @Test(arguments: [NotikaMakeRoute.coverage, .coverageQuiet, .coverageJSON, .resultsFile])
    func routeReportsRetainExactPrivateReservationsAndExistingSummary(route: NotikaMakeRoute) async throws {
        let fixture = try ConsumerFixture(route: route)
        defer { fixture.remove() }
        let summary = try await fixture.summary()
        let calls = ConsumerCalls()
        let evidence = await NotikaResultConsumers(summary: summary).runForTrustedFixture(
            environment: fixture.environment
        ) { command, directory in
            calls.append(command.arguments)
            let bytes = route == .coverageJSON ? #"{"targets":[]}"# : "native coverage\n"
            return try await fixture.capture(#"printf '%s' "$1""#, arguments: [bytes], requested: command, directory: directory)
        }
        #expect(evidence.summary === summary)
        #expect(evidence.provesSuccessfulConsumption)
        #expect(evidence.failures.isEmpty)
        #expect(evidence.reports.map(\.name).sorted() == NotikaResultConsumers.requiredReportNames(request: fixture.request).sorted())
        #expect(calls.value.withLock { $0.count } == NotikaResultConsumers.requiredCaptureRoles(request: fixture.request).count)
        for report in evidence.reports {
            var status = stat()
            #expect(lstat(report.path, &status) == 0)
            #expect(status.st_mode & 0o7777 == 0o600)
            #expect(status.st_nlink == 1)
            #expect(UInt64(status.st_ino) == report.inode)
            #expect(CanonicalJSONDigest.digest(try Data(contentsOf: URL(fileURLWithPath: report.path))) == report.sha256)
        }
        let canonical = try evidence.canonicalValue
        #expect(try NotikaResultConsumerEvidence.validateCanonicalValue(
            canonical, request: fixture.request, resultReceiptSHA256: summary.resultBundle.receiptSHA256,
            sessionPath: fixture.session.path, expectedResultIdentity: summary.probe?.workingDirectoryIdentity,
            allowFixtureAdmission: true))
        #expect(throws: (any Error).self) {
            try NotikaResultConsumerEvidence.validateCanonicalValue(
                canonical, request: fixture.request, resultReceiptSHA256: summary.resultBundle.receiptSHA256,
                sessionPath: fixture.session.path, expectedResultIdentity: summary.probe?.workingDirectoryIdentity)
        }
        try evidence.revalidateForPublication()
    }

    @Test(arguments: [NotikaMakeRoute.coverageFile, .coverageFileUnit])
    func successfulDiagnosticCannotReplaceRequestedCoverageLookupFailure(route: NotikaMakeRoute) async throws {
        let fixture = try ConsumerFixture(route: route, file: "Sources/Missing.swift")
        defer { fixture.remove() }
        let summary = try await fixture.summary()
        let calls = ConsumerCalls()
        let evidence = await NotikaResultConsumers(summary: summary).runForTrustedFixture(environment: fixture.environment) { command, directory in
            calls.append(command.arguments)
            if command.arguments.contains("--file") {
                return try await fixture.capture("printf lookup-failed >&2; exit 47", requested: command, directory: directory)
            }
            let paths = (0..<30).map { "/Sources/File\($0).swift" }.joined(separator: "\n")
            return try await fixture.capture(#"printf '%s' "$1""#, arguments: [paths], requested: command, directory: directory)
        }
        #expect(!evidence.provesSuccessfulConsumption)
        #expect(summary.provesPassingRun)
        #expect(evidence.captures.first(where: { $0.role == "coverage-file" })?.capture.observation.termination?.value == 47)
        #expect(evidence.captures.last?.diagnostic == true)
        #expect(evidence.captures.last?.capture.observation.termination?.value == 0)
        #expect(evidence.consoleOutput?.split(separator: "\n").count == 20)
        #expect(calls.value.withLock { $0.last } == ["xccov", "view", "--file-list", "."])
        #expect(try !NotikaResultConsumerEvidence.validateCanonicalValue(
            evidence.canonicalValue, request: fixture.request, resultReceiptSHA256: summary.resultBundle.receiptSHA256,
            sessionPath: fixture.session.path, expectedResultIdentity: summary.probe?.workingDirectoryIdentity,
            allowFixtureAdmission: true))
        try evidence.revalidateForPublication()
    }

    @Test func reportReplacementAndRewriteRestoreInvalidateTerminalCustody() async throws {
        let fixture = try ConsumerFixture(route: .resultsFile)
        defer { fixture.remove() }
        let summary = try await fixture.summary()
        let evidence = await NotikaResultConsumers(summary: summary).run(environment: fixture.environment) { _, _ in
            throw ResultBundleFailure(operation: "summary must be reused")
        }
        #expect(evidence.provesSuccessfulConsumption)
        let report = try #require(evidence.reports.first)
        let url = URL(fileURLWithPath: report.path)
        let bytes = try Data(contentsOf: url)
        try Data("tampered".utf8).write(to: url)
        try bytes.write(to: url)
        #expect(throws: (any Error).self) { try evidence.revalidateForPublication() }
        #expect(throws: (any Error).self) { try evidence.revalidateForPublication() }
    }

    @Test func reportCollisionDoesNotOverwriteAnotherOwnersFile() async throws {
        let fixture = try ConsumerFixture(route: .coverageJSON)
        defer { fixture.remove() }
        let summary = try await fixture.summary()
        let output = fixture.session.appendingPathComponent("coverage.json")
        let original = Data("another writer".utf8)
        try original.write(to: output)
        let calls = ConsumerCalls()
        let evidence = await NotikaResultConsumers(summary: summary).run(environment: fixture.environment) { command, _ in
            calls.append(command.arguments)
            throw ResultBundleFailure(operation: "must not start")
        }
        #expect(!evidence.provesSuccessfulConsumption)
        #expect(calls.value.withLock { $0.isEmpty })
        #expect(try Data(contentsOf: output) == original)
        #expect(evidence.reports.isEmpty)
    }

    @Test func coverageHTMLRequiresRetainedIndexAndRefusesTreeMutation() async throws {
        let fixture = try ConsumerFixture(route: .coverageHTML)
        defer { fixture.remove() }
        let summary = try await fixture.summary()
        let calls = ConsumerCalls()
        let evidence = await NotikaResultConsumers(summary: summary).runForTrustedFixture(
            environment: fixture.environment, genhtmlExecutable: "/fixture/genhtml"
        ) { command, directory in
            calls.append(command.arguments)
            if command.executable == "/usr/bin/xcrun" {
                return try await fixture.capture(#"printf '%s' "$1""#,
                    arguments: [#"{"targets":[{"files":[{"path":"/Sources/A.swift","functions":[{"lineNumber":9,"executionCount":2}]}]}]}"#],
                    requested: command, directory: directory)
            }
            #expect(command.workingDirectory == fixture.session.path)
            #expect(command.arguments == ["coverage.lcov", "--output-directory", "coverage-html"])
            return try await fixture.capture("umask 077; printf '<html>coverage</html>' > coverage-html/index.html",
                                              requested: command, directory: directory)
        }
        #expect(evidence.provesSuccessfulConsumption)
        #expect(evidence.reports.map(\.name).sorted() == ["coverage-html", "coverage.json", "coverage.lcov"])
        let html = try #require(evidence.reports.first { $0.name == "coverage-html" })
        #expect(html.entries.contains { $0.path == "index.html" && $0.type == "file" })
        #expect(try NotikaResultConsumerEvidence.validateCanonicalValue(
            evidence.canonicalValue, request: fixture.request, resultReceiptSHA256: summary.resultBundle.receiptSHA256,
            sessionPath: fixture.session.path, expectedResultIdentity: summary.probe?.workingDirectoryIdentity,
            allowFixtureAdmission: true))
        try evidence.revalidateForPublication()
        try Data("changed".utf8).write(to: URL(fileURLWithPath: html.path + "/index.html"))
        #expect(throws: (any Error).self) { try evidence.revalidateForPublication() }
    }

    @Test(arguments: [false, true])
    func foreignCommandOrUnpinnedCaptureCannotCreateAReport(omitPin: Bool) async throws {
        let fixture = try ConsumerFixture(route: .coverageJSON)
        defer { fixture.remove() }
        let summary = try await fixture.summary()
        let evidence = await NotikaResultConsumers(summary: summary).run(environment: fixture.environment) { command, directory in
            try await fixture.capture(#"printf '%s' '{"targets":[]}'"#, requested: command,
                                      directory: omitPin ? nil : directory)
        }
        #expect(!evidence.provesSuccessfulConsumption)
        #expect(!evidence.failures.isEmpty)
        #expect(evidence.reports.isEmpty)
        #expect(evidence.captures.count == 1)
        #expect(evidence.summary.nativeObservation.termination?.value == 0)
    }

    @Test func LCOVMatchesFunctionLineOrderAndRejectsInvalidStructuredInput() throws {
        let input = Data(#"{"targets":[{"files":[{"path":"/A.swift","functions":[{"lineNumber":7,"executionCount":3},{"lineNumber":7,"executionCount":0},{"lineNumber":9,"executionCount":null}]},{"path":"/B.swift"}]}]}"#.utf8)
        #expect(try NotikaResultConsumers.convertCoverageToLCOV(input)
                == Data("TN:\nSF:/A.swift\nDA:7,3\nDA:7,0\nend_of_record\nSF:/B.swift\nend_of_record\n".utf8))
        for json in [
            #"{"targets":[],"targets":[]}"#,
            #"{"targets":[{"files":[{"path":"a\nSF:forged"}]}]}"#,
            #"{"targets":[{"files":[{"path":"a","functions":[{"lineNumber":1,"executionCount":true}]}]}]}"#,
            #"{"targets":[{"files":[{"path":"a","functions":[{"lineNumber":0,"executionCount":1}]}]}]}"#,
        ] {
            #expect(throws: (any Error).self) { try NotikaResultConsumers.convertCoverageToLCOV(Data(json.utf8)) }
        }
    }
}

private struct ConsumerFixture: Sendable {
    let repository: URL
    let session: URL
    let request: NotikaActionRequest
    let invocation: NotikaXcodeInvocation
    let phase: NativeInvocationPhase
    let runID = UUID().uuidString
    let environment = ["PATH": "/usr/bin:/bin"]
    var helper: String {
        AgentBuildTestPaths.packageRoot.appendingPathComponent(".build/debug/agentbuild").path
    }

    init(route: NotikaMakeRoute, file: String = "") throws {
        repository = URL(fileURLWithPath: "/private/tmp/result-consumer-" + UUID().uuidString)
        session = repository.appendingPathComponent("Artifacts/AgentSessions/" + runID)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        request = try NotikaActionRequest(makeRoute: route, testFile: file)
        let plan = try NotikaXcodeInvocationPlan(request: request, destination: "platform=macOS,arch=arm64",
            cacheDirectory: repository.appendingPathComponent("cache").path,
            resultBundle: session.appendingPathComponent("result.xcresult").path)
        invocation = try #require(plan.invocations.last)
        phase = try #require(NativeInvocationLedger(plan: plan).phases.last)
    }

    func summary() async throws -> NotikaResultSummaryEvidence {
        let reservation = try NotikaResultBundle(sessionDirectory: session.path, runID: runID,
            sourceBeforeHash: String(repeating: "c", count: 64), request: request, invocation: invocation, phase: phase)
        let native = try await capture("exit 0", cwd: repository.path)
        try FileManager.default.createDirectory(at: session.appendingPathComponent("result.xcresult/Data"),
                                                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let retained = try reservation.admitAfterRetirementForTrustedFixture(native)
        return await retained.observeSummaryForTrustedFixture(environment: environment) { requested, directory in
            try await capture(#"printf '%s' '{"result":"Passed","passedTests":3,"failedTests":0,"skippedTests":0,"totalTestCount":3}'"#,
                              requested: requested, directory: directory)
        }
    }

    func capture(_ script: String, arguments: [String] = [], requested: DarwinWorkloadCommand, directory: Int32?) async throws -> CapturedNativePhase {
        try await capture(script, arguments: arguments, cwd: requested.workingDirectory,
                          environment: requested.environment, directory: directory)
    }

    func capture(_ script: String, arguments: [String] = [], cwd: String,
                 environment: [String: String] = ["PATH": "/usr/bin:/bin"], directory: Int32? = nil) async throws -> CapturedNativePhase {
        let command = try DarwinWorkloadCommand(executable: "/bin/sh", arguments: ["-c", script, "consumer-fixture"] + arguments,
                                               workingDirectory: cwd, environment: environment)
        return try await CapturedNativePhaseRunner().run(helperExecutable: helper, command: command,
            retainedLockDescriptors: [], nativeWorkingDirectoryDescriptor: directory, artifactRoot: session.path)
    }

    func remove() { try? FileManager.default.removeItem(at: repository) }
}

private final class ConsumerCalls: Sendable {
    let value = Mutex<[[String]]>([])
    func append(_ arguments: [String]) { value.withLock { $0.append(arguments) } }
}
