import Foundation

public struct NotikaPerformanceFailure: Codable, Equatable, Error, Sendable {
    public let operation: String
    public let detail: String?

    public init(operation: String, detail: String? = nil) {
        self.operation = operation; self.detail = detail
    }
}

/// The fixed native report contracts are interpreted here; Python runner or
/// analyzer code is never loaded into the Swift controller. Original bytes and
/// native outcomes remain separate evidence from this derived interpretation.
public enum NotikaPerformanceReports {
    public static let textConfiguration = "Release|ENABLE_TESTABILITY=YES|parallel-testing-enabled=NO"
    public static let canvasConfiguration = "Debug|SWIFT_OPTIMIZATION_LEVEL=-O|SWIFT_COMPILATION_MODE=wholemodule|parallel-testing-enabled=NO"
    public static let textLabels = ["incremental-heavy-dependencies-production-refresh", "incremental-light-dependencies-production-refresh"]
    public static let textTestIdentifiers = [
        "MacTextInputHeavyDependencyPerformanceTests/testReleaseNativeInputWithHeavyDependenciesAndProductionRefresh()",
        "MacTextInputHeavyDependencyPerformanceTests/testReleaseNativeInputWithProductionRefresh()",
    ]
    public static let textAcceptanceCostFields = [
        "publicationMilliseconds", "delegateMilliseconds", "postPublicationMilliseconds", "stateCallbackMilliseconds",
        "contentBoundsIncrementalMilliseconds", "incrementalDependencyDiscoveryMilliseconds", "incrementalAffectedElementsMilliseconds",
        "incrementalGroupTraversalMilliseconds", "incrementalGraphLinksMilliseconds", "incrementalUnionMilliseconds",
        "delegateFrameworkResidualMilliseconds",
    ]
    public static let canvasTestIdentifier = "CanvasPerformanceUITests/testFramePacingMatrix()"

    public static func textSummary(raw: Data, label: String, sourceHash: String, sourceHead: String) throws -> Data {
        guard textLabels.contains(label) else { throw performanceFailure("unknown text scenario") }
        try requireHex(sourceHash, length: 64); try requireHex(sourceHead, length: 40)
        let object = try performanceDocument(raw).object()
        try requireString(object, "schema", "notika.text.native-input-heavy-dependency-performance.v2")
        try requireString(object, "profileLabel", label)
        try requireString(object, "sourceIdentitySHA256", sourceHash)
        try requireString(object, "revision", sourceHead)
        try requireString(object, "configurationIdentity", textConfiguration)
        try requireString(object, "diagnosticMode", "disabled")
        try requireInteger(object, "profileRunOrdinal", 0)
        return try TextPerformanceAnalyzer(report: object, heavy: label == textLabels[0]).summary().encoded()
    }

