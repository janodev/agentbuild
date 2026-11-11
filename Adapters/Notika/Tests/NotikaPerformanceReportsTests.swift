@testable import AgentBuildCore
import AgentBuildTestSupport
import Foundation
@testable import NotikaAdapter
import Testing

@Suite("Fixed Notika performance reports")
struct NotikaPerformanceReportsTests {
    private let sourceHash = "eaf3b9a9369a419792819017d2161e9e34220cf6f8487a92ef70f999492e0579"
    private let head = "40716192d308830a578f44ae89f52276aea2c205"

    @Test(arguments: ["heavy", "light"])
    func independentlyRetainedPythonSummariesMatchSwiftReproduction(_ fixture: String) throws {
        let raw = try fixtureData(fixture + "-raw.json"), expected = try fixtureData(fixture + "-summary.json")
        let summary = try NotikaPerformanceReports.textSummary(raw: raw,
            label: NotikaPerformanceReports.textLabels[fixture == "heavy" ? 0 : 1], sourceHash: sourceHash, sourceHead: head)
        let matches = try NotikaPerformanceReports.summariesAgree(summary, expected)
        #expect(matches)
    }

    @Test(arguments: ["sourceIdentitySHA256", "revision", "configurationIdentity", "diagnosticMode", "profileRunOrdinal"])
    func rejectsTextIdentitySubstitution(_ field: String) throws {
        var report = try performanceDocument(fixtureData("heavy-raw.json")).object()
        report[field] = field == "profileRunOrdinal" ? .real(0) : .string("foreign")
        let data = try PerformanceJSON.object(report).encoded()
        #expect(throws: (any Error).self) {
            try NotikaPerformanceReports.textSummary(raw: data, label: NotikaPerformanceReports.textLabels[0], sourceHash: sourceHash, sourceHead: head)
        }
    }

    @Test(arguments: ["duplicate", "missing", "groupTraversal", "counterOverflow", "timestamps", "history"])
    func rejectsFalseTextMeasurementEvidence(_ mutation: String) throws {
        var report = try performanceDocument(fixtureData("heavy-raw.json")).object()
        var samples = try report["samples"]!.array()
        if mutation == "duplicate" { samples[1] = samples[0] }
        else if mutation == "missing" { samples.removeLast() }
        else if mutation == "history" {
            var completions = try report["completions"]!.array(), completion = try completions[0].object()
            completion["undoRestored"] = .bool(false); completions[0] = .object(completion); report["completions"] = .array(completions)
        } else {
            var row = try samples[0].object()
            if mutation == "timestamps" {
                var timestamps = try row["timestampsNanoseconds"]!.object()
                timestamps["dispatchReturn"] = .integer(0); row["timestampsNanoseconds"] = .object(timestamps)
            } else if mutation == "counterOverflow" {
                var cache = try row["richCache"]!.object()
                cache["hits"] = .integer(Int64.max); cache["absentMisses"] = .integer(Int64.max); row["richCache"] = .object(cache)
            } else {
                var bounds = try row["canvasContentBounds"]!.object()
                bounds["incrementalGroupChildrenVisited"] = .integer(2000); row["canvasContentBounds"] = .object(bounds)
            }
            samples[0] = .object(row)
        }
        report["samples"] = .array(samples)
        let data = try PerformanceJSON.object(report).encoded()
        #expect(throws: (any Error).self) {
            try NotikaPerformanceReports.textSummary(raw: data, label: NotikaPerformanceReports.textLabels[0], sourceHash: sourceHash, sourceHead: head)
        }
    }

    @Test func summaryTypeAndValueAreNotCoerced() throws {
        #expect(try !NotikaPerformanceReports.summariesAgree(Data("{\"count\":1}".utf8), Data("{\"count\":1.0}".utf8)))
        #expect(try !NotikaPerformanceReports.summariesAgree(Data("{\"count\":true}".utf8), Data("{\"count\":1}".utf8)))
        #expect(try NotikaPerformanceReports.summariesAgree(Data("{\"time\":1.5}".utf8), Data(" {\"time\":1.50} ".utf8)))
        #expect(throws: (any Error).self) { try NotikaPerformanceReports.summariesAgree(Data("{\"x\":1,\"x\":2}".utf8), Data("{}".utf8)) }
    }

    @Test func canvasMatrixProducesEightIndependentlyCheckableRows() throws {
        let session = UUID().uuidString, raw = try performanceCanvasFixture(sessionID: session, sourceHash: sourceHash, head: head)
        let summary = try performanceDocument(NotikaPerformanceReports.canvasSummary(raw: raw, sessionID: session, sourceHash: sourceHash, sourceHead: head)).object()
        let rows = try summary["rows"]!.array().map { try $0.object() }
        #expect(rows.count == 8)
        #expect(rows[0]["fixture"] == .string("1000-infinite"))
        #expect(rows[0]["framePacingEnabled"] == .bool(false))
        #expect(rows[0]["medianCameraApplications"] == .integer(240))
        #expect(rows[1]["medianCameraApplications"] == .integer(120))
        #expect(rows[0]["medianPageStackLayoutCount"] == .integer(0))
        #expect(rows[4]["medianPageStackLayoutCount"] == .integer(240))
        #expect(rows[5]["medianPageStackLayoutCount"] == .integer(120))
        #expect(rows[0]["medianTotalDuration"] == .real(1.7))
        #expect(rows[0]["maximumTotalDuration"] == .real(1.8))
        #expect(rows[0]["medianMeanCanvasDrawDuration"] == .real(0.001))
    }

    @Test(arguments: ["order", "duplicate", "missing", "counts", "integerType", "nonfinite", "field", "source"])
    func canvasRejectsIncompleteOrFalseMatrix(_ mutation: String) throws {
        let session = UUID().uuidString
        var report = try performanceDocument(performanceCanvasFixture(sessionID: session, sourceHash: sourceHash, head: head)).object()
        var samples = try report["samples"]!.array()
        if mutation == "order" { samples.swapAt(0, 1) }
        else if mutation == "duplicate" { samples[1] = samples[0] }
        else if mutation == "missing" { samples.removeLast() }
        else if mutation == "field" { report["extra"] = .null }
        else if mutation == "source" { report["sourceHead"] = .string(String(repeating: "0", count: 40)) }
        else {
            var sample = try samples[0].object()
            if mutation == "nonfinite" { sample["inputDuration"] = .real(.infinity) }
            else if mutation == "integerType" { sample["eventCount"] = .real(240) }
            else {
                var snapshot = try sample["snapshot"]!.object()
                snapshot["cameraApplications"] = .integer(239); sample["snapshot"] = .object(snapshot)
            }
            samples[0] = .object(sample)
        }
        report["samples"] = .array(samples)
        #expect(throws: (any Error).self) {
            let raw = try PerformanceJSON.object(report).encoded()
            return try NotikaPerformanceReports.canvasSummary(raw: raw, sessionID: session, sourceHash: sourceHash, sourceHead: head)
        }
    }

    private func fixtureData(_ name: String) throws -> Data {
        let path = AgentBuildTestPaths.packageRoot.appendingPathComponent("Tests")
            .appendingPathComponent("Evidence/NotikaPerformance").appendingPathComponent(name)
        return try Data(contentsOf: path)
    }
}

