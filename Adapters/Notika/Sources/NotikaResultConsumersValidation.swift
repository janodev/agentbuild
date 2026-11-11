import AgentBuildCore
import AgentLeaseCore
import Darwin
import Foundation

extension NotikaResultConsumerEvidence {
    /// Validates descriptor-free metadata, not filesystem authority. A caller
    /// publishing a successful session must also retain and revalidate the
    /// corresponding live consumer, summary, and result objects.
    public static func validateCanonicalValue(
        _ value: CanonicalJSONValue, request: NotikaActionRequest, resultReceiptSHA256: String,
        sessionPath: String, expectedResultIdentity: NativeWorkingDirectoryIdentity? = nil,
        allowFixtureAdmission: Bool = false
    ) throws -> Bool {
        try validateCanonicalValue(value, request: request, resultReceiptSHA256: resultReceiptSHA256,
            sessionPath: sessionPath, expectedResultIdentity: expectedResultIdentity,
            allowFixtureAdmission: allowFixtureAdmission, captureAdmissionPolicy: .current)
    }

    internal static func validateCanonicalValue(
        _ value: CanonicalJSONValue, request: NotikaActionRequest, resultReceiptSHA256: String,
        sessionPath: String, expectedResultIdentity: NativeWorkingDirectoryIdentity? = nil,
        allowFixtureAdmission: Bool = false, captureAdmissionPolicy: NativeCaptureAdmissionPolicy
    ) throws -> Bool {
        let document = try StrictJSONDocument(data: CanonicalJSONDigest.encode(value))
        let root = try document.root.requireObject().project(requiredKeys: [
            "schemaVersion", "kind", "route", "resultReceiptSHA256", "successfulConsumption",
            "fixtureAdmission", "captures", "reports", "failures",
        ])
        guard try consumerReadInteger(root, "schemaVersion") == 1,
              try consumerReadString(root, "kind") == "notika.result-consumers",
              try consumerReadString(root, "route") == (request.makeRoute?.canonicalRoute.rawValue ?? "direct-test"),
              try consumerReadString(root, "resultReceiptSHA256").utf8.elementsEqual(resultReceiptSHA256.utf8),
              consumerSHA(resultReceiptSHA256) else { throw consumerInvalid("consumer binding") }
        let fixture = try consumerReadBool(root, "fixtureAdmission")
        guard !fixture || allowFixtureAdmission else { throw consumerInvalid("fixture consumer admission") }
        let successful = try consumerReadBool(root, "successfulConsumption")
        let failures = try consumerReadArray(root, "failures")
        for failure in failures {
            let fields = try failure.requireObject().project(requiredKeys: ["operation"], optionalKeys: ["code", "detail"])
            _ = try consumerReadString(fields, "operation")
            if let code = fields.value(forKey: "code") { _ = try consumerReadNumber(code).int64() }
            if let detail = fields.value(forKey: "detail"), case .string = detail {} else if fields.value(forKey: "detail") != nil {
                throw consumerInvalid("failure detail")
            }
        }
        let captures = try consumerReadArray(root, "captures")
        guard captures.count <= 8 else { throw consumerInvalid("consumer capture count") }
        var roles: [String] = []
        var capturesPassed = true
        var sawDiagnostic = false
        for value in captures {
            let capture = try value.requireObject().project(requiredKeys: [
                "role", "diagnostic", "executable", "arguments", "workingDirectory", "argumentSHA256",
                "workingDirectoryIdentity", "observation", "rawCapture",
            ])
            let role = try consumerReadString(capture, "role")
            let diagnostic = try consumerReadBool(capture, "diagnostic")
            let arguments = try consumerReadArray(capture, "arguments").map { value -> String in
                guard case .string(let string) = value else { throw consumerInvalid("consumer argument") }
                return string
            }
            guard try consumerReadString(capture, "argumentSHA256") == ArgumentCommitment.digest(arguments: arguments) else {
                throw consumerInvalid("consumer argument commitment")
            }
            let executable = try consumerReadString(capture, "executable")
            let cwd = try consumerReadString(capture, "workingDirectory")
            let html = role == "coverage-html"
            guard cwd.utf8.elementsEqual((html ? sessionPath : sessionPath + "/result.xcresult").utf8) else {
                throw consumerInvalid("consumer working directory")
            }
            if diagnostic {
                guard !sawDiagnostic, role == "coverage-file-list",
                      [.coverageFile, .coverageFileUnit].contains(request.makeRoute?.canonicalRoute ?? .build),
                      roles.last == "coverage-file" else { throw consumerInvalid("consumer diagnostic role") }
                sawDiagnostic = true
            } else { roles.append(role) }
            let expected = try consumerExpectedArguments(role: role, request: request)
            if !fixture {
                guard (html ? executable.hasPrefix("/") && URL(fileURLWithPath: executable).lastPathComponent == "genhtml"
                            : executable == "/usr/bin/xcrun"),
                      arguments.map({ Data($0.utf8) }) == expected.map({ Data($0.utf8) }) else {
                    throw consumerInvalid("consumer native command")
                }
            } else if executable != "/bin/sh" {
                throw consumerInvalid("fixture consumer command")
            }
            let pin = try capture.requiredValue(forKey: "workingDirectoryIdentity")
            if case .null = pin {
                capturesPassed = false
            } else {
                let identity = try pin.requireObject().project(requiredKeys: ["device", "inode", "owner", "mode"])
                let device = try consumerReadInteger(identity, "device")
                let inode = try consumerReadNumber(identity.requiredValue(forKey: "inode")).uint64()
                let owner = try consumerReadInteger(identity, "owner"), mode = try consumerReadInteger(identity, "mode")
                guard owner == Int64(geteuid()), mode & Int64(S_IFMT) == Int64(S_IFDIR) else {
                    throw consumerInvalid("consumer directory identity")
                }
                if !html {
                    if let expectedResultIdentity {
                        guard device == expectedResultIdentity.device, inode == expectedResultIdentity.inode,
                              owner == Int64(expectedResultIdentity.owner), mode == Int64(expectedResultIdentity.mode) else {
                            throw consumerInvalid("consumer result directory binding")
                        }
                    } else { capturesPassed = false }
                }
            }
            let observed = try capture.requiredValue(forKey: "observation").requireObject().project(requiredKeys: [
                "processIdentifier", "termination", "retirement", "cancelled", "failures", "worker", "helperTermination",
            ])
            let nativePassed = try consumerZero(observed.requiredValue(forKey: "termination"))
                && consumerReadString(observed, "retirement") == "workerReaped"
                && !consumerReadBool(observed, "cancelled") && consumerReadArray(observed, "failures").isEmpty
                && consumerZero(observed.requiredValue(forKey: "helperTermination"))
            if let worker = try? observed.requiredValue(forKey: "worker").requireObject() {
                _ = try worker.project(requiredKeys: ["retirement", "failures"],
                                       optionalKeys: ["processIdentifier", "termination", "stopReason"])
                let workerPassed = try consumerZero(worker.value(forKey: "termination") ?? .null)
                    && consumerReadString(worker, "retirement") == "reaped"
                    && consumerReadArray(worker, "failures").isEmpty && worker.value(forKey: "stopReason") == nil
                if !diagnostic { capturesPassed = capturesPassed && workerPassed }
            } else if !diagnostic { capturesPassed = false }
            let raw = try admitNativeLogCaptureRecord(capture.requiredValue(forKey: "rawCapture"),
                sessionPath: sessionPath, policy: captureAdmissionPolicy)
            if !diagnostic { capturesPassed = capturesPassed && nativePassed && raw.captureComplete }
        }
        let reports = try consumerReadArray(root, "reports")
        guard reports.count <= 4 else { throw consumerInvalid("consumer report count") }
        var names: [String] = []
        for value in reports {
            let report = try value.requireObject().project(requiredKeys: [
                "name", "path", "kind", "device", "inode", "owner", "mode", "bytes", "sha256", "entries",
            ])
            let name = try consumerReadString(report, "name")
            let html = name == "coverage-html"
            guard NotikaResultConsumers.requiredReportNames(request: request).contains(name),
                  !names.contains(name), try consumerReadString(report, "path") == sessionPath + "/" + name,
                  try consumerReadString(report, "kind") == (html ? "directory" : "file"),
                  try consumerReadInteger(report, "owner") == Int64(geteuid()),
                  try consumerReadInteger(report, "mode") & 0o7777 == (html ? 0o700 : 0o600),
                  consumerSHA(try consumerReadString(report, "sha256")),
                  (0...(64 * 1_024 * 1_024)).contains(try consumerReadInteger(report, "bytes")) else {
                throw consumerInvalid("consumer report identity")
            }
            _ = try consumerReadInteger(report, "device")
            _ = try consumerReadNumber(report.requiredValue(forKey: "inode")).uint64()
            let entries = try consumerReadArray(report, "entries")
            if html { try consumerValidateHTMLRecords(entries, report: report) }
            else if !entries.isEmpty { throw consumerInvalid("flat report tree") }
            names.append(name)
        }
        let complete = failures.isEmpty && capturesPassed
            && expectedResultIdentity != nil
            && roles == NotikaResultConsumers.requiredCaptureRoles(request: request)
            && names.sorted() == NotikaResultConsumers.requiredReportNames(request: request).sorted()
            && ![.testTextInputHeavyDependencyPerformance, .testCanvasFramePacingPerformance]
                .contains(request.makeRoute?.canonicalRoute ?? .build)
        guard !successful || complete else { throw consumerInvalid("consumer successful proof") }
        return successful && complete
    }
}