    public static func canvasSummary(raw: Data, sessionID: String, sourceHash: String, sourceHead: String) throws -> Data {
        let object = try performanceDocument(raw).object()
        try requireKeys(object, ["schema", "status", "completedAt", "startedAt", "runIdentifier", "sessionID",
            "sourceBeforeSHA256", "sourceHead", "configurationIdentity", "operatingSystemVersion", "windowWidth", "windowHeight",
            "eventCount", "eventIntervalMilliseconds", "repetitions", "samples"])
        try requireString(object, "schema", "notika.canvas.frame-pacing-ab.v1")
        try requireString(object, "status", "complete")
        try requireString(object, "configurationIdentity", canvasConfiguration)
        try requireString(object, "sessionID", sessionID)
        try requireString(object, "sourceBeforeSHA256", sourceHash)
        try requireString(object, "sourceHead", sourceHead)
        try requireHex(sourceHash, length: 64); try requireHex(sourceHead, length: 40)
        let run = try field(object, "runIdentifier").string()
        guard run.utf8.count == 36, UUID(uuidString: run) != nil else { throw performanceFailure("invalid matrix run identifier") }
        _ = try field(object, "operatingSystemVersion").string()
        let started = try performanceDate(field(object, "startedAt").string())
        let completed = try performanceDate(field(object, "completedAt").string())
        guard completed >= started else { throw performanceFailure("matrix completed before start") }
        for (name, value) in [("windowWidth", 1200), ("windowHeight", 800), ("eventCount", 240),
                              ("eventIntervalMilliseconds", 4), ("repetitions", 3)] {
            try requireInteger(object, name, Int64(value))
        }
        let samples = try field(object, "samples").array()
        guard samples.count == 24 else { throw performanceFailure("matrix requires exactly 24 samples") }
        let matrix = canvasMatrix()
        for (sample, entry) in zip(samples, matrix) { try validateCanvasSample(sample.object(), entry: entry) }
        var rows: [PerformanceJSON] = []
        for fixture in canvasFixtures {
            for enabled in [false, true] {
                let group = try samples.map { try $0.object() }.filter {
                    try field($0, "fixture").string() == fixture && field($0, "framePacingEnabled").boolean() == enabled
                }
                func values(_ name: String) throws -> [PerformanceJSON] { try group.map { try field($0, name) } }
                func counts(_ name: String) throws -> [PerformanceJSON] { try group.map { try field(field($0, "snapshot").object(), name) } }
                let meanDraw = try group.map { item -> PerformanceJSON in
                    let snapshot = try field(item, "snapshot").object()
                    return .real(try field(snapshot, "totalCanvasDrawDuration").number() / Double(field(snapshot, "canvasDrawCount").integer()))
                }
                rows.append(.object([
                    "fixture": .string(fixture), "framePacingEnabled": .bool(enabled), "sampleCount": .integer(Int64(group.count)),
                    "medianTotalDuration": try median(values("totalDuration")), "maximumTotalDuration": try maximum(values("totalDuration")),
                    "medianInputDuration": try median(values("inputDuration")), "medianCameraApplications": try median(counts("cameraApplications")),
                    "medianCanvasDrawCount": try median(counts("canvasDrawCount")), "medianPageStackLayoutCount": try median(counts("pageStackLayoutCount")),
                    "medianMeanCanvasDrawDuration": try median(meanDraw),
                ]))
            }
        }
        return try PerformanceJSON.object([
            "schema": .string("notika.canvas.frame-pacing-ab-summary.v1"), "runIdentifier": .string(run),
            "sessionID": .string(sessionID), "sourceBeforeSHA256": .string(sourceHash), "sourceHead": .string(sourceHead),
            "configurationIdentity": .string(canvasConfiguration), "sampleCount": .integer(24), "rows": .array(rows),
        ]).encoded()
    }

    /// Reproduction compares JSON value and numeric type, rather than rounded
    /// display text. Whitespace is not part of a derived summary's semantics.
    public static func summariesAgree(_ actual: Data, _ recomputed: Data) throws -> Bool {
        try performanceDocument(actual) == performanceDocument(recomputed)
    }
}

private let canvasFixtures = ["1000-infinite", "2000-infinite", "1000-paged", "2000-paged"]
private let canvasCountFields = [
    "cameraApplications", "canvasDrawCount", "canvasDrawsOver120HzBudget", "canvasDrawsOver60HzBudget", "compoundFillGeometryBuildCount",
    "displayLinkCallbacks", "elementCandidateDiscoveryCount", "elementCandidates", "elementPaintDispatches", "elementPaintingCount",
    "elementRenderingCount", "elementsRendered", "elementsVisited", "graphLinkCandidateDiscoveryCount", "graphLinkCandidates",
    "graphLinkPaintDispatches", "graphLinkPaintingCount", "graphLinkRenderingCount", "graphLinksVisited", "idleDisplayLinkCallbacks",
    "lateDisplayLinkCallbacks", "missedDisplayLinkDeadlines", "pageStackLayoutCount", "device3DSynchronizationCount",
    "textEditorSynchronizationCount", "zoomInputEvents",
]
private let canvasDurationFields = ["last", "maximum", "total"].flatMap { prefix in
    ["CameraApplication", "CanvasDraw", "ElementCandidateDiscovery", "ElementPainting", "ElementRendering",
     "GraphLinkCandidateDiscovery", "GraphLinkPainting", "GraphLinkRendering", "PageStackLayout"].map { prefix + $0 + "Duration" }
}

private func canvasMatrix() -> [(String, Int64, Bool)] {
    canvasFixtures.enumerated().flatMap { index, fixture in
        (1...3).flatMap { repetition in
            let base = index.isMultiple(of: 2) ? [false, true] : [true, false]
            return (repetition == 2 ? base.reversed().map { $0 } : base).map { (fixture, Int64(repetition), $0) }
        }
    }
}

