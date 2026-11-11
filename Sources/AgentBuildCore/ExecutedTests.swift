import Darwin
import Foundation

public struct ResultBundleFailure: Codable, Equatable, Error, Sendable {
    public let operation: String
    public let code: Int32?
    public let detail: String?

    public init(operation: String, code: Int32? = nil, detail: String? = nil) {
        self.operation = operation; self.code = code; self.detail = detail
    }
}

/// Counts are observations from xcresulttool, never inferred from selectors or
/// an Xcode exit code. The supported outcome requires actual executed tests.
public struct ExecutedTests: Codable, Equatable, Sendable {
    public let result: String
    public let passed: Int64
    public let failed: Int64
    public let skipped: Int64
    public let total: Int64
    public let executed: Int64

    public var provesPassingNonemptyRun: Bool {
        result == "Passed" && passed > 0 && failed == 0
    }

    /// Focused UI methods retain the Python contract: exactly one passing test
    /// and no skipped tests. Unit selector batches use the nonempty rule.
    public func satisfiesExpectedRun(focusedMethod: Bool) -> Bool {
        provesPassingNonemptyRun && (!focusedMethod || (passed == 1 && skipped == 0 && total == 1))
    }

    public static func parse(_ data: Data) throws -> Self {
        let limits = try StrictJSONLimits(maximumBytes: 1_024 * 1_024, maximumDepth: 32, maximumNodes: 65_536)
        let object = try StrictJSONDocument(data: data, limits: limits).root.requireObject()
        guard case .string(let result) = try object.requiredValue(forKey: "result"),
              ["Passed", "Failed", "Skipped", "Unknown"].contains(result) else {
            throw ResultBundleFailure(operation: "invalid xcresult status", code: EPROTO)
        }
        func count(_ name: String) throws -> Int64 {
            guard case .number(let number) = try object.requiredValue(forKey: name) else {
                throw ResultBundleFailure(operation: "invalid xcresult count", code: EPROTO, detail: name)
            }
            let value = try number.int64()
            guard value >= 0 else { throw ResultBundleFailure(operation: "negative xcresult count", code: EPROTO, detail: name) }
            return value
        }
        let passed = try count("passedTests")
        let failed = try count("failedTests")
        let skipped = try count("skippedTests")
        let total = try count("totalTestCount")
        let executed = passed.addingReportingOverflow(failed)
        let sum = executed.partialValue.addingReportingOverflow(skipped)
        guard !executed.overflow, !sum.overflow, sum.partialValue == total else {
            throw ResultBundleFailure(operation: "inconsistent xcresult counts", code: EPROTO)
        }
        return Self(result: result, passed: passed, failed: failed, skipped: skipped, total: total, executed: executed.partialValue)
    }
}

