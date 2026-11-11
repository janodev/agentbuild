import AgentBuildCore
import AgentLeaseCore
import Darwin
import Foundation

public struct NotikaResultConsumerCapture: Sendable {
    public let role: String
    public let diagnostic: Bool
    public let capture: CapturedNativePhase
}

/// The real capture and report owners outlive terminal sealing. Serialization
/// is a descriptor-free observation, never permission to consume another path.
public final class NotikaResultConsumerEvidence: @unchecked Sendable {
    public let summary: NotikaResultSummaryEvidence
    public let captures: [NotikaResultConsumerCapture]
    public let reports: [NotikaResultReportMetadata]
    public let failures: [ResultBundleFailure]
    public let fixtureAdmission: Bool
    public let consoleOutput: String?
    private let files: [NotikaResultReportFile]
    private let html: NotikaResultReportDirectory?

    internal init(summary: NotikaResultSummaryEvidence, captures: [NotikaResultConsumerCapture],
                  files: [NotikaResultReportFile], html: NotikaResultReportDirectory?,
                  directoryReport: NotikaResultReportMetadata?, failures: [ResultBundleFailure],
                  fixtureAdmission: Bool, consoleOutput: String?) {
        self.summary = summary; self.captures = captures; self.files = files; self.html = html
        reports = files.compactMap(\.metadata) + (directoryReport.map { [$0] } ?? [])
        self.failures = failures; self.fixtureAdmission = fixtureAdmission; self.consoleOutput = consoleOutput
    }

    public var provesSuccessfulConsumption: Bool {
        let request = summary.resultBundle.custody.actionRequest
        return summary.provesPassingRun && failures.isEmpty
            && reports.map(\.name).sorted() == NotikaResultConsumers.requiredReportNames(request: request).sorted()
            && captures.filter { !$0.diagnostic }.map(\.role) == NotikaResultConsumers.requiredCaptureRoles(request: request)
    }

    public func revalidateForPublication() throws {
        try summary.revalidateForPublication()
        for capture in captures { try capture.capture.revalidateForPublication() }
        for file in files { try file.revalidate() }
        try html?.revalidate()
        try summary.revalidateForPublication()
    }

    public var canonicalValue: CanonicalJSONValue {
        get throws {
            let route = summary.resultBundle.custody.actionRequest.makeRoute?.canonicalRoute.rawValue ?? "direct-test"
            return .object([
                "schemaVersion": .integer(1), "kind": .string("notika.result-consumers"), "route": .string(route),
                "resultReceiptSHA256": .string(summary.resultBundle.receiptSHA256),
                "successfulConsumption": .bool(provesSuccessfulConsumption), "fixtureAdmission": .bool(fixtureAdmission),
                "captures": .array(try captures.map { value in
                    let capture = value.capture
                    return .object([
                        "role": .string(value.role), "diagnostic": .bool(value.diagnostic),
                        "executable": .string(capture.command.executable),
                        "arguments": .array(capture.command.arguments.map(CanonicalJSONValue.string)),
                        "workingDirectory": .string(capture.command.workingDirectory),
                        "argumentSHA256": .string(ArgumentCommitment.digest(arguments: capture.command.arguments)),
                        "workingDirectoryIdentity": try capture.workingDirectoryIdentity.map(consumerEncoded) ?? .null,
                        "observation": try consumerObservation(capture.observation),
                        "rawCapture": try consumerEncoded(capture.rawCapture),
                    ])
                }),
                "reports": .array(reports.map(consumerReportValue)),
                "failures": try consumerEncoded(failures),
            ])
        }
    }
}

/// Ordinary route consumers operate only on the freshly admitted bundle.
/// Coverage lookup diagnostics stay ancillary to the requested lookup failure.
public struct NotikaResultConsumers: Sendable {
    public let summary: NotikaResultSummaryEvidence
    public init(summary: NotikaResultSummaryEvidence) { self.summary = summary }

    public static func requiredReportNames(request: NotikaActionRequest) -> [String] {
        switch request.makeRoute?.canonicalRoute {
        case .coverage, .coverageQuiet: ["coverage-summary.txt"]
        case .coverageJSON: ["coverage.json"]
        case .coverageHTML: ["coverage.json", "coverage.lcov", "coverage-html"]
        case .resultsFile: ["summary.json"]
        default: []
        }
    }