func performanceCanvasFixture(sessionID: String, sourceHash: String, head: String) throws -> Data {
    let counts = ["cameraApplications", "canvasDrawCount", "canvasDrawsOver120HzBudget", "canvasDrawsOver60HzBudget",
        "compoundFillGeometryBuildCount", "displayLinkCallbacks", "elementCandidateDiscoveryCount", "elementCandidates",
        "elementPaintDispatches", "elementPaintingCount", "elementRenderingCount", "elementsRendered", "elementsVisited",
        "graphLinkCandidateDiscoveryCount", "graphLinkCandidates", "graphLinkPaintDispatches", "graphLinkPaintingCount",
        "graphLinkRenderingCount", "graphLinksVisited", "idleDisplayLinkCallbacks", "lateDisplayLinkCallbacks", "missedDisplayLinkDeadlines",
        "pageStackLayoutCount", "device3DSynchronizationCount", "textEditorSynchronizationCount", "zoomInputEvents"]
    let durations = ["last", "maximum", "total"].flatMap { prefix in
        ["CameraApplication", "CanvasDraw", "ElementCandidateDiscovery", "ElementPainting", "ElementRendering",
         "GraphLinkCandidateDiscovery", "GraphLinkPainting", "GraphLinkRendering", "PageStackLayout"].map { prefix + $0 + "Duration" }
    }
    var samples: [PerformanceJSON] = []
    for (index, fixture) in ["1000-infinite", "2000-infinite", "1000-paged", "2000-paged"].enumerated() {
        for repetition in 1...3 {
            let base = index.isMultiple(of: 2) ? [false, true] : [true, false]
            for enabled in repetition == 2 ? base.reversed().map({ $0 }) : base {
                var snapshot = Dictionary(uniqueKeysWithValues: counts.map { ($0, PerformanceJSON.integer(0)) })
                for name in durations { snapshot[name] = .real(0) }
                let applications: Int64 = enabled ? 120 : 240
                snapshot["cameraApplications"] = .integer(applications); snapshot["canvasDrawCount"] = .integer(applications)
                snapshot["displayLinkCallbacks"] = .integer(enabled ? applications : 0); snapshot["zoomInputEvents"] = .integer(240)
                snapshot["elementsVisited"] = .integer(1000); snapshot["elementsRendered"] = .integer(1000)
                snapshot["pageStackLayoutCount"] = .integer(fixture.hasSuffix("-paged") ? applications : 0)
                snapshot["totalCanvasDrawDuration"] = .real(Double(applications) * 0.001)
                samples.append(.object(["fixture": .string(fixture), "repetition": .integer(Int64(repetition)),
                    "framePacingEnabled": .bool(enabled), "canvasMode": .string(fixture.hasSuffix("-paged") ? "paged" : "infiniteCanvas"),
                    "eventCount": .integer(240), "eventIntervalMilliseconds": .integer(4), "initialZoom": .real(1), "finalZoom": .real(1),
                    "inputDuration": .real(0.96), "totalDuration": .real(1.5 + Double(repetition) / 10), "snapshot": .object(snapshot)]))
            }
        }
    }
    return try PerformanceJSON.object(["schema": .string("notika.canvas.frame-pacing-ab.v1"), "status": .string("complete"),
        "startedAt": .string("2026-10-10T12:00:00Z"), "completedAt": .string("2026-10-10T12:01:00Z"),
        "runIdentifier": .string(UUID().uuidString), "sessionID": .string(sessionID), "sourceBeforeSHA256": .string(sourceHash),
        "sourceHead": .string(head), "configurationIdentity": .string(NotikaPerformanceReports.canvasConfiguration),
        "operatingSystemVersion": .string("Version 27.0"), "windowWidth": .integer(1200), "windowHeight": .integer(800),
        "eventCount": .integer(240), "eventIntervalMilliseconds": .integer(4), "repetitions": .integer(3), "samples": .array(samples)]).encoded()
}
