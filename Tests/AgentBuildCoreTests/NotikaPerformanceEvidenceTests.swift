@testable import AgentBuildCore
import AgentLeaseCore
import Darwin
import Foundation
import Testing

@Suite("Retained Notika performance export")
struct NotikaPerformanceEvidenceTests {
    @Test(arguments: [NotikaMakeRoute.testTextInputHeavyDependencyPerformance, .testCanvasFramePacingPerformance])
    func actualHelperExportIsBoundToResultAndSealedThroughPublication(_ route: NotikaMakeRoute) async throws {
        let fixture = try PerformanceEvidenceFixture(route: route)
        defer { fixture.remove() }
        let reservation = try fixture.reserve(), summary = try await fixture.summary()
        if fixture.canvas {
            #expect(reservation.childEnvironment["TEST_RUNNER_NOTIKA_AGENT_SESSION_ID"] == fixture.runID)
            #expect(reservation.childEnvironment["TEST_RUNNER_NOTIKA_CANVAS_FRAME_PACING_REPORT_INODE"] != nil)
        } else {
            #expect(reservation.childEnvironment["TEST_RUNNER_NOTIKA_TEXT_HEAVY_DEPENDENCY_BENCHMARK"] == "1")
            #expect(reservation.childEnvironment["TEST_RUNNER_NOTIKA_TEXT_BENCHMARK_REVISION"] == fixture.head)
            #expect(reservation.childEnvironment["TEST_RUNNER_NOTIKA_TEXT_PROFILE_DIAGNOSTICS"] == "disabled")
            #expect(reservation.childEnvironment["TEST_RUNNER_NOTIKA_TEXT_PROFILE_RUN_ORDINAL"] == "0")
        }
        let evidence = await reservation.consumeForTrustedFixture(summary: summary, environment: fixture.environment) { command, descriptor in
            #expect(command.arguments == ["xcresulttool", "export", "attachments", "--path", ".", "--output-path", reservation.evidenceDirectory + "/attachments"])
            return try await fixture.export(command: command, descriptor: descriptor)
        }
        #expect(evidence.complete, "\(evidence.failures)")
        try evidence.revalidateForPublication()
        let record = try #require(evidence.record)
        #expect(record.resultReceiptSHA256 == summary.resultBundle.receiptSHA256)
        #expect(record.toolchainBeforeHash == fixture.toolchainHash)
        #expect(record.scenarios.count == (fixture.canvas ? 1 : 2))
        #expect(record.leaseSessionID == "fixture-lease")
        let snapshot = try evidence.canonicalValue
        let admitted = try NotikaPerformanceEvidence.validateCanonicalValue(snapshot, request: fixture.request,
            sourceBeforeSHA256: fixture.sourceHash, toolchainBeforeSHA256: fixture.toolchainHash, sessionPath: fixture.session.path,
            resultReceiptSHA256: summary.resultBundle.receiptSHA256, outerLeaseEvidence: nil, sourceHead: fixture.head,
            expectedResultIdentity: summary.probe?.workingDirectoryIdentity, allowFixtureAdmission: true)
        #expect(admitted)
        for mutation in ["foreignDirectory", "unknownObservation", "foreignWorker", "missingProcess", "unknownRaw", "outsideRaw", "truncatedRaw",
                         "missingCombined", "foreignCombined", "combinedCount", "combinedEOF"] {
            var snapshotObject = try performanceDocument(CanonicalJSONDigest.encode(snapshot)).object()
            var export = try snapshotObject["exportCapture"]!.object()
            if mutation == "foreignDirectory" {
                var pin = try export["workingDirectoryIdentity"]!.object()
                pin["inode"] = .integer(1); export["workingDirectoryIdentity"] = .object(pin)
            } else if ["unknownObservation", "foreignWorker", "missingProcess"].contains(mutation) {
                var observed = try export["observation"]!.object()
                if mutation == "unknownObservation" { observed["extra"] = .null }
                else if mutation == "missingProcess" { observed["processIdentifier"] = .null }
                else {
                    var worker = try observed["worker"]!.object()
                    worker["processIdentifier"] = .integer(1); observed["worker"] = .object(worker)
                }
                export["observation"] = .object(observed)
            } else {
                var raw = try export["rawCapture"]!.object()
                if mutation == "unknownRaw" { raw["extra"] = .null }
                else if mutation == "missingCombined" { raw.removeValue(forKey: "combined") }
                else if ["foreignCombined", "combinedCount", "combinedEOF"].contains(mutation) {
                    var stream = try raw["combined"]!.object()
                    if mutation == "foreignCombined" { stream["path"] = .string(fixture.session.path + "/" + UUID().uuidString + "/combined.log") }
                    else if mutation == "combinedCount" { stream["observedBytes"] = .integer(1) }
                    else { stream["reachedEOF"] = .bool(false) }
                    raw["combined"] = .object(stream)
                }
                else {
                    var stream = try raw["standardOutput"]!.object()
                    if mutation == "outsideRaw" { stream["path"] = .string("/private/tmp/foreign/stdout.log") }
                    else { stream["reachedEOF"] = .bool(false) }
                    raw["standardOutput"] = .object(stream)
                }
                export["rawCapture"] = .object(raw)
            }
            snapshotObject["exportCapture"] = .object(export)
            let changed = try testPerformanceCanonical(StrictJSONDocument(data: PerformanceJSON.object(snapshotObject).encoded()).root)
            #expect(throws: (any Error).self) {
                try NotikaPerformanceEvidence.validateCanonicalValue(changed, request: fixture.request,
                    sourceBeforeSHA256: fixture.sourceHash, toolchainBeforeSHA256: fixture.toolchainHash, sessionPath: fixture.session.path,
                    resultReceiptSHA256: summary.resultBundle.receiptSHA256, outerLeaseEvidence: nil, sourceHead: fixture.head,
                    expectedResultIdentity: summary.probe?.workingDirectoryIdentity, allowFixtureAdmission: true)
            }
        }
        #expect(throws: (any Error).self) {
            try NotikaPerformanceEvidence.validateCanonicalValue(snapshot, request: fixture.request,
                sourceBeforeSHA256: String(repeating: "f", count: 64), toolchainBeforeSHA256: fixture.toolchainHash,
                sessionPath: fixture.session.path, resultReceiptSHA256: summary.resultBundle.receiptSHA256,
                outerLeaseEvidence: nil, sourceHead: fixture.head, expectedResultIdentity: summary.probe?.workingDirectoryIdentity, allowFixtureAdmission: true)
        }
        let file = URL(fileURLWithPath: reservation.evidenceDirectory).appendingPathComponent(record.scenarios[0].summaryPath)
        let original = try Data(contentsOf: file)
        #expect(chmod(file.path, 0o600) == 0)
        try Data("{}".utf8).write(to: file)
        try original.write(to: file)
        #expect(chmod(file.path, 0o400) == 0)
        #expect(throws: (any Error).self) { try evidence.revalidateForPublication() }
    }

    @Test func canvasUsesOriginalReservedInodeAndRejectsNameReplacement() async throws {
        let fixture = try PerformanceEvidenceFixture(route: .testCanvasFramePacingPerformance)
        defer { fixture.remove() }
        let reservation = try fixture.reserve(), summary = try await fixture.summary()
        let original = reservation.evidenceDirectory + "/report.json"
        var status = stat(); #expect(lstat(original, &status) == 0)
        #expect(reservation.childEnvironment["NOTIKA_CANVAS_FRAME_PACING_REPORT_INODE"] == String(status.st_ino))
        try FileManager.default.moveItem(atPath: original, toPath: original + ".old")
        try Data().write(to: URL(fileURLWithPath: original)); #expect(chmod(original, 0o600) == 0)
        let evidence = await reservation.consumeForTrustedFixture(summary: summary, environment: fixture.environment) { _, _ in
            Issue.record("A replaced reservation must fail before export")
            throw NotikaPerformanceFailure(operation: "unexpected export")
        }
        #expect(!evidence.complete)
        #expect(evidence.exportCapture == nil)
        #expect(evidence.failures.contains(where: { $0.operation == "canvas report reservation changed" }))
    }

    @Test(arguments: ["third", "wrongTest", "unknownFile", "symlink", "nativeFailure"])
    func untrustedAttachmentEvidenceNeverPublishesSuccess(_ mutation: String) async throws {
        let fixture = try PerformanceEvidenceFixture(route: .testTextInputHeavyDependencyPerformance)
        defer { fixture.remove() }
        let reservation = try fixture.reserve(), summary = try await fixture.summary()
        let evidence = await reservation.consumeForTrustedFixture(summary: summary, environment: fixture.environment) { command, descriptor in
            try await fixture.export(command: command, descriptor: descriptor, mutation: mutation)
        }
        #expect(!evidence.complete)
        #expect(evidence.record == nil)
        #expect(!evidence.failures.isEmpty)
        #expect(summary.nativeObservation.termination == RunTermination(kind: .exit, value: 0))
        if mutation == "nativeFailure" {
            #expect(evidence.exportCapture?.observation.termination == RunTermination(kind: .exit, value: 71))
        }
        let snapshot = try evidence.canonicalValue
        #expect(try !NotikaPerformanceEvidence.validateCanonicalValue(snapshot, request: fixture.request,
            sourceBeforeSHA256: fixture.sourceHash, toolchainBeforeSHA256: fixture.toolchainHash, sessionPath: fixture.session.path,
            resultReceiptSHA256: summary.resultBundle.receiptSHA256, outerLeaseEvidence: nil, sourceHead: fixture.head,
            expectedResultIdentity: summary.probe?.workingDirectoryIdentity, allowFixtureAdmission: true))
        #expect(!FileManager.default.fileExists(atPath: reservation.evidenceDirectory + "/run-manifest.json"))
    }
}