private func consumerExpectedArguments(role: String, request: NotikaActionRequest) throws -> [String] {
    switch role {
    case "coverage-targets": ["xccov", "view", "--report", "--only-targets", "."]
    case "coverage-detailed": ["xccov", "view", "--report", "."]
    case "coverage-json": ["xccov", "view", "--report", "--json", "."]
    case "coverage-file": ["xccov", "view", "--file", request.testFile, "."]
    case "coverage-file-list": ["xccov", "view", "--file-list", "."]
    case "coverage-html": ["coverage.lcov", "--output-directory", "coverage-html"]
    default: throw consumerInvalid("consumer role")
    }
}

private func consumerValidateHTMLRecords(_ values: [StrictJSONValue], report: StrictJSONObject) throws {
    guard !values.isEmpty, values.count <= 1_024 else { throw consumerInvalid("HTML inventory count") }
    var paths = Set<String>()
    var total: Int64 = 0
    var hasIndex = false
    for value in values {
        let entry = try value.requireObject().project(requiredKeys: ["path", "type", "device", "inode", "mode", "owner", "bytes", "sha256"])
        let path = try consumerReadString(entry, "path"), type = try consumerReadString(entry, "type")
        let mode = try consumerReadInteger(entry, "mode"), bytes = try consumerReadInteger(entry, "bytes")
        guard paths.insert(path).inserted, path == "." || (!path.hasPrefix("/") && !path.hasSuffix("/")
                && !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })),
              ["directory", "file"].contains(type), try consumerReadInteger(entry, "owner") == Int64(geteuid()),
              mode & 0o7777 == (type == "directory" ? 0o700 : 0o600) || (type == "file" && mode & 0o7777 == 0o400),
              bytes >= 0 else { throw consumerInvalid("HTML inventory entry") }
        _ = try consumerReadInteger(entry, "device")
        _ = try consumerReadNumber(entry.requiredValue(forKey: "inode")).uint64()
        if type == "file" {
            guard consumerSHA(try consumerReadString(entry, "sha256")) else { throw consumerInvalid("HTML file digest") }
            let addition = total.addingReportingOverflow(bytes)
            guard !addition.overflow, addition.partialValue <= 64 * 1_024 * 1_024 else { throw consumerInvalid("HTML byte limit") }
            total = addition.partialValue
            if path == "index.html" && bytes > 0 { hasIndex = true }
        } else {
            guard bytes == 0, try entry.requiredValue(forKey: "sha256") == .null else { throw consumerInvalid("HTML directory metadata") }
        }
    }
    guard paths.contains("."), hasIndex, total == (try consumerReadInteger(report, "bytes")) else {
        throw consumerInvalid("HTML required index or accounting")
    }
}

