import AgentLeaseCore
import Darwin
import Foundation

public struct NotikaPerformanceScenarioRecord: Codable, Equatable, Sendable {
    public let label: String
    public let testIdentifier: String
    public let rawPath: String
    public let rawBytes: Int64
    public let rawSHA256: String
    public let summaryPath: String
    public let summaryBytes: Int64
    public let summarySHA256: String
}

public struct NotikaPerformanceEvidenceRecord: Codable, Equatable, Sendable {
    public let namespace: String
    public let schemaVersion: Int
    public let interpreter: String
    public let toolchainBeforeHash: String
    public let route: String
    public let sessionID: String
    public let sourceBeforeHash: String
    public let sourceHead: String
    public let configurationIdentity: String
    public let leaseSessionID: String
    public let evidenceDirectory: String
    public let resultReceiptSHA256: String
    public let exportCommand: NotikaPerformanceExportRecord
    public let scenarios: [NotikaPerformanceScenarioRecord]
    public let reservedReportDevice: Int64?
    public let reservedReportInode: UInt64?
}

public struct NotikaPerformanceExportRecord: Codable, Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: String
    public let standardOutputSHA256: String
    public let standardErrorSHA256: String
    public let nativeTermination: RunTermination
}

public final class NotikaPerformanceEvidence: @unchecked Sendable {
    public let record: NotikaPerformanceEvidenceRecord?
    public let manifestSHA256: String?
    public let treeSHA256: String?
    public let exportCapture: CapturedNativePhase?
    public let failures: [NotikaPerformanceFailure]
    public let fixtureAdmission: Bool
    public var complete: Bool { record != nil && manifestSHA256 != nil && treeSHA256 != nil && failures.isEmpty }
    private let reservation: NotikaPerformanceReservation
    private let summary: NotikaResultSummaryEvidence
    private let tree: NotikaResultBundleTree?

    fileprivate init(reservation: NotikaPerformanceReservation, summary: NotikaResultSummaryEvidence,
                     record: NotikaPerformanceEvidenceRecord?, tree: NotikaResultBundleTree?,
                     manifestSHA256: String?, exportCapture: CapturedNativePhase?, failures: [NotikaPerformanceFailure], fixtureAdmission: Bool) {
        self.reservation = reservation; self.summary = summary; self.record = record; self.tree = tree
        self.manifestSHA256 = manifestSHA256; treeSHA256 = tree?.commitment
        self.exportCapture = exportCapture; self.failures = failures
        self.fixtureAdmission = fixtureAdmission
    }

    public func revalidateForPublication() throws {
        try reservation.revalidate(); try summary.revalidateForPublication()
        try exportCapture?.revalidateForPublication(); try tree?.revalidate()
    }

    public var canonicalValue: CanonicalJSONValue {
        get throws {
            .object([
                "schemaVersion": .integer(1), "kind": .string("notika.performance-evidence"), "complete": .bool(complete),
                "fixtureAdmission": .bool(fixtureAdmission), "record": try record.map(performanceEncoded) ?? .null,
                "manifestSHA256": manifestSHA256.map(CanonicalJSONValue.string) ?? .null,
                "treeSHA256": treeSHA256.map(CanonicalJSONValue.string) ?? .null,
                "exportCapture": try exportCapture.map { capture in
                    .object(["executable": .string(capture.command.executable),
                        "arguments": .array(capture.command.arguments.map(CanonicalJSONValue.string)),
                        "workingDirectory": .string(capture.command.workingDirectory),
                        "argumentSHA256": .string(ArgumentCommitment.digest(arguments: capture.command.arguments)),
                        "workingDirectoryIdentity": try capture.workingDirectoryIdentity.map(performanceEncoded) ?? .null,
                        "observation": try performanceObservation(capture.observation),
                        "rawCapture": try performanceEncoded(capture.rawCapture)])
                } ?? .null,
                "failures": try performanceEncoded(failures),
            ])
        }
    }

