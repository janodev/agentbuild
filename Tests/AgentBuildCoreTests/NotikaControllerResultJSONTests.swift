@testable import AgentBuildCore
import AgentLeaseCore
import Darwin
import Foundation
import Testing

@Suite("Notika controller maintenance JSON")
struct NotikaControllerResultJSONTests {
    @Test(arguments: ["preflight", "generation", "rust", "documentation"])
    func fractionalMaintenanceDatesCannotReplaceNativeOutcomes(_ family: String) throws {
        // This fractional Foundation reference time reproduced the live CLI
        // failure after the native preflight was cancelled and fully retired.
        let evaluated = Date(timeIntervalSinceReferenceDate: 813_353_626.317627)
        let maintenance = controllerMaintenanceFixture(evaluatedAt: evaluated)
        #expect(evaluated.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) != 0)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let expectedMaintenance = try StrictJSONDocument(data: encoder.encode(maintenance))
        let expectedDate = try StrictJSONDocument(data: encoder.encode(evaluated)).root

        for interrupted in [false, true] {
            let native = RunTermination(kind: interrupted ? .signal : .exit, value: interrupted ? SIGTERM : 0)
            let data = try controllerResultFixture(family: family, native: native, cancelled: interrupted, maintenance: maintenance)
            let root = try StrictJSONDocument(data: data).root.requireObject()
            #expect(try controllerString(root, "status") == (interrupted ? "failed" : "inconclusive"))
            #expect(try controllerInteger(root, "exitCode") == (interrupted ? 143 : 70))
            #expect(try controllerBool(root, "cancelled") == interrupted)
            let nativeKey = family == "documentation" ? "buildNativeTermination" : "nativeTermination"
            #expect(try controllerTermination(root.requiredValue(forKey: nativeKey)) == native)
            #expect(try controllerStrings(root, "orchestrationFailures", maximum: 128) == ["observation diagnostic"])
            #expect(try controllerStrings(root, "maintenanceFailures", maximum: 128) == ["maintenance diagnostic"])
            let observed = try root.requiredValue(forKey: "maintenanceReport")
            #expect(observed == expectedMaintenance.root)
            let domains = try observed.requireObject()
            for domain in ["caches", "sessions", "rustCaches"] {
                let report = try domains.requiredValue(forKey: domain).requireObject()
                #expect(try report.requiredValue(forKey: "evaluatedAt") == expectedDate)
                #expect(try report.requiredValue(forKey: "localDayCutoff") != .null)
            }
            let sessions = try domains.requiredValue(forKey: "sessions").requireObject()
            let entries = try controllerArray(sessions, "entries", maximum: 128)
            let retained = try #require(entries.first)
            let expiry = try retained.requireObject().requiredValue(forKey: "effectiveExpiresAt")
            #expect(try expiry == StrictJSONDocument(data: encoder.encode(evaluated.addingTimeInterval(60))).root)
        }
    }
}

private func controllerMaintenanceFixture(evaluatedAt: Date) -> NotikaArtifactMaintenanceReport {
    let cutoff = Date(timeIntervalSince1970: 1_791_590_400)
    let caches = NotikaCacheRetentionReport(policy: .todayOnlyCaches, execute: true, evaluatedAt: evaluatedAt,
        localDayCutoff: cutoff, timeZoneIdentifier: "UTC", rootState: .ready, rootReason: nil,
        scanComplete: true, entries: [], trashOperatorIdentifier: "fixture")
    let sessions = NotikaSessionRetentionReport(policy: .todayOnlySessions, execute: true, evaluatedAt: evaluatedAt,
        localDayCutoff: cutoff, timeZoneIdentifier: "UTC", rootState: .ready, rootReason: nil,
        scanComplete: true, entries: [.init(name: "retained-session", classification: .retained, action: .none,
            reason: .expiryNotReached, manifestDigest: nil, keepDigest: nil,
            effectiveExpiresAt: evaluatedAt.addingTimeInterval(60), retentionSource: .manifest, detail: nil)],
        trashOperatorIdentifier: "fixture")
    let rust = NotikaRustCacheRetentionReport(policy: .todayOnlyRustCaches, execute: true, evaluatedAt: evaluatedAt,
        localDayCutoff: cutoff, timeZoneIdentifier: "UTC", rootState: .ready, rootReason: nil,
        scanComplete: true, entries: [], trashOperatorIdentifier: "fixture")
    return NotikaArtifactMaintenanceReport(caches: caches, sessions: sessions, rustCaches: rust)
}

private func controllerResultFixture(family: String, native: RunTermination, cancelled: Bool,
                                     maintenance: NotikaArtifactMaintenanceReport) throws -> Data {
    let runID = "16240C6B-E2DC-4D4A-9CC2-0E0D36D4855F"
    let session = "/worktree/Artifacts/AgentSessions/" + runID
    let diagnostics = ["observation diagnostic"], maintenanceDiagnostics = ["maintenance diagnostic"]
    switch family {
    case "preflight":
        return try NotikaPreflightDriverResult(runID: runID, sessionPath: session, report: nil, rawCaptures: [],
            nativeTermination: native, cancelled: cancelled, orchestrationFailures: diagnostics, publicationFailures: [],
            maintenanceReport: maintenance, maintenanceFailures: maintenanceDiagnostics).jsonData()
    case "generation":
        return try NotikaGenerationDriverResult(runID: runID, sessionPath: session, report: nil, rawCaptures: [],
            nativeTermination: native, orchestrationFailures: diagnostics, publicationFailures: [], cancelled: cancelled,
            maintenanceReport: maintenance, maintenanceFailures: maintenanceDiagnostics).jsonData()
    case "rust":
        return try NotikaRustTestDriverResult(runID: runID, sessionPath: session, report: nil, rawCaptures: [],
            nativeTermination: native, cancelled: cancelled, orchestrationFailures: diagnostics, publicationFailures: [],
            maintenanceReport: maintenance, maintenanceFailures: maintenanceDiagnostics).jsonData()
    case "documentation":
        return try NotikaDocumentationDriverResult(runID: runID, sessionPath: session, report: nil, rawCaptures: [],
            nativeTermination: native, ancillaryTerminations: [], orchestrationFailures: diagnostics, publicationFailures: [],
            maintenanceReport: maintenance, maintenanceFailures: maintenanceDiagnostics, cancelled: cancelled).jsonData()
    default:
        throw StrictJSONError.invalidSchema
    }
}