private func validateCanvasSample(_ sample: [String: PerformanceJSON], entry: (String, Int64, Bool)) throws {
    try requireKeys(sample, ["fixture", "repetition", "framePacingEnabled", "canvasMode", "eventCount", "eventIntervalMilliseconds",
        "initialZoom", "finalZoom", "inputDuration", "totalDuration", "snapshot"])
    let (fixture, repetition, enabled) = entry
    try requireString(sample, "fixture", fixture); try requireInteger(sample, "repetition", repetition)
    try requireBool(sample, "framePacingEnabled", enabled)
    try requireString(sample, "canvasMode", fixture.hasSuffix("-paged") ? "paged" : "infiniteCanvas")
    try requireInteger(sample, "eventCount", 240); try requireInteger(sample, "eventIntervalMilliseconds", 4)
    guard abs(try field(sample, "initialZoom").nonnegative() - 1) <= 0.000001,
          abs(try field(sample, "finalZoom").nonnegative() - 1) <= 0.000001,
          try field(sample, "totalDuration").nonnegative() >= field(sample, "inputDuration").nonnegative() else {
        throw performanceFailure("invalid matrix zoom or duration")
    }
    let snapshot = try field(sample, "snapshot").object()
    try requireKeys(snapshot, canvasCountFields + canvasDurationFields)
    for name in canvasCountFields { _ = try field(snapshot, name).integer() }
    for name in canvasDurationFields { _ = try field(snapshot, name).nonnegative() }
    let applications = try field(snapshot, "cameraApplications").integer()
    let callbacks = try field(snapshot, "displayLinkCallbacks").integer()
    try requireInteger(snapshot, "zoomInputEvents", 240); try requireInteger(snapshot, "idleDisplayLinkCallbacks", 0)
    try requireInteger(snapshot, "pageStackLayoutCount", fixture.hasSuffix("-paged") ? applications : 0)
    guard applications > 0, try field(snapshot, "canvasDrawCount").integer() > 0,
          try field(snapshot, "elementsVisited").integer() > 0, try field(snapshot, "elementsRendered").integer() > 0,
          enabled ? applications < 240 && callbacks == applications : applications == 240 && callbacks == 0 else {
        throw performanceFailure("invalid matrix monitor counts")
    }
}

/// This value distinguishes integral and floating tokens even when the numeric
/// value is equal. It is private to performance summaries, not a replacement
/// for the bounded general evidence reader or canonical integer JSON format.
indirect enum PerformanceJSON: Equatable, Sendable {
    case array([Self]), bool(Bool), integer(Int64), null, object([String: Self]), real(Double), string(String)

    init(_ value: StrictJSONValue) throws {
        switch value {
        case .array(let values): self = .array(try values.map(Self.init))
        case .bool(let value): self = .bool(value)
        case .null: self = .null
        case .number(let value): self = value.isInteger ? .integer(try value.int64()) : .real(try value.finiteDouble())
        case .object(let object):
            var values: [String: Self] = [:]
            for member in object.members {
                guard values[member.key] == nil else { throw performanceFailure("ambiguous normalized report key") }
                values[member.key] = try Self(member.value)
            }
            self = .object(values)
        case .string(let value): self = .string(value)
        }
    }

    func object() throws -> [String: Self] { guard case .object(let value) = self else { throw performanceFailure("expected object") }; return value }
    func array() throws -> [Self] { guard case .array(let value) = self else { throw performanceFailure("expected array") }; return value }
    func string() throws -> String { guard case .string(let value) = self, !value.isEmpty else { throw performanceFailure("expected nonempty string") }; return value }
    func boolean() throws -> Bool { guard case .bool(let value) = self else { throw performanceFailure("expected boolean") }; return value }
    func integer() throws -> Int64 { guard case .integer(let value) = self, value >= 0 else { throw performanceFailure("expected nonnegative integer") }; return value }
    func number() throws -> Double {
        let result: Double
        switch self { case .integer(let value): result = Double(value); case .real(let value): result = value; default: throw performanceFailure("expected number") }
        guard result.isFinite else { throw performanceFailure("nonfinite number") }; return result
    }
    func nonnegative() throws -> Double { let result = try number(); guard result >= 0 else { throw performanceFailure("negative number") }; return result }

    func encoded() throws -> Data { Data(try encodedString().utf8) }
    private func encodedString() throws -> String {
        switch self {
        case .array(let value): return "[" + (try value.map { try $0.encodedString() }).joined(separator: ",") + "]"
        case .bool(let value): return value ? "true" : "false"
        case .integer(let value): return String(value)
        case .null: return "null"
        case .object(let value):
            return "{" + (try value.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map {
                try PerformanceJSON.string($0).encodedString() + ":" + value[$0]!.encodedString()
            }).joined(separator: ",") + "}"
        case .real(let value):
            guard value.isFinite else { throw performanceFailure("nonfinite summary") }
            let encoded = String(value)
            return encoded.contains(".") || encoded.contains("e") || encoded.contains("E") ? encoded : encoded + ".0"
        case .string(let value): return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        }
    }
}