private func consumerReadString(_ object: StrictJSONObject, _ key: String) throws -> String {
    guard case .string(let value) = try object.requiredValue(forKey: key) else { throw consumerInvalid(key) }
    return value
}
private func consumerReadBool(_ object: StrictJSONObject, _ key: String) throws -> Bool {
    guard case .bool(let value) = try object.requiredValue(forKey: key) else { throw consumerInvalid(key) }
    return value
}
private func consumerReadArray(_ object: StrictJSONObject, _ key: String) throws -> [StrictJSONValue] {
    guard case .array(let value) = try object.requiredValue(forKey: key) else { throw consumerInvalid(key) }
    return value
}
private func consumerReadNumber(_ value: StrictJSONValue) throws -> StrictJSONNumber {
    guard case .number(let number) = value else { throw consumerInvalid("integer") }
    return number
}
private func consumerReadInteger(_ object: StrictJSONObject, _ key: String) throws -> Int64 {
    try consumerReadNumber(object.requiredValue(forKey: key)).int64()
}
private func consumerZero(_ value: StrictJSONValue) throws -> Bool {
    if case .null = value { return false }
    let object = try value.requireObject().project(requiredKeys: ["kind", "value"])
    return try consumerReadString(object, "kind") == "exit" && consumerReadInteger(object, "value") == 0
}
private func consumerSHA(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}
private func consumerInvalid(_ detail: String) -> ResultBundleFailure {
    .init(operation: "invalid result consumer evidence", code: EPROTO, detail: detail)
}