    public static func requiredCaptureRoles(request: NotikaActionRequest) -> [String] {
        switch request.makeRoute?.canonicalRoute {
        case .coverage: ["coverage-targets", "coverage-detailed"]
        case .coverageQuiet, .testUnitCoverage: ["coverage-targets"]
        case .coverageJSON: ["coverage-json"]
        case .coverageHTML: ["coverage-json", "coverage-html"]
        case .coverageFile: ["coverage-file"]
        case .coverageFileUnit: ["coverage-targets", "coverage-file"]
        default: []
        }
    }

    public func run(
        environment: [String: String], genhtmlExecutable: String? = nil,
        operation: @Sendable (DarwinWorkloadCommand, Int32) async throws -> CapturedNativePhase
    ) async -> NotikaResultConsumerEvidence {
        await run(environment: environment, genhtmlExecutable: genhtmlExecutable,
                  allowsTrustedShellFixture: false, operation: operation)
    }

    internal func runForTrustedFixture(
        environment: [String: String], genhtmlExecutable: String? = nil,
        operation: @Sendable (DarwinWorkloadCommand, Int32) async throws -> CapturedNativePhase
    ) async -> NotikaResultConsumerEvidence {
        await run(environment: environment, genhtmlExecutable: genhtmlExecutable,
                  allowsTrustedShellFixture: true, operation: operation)
    }