private func testPerformanceCanonical(_ value: StrictJSONValue) throws -> CanonicalJSONValue {
    switch value {
    case .array(let values): .array(try values.map(testPerformanceCanonical))
    case .bool(let value): .bool(value)
    case .null: .null
    case .number(let value): .integer(try value.int64())
    case .object(let value): .object(try value.members.map { .init(key: $0.key, value: try testPerformanceCanonical($0.value)) })
    case .string(let value): .string(value)
    }
}

private struct PerformanceEvidenceFixture: Sendable {
    let repository: URL
    let session: URL
    let result: URL
    let runID = UUID().uuidString
    let sourceHash = "eaf3b9a9369a419792819017d2161e9e34220cf6f8487a92ef70f999492e0579"
    let head = "40716192d308830a578f44ae89f52276aea2c205"
    let toolchainHash = String(repeating: "c", count: 64)
    let request: NotikaActionRequest
    let environment = ["PATH": "/usr/bin:/bin"]
    var canvas: Bool { request.canonicalMakeRoute == .testCanvasFramePacingPerformance }
    var helper: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/agentbuild").path
    }
    init(route: NotikaMakeRoute) throws {
        repository = URL(fileURLWithPath: "/private/tmp/agentbuild-performance-" + UUID().uuidString)
        session = repository.appendingPathComponent("Artifacts/AgentSessions/" + runID)
        result = session.appendingPathComponent("result.xcresult")
        request = try NotikaActionRequest(makeRoute: route)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func reserve() throws -> NotikaPerformanceReservation {
        try NotikaPerformanceReservation(sessionDirectory: session.path, runID: runID, request: request, sourceBeforeHash: sourceHash,
            sourceHead: head, toolchainBeforeHash: toolchainHash, leaseSessionID: "fixture-lease")
    }
    func summary() async throws -> NotikaResultSummaryEvidence {
        let plan = try NotikaXcodeInvocationPlan(request: request, destination: "platform=macOS,arch=arm64",
            cacheDirectory: repository.appendingPathComponent("cache").path, resultBundle: result.path)
        let reservation = try NotikaResultBundle(sessionDirectory: session.path, runID: runID, sourceBeforeHash: sourceHash,
            request: request, invocation: #require(plan.invocations.last), phase: #require(NativeInvocationLedger(plan: plan).phases.last))
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = result.appendingPathComponent("data"); try Data([1, 2, 3]).write(to: file); #expect(chmod(file.path, 0o600) == 0)
        let worker = DarwinWorkloadResult(processIdentifier: 42, termination: .init(kind: .exit, value: 0), stopReason: nil, retirement: .reaped, failures: [])
        let stream = NativeLogStreamResult(path: "/fixture/unused", observedBytes: 0, retainedBytes: 0, sha256: CanonicalJSONDigest.digest(Data()), reachedEOF: true)
        let raw = NativeLogCaptureResult(standardOutput: stream, standardError: stream, combined: stream, maximumBytes: 0, captureComplete: true, failures: [])
        let bundle = try reservation.admit(nativeObservation: NotikaNativeObservation(worker: worker), rawCapture: raw)
        let count = canvas ? 1 : 2
        let encoded = "{\"result\":\"Passed\",\"passedTests\":\(count),\"failedTests\":0,\"skippedTests\":0,\"totalTestCount\":\(count)}"
        return await bundle.observeSummaryForTrustedFixture(environment: environment) { command, descriptor in
            let shell = try DarwinWorkloadCommand(executable: "/bin/sh", arguments: ["-c", "printf '%s' \"$1\"", "summary", encoded],
                workingDirectory: command.workingDirectory, environment: command.environment)
            return try await CapturedNativePhaseRunner().run(helperExecutable: helper, command: shell, retainedLockDescriptors: [],
                nativeWorkingDirectoryDescriptor: descriptor, artifactRoot: session.path)
        }
    }
    func export(command: DarwinWorkloadCommand, descriptor: Int32, mutation: String = "") async throws -> CapturedNativePhase {
        let staged = repository.appendingPathComponent("export-source")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var attachments: [[String: Any]] = []
        if canvas {
            try performanceCanvasFixture(sessionID: runID, sourceHash: sourceHash, head: head).write(to: staged.appendingPathComponent("canvas.json"))
            attachments = [["testIdentifier": NotikaPerformanceReports.canvasTestIdentifier, "attachments": [["exportedFileName": "canvas.json"]]]]
        } else {
            for (index, name) in ["heavy", "light"].enumerated() {
                let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("Evidence/NotikaPerformance/" + name + "-raw.json")
                try Data(contentsOf: fixture).write(to: staged.appendingPathComponent(name + ".json"))
                attachments.append(["testIdentifier": mutation == "wrongTest" && index == 0 ? "Wrong/test()" : NotikaPerformanceReports.textTestIdentifiers[index],
                    "attachments": [["exportedFileName": name + ".json"]]])
            }
            if mutation == "third" {
                try Data("{}".utf8).write(to: staged.appendingPathComponent("third.json"))
                attachments.append(["testIdentifier": "Wrong/test()", "attachments": [["exportedFileName": "third.json"]]])
            }
        }
        try JSONSerialization.data(withJSONObject: attachments).write(to: staged.appendingPathComponent("manifest.json"))
        if mutation == "unknownFile" { try Data("foreign".utf8).write(to: staged.appendingPathComponent("unknown")) }
        if mutation == "symlink" { try FileManager.default.createSymbolicLink(at: staged.appendingPathComponent("foreign"), withDestinationURL: result) }
        let script = mutation == "nativeFailure" ? "exit 71" : "/bin/cp -R \"$1\" \"$2\""
        let shell = try DarwinWorkloadCommand(executable: "/bin/sh", arguments: ["-c", script, "export", staged.path, command.arguments.last!],
            workingDirectory: command.workingDirectory, environment: command.environment)
        return try await CapturedNativePhaseRunner().run(helperExecutable: helper, command: shell, retainedLockDescriptors: [],
            nativeWorkingDirectoryDescriptor: descriptor, artifactRoot: session.path)
    }
    func remove() { try? FileManager.default.removeItem(at: repository) }
}