func performanceDocument(_ data: Data) throws -> PerformanceJSON {
    try PerformanceJSON(StrictJSONDocument(data: data, limits: StrictJSONLimits(maximumBytes: 8 * 1_024 * 1_024)).root)
}
func performanceFailure(_ operation: String, detail: String? = nil) -> NotikaPerformanceFailure { .init(operation: operation, detail: detail) }
private func field(_ object: [String: PerformanceJSON], _ name: String) throws -> PerformanceJSON {
    guard let value = object[name] else { throw performanceFailure("missing report field", detail: name) }; return value
}
private func requireKeys(_ object: [String: PerformanceJSON], _ names: [String]) throws {
    guard Set(object.keys) == Set(names) else { throw performanceFailure("report field inventory differs") }
}
private func requireString(_ object: [String: PerformanceJSON], _ name: String, _ expected: String) throws {
    guard try field(object, name).string().utf8.elementsEqual(expected.utf8) else { throw performanceFailure("report identity differs", detail: name) }
}
private func requireInteger(_ object: [String: PerformanceJSON], _ name: String, _ expected: Int64) throws {
    guard try field(object, name).integer() == expected else { throw performanceFailure("report integer differs", detail: name) }
}
private func requireBool(_ object: [String: PerformanceJSON], _ name: String, _ expected: Bool) throws {
    guard try field(object, name).boolean() == expected else { throw performanceFailure("report boolean differs", detail: name) }
}
private func requireHex(_ value: String, length: Int) throws {
    guard value.utf8.count == length, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
        throw performanceFailure("invalid source digest")
    }
}
private func performanceDate(_ value: String) throws -> Date {
    let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let ordinary = ISO8601DateFormatter(); ordinary.formatOptions = [.withInternetDateTime]
    guard let date = fractional.date(from: value) ?? ordinary.date(from: value) else { throw performanceFailure("invalid timestamp") }
    return date
}
private func median(_ values: [PerformanceJSON]) throws -> PerformanceJSON {
    guard !values.isEmpty else { throw performanceFailure("empty statistic") }
    let ordered = try values.sorted { try $0.number() < $1.number() }
    let center = ordered.count / 2
    return ordered.count.isMultiple(of: 2) ? .real(try (ordered[center - 1].number() + ordered[center].number()) / 2) : ordered[center]
}
private func maximum(_ values: [PerformanceJSON]) throws -> PerformanceJSON {
    guard let result = try values.max(by: { try $0.number() < $1.number() }) else { throw performanceFailure("empty statistic") }
    return result
}
private func durationSummary(_ values: [PerformanceJSON]) throws -> PerformanceJSON {
    let ordered = try values.sorted { try $0.number() < $1.number() }
    guard !ordered.isEmpty else { throw performanceFailure("empty statistic") }
    return .object(["median": try median(ordered), "p95": ordered[Int(ceil(Double(ordered.count) * 0.95)) - 1], "maximum": try maximum(ordered)])
}