    private func run(
        environment: [String: String], genhtmlExecutable: String?, allowsTrustedShellFixture: Bool,
        operation: @Sendable (DarwinWorkloadCommand, Int32) async throws -> CapturedNativePhase
    ) async -> NotikaResultConsumerEvidence {
        let bundle = summary.resultBundle
        let request = bundle.custody.actionRequest
        let route = request.makeRoute?.canonicalRoute ?? .testUnit
        var captures: [NotikaResultConsumerCapture] = []
        var files: [NotikaResultReportFile] = []
        var html: NotikaResultReportDirectory?
        var directoryReport: NotikaResultReportMetadata?
        var failures: [ResultBundleFailure] = []
        var console: String?

        func consume(_ role: String, _ arguments: [String], diagnostic: Bool = false) async throws -> Data {
            try bundle.revalidateForPublication()
            let command = try DarwinWorkloadCommand(executable: "/usr/bin/xcrun", arguments: arguments,
                workingDirectory: bundle.custody.resultPath, environment: environment)
            let captured = try await operation(command, bundle.resultDirectoryDescriptor)
            captures.append(.init(role: role, diagnostic: diagnostic, capture: captured))
            try bundle.validateConsumerCapture(captured, command: command, directoryDescriptor: bundle.resultDirectoryDescriptor,
                                               allowsTrustedShellFixture: allowsTrustedShellFixture)
            return try bundle.readCapturedStandardOutput(captured, maximumBytes: 16 * 1_024 * 1_024)
        }

        do {
            try summary.revalidateForPublication()
            guard summary.provesPassingRun else {
                throw ResultBundleFailure(operation: "result consumer prerequisite did not pass", code: EPROTO)
            }
            guard ![.testTextInputHeavyDependencyPerformance, .testCanvasFramePacingPerformance].contains(route) else {
                throw ResultBundleFailure(operation: "performance requires validated performance adapter", code: ENOTSUP)
            }
            for name in Self.requiredReportNames(request: request) where name != "coverage-html" {
                files.append(try NotikaResultReportFile(bundle: bundle, name: name))
            }
            if route == .coverageHTML { html = try NotikaResultReportDirectory(bundle: bundle) }
            func write(_ name: String, _ data: Data) throws {
                guard let file = files.first(where: { $0.name == name }) else {
                    throw ResultBundleFailure(operation: "unreserved result report", code: EINVAL)
                }
                try file.write(data)
            }
            if [.coverage, .coverageQuiet, .testUnitCoverage, .coverageFileUnit].contains(route) {
                let targets = try await consume("coverage-targets", ["xccov", "view", "--report", "--only-targets", "."])
                if route == .coverageQuiet { try write("coverage-summary.txt", targets) }
                console = String(data: targets, encoding: .utf8)
            }
            if route == .coverage {
                try write("coverage-summary.txt", await consume("coverage-detailed", ["xccov", "view", "--report", "."]))
            }
            if [.coverageJSON, .coverageHTML].contains(route) {
                let json = try await consume("coverage-json", ["xccov", "view", "--report", "--json", "."])
                _ = try consumerJSON(json).requireObject()
                try write("coverage.json", json)
                if route == .coverageHTML {
                    try write("coverage.lcov", Self.convertCoverageToLCOV(json))
                    guard let genhtmlExecutable, genhtmlExecutable.hasPrefix("/"), !genhtmlExecutable.utf8.contains(0) else {
                        throw ResultBundleFailure(operation: "genhtml executable unavailable", code: ENOENT)
                    }
                    let command = try DarwinWorkloadCommand(executable: genhtmlExecutable,
                        arguments: ["coverage.lcov", "--output-directory", "coverage-html"],
                        workingDirectory: bundle.sessionDirectory, environment: environment)
                    let captured = try await operation(command, bundle.sessionDirectoryDescriptor)
                    captures.append(.init(role: "coverage-html", diagnostic: false, capture: captured))
                    try bundle.validateConsumerCapture(captured, command: command,
                        directoryDescriptor: bundle.sessionDirectoryDescriptor,
                        allowsTrustedShellFixture: allowsTrustedShellFixture)
                    directoryReport = try html?.admitAfterRetirement()
                }
            }
            if [.coverageFile, .coverageFileUnit].contains(route) {
                do {
                    let data = try await consume("coverage-file", ["xccov", "view", "--file", request.testFile, "."])
                    console = String(data: data, encoding: .utf8)
                } catch {
                    failures.append(consumerFailure(error, operation: "requested coverage file lookup"))
                    do {
                        let diagnostic = try await consume("coverage-file-list", ["xccov", "view", "--file-list", "."], diagnostic: true)
                        console = String(data: diagnostic, encoding: .utf8)?.split(separator: "\n")
                            .filter { $0.lowercased().contains("swift") }.prefix(20).joined(separator: "\n")
                    } catch {
                        // Diagnostics cannot turn a failed requested lookup into success.
                        failures.append(consumerFailure(error, operation: "coverage file-list diagnostic"))
                    }
                }
            }
            if [.resultsFile, .resultsSummary, .resultsBrief].contains(route) {
                guard let probe = summary.probe else {
                    throw ResultBundleFailure(operation: "result summary raw capture missing", code: EPROTO)
                }
                let data = try bundle.readCapturedStandardOutput(probe, maximumBytes: 1_024 * 1_024)
                if route == .resultsFile { try write("summary.json", data) }
                if route == .resultsSummary { console = String(data: data, encoding: .utf8) }
                if route == .resultsBrief, let tests = summary.tests {
                    console = "Result: \(tests.result)  │  Total: \(tests.total)  │  Passed: \(tests.passed)  │  Failed: \(tests.failed)  │  Skipped: \(tests.skipped)"
                }
            }
            try summary.revalidateForPublication()
            for file in files { try file.revalidate() }
            try html?.revalidate()
        } catch { failures.append(consumerFailure(error, operation: "consume route results")) }
        return .init(summary: summary, captures: captures, files: files, html: html, directoryReport: directoryReport,
                     failures: failures, fixtureAdmission: allowsTrustedShellFixture, consoleOutput: console)
    }