    /// Pure manifest admission verifies bindings and inventory. It never turns
    /// serialized paths into retained descriptors or native execution authority.
    public static func validateCanonicalValue(_ value: CanonicalJSONValue, request: NotikaActionRequest,
        sourceBeforeSHA256: String, toolchainBeforeSHA256: String, sessionPath: String,
        resultReceiptSHA256: String, outerLeaseEvidence: NotikaOuterLeaseEvidence?, sourceHead: String? = nil,
        expectedResultIdentity: NativeWorkingDirectoryIdentity? = nil, allowFixtureAdmission: Bool
    ) throws -> Bool {
        let root = try StrictJSONDocument(data: CanonicalJSONDigest.encode(value)).root.requireObject()
        try root.project(requiredKeys: ["schemaVersion", "kind", "complete", "fixtureAdmission", "record", "manifestSHA256",
            "treeSHA256", "exportCapture", "failures"])
        guard root.value(forKey: "schemaVersion") == .number(try performanceNumber(1)),
              root.value(forKey: "kind") == .string("notika.performance-evidence"),
              case .bool(let complete) = root.value(forKey: "complete"),
              case .bool(let fixtureAdmission) = root.value(forKey: "fixtureAdmission"),
              !fixtureAdmission || allowFixtureAdmission,
              performanceHex(sourceBeforeSHA256, length: 64), performanceHex(toolchainBeforeSHA256, length: 64),
              performanceHex(resultReceiptSHA256, length: 64),
              let route = request.canonicalMakeRoute,
              [.testTextInputHeavyDependencyPerformance, .testCanvasFramePacingPerformance].contains(route) else {
            throw performanceFailure("invalid performance evidence schema")
        }
        let failures = try JSONDecoder().decode([NotikaPerformanceFailure].self,
            from: CanonicalJSONDigest.encode(performanceCanonical(root.requiredValue(forKey: "failures"))))
        if !complete {
            guard root.value(forKey: "record") == .null, root.value(forKey: "manifestSHA256") == .null,
                  root.value(forKey: "treeSHA256") == .null, !failures.isEmpty else { throw performanceFailure("invalid incomplete performance evidence") }
            if let export = root.value(forKey: "exportCapture"), export != .null {
                _ = try performanceValidateCapture(export.requireObject(), sessionPath: sessionPath,
                    expectedResultIdentity: expectedResultIdentity, fixtureAdmission: fixtureAdmission)
            }
            return false
        }
        let recordValue = try performanceCanonical(root.requiredValue(forKey: "record"))
        let record = try JSONDecoder().decode(NotikaPerformanceEvidenceRecord.self, from: CanonicalJSONDigest.encode(recordValue))
        guard try CanonicalJSONDigest.encode(performanceEncoded(record)) == CanonicalJSONDigest.encode(recordValue) else {
            throw performanceFailure("unknown performance record fields")
        }
        let canvas = request.canonicalMakeRoute == .testCanvasFramePacingPerformance
        let expectedDirectory = sessionPath + "/" + (canvas ? "canvas-frame-pacing-performance" : "text-input-heavy-dependency-performance")
        guard record.namespace == "agentbuild.notika-performance", record.schemaVersion == 1,
              record.interpreter == "agentbuild.notika-performance.v1", record.toolchainBeforeHash == toolchainBeforeSHA256,
              record.sourceBeforeHash == sourceBeforeSHA256, record.route == request.makeRoute?.rawValue,
              record.sessionID == URL(fileURLWithPath: sessionPath).lastPathComponent,
              record.evidenceDirectory.utf8.elementsEqual(expectedDirectory.utf8), record.resultReceiptSHA256 == resultReceiptSHA256,
              performanceHex(record.sourceHead, length: 40), record.sourceHead == sourceHead,
              record.configurationIdentity == (canvas ? NotikaPerformanceReports.canvasConfiguration : NotikaPerformanceReports.textConfiguration),
              failures.isEmpty, fixtureAdmission || outerLeaseEvidence?.sessionID == record.leaseSessionID,
              fixtureAdmission || outerLeaseEvidence?.hostResource == "macos-ui" else {
            throw performanceFailure("performance record session/source/tool/lease differs")
        }
        let export = record.exportCommand
        guard export.executable == "/usr/bin/xcrun",
              export.arguments == ["xcresulttool", "export", "attachments", "--path", ".", "--output-path", expectedDirectory + "/attachments"],
              export.workingDirectory.utf8.elementsEqual((sessionPath + "/result.xcresult").utf8),
              export.nativeTermination == RunTermination(kind: .exit, value: 0),
              performanceHex(export.standardOutputSHA256, length: 64), performanceHex(export.standardErrorSHA256, length: 64) else {
            throw performanceFailure("performance export command differs")
        }
        let capture = try root.requiredValue(forKey: "exportCapture").requireObject()
        guard try performanceValidateCapture(capture, sessionPath: sessionPath, expectedResultIdentity: expectedResultIdentity,
            fixtureAdmission: fixtureAdmission) else { throw performanceFailure("performance export lacks complete native proof") }
        try capture.project(requiredKeys: ["executable", "arguments", "workingDirectory", "argumentSHA256", "workingDirectoryIdentity", "observation", "rawCapture"])
        let actualExecutable = try performanceString(capture, "executable")
        guard actualExecutable == export.executable || fixtureAdmission && actualExecutable == "/bin/sh",
              try performanceString(capture, "workingDirectory") == export.workingDirectory else { throw performanceFailure("performance capture differs") }
        let argumentsValue = try capture.requiredValue(forKey: "arguments")
        guard case .array(let arguments) = argumentsValue else { throw performanceFailure("invalid performance argument list") }
        let actualArguments = try arguments.map { item -> String in
            guard case .string(let result) = item else { throw performanceFailure("invalid performance argument") }; return result
        }
        guard fixtureAdmission || actualArguments == export.arguments,
              try performanceString(capture, "argumentSHA256") == ArgumentCommitment.digest(arguments: actualArguments) else {
            throw performanceFailure("performance export argument digest differs")
        }
        let observation = try capture.requiredValue(forKey: "observation").requireObject()
        guard observation.value(forKey: "termination") == (try StrictJSONDocument(data: JSONEncoder().encode(RunTermination(kind: .exit, value: 0))).root),
              observation.value(forKey: "retirement") == .string("workerReaped"), observation.value(forKey: "cancelled") == .bool(false),
              observation.value(forKey: "failures") == .array([]) else { throw performanceFailure("performance ancillary export failed") }
        let raw = try JSONDecoder().decode(NativeLogCaptureResult.self, from: CanonicalJSONDigest.encode(performanceCanonical(capture.requiredValue(forKey: "rawCapture"))))
        guard raw.captureComplete, raw.failures.isEmpty, raw.standardOutput.sha256 == export.standardOutputSHA256,
              raw.standardError.sha256 == export.standardErrorSHA256 else { throw performanceFailure("performance raw export incomplete") }
        if canvas {
            guard record.scenarios.count == 1, record.scenarios[0].label == "canvas-frame-pacing-matrix",
                  record.scenarios[0].testIdentifier == NotikaPerformanceReports.canvasTestIdentifier,
                  record.scenarios[0].rawPath == "report.json", record.scenarios[0].summaryPath == "summary.json",
                  let device = record.reservedReportDevice, let inode = record.reservedReportInode, device > 0, inode > 0 else {
                throw performanceFailure("canvas report record differs")
            }
        } else {
            guard record.reservedReportDevice == nil, record.reservedReportInode == nil, record.scenarios.count == 2 else {
                throw performanceFailure("text report inventory differs")
            }
            for (index, scenario) in record.scenarios.enumerated() {
                let label = NotikaPerformanceReports.textLabels[index]
                let components = scenario.rawPath.split(separator: "/", omittingEmptySubsequences: false)
                guard scenario.label == label, scenario.testIdentifier == NotikaPerformanceReports.textTestIdentifiers[index],
                      scenario.summaryPath == "summary-" + label + ".json", components.count == 2,
                      components[0] == "attachments", !components[1].isEmpty, ![".", "..", "manifest.json"].contains(String(components[1])) else {
                    throw performanceFailure("text scenario record differs")
                }
            }
            guard Set(record.scenarios.map(\.rawPath)).count == 2 else { throw performanceFailure("duplicate raw text record") }
        }
        for scenario in record.scenarios {
            guard scenario.rawBytes > 0, scenario.rawBytes <= 8 * 1_024 * 1_024, scenario.summaryBytes > 0,
                  scenario.summaryBytes <= 8 * 1_024 * 1_024, performanceHex(scenario.rawSHA256, length: 64),
                  performanceHex(scenario.summarySHA256, length: 64) else { throw performanceFailure("invalid scenario file commitment") }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard try performanceString(root, "manifestSHA256") == CanonicalJSONDigest.digest(encoder.encode(record)),
              performanceHex(try performanceString(root, "treeSHA256"), length: 64) else { throw performanceFailure("performance tree or manifest commitment differs") }
        return true
    }
}

/// A fixed private evidence root exists before Xcode. Canvas additionally
/// reserves the report inode before launch; exported attachment bytes are later
/// written through this descriptor, never by replacing its name.
public final class NotikaPerformanceReservation: @unchecked Sendable {
    public let sessionDirectory: String
    public let evidenceDirectory: String
    public let childEnvironment: [String: String]
    public let request: NotikaActionRequest
    private let runID: String
    private let sourceHash: String
    private let sourceHead: String
    private let toolchainHash: String
    private let leaseSessionID: String
    private let retainedSession: RetainedArtifactDirectory
    private let sessionDescriptor: Int32
    private let rootDescriptor: Int32
    private let rootName: String
    private let rootIdentity: ResultNodeIdentity
    private let rootWatch: ResultMutationWatch
    private let reservedReport: Int32?
    private let reportIdentity: ResultNodeIdentity?
    private let lock = NSLock()
    private var consumed = false