private let textTimestampNames = [
    "dispatchStart", "delegateEntry", "captureStart", "captureEnd", "coreSubmitStart", "evidenceCallbackStart", "evidenceCallbackEnd",
    "reservationReleaseStart", "reservationReleaseEnd", "coreSubmitEnd", "nativeAcknowledgementEnd", "documentGeometryStart",
    "documentGeometryEnd", "editorGeometryStart", "editorGeometryEnd", "accessibilityStart", "accessibilityEnd",
    "displayInvalidationStart", "displayInvalidationEnd", "stateCallbackStart", "stateCallbackEnd", "delegateExit", "dispatchReturn",
]
private let textStageIntervals: [(String, String, String)] = [
    ("captureMilliseconds", "captureStart", "captureEnd"), ("coreSubmitMilliseconds", "coreSubmitStart", "coreSubmitEnd"),
    ("evidenceCallbackMilliseconds", "evidenceCallbackStart", "evidenceCallbackEnd"),
    ("corePostEvidenceCallbackMilliseconds", "evidenceCallbackEnd", "coreSubmitEnd"),
    ("reservationReleaseMilliseconds", "reservationReleaseStart", "reservationReleaseEnd"),
    ("nativeAcknowledgementMilliseconds", "coreSubmitEnd", "nativeAcknowledgementEnd"),
    ("documentGeometryMilliseconds", "documentGeometryStart", "documentGeometryEnd"),
    ("editorGeometryMilliseconds", "editorGeometryStart", "editorGeometryEnd"),
    ("accessibilityMilliseconds", "accessibilityStart", "accessibilityEnd"),
    ("displayInvalidationMilliseconds", "displayInvalidationStart", "displayInvalidationEnd"),
    ("stateCallbackMilliseconds", "stateCallbackStart", "stateCallbackEnd"),
]
private let textDisjointStages = ["captureMilliseconds", "coreSubmitMilliseconds", "nativeAcknowledgementMilliseconds",
    "documentGeometryMilliseconds", "editorGeometryMilliseconds", "accessibilityMilliseconds", "displayInvalidationMilliseconds",
    "stateCallbackMilliseconds"]
private let textBoundsFields = ["requests", "hits", "misses", "rebuildNanoseconds", "elementsVisited", "graphLinksVisited",
    "incrementalUpdates", "incrementalNanoseconds", "incrementalElementsVisited", "incrementalGraphLinksVisited", "unionedContributions",
    "incrementalDependencyNanoseconds", "incrementalElementNanoseconds", "incrementalGroupNanoseconds", "incrementalGroupChildrenVisited",
    "incrementalGraphLinkNanoseconds", "incrementalUnionNanoseconds"]
private let textRichFields = ["lookups", "hits", "absentMisses", "signatureMismatches", "preparations", "insertions", "replacements",
    "evictions", "occupancyBefore", "occupancyAfter", "highWaterBefore", "highWaterAfter"]
private let textDiagnosticFields = ["calls", "nanoseconds"]

private struct TextPerformanceAnalyzer {
    let report: [String: PerformanceJSON]
    let heavy: Bool
    var fixture: [String: PerformanceJSON] {
        ["textCount": .integer(2000), "groupCount": .integer(heavy ? 1 : 0), "containingGroupChildCount": .integer(heavy ? 2000 : 0),
         "graphLinkCount": .integer(heavy ? 256 : 0), "styleCount": .integer(8), "runCount": .integer(8000)]
    }