    /// Matches the reference's function-line LCOV conversion, preserving file
    /// order and repeated function lines. Invalid fields never mint coverage.
    internal static func convertCoverageToLCOV(_ data: Data) throws -> Data {
        let root = try consumerJSON(data).requireObject()
        func array(_ object: StrictJSONObject, _ key: String) throws -> [StrictJSONValue] {
            guard let value = object.value(forKey: key) else { return [] }
            guard case .array(let values) = value else { throw ResultBundleFailure(operation: "invalid coverage array", code: EPROTO) }
            return values
        }
        var output = "TN:\n"
        for target in try array(root, "targets") {
            for fileValue in try array(target.requireObject(), "files") {
                let file = try fileValue.requireObject()
                guard case .string(let path) = try file.requiredValue(forKey: "path"), !path.isEmpty,
                      !path.utf8.contains(where: { $0 < 32 || $0 == 127 }) else {
                    throw ResultBundleFailure(operation: "invalid coverage source path", code: EPROTO)
                }
                output += "SF:\(path)\n"
                for functionValue in try array(file, "functions") {
                    let function = try functionValue.requireObject()
                    guard let count = function.value(forKey: "executionCount"), count != .null else { continue }
                    guard case .number(let executions) = count,
                          case .number(let line) = try function.requiredValue(forKey: "lineNumber") else {
                        throw ResultBundleFailure(operation: "invalid coverage function count", code: EPROTO)
                    }
                    let lineNumber = try line.int64(), executionCount = try executions.int64()
                    guard lineNumber > 0, executionCount >= 0 else {
                        throw ResultBundleFailure(operation: "invalid coverage function line", code: EPROTO)
                    }
                    output += "DA:\(lineNumber),\(executionCount)\n"
                }
                output += "end_of_record\n"
                guard output.utf8.count <= 64 * 1_024 * 1_024 else {
                    throw ResultBundleFailure(operation: "coverage LCOV byte limit", code: EFBIG)
                }
            }
        }
        return Data(output.utf8)
    }
}

private func consumerReportValue(_ report: NotikaResultReportMetadata) -> CanonicalJSONValue {
    .object([
        "name": .string(report.name), "path": .string(report.path), "kind": .string(report.kind),
        "device": .integer(report.device), "inode": .unsignedInteger(report.inode),
        "owner": .integer(Int64(report.owner)), "mode": .integer(Int64(report.mode)), "bytes": .integer(report.bytes),
        "sha256": .string(report.sha256),
        "entries": .array(report.entries.map {
            .object(["path": .string($0.path), "type": .string($0.type), "device": .integer($0.device),
                     "inode": .unsignedInteger($0.inode), "mode": .integer(Int64($0.mode)), "owner": .integer(Int64($0.owner)),
                     "bytes": .integer($0.bytes), "sha256": $0.sha256.map(CanonicalJSONValue.string) ?? .null])
        }),
    ])
}

private func consumerObservation(_ value: NativeObservation) throws -> CanonicalJSONValue {
    .object(["processIdentifier": value.processIdentifier.map { .integer(Int64($0)) } ?? .null,
             "termination": try value.termination.map(consumerEncoded) ?? .null,
             "retirement": .string(value.retirement.rawValue), "cancelled": .bool(value.cancelled),
             "failures": try consumerEncoded(value.failures),
             "worker": try value.worker.map(consumerEncoded) ?? .null,
             "helperTermination": try value.helperTermination.map(consumerEncoded) ?? .null])
}

private func consumerEncoded<T: Encodable>(_ value: T) throws -> CanonicalJSONValue {
    try consumerCanonical(consumerJSON(JSONEncoder().encode(value)))
}

private func consumerJSON(_ data: Data) throws -> StrictJSONValue {
    // Consumer stdout is bounded by raw capture; structured reports also have
    // a tighter parser budget instead of accepting an unbounded JSON tree.
    try StrictJSONDocument(data: data, limits: StrictJSONLimits(maximumBytes: 16 * 1_024 * 1_024,
                                                               maximumDepth: 64, maximumNodes: 1_000_000)).root
}

private func consumerCanonical(_ value: StrictJSONValue) throws -> CanonicalJSONValue {
    switch value {
    case .array(let values): .array(try values.map(consumerCanonical))
    case .bool(let value): .bool(value)
    case .null: .null
    case .number(let value):
        if let signed = try? value.int64() { .integer(signed) }
        else { .unsignedInteger(try value.uint64()) }
    case .object(let object):
        .object(try object.members.map { .init(key: $0.key, value: try consumerCanonical($0.value)) })
    case .string(let value): .string(value)
    }
}

private func consumerFailure(_ error: any Error, operation: String) -> ResultBundleFailure {
    error as? ResultBundleFailure ?? .init(operation: operation, detail: String(describing: error))
}