    public init(sessionDirectory: String, runID: String, request: NotikaActionRequest,
                sourceBeforeHash: String, sourceHead: String, toolchainBeforeHash: String,
                leaseSessionID: String) throws {
        let canvas = request.canonicalMakeRoute == .testCanvasFramePacingPerformance
        guard let route = request.canonicalMakeRoute,
              [NotikaMakeRoute.testCanvasFramePacingPerformance, .testTextInputHeavyDependencyPerformance].contains(route),
              request.platform == .macOS, UUID(uuidString: runID) != nil,
              sessionDirectory.hasSuffix("/Artifacts/AgentSessions/" + runID),
              performanceHex(sourceBeforeHash, length: 64), performanceHex(sourceHead, length: 40), performanceHex(toolchainBeforeHash, length: 64),
              !leaseSessionID.isEmpty, leaseSessionID.utf8.count <= 256,
              !leaseSessionID.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw performanceFailure("invalid performance reservation")
        }
        let retained = try RetainedArtifactDirectory(path: sessionDirectory, requiredPermissions: 0o700)
        let session = Darwin.open(sessionDirectory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard session >= 3 else { throw performanceFailure("open performance session", detail: String(errno)) }
        var root: Int32 = -1, report: Int32 = -1, transferred = false
        defer { if !transferred { if report >= 0 { _ = Darwin.close(report) }; if root >= 0 { _ = Darwin.close(root) }; _ = Darwin.close(session) } }
        let sessionIdentity = try resultDescriptorIdentity(session)
        guard sessionIdentity.device == retained.fingerprint.device, sessionIdentity.inode == retained.fingerprint.inode else {
            throw performanceFailure("performance session changed")
        }
        let name = canvas ? "canvas-frame-pacing-performance" : "text-input-heavy-dependency-performance"
        guard mkdirat(session, name, 0o700) == 0 else { throw performanceFailure("reserve performance directory", detail: String(errno)) }
        root = openat(session, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 3, fchmod(root, 0o700) == 0 else { throw performanceFailure("open performance directory", detail: String(errno)) }
        let identity = try resultDescriptorIdentity(root)
        guard identity == (try resultEntryIdentity(session, name)), identity.owner == UInt32(geteuid()), identity.mode & 0o7777 == 0o700 else {
            throw performanceFailure("performance directory binding changed")
        }
        var reservedIdentity: ResultNodeIdentity?
        if canvas {
            report = openat(root, "report.json", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
            guard report >= 3, fchmod(report, 0o600) == 0 else { throw performanceFailure("reserve canvas report", detail: String(errno)) }
            let metadata = try resultDescriptorIdentity(report)
            guard metadata.regular, metadata.links == 1, metadata.owner == UInt32(geteuid()), metadata.size == 0 else {
                throw performanceFailure("unsafe canvas reservation")
            }
            reservedIdentity = metadata
        }
        let watch = try ResultMutationWatch(); try watch.arm(root, writes: false)
        try retained.revalidate(); try watch.check()
        let rootPath = sessionDirectory + "/" + name
        self.sessionDirectory = sessionDirectory; evidenceDirectory = rootPath
        self.request = request; self.runID = runID; sourceHash = sourceBeforeHash; self.sourceHead = sourceHead
        toolchainHash = toolchainBeforeHash; self.leaseSessionID = leaseSessionID
        retainedSession = retained; sessionDescriptor = session; rootDescriptor = root; rootName = name
        rootIdentity = identity; rootWatch = watch; reservedReport = canvas ? report : nil; reportIdentity = reservedIdentity
        var environment = ["NOTIKA_AGENT_SESSION_ID": runID, "NOTIKA_AGENT_SESSION_DIR": sessionDirectory,
            "NOTIKA_AGENT_SOURCE_BEFORE_HASH": sourceBeforeHash, "NOTIKA_AGENT_SOURCE_HEAD": sourceHead,
            "NOTIKA_AGENT_TEST_PLATFORM": "macos-ui"]
        if let reservedIdentity {
            environment["NOTIKA_CANVAS_FRAME_PACING_PERFORMANCE_PATH"] = rootPath
            environment["NOTIKA_CANVAS_FRAME_PACING_REPORT_DEVICE_ID"] = String(reservedIdentity.device)
            environment["NOTIKA_CANVAS_FRAME_PACING_REPORT_INODE"] = String(reservedIdentity.inode)
            // Xcode forwards TEST_RUNNER_ variables to the sandboxed UI runner;
            // scheme $(...) values do not resolve this session's environment.
            for (key, value) in Array(environment) { environment["TEST_RUNNER_" + key] = value }
        } else {
            environment["NOTIKA_TEXT_INPUT_HEAVY_DEPENDENCY_PERFORMANCE_PATH"] = rootPath
            environment["NOTIKA_TEXT_PERFORMANCE_ROOT_DEVICE_ID"] = String(identity.device)
            environment["NOTIKA_TEXT_PERFORMANCE_ROOT_INODE"] = String(identity.inode)
            let benchmark = ["NOTIKA_TEXT_HEAVY_DEPENDENCY_BENCHMARK": "1", "NOTIKA_TEXT_BENCHMARK_REVISION": sourceHead,
                "NOTIKA_TEXT_BENCHMARK_SOURCE_IDENTITY_SHA256": sourceBeforeHash,
                "NOTIKA_TEXT_BENCHMARK_CONFIGURATION_IDENTITY": NotikaPerformanceReports.textConfiguration,
                "NOTIKA_TEXT_PROFILE_DIAGNOSTICS": "disabled", "NOTIKA_TEXT_PROFILE_RUN_ORDINAL": "0"]
            for (key, value) in benchmark { environment[key] = value; environment["TEST_RUNNER_" + key] = value }
        }
        childEnvironment = environment; transferred = true
    }

    deinit { if let reservedReport { _ = Darwin.close(reservedReport) }; _ = Darwin.close(rootDescriptor); _ = Darwin.close(sessionDescriptor) }

    public func consume(summary: NotikaResultSummaryEvidence, environment: [String: String],
        operation: @Sendable (DarwinWorkloadCommand, Int32) async throws -> CapturedNativePhase
    ) async -> NotikaPerformanceEvidence {
        await consume(summary: summary, environment: environment, allowsTrustedShellFixture: false, operation: operation)
    }

    internal func consumeForTrustedFixture(summary: NotikaResultSummaryEvidence, environment: [String: String],
        operation: @Sendable (DarwinWorkloadCommand, Int32) async throws -> CapturedNativePhase
    ) async -> NotikaPerformanceEvidence {
        await consume(summary: summary, environment: environment, allowsTrustedShellFixture: true, operation: operation)
    }

    private func consume(summary: NotikaResultSummaryEvidence, environment: [String: String], allowsTrustedShellFixture: Bool,
        operation: @Sendable (DarwinWorkloadCommand, Int32) async throws -> CapturedNativePhase
    ) async -> NotikaPerformanceEvidence {
        var capture: CapturedNativePhase?, tree: NotikaResultBundleTree?, record: NotikaPerformanceEvidenceRecord?, manifestHash: String?
        var failures: [NotikaPerformanceFailure] = []
        do {
            try claimConsumption(); try revalidate(); try summary.revalidateForPublication()
            let canvas = reservedReport != nil
            guard summary.provesPassingRun, let tests = summary.tests,
                  tests.satisfiesExpectedRun(focusedMethod: canvas),
                  canvas || tests.passed == 2 && tests.skipped == 0 && tests.total == 2,
                  summary.resultBundle.custody.actionRequest == request,
                  summary.resultBundle.custody.sessionID == runID,
                  summary.resultBundle.custody.sourceBeforeHash == sourceHash,
                  summary.resultBundle.sessionDirectory.utf8.elementsEqual(sessionDirectory.utf8) else {
                throw performanceFailure("performance result does not prove expected tests and source")
            }
            try requireAbsent("attachments")
            let command = try DarwinWorkloadCommand(executable: "/usr/bin/xcrun",
                arguments: ["xcresulttool", "export", "attachments", "--path", ".", "--output-path", evidenceDirectory + "/attachments"],
                workingDirectory: summary.resultBundle.custody.resultPath, environment: environment)
            let exported = try await operation(command, summary.resultBundle.resultDirectoryDescriptor)
            capture = exported
            try summary.resultBundle.validateConsumerCapture(exported, command: command,
                directoryDescriptor: summary.resultBundle.resultDirectoryDescriptor, allowsTrustedShellFixture: allowsTrustedShellFixture)
            try revalidate(); try summary.revalidateForPublication()
            try sealPerformanceTree(parent: rootDescriptor, name: "attachments", maximumEntries: 256, maximumBytes: 32 * 1_024 * 1_024)
            let attachments = try NotikaResultBundleTree(parent: rootDescriptor, name: "attachments", maximumBytes: 32 * 1_024 * 1_024,
                maximumEntries: 256, privatePermissions: true, requiredFilePermissions: 0o400, requiredRootFile: "manifest.json")
            let declared = try attachmentEntries(attachments.readFile(relativePath: "manifest.json", maximumBytes: 8 * 1_024 * 1_024))
            guard Set(attachments.records.map(\.path)) == Set([".", "manifest.json"] + declared.map(\.filename)) else {
                throw performanceFailure("undeclared performance attachment artifact")
            }
            var scenarios: [NotikaPerformanceScenarioRecord] = []
            var canvasAttachmentFilename: String?
            if canvas {
                let matching = try declared.filter { entry in
                    let payload = try attachments.readFile(relativePath: entry.filename, maximumBytes: 8 * 1_024 * 1_024)
                    guard payload.range(of: Data("notika.canvas.frame-pacing-ab.v1".utf8)) != nil else { return false }
                    let object = try performanceDocument(payload).object()
                    return object["schema"] == .string("notika.canvas.frame-pacing-ab.v1")
                }
                guard matching.count == 1, matching[0].testIdentifier == NotikaPerformanceReports.canvasTestIdentifier else {
                    throw performanceFailure("expected one correctly identified canvas matrix attachment")
                }
                let entry = matching[0], raw = try attachments.readFile(relativePath: entry.filename, maximumBytes: 8 * 1_024 * 1_024)
                canvasAttachmentFilename = entry.filename
                let derived = try NotikaPerformanceReports.canvasSummary(raw: raw, sessionID: runID, sourceHash: sourceHash, sourceHead: sourceHead)
                try writeReservedReport(raw)
                try publishFile("summary.json", data: derived)
                scenarios.append(.init(label: "canvas-frame-pacing-matrix", testIdentifier: entry.testIdentifier,
                    rawPath: "report.json", rawBytes: Int64(raw.count), rawSHA256: CanonicalJSONDigest.digest(raw),
                    summaryPath: "summary.json", summaryBytes: Int64(derived.count), summarySHA256: CanonicalJSONDigest.digest(derived)))
            } else {
                guard declared.count == 2 else { throw performanceFailure("expected exactly two text scenario attachments") }
                var byLabel: [String: (PerformanceAttachmentEntry, Data)] = [:]
                for entry in declared {
                    let raw = try attachments.readFile(relativePath: entry.filename, maximumBytes: 8 * 1_024 * 1_024)
                    let object = try performanceDocument(raw).object()
                    guard case .string(let label) = object["profileLabel"], let index = NotikaPerformanceReports.textLabels.firstIndex(of: label),
                          entry.testIdentifier == NotikaPerformanceReports.textTestIdentifiers[index], byLabel[label] == nil else {
                        throw performanceFailure("unknown, duplicate, or misidentified text attachment")
                    }
                    byLabel[label] = (entry, raw)
                }
                for label in NotikaPerformanceReports.textLabels {
                    guard let (entry, raw) = byLabel[label] else { throw performanceFailure("missing text scenario attachment") }
                    let derived = try NotikaPerformanceReports.textSummary(raw: raw, label: label, sourceHash: sourceHash, sourceHead: sourceHead)
                    let filename = "summary-" + label + ".json"
                    try publishFile(filename, data: derived)
                    scenarios.append(.init(label: label, testIdentifier: entry.testIdentifier, rawPath: "attachments/" + entry.filename,
                        rawBytes: Int64(raw.count), rawSHA256: CanonicalJSONDigest.digest(raw), summaryPath: filename,
                        summaryBytes: Int64(derived.count), summarySHA256: CanonicalJSONDigest.digest(derived)))
                }
            }
            try attachments.revalidate(); try revalidate(); try summary.revalidateForPublication(); try exported.revalidateForPublication()
            let value = NotikaPerformanceEvidenceRecord(namespace: "agentbuild.notika-performance", schemaVersion: 1,
                interpreter: "agentbuild.notika-performance.v1", toolchainBeforeHash: toolchainHash,
                route: request.makeRoute!.rawValue, sessionID: runID, sourceBeforeHash: sourceHash, sourceHead: sourceHead,
                configurationIdentity: canvas ? NotikaPerformanceReports.canvasConfiguration : NotikaPerformanceReports.textConfiguration,
                leaseSessionID: leaseSessionID, evidenceDirectory: evidenceDirectory, resultReceiptSHA256: summary.resultBundle.receiptSHA256,
                exportCommand: .init(executable: command.executable, arguments: command.arguments, workingDirectory: command.workingDirectory,
                    standardOutputSHA256: exported.rawCapture.standardOutput.sha256, standardErrorSHA256: exported.rawCapture.standardError.sha256,
                    nativeTermination: exported.observation.termination!), scenarios: scenarios,
                reservedReportDevice: reportIdentity?.device, reservedReportInode: reportIdentity?.inode)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let manifest = try encoder.encode(value); try publishFile("run-manifest.json", data: manifest)
            let admitted = try NotikaResultBundleTree(parent: sessionDescriptor, name: rootName, maximumBytes: 64 * 1_024 * 1_024,
                maximumEntries: 300, privatePermissions: true, requiredFilePermissions: 0o400, requiredRootFile: "run-manifest.json")
            let expectedPaths = Set([".", "attachments", "attachments/manifest.json", "run-manifest.json"]
                + declared.map { "attachments/" + $0.filename } + scenarios.map(\.summaryPath) + (canvas ? ["report.json"] : []))
            guard Set(admitted.records.map(\.path)) == expectedPaths else { throw performanceFailure("undeclared performance evidence artifact") }
            for scenario in scenarios {
                let raw = try admitted.readFile(relativePath: scenario.rawPath, maximumBytes: 8 * 1_024 * 1_024)
                let stored = try admitted.readFile(relativePath: scenario.summaryPath, maximumBytes: 8 * 1_024 * 1_024)
                let reproduced = try canvas
                    ? NotikaPerformanceReports.canvasSummary(raw: raw, sessionID: runID, sourceHash: sourceHash, sourceHead: sourceHead)
                    : NotikaPerformanceReports.textSummary(raw: raw, label: scenario.label, sourceHash: sourceHash, sourceHead: sourceHead)
                guard try NotikaPerformanceReports.summariesAgree(stored, reproduced) else { throw performanceFailure("summary reproduction differs") }
                if canvas {
                    guard let canvasAttachmentFilename else { throw performanceFailure("missing retained canvas attachment") }
                    let original = try admitted.readFile(relativePath: "attachments/" + canvasAttachmentFilename,
                        maximumBytes: 8 * 1_024 * 1_024)
                    guard raw == original else { throw performanceFailure("reserved canvas report differs from exported attachment") }
                }
            }
            try revalidate(); try summary.revalidateForPublication(); try exported.revalidateForPublication(); try admitted.revalidate()
            tree = admitted; record = value; manifestHash = CanonicalJSONDigest.digest(manifest)
        } catch let failure as NotikaPerformanceFailure { failures.append(failure) }
        catch { failures.append(performanceFailure("performance evidence admission failed", detail: String(describing: error))) }
        return NotikaPerformanceEvidence(reservation: self, summary: summary, record: record, tree: tree,
            manifestSHA256: manifestHash, exportCapture: capture, failures: failures, fixtureAdmission: allowsTrustedShellFixture)
    }

    internal func revalidate() throws {
        try retainedSession.revalidate(); try rootWatch.check()
        let descriptor = try resultDescriptorIdentity(rootDescriptor), named = try resultEntryIdentity(sessionDescriptor, rootName)
        guard descriptor.sameDirectoryBinding(rootIdentity), named.sameDirectoryBinding(rootIdentity) else {
            throw performanceFailure("performance root binding changed")
        }
        if let reservedReport, let reportIdentity {
            let status = try resultDescriptorIdentity(reservedReport), entry = try resultEntryIdentity(rootDescriptor, "report.json")
            guard status.regular, status.device == reportIdentity.device, status.inode == reportIdentity.inode,
                  status.owner == reportIdentity.owner, status.links == 1, status == entry,
                  [UInt16(0o600), UInt16(0o400)].contains(status.mode & 0o7777) else { throw performanceFailure("canvas report reservation changed") }
        }
        try rootWatch.check()
    }

    private func claimConsumption() throws {
        lock.lock(); defer { lock.unlock() }
        guard !consumed else { throw performanceFailure("performance reservation already consumed") }; consumed = true
    }
    private func requireAbsent(_ name: String) throws {
        var metadata = stat()
        guard fstatat(rootDescriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
            throw performanceFailure("performance output already exists", detail: name)
        }
    }
    private func publishFile(_ name: String, data: Data) throws {
        try revalidate(); try requireAbsent(name)
        let descriptor = openat(rootDescriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 3 else { throw performanceFailure("create performance file", detail: String(errno)) }
        defer { _ = Darwin.close(descriptor) }
        try performanceWrite(descriptor, data: data)
        guard fsync(descriptor) == 0, fchmod(descriptor, 0o400) == 0,
              try resultDescriptorIdentity(descriptor) == resultEntryIdentity(rootDescriptor, name), fsync(rootDescriptor) == 0 else {
            throw performanceFailure("seal performance file", detail: String(errno))
        }
        try revalidate()
    }
    private func writeReservedReport(_ data: Data) throws {
        try revalidate()
        guard let reservedReport, let reportIdentity,
              try resultDescriptorIdentity(reservedReport) == reportIdentity else { throw performanceFailure("canvas reservation already written") }
        try performanceWrite(reservedReport, data: data)
        guard fsync(reservedReport) == 0, fchmod(reservedReport, 0o400) == 0, fsync(rootDescriptor) == 0 else {
            throw performanceFailure("seal reserved canvas report", detail: String(errno))
        }
        try revalidate()
    }
}

private struct PerformanceAttachmentEntry {
    let testIdentifier: String
    let filename: String
}

private func attachmentEntries(_ data: Data) throws -> [PerformanceAttachmentEntry] {
    let root = try performanceDocument(data).array()
    var entries: [PerformanceAttachmentEntry] = [], names = Set<String>()
    for test in root {
        let object = try test.object()
        guard let identifierValue = object["testIdentifier"], let attachmentsValue = object["attachments"] else {
            throw performanceFailure("invalid performance attachment manifest")
        }
        let identifier = try identifierValue.string()
        for attachment in try attachmentsValue.array() {
            let attachment = try attachment.object()
            guard let value = attachment["exportedFileName"] else { throw performanceFailure("attachment missing exported name") }
            let name = try value.string()
            guard !name.contains("/"), !name.contains("\0"), name != ".", name != "..", name != "manifest.json",
                  name.utf8.count <= 255, names.insert(name).inserted else { throw performanceFailure("invalid or duplicate attachment name") }
            entries.append(.init(testIdentifier: identifier, filename: name))
        }
    }
    return entries
}

private func performanceHex(_ value: String, length: Int) -> Bool {
    value.utf8.count == length && value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
}
private func performanceEncoded<T: Encodable>(_ value: T) throws -> CanonicalJSONValue {
    try performanceCanonical(StrictJSONDocument(data: JSONEncoder().encode(value)).root)
}
private func performanceCanonical(_ value: StrictJSONValue) throws -> CanonicalJSONValue {
    switch value {
    case .array(let values): .array(try values.map(performanceCanonical))
    case .bool(let value): .bool(value)
    case .null: .null
    case .number(let value):
        if let signed = try? value.int64() { .integer(signed) } else { .unsignedInteger(try value.uint64()) }
    case .object(let value): .object(try value.members.map { .init(key: $0.key, value: try performanceCanonical($0.value)) })
    case .string(let value): .string(value)
    }
}
private func performanceObservation(_ value: NotikaNativeObservation) throws -> CanonicalJSONValue {
    .object(["processIdentifier": value.processIdentifier.map { .integer(Int64($0)) } ?? .null,
        "termination": try value.termination.map(performanceEncoded) ?? .null, "retirement": .string(value.retirement.rawValue),
        "cancelled": .bool(value.cancelled), "failures": try performanceEncoded(value.failures),
        "worker": try value.worker.map(performanceEncoded) ?? .null, "helperTermination": try value.helperTermination.map(performanceEncoded) ?? .null])
}
private func performanceString(_ object: StrictJSONObject, _ name: String) throws -> String {
    guard case .string(let value) = try object.requiredValue(forKey: name) else { throw performanceFailure("invalid performance string", detail: name) }
    return value
}
private func performanceNumber(_ value: Int64) throws -> StrictJSONNumber {
    guard case .number(let number) = try StrictJSONDocument(data: Data(String(value).utf8)).root else { throw performanceFailure("invalid integer") }
    return number
}
private func performanceValidateCapture(_ capture: StrictJSONObject, sessionPath: String,
    expectedResultIdentity: NativeWorkingDirectoryIdentity?, fixtureAdmission: Bool
) throws -> Bool {
    _ = try capture.project(requiredKeys: ["executable", "arguments", "workingDirectory", "argumentSHA256", "workingDirectoryIdentity", "observation", "rawCapture"])
    guard try performanceString(capture, "workingDirectory").utf8.elementsEqual((sessionPath + "/result.xcresult").utf8) else {
        throw performanceFailure("performance export working directory differs")
    }
    let executable = try performanceString(capture, "executable")
    guard executable == "/usr/bin/xcrun" || fixtureAdmission && executable == "/bin/sh" else { throw performanceFailure("invalid performance export executable") }
    guard case .array(let values) = try capture.requiredValue(forKey: "arguments") else { throw performanceFailure("invalid export arguments") }
    let arguments = try values.map { value -> String in
        guard case .string(let argument) = value else { throw performanceFailure("invalid export argument") }; return argument
    }
    guard try performanceString(capture, "argumentSHA256") == ArgumentCommitment.digest(arguments: arguments) else {
        throw performanceFailure("performance argument digest differs")
    }
    var passed = true
    let pin = try capture.requiredValue(forKey: "workingDirectoryIdentity")
    if pin == .null { passed = false }
    else {
        let fields = try pin.requireObject().project(requiredKeys: ["device", "inode", "owner", "mode"])
        let identity = try JSONDecoder().decode(NativeWorkingDirectoryIdentity.self,
            from: CanonicalJSONDigest.encode(performanceCanonical(.object(fields))))
        guard identity.owner == UInt32(geteuid()), identity.mode & UInt16(S_IFMT) == UInt16(S_IFDIR), identity.mode & 0o7022 == 0 else {
            throw performanceFailure("unsafe performance result identity")
        }
        if let expectedResultIdentity {
            guard identity == expectedResultIdentity else { throw performanceFailure("performance result directory binding differs") }
        } else { passed = false }
    }
    let observation = try capture.requiredValue(forKey: "observation").requireObject().project(requiredKeys:
        ["processIdentifier", "termination", "retirement", "cancelled", "failures", "worker", "helperTermination"])
    let retirement = try performanceString(observation, "retirement")
    guard NotikaNativeRetirementEvidence(rawValue: retirement) != nil,
          case .bool(let cancelled) = observation.value(forKey: "cancelled") else { throw performanceFailure("invalid performance process observation") }
    let observationFailures = try performanceWorkloadFailures(observation.requiredValue(forKey: "failures"))
    var observedProcessIdentifier: Int32?
    if let pid = observation.value(forKey: "processIdentifier"), pid != .null {
        guard case .number(let value) = pid, try value.int64() > 0, try value.int64() <= Int32.max else { throw performanceFailure("invalid performance process identifier") }
        observedProcessIdentifier = Int32(try value.int64())
    } else { passed = false }
    let nativePassed = try performanceZero(observation.requiredValue(forKey: "termination"))
    let helperPassed = try performanceZero(observation.requiredValue(forKey: "helperTermination"))
    passed = passed && nativePassed && helperPassed && retirement == "workerReaped" && !cancelled && observationFailures.isEmpty
    let workerValue = try observation.requiredValue(forKey: "worker")
    if workerValue == .null { passed = false }
    else {
        let worker = try workerValue.requireObject().project(requiredKeys: ["retirement", "failures"],
            optionalKeys: ["processIdentifier", "termination", "stopReason"])
        let decoded = try JSONDecoder().decode(DarwinWorkloadResult.self, from: CanonicalJSONDigest.encode(performanceCanonical(.object(worker))))
        _ = try performanceWorkloadFailures(worker.requiredValue(forKey: "failures"))
        if let processIdentifier = decoded.processIdentifier {
            guard processIdentifier > 0, processIdentifier == observedProcessIdentifier else {
                throw performanceFailure("performance worker process binding differs")
            }
        } else { passed = false }
        passed = passed && decoded.termination == RunTermination(kind: .exit, value: 0) && decoded.retirement == .reaped
            && decoded.stopReason == nil && decoded.failures.isEmpty
    }
    let rawValue = try capture.requiredValue(forKey: "rawCapture")
    let raw = try rawValue.requireObject().project(requiredKeys: ["standardOutput", "standardError", "maximumBytes", "captureComplete", "failures"])
    guard case .number(let maximumToken) = raw.value(forKey: "maximumBytes"), case .bool(let complete) = raw.value(forKey: "captureComplete"),
          case .array(let rawFailures) = raw.value(forKey: "failures") else { throw performanceFailure("invalid raw export fields") }
    let maximum = try maximumToken.int64()
    guard (0...(64 * 1_024 * 1_024)).contains(maximum) else { throw performanceFailure("invalid export raw byte limit") }
    for value in rawFailures {
        let failure = try value.requireObject().project(requiredKeys: ["operation"], optionalKeys: ["code", "stream", "detail"])
        let decoded = try JSONDecoder().decode(NativeLogCaptureFailure.self, from: CanonicalJSONDigest.encode(performanceCanonical(.object(failure))))
        guard !decoded.operation.isEmpty else { throw performanceFailure("empty raw export failure") }
    }
    var total: Int64 = 0, streamRoot: String?
    for (name, leaf) in [("standardOutput", "stdout.log"), ("standardError", "stderr.log")] {
        let stream = try raw.requiredValue(forKey: name).requireObject().project(requiredKeys: ["path", "observedBytes", "retainedBytes", "sha256", "reachedEOF"])
        guard case .number(let observedToken) = stream.value(forKey: "observedBytes"),
              case .number(let retainedToken) = stream.value(forKey: "retainedBytes"),
              case .bool(let reachedEOF) = stream.value(forKey: "reachedEOF") else { throw performanceFailure("invalid export raw accounting") }
        let observed = try observedToken.int64(), retained = try retainedToken.int64()
        let addition = total.addingReportingOverflow(retained)
        guard retained >= 0, observed >= retained, !addition.overflow, addition.partialValue <= maximum,
              performanceHex(try performanceString(stream, "sha256"), length: 64) else { throw performanceFailure("invalid export raw accounting") }
        let path = try performanceString(stream, "path")
        guard path.utf8.starts(with: (sessionPath + "/").utf8) else { throw performanceFailure("export raw path outside session") }
        let relative = String(decoding: path.utf8.dropFirst((sessionPath + "/").utf8.count), as: UTF8.self)
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, UUID(uuidString: String(components[0])) != nil, components[1] == Substring(leaf),
              streamRoot == nil || streamRoot == String(components[0]) else { throw performanceFailure("invalid export raw path") }
        streamRoot = String(components[0]); total = addition.partialValue
        passed = passed && observed == retained && reachedEOF
    }
    return passed && complete && rawFailures.isEmpty
}
private func performanceWorkloadFailures(_ value: StrictJSONValue) throws -> [DarwinWorkloadFailure] {
    guard case .array(let values) = value else { throw performanceFailure("invalid process failure list") }
    return try values.map { value in
        let object = try value.requireObject().project(requiredKeys: ["operation"], optionalKeys: ["code", "detail"])
        let result = try JSONDecoder().decode(DarwinWorkloadFailure.self, from: CanonicalJSONDigest.encode(performanceCanonical(.object(object))))
        guard !result.operation.isEmpty else { throw performanceFailure("empty process failure") }; return result
    }
}
private func performanceZero(_ value: StrictJSONValue) throws -> Bool {
    if value == .null { return false }
    let object = try value.requireObject().project(requiredKeys: ["kind", "value"])
    let termination = try JSONDecoder().decode(RunTermination.self, from: CanonicalJSONDigest.encode(performanceCanonical(.object(object))))
    return termination == RunTermination(kind: .exit, value: 0)
}
private func performanceWrite(_ descriptor: Int32, data: Data) throws {
    var offset = 0
    while offset < data.count {
        let count = data.withUnsafeBytes { pwrite(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset, off_t(offset)) }
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw performanceFailure("write performance output", detail: String(errno)) }
        offset += count
    }
}

/// Normalize only the exported, bounded no-follow tree. Each original entry and
/// descriptor is checked before and after permission changes; symlinks, hard
/// links, foreign ownership, writable peers and hidden inventory are refused.
private func sealPerformanceTree(parent: Int32, name: String, maximumEntries: Int, maximumBytes: Int64) throws {
    var entries = 0, bytes: Int64 = 0
    func seal(_ parent: Int32, _ name: String, depth: Int) throws {
        guard depth <= 8, entries < maximumEntries else { throw performanceFailure("attachment tree entry limit") }
        entries += 1
        let original = try resultEntryIdentity(parent, name)
        guard original.safe else { throw performanceFailure("unsafe exported attachment") }
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (original.directory ? O_DIRECTORY : 0))
        guard descriptor >= 3 else { throw performanceFailure("open exported attachment", detail: String(errno)) }
        defer { _ = Darwin.close(descriptor) }
        guard try resultDescriptorIdentity(descriptor) == original else { throw performanceFailure("exported attachment changed") }
        if original.directory {
            let copy = fcntl(descriptor, F_DUPFD_CLOEXEC, 3)
            guard copy >= 3 else { throw performanceFailure("duplicate attachment directory") }
            guard let stream = fdopendir(copy) else { _ = Darwin.close(copy); throw performanceFailure("enumerate attachment directory") }
            defer { _ = closedir(stream) }; rewinddir(stream)
            while true {
                errno = 0
                guard let entry = readdir(stream) else { guard errno == 0 else { throw performanceFailure("read attachment directory") }; break }
                let child = withUnsafePointer(to: entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(validatingCString: $0) }
                }
                guard let child else { throw performanceFailure("invalid attachment filename") }
                if child == "." || child == ".." { continue }
                try seal(descriptor, child, depth: depth + 1)
            }
            let current = try resultDescriptorIdentity(descriptor)
            guard current.sameDirectoryBinding(original), current.sameDirectoryBinding(try resultEntryIdentity(parent, name)) else {
                throw performanceFailure("attachment directory changed during seal")
            }
        } else {
            let total = bytes.addingReportingOverflow(original.size)
            guard original.size >= 0, !total.overflow, total.partialValue <= maximumBytes else { throw performanceFailure("attachment byte limit") }
            bytes = total.partialValue
            guard try resultDescriptorIdentity(descriptor) == original, try resultEntryIdentity(parent, name) == original else {
                throw performanceFailure("attachment file changed during seal")
            }
        }
        guard fchmod(descriptor, original.directory ? 0o700 : 0o400) == 0, fsync(descriptor) == 0,
              try resultDescriptorIdentity(descriptor) == resultEntryIdentity(parent, name) else { throw performanceFailure("seal exported attachment") }
    }
    try seal(parent, name, depth: 0)
}