    func summary() throws -> PerformanceJSON {
        try requireString(report, "boundary", "native-didChangeText-dispatch-through-production-refresh-return")
        try requireInteger(report, "fixtureVersion", 1)
        try requireString(report, "callbackIdentity", "RootContentView.canvasView.onStateChanged->RootContentView.refresh")
        try requireBool(report, "release", true); try requireString(report, "platform", "macOS")
        try requireInteger(report, "assertionFailures", 0); try requireBool(report, "lowPower", false)
        let hardware = try field(report, "hardwareModel").string()
        guard hardware != "unknown", hardware.utf8.count <= 64,
              hardware.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [44, 46, 95, 45].contains($0) }),
              try field(report, "processorCount").integer() > 0, try field(report, "physicalMemory").integer() > 0,
              try field(report, "clockOriginNanoseconds").integer() > 0,
              (0...3).contains(try field(report, "initialThermal").integer()),
              (0...3).contains(try field(report, "finalThermal").integer()) else { throw performanceFailure("invalid text measurement conditions") }
        _ = try field(report, "os").string()
        let samples = try field(report, "samples").array().map { try $0.object() }
        guard samples.count == 70 else { throw performanceFailure("text report requires two complete 35-input passes") }
        var observed = Set<String>()
        var stages: [String: [String: PerformanceJSON]] = [:]
        var previousReturn: Int64?
        for row in samples {
            let pass = try field(row, "pass").integer(), index = try field(row, "index").integer()
            let key = "\(pass):\(index)"
            guard pass < 2, index < 35, observed.insert(key).inserted else { throw performanceFailure("duplicate or unknown text input") }
            for (name, expected) in fixture { guard try field(row, name) == expected else { throw performanceFailure("wrong text fixture", detail: name) } }
            try requireBool(row, "warmup", index < 5); try requireInteger(row, "sessionSequence", index)
            try requireInteger(row, "contentRevisionDelta", 1); try requireInteger(row, "persistenceRevisionDelta", 1)
            try requireBool(row, "supported", true); try requireBool(row, "stateCallbackPresent", true)
            let publication = try field(row, "publicationMilliseconds").number()
            let delegate = try field(row, "delegateMilliseconds").number()
            guard publication > 0, delegate >= publication else { throw performanceFailure("invalid text input duration") }
            let bounds = try field(row, "canvasContentBounds").object()
            try requireKeys(bounds, textBoundsFields)
            for name in textBoundsFields { _ = try field(bounds, name).integer() }
            guard try field(bounds, "requests").integer() > 0 else { throw performanceFailure("text input did not inspect bounds") }
            try requireInteger(bounds, "hits", field(bounds, "requests").integer())
            for name in ["misses", "rebuildNanoseconds", "elementsVisited", "graphLinksVisited", "incrementalGroupChildrenVisited"] {
                try requireInteger(bounds, name, 0)
            }
            try requireInteger(bounds, "incrementalUpdates", 1)
            try requireInteger(bounds, "incrementalElementsVisited", heavy ? 2 : 1)
            try requireInteger(bounds, "incrementalGraphLinksVisited", heavy ? 256 : 0)
            try requireInteger(bounds, "unionedContributions", heavy ? 2257 : 2000)
            let timestamps = try integerDictionary(field(row, "timestampsNanoseconds").object(), expected: textTimestampNames)
            if let previousReturn, timestamps["dispatchStart"]! < previousReturn { throw performanceFailure("overlapping text input intervals") }
            previousReturn = timestamps["dispatchReturn"]!
            stages[key] = try validateProfile(row, bounds: bounds, timestamps: timestamps)
        }
        let completions = try field(report, "completions").array()
        guard completions.count == 2 else { throw performanceFailure("missing text completion evidence") }
        var completed = Set<Int64>()
        for completion in completions {
            let row = try completion.object(), pass = try field(row, "pass").integer()
            guard pass < 2, completed.insert(pass).inserted else { throw performanceFailure("duplicate text completion") }
            try requireInteger(row, "textCount", 2000); try requireInteger(row, "sessionSequence", 35)
            try requireInteger(row, "contentRevisionDelta", 0); try requireInteger(row, "persistenceRevisionDelta", 0)
            for name in ["supported", "finishesSession", "completedSession", "createdHistoryRecord", "oneHistoryEntry", "undoRestored", "redoRestored"] {
                try requireBool(row, name, true)
            }
            guard try field(row, "milliseconds").number() > 0 else { throw performanceFailure("invalid text finish duration") }
        }
        let measured = try samples.filter { try !field($0, "warmup").boolean() }
        let groups = try (0...1).map { pass in
            try group(measured.filter { try field($0, "pass").integer() == Int64(pass) }, stages: stages, pass: Int64(pass))
        }
        var result: [String: PerformanceJSON] = [
            "schema": .string("notika.text.native-input-heavy-dependency-performance-summary.v2"),
            "fixture": .object(fixture), "groups": .array(groups), "combinedGroup": try group(measured, stages: stages, pass: nil),
            "completions": .array(completions), "acceptanceCostFields": .array(NotikaPerformanceReports.textAcceptanceCostFields.map(PerformanceJSON.string)),
            "stageIntervals": .object(Dictionary(uniqueKeysWithValues: textStageIntervals.map { ($0.0, .array([.string($0.1), .string($0.2)])) })),
            "stageAccounting": .object([
                "disjointStages": .array(textDisjointStages.map(PerformanceJSON.string)),
                "nestedStagesAreNotAdditionalCosts": .array([
                    "evidenceCallbackMilliseconds", "corePostEvidenceCallbackMilliseconds", "reservationReleaseMilliseconds",
                    "contentBoundsIncrementalMilliseconds", "incrementalDependencyDiscoveryMilliseconds", "incrementalAffectedElementsMilliseconds",
                    "incrementalGroupTraversalMilliseconds", "incrementalGraphLinksMilliseconds", "incrementalUnionMilliseconds", "diagnosticLayoutMilliseconds",
                ].map(PerformanceJSON.string)),
                "incrementalGroupTraversalIsNestedWithin": .string("incrementalAffectedElementsMilliseconds"),
                "delegateFrameworkResidual": .string("dispatch duration minus disjoint stage durations"),
            ]),
            "hostedFixtureLimits": .array([
                "App-hosted macOS XCTest with a synthetic deterministic document.",
                heavy ? "One edited Text, one 2,000-child containing Group, and 256 direct graph links." : "One edited Text among 2,000 Texts, with no Group or graph dependencies.",
                "Production RootContentView callback installed; synthetic document has no Ink and no outer application callback. Deferred rendering and asynchronous work are outside the dispatch interval.",
                "Revision assertions do not independently establish successful disk persistence.",
            ].map(PerformanceJSON.string)), "productLatencyBudgetMilliseconds": .null,
        ]
        for name in ["revision", "sourceIdentitySHA256", "profileLabel", "callbackIdentity", "configurationIdentity", "boundary",
                     "diagnosticMode", "profileRunOrdinal", "clockOriginNanoseconds"] { result[name] = try field(report, name) }
        result["conditions"] = .object(try Dictionary(uniqueKeysWithValues: ["os", "hardwareModel", "processorCount", "physicalMemory",
            "lowPower", "initialThermal", "finalThermal"].map { ($0, try field(report, $0)) }))
        return .object(result)
    }

    private func validateProfile(_ row: [String: PerformanceJSON], bounds: [String: PerformanceJSON], timestamps: [String: Int64]) throws -> [String: PerformanceJSON] {
        guard zip(textTimestampNames, textTimestampNames.dropFirst()).allSatisfy({ timestamps[$0.0]! <= timestamps[$0.1]! }) else {
            throw performanceFailure("text profile timestamps out of order")
        }
        let publication = Double(timestamps["evidenceCallbackStart"]! - timestamps["dispatchStart"]!) / 1_000_000
        let delegate = Double(timestamps["dispatchReturn"]! - timestamps["dispatchStart"]!) / 1_000_000
        for (name, expected) in [("publicationMilliseconds", publication), ("delegateMilliseconds", delegate)] {
            let actual = try field(row, name).number()
            guard abs(actual - expected) <= max(0.000002, 1e-9 * max(abs(actual), abs(expected))) else {
                throw performanceFailure("text duration differs from timestamps", detail: name)
            }
        }
        let rich = try integerDictionary(field(row, "richCache").object(), expected: textRichFields)
        let diagnostics = try integerDictionary(field(row, "diagnosticLayout").object(), expected: textDiagnosticFields)
        guard diagnostics.values.allSatisfy({ $0 == 0 }) else { throw performanceFailure("disabled diagnostics performed layout work") }
        guard try sum([rich["hits"]!, rich["absentMisses"]!, rich["signatureMismatches"]!]) == rich["lookups"]!,
              try sum([rich["absentMisses"]!, rich["signatureMismatches"]!]) == rich["preparations"]!,
              try sum([rich["insertions"]!, rich["replacements"]!]) == rich["preparations"]! else {
            throw performanceFailure("rich cache conservation failed")
        }
        let occupancyBase = try sum([rich["occupancyBefore"]!, rich["insertions"]!])
        guard occupancyBase >= rich["evictions"]!, rich["occupancyAfter"]! == occupancyBase - rich["evictions"]!,
              rich["highWaterBefore"]! >= rich["occupancyBefore"]!, rich["highWaterAfter"]! >= rich["occupancyAfter"]!,
              rich["highWaterAfter"]! >= rich["highWaterBefore"]!,
              rich["highWaterAfter"]! <= (try sum([rich["highWaterBefore"]!, rich["insertions"]!])),
              rich["evictions"]! <= rich["insertions"]!,
              ["occupancyBefore", "occupancyAfter", "highWaterBefore", "highWaterAfter"].allSatisfy({ rich[$0]! <= 512 }) else {
            throw performanceFailure("rich cache occupancy accounting failed")
        }
        let counters = try integerDictionary(bounds, expected: textBoundsFields)
        let incremental = counters["incrementalNanoseconds"]!, dependency = counters["incrementalDependencyNanoseconds"]!
        let elements = counters["incrementalElementNanoseconds"]!, group = counters["incrementalGroupNanoseconds"]!
        let graphLinks = counters["incrementalGraphLinkNanoseconds"]!, union = counters["incrementalUnionNanoseconds"]!
        guard incremental > 0, dependency > 0, (elements > 0) == (counters["incrementalElementsVisited"]! > 0),
              (group > 0) == (counters["incrementalElementsVisited"]! > 1),
              (graphLinks > 0) == (counters["incrementalGraphLinksVisited"]! > 0),
              (union > 0) == (counters["unionedContributions"]! > 0), group <= elements,
              try sum([dependency, elements, graphLinks, union]) <= incremental,
              incremental <= timestamps["documentGeometryEnd"]! - timestamps["documentGeometryStart"]! else {
            throw performanceFailure("invalid incremental text timing or traversal")
        }
        var intervals = Dictionary(uniqueKeysWithValues: textStageIntervals.map { ($0.0, timestamps[$0.2]! - timestamps[$0.1]!) })
        let delegateSpan = timestamps["delegateExit"]! - timestamps["delegateEntry"]!
        let accounted = try sum(textDisjointStages.map { intervals[$0]! })
        guard accounted <= delegateSpan else { throw performanceFailure("text disjoint stages exceed delegate interval") }
        let framework = try sum([timestamps["delegateEntry"]! - timestamps["dispatchStart"]!,
                                 timestamps["dispatchReturn"]! - timestamps["delegateExit"]!])
        intervals["delegateResidualMilliseconds"] = delegateSpan - accounted
        intervals["frameworkResidualMilliseconds"] = framework
        intervals["delegateFrameworkResidualMilliseconds"] = try sum([delegateSpan - accounted, framework])
        intervals["contentBoundsRebuildMilliseconds"] = counters["rebuildNanoseconds"]!
        intervals["diagnosticLayoutMilliseconds"] = diagnostics["nanoseconds"]!
        intervals["contentBoundsIncrementalMilliseconds"] = incremental
        intervals["incrementalDependencyDiscoveryMilliseconds"] = dependency
        intervals["incrementalAffectedElementsMilliseconds"] = elements
        intervals["incrementalGroupTraversalMilliseconds"] = group
        intervals["incrementalGraphLinksMilliseconds"] = graphLinks
        intervals["incrementalUnionMilliseconds"] = union
        return intervals.mapValues { .real(Double($0) / 1_000_000) }
    }

    private func group(_ rows: [[String: PerformanceJSON]], stages: [String: [String: PerformanceJSON]], pass: Int64?) throws -> PerformanceJSON {
        var result = fixture
        result["samples"] = .integer(Int64(rows.count)); result["diagnosticMode"] = .string("disabled")
        if let pass { result["pass"] = .integer(pass) }
        for name in ["publicationMilliseconds", "delegateMilliseconds"] {
            result[name] = try durationSummary(rows.map { try field($0, name) })
        }
        result["postPublicationMilliseconds"] = try durationSummary(rows.map {
            .real(try field($0, "delegateMilliseconds").number() - field($0, "publicationMilliseconds").number())
        })
        let rowStages = try rows.map { row -> [String: PerformanceJSON] in
            let key = "\(try field(row, "pass").integer()):\(try field(row, "index").integer())"
            guard let value = stages[key] else { throw performanceFailure("missing text stage profile") }; return value
        }
        guard let first = rowStages.first else { throw performanceFailure("empty text measured group") }
        result["stages"] = .object(try Dictionary(uniqueKeysWithValues: first.keys.map { name in
            (name, try durationSummary(rowStages.map { try field($0, name) }))
        }))
        var counterGroups: [String: PerformanceJSON] = [:]
        for (category, names) in [("canvasContentBounds", textBoundsFields), ("richCache", textRichFields), ("diagnosticLayout", textDiagnosticFields)] {
            counterGroups[category] = .object(try Dictionary(uniqueKeysWithValues: names.map { name in
                (name, try durationSummary(rows.map { try field(field($0, category).object(), name) }))
            }))
        }
        result["counters"] = .object(counterGroups)
        return .object(result)
    }
}

private func integerDictionary(_ object: [String: PerformanceJSON], expected: [String]) throws -> [String: Int64] {
    try requireKeys(object, expected)
    return try object.mapValues { try $0.integer() }
}
private func sum(_ values: [Int64]) throws -> Int64 {
    try values.reduce(0) { value, next in
        let result = value.addingReportingOverflow(next)
        guard !result.overflow else { throw performanceFailure("counter sum overflow") }
        return result.partialValue
    }
}
