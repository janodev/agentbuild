import AgentBuildCore
import Foundation

/// Project-specific request vocabulary for the Notika adapter, not generic build policy.
public enum NotikaPlatform: String, Codable, CaseIterable, Hashable, Sendable {
    case macOS = "macos-ui"
    case iPadSimulator = "ipad-simulator"
}

public enum NotikaInteractiveMode: String, Codable, Hashable, Sendable {
    case run
}

public enum NotikaDocumentationMode: String, Codable, CaseIterable, Hashable, Sendable {
    case archive
    case rendered
    case preview
}

/// The closed route inventory admitted by Notika's Python reference driver.
public enum NotikaMakeRoute: String, Codable, CaseIterable, Hashable, Sendable {
    case build
    case buildAndTest = "build-and-test"
    case buildRelease = "build-release"
    case coverage
    case coverageFile = "coverage-file"
    case coverageFileUnit = "coverage-file-unit"
    case coverageHTML = "coverage-html"
    case coverageJSON = "coverage-json"
    case coverageQuiet = "coverage-quiet"
    case resultsBrief = "results-brief"
    case resultsBundle = "results-bundle"
    case resultsFile = "results-file"
    case resultsSummary = "results-summary"
    case test
    case testCoverage = "test-coverage"
    case testShowOnlyErrors = "test-show-only-errors"
    case testUI = "test-ui"
    case testUIFile = "test-ui-file"
    case testUIOnly = "test-ui-only"
    case testUIOnlyFile = "test-ui-only-file"
    case testUnit = "test-unit"
    case testUnitCoverage = "test-unit-coverage"
    case testUnitFile = "test-unit-file"
    case testUnitFocused = "test-unit-focused"
    case testTextInputHeavyDependencyPerformance = "test-text-input-heavy-dependency-performance"
    case testCanvasFramePacingPerformance = "test-canvas-frame-pacing-performance"
    case buildXcode = "build-xcode"
    case testXcode = "test-xcode"
    case unitTestXcode = "unit-test-xcode"
    case unitTest = "unit-test"
    case testXcodeFile = "test-xcode-file"
    case uiTestXcodeFile = "uitest-xcode-file"
    case buildIOS = "build-ios"
    case buildUIKit = "build-uikit"
    case buildMacOS = "build-macos"
    case buildReleaseIOS = "build-release-ios"
    case buildReleaseMacOS = "build-release-macos"
    case testIOS = "test-ios"
    case testUIKit = "test-uikit"
    case testMacOS = "test-macos"
    case testUnitIOS = "test-unit-ios"
    case testUnitMacOS = "test-unit-macos"
    case testUIIOS = "test-ui-ios"
    case testUIMacOS = "test-ui-macos"
    case replayFixedSemantic = "replay-fixed-semantic"
    case testUIVisual = "test-ui-visual"
    case coverageXcodeFile = "coverage-xcode-file"
    case coverageXcodeHTML = "coverage-xcode-html"
    case coverageXcodeJSON = "coverage-xcode-json"
    case resultBundle = "result-bundle"
    case summary
    case summaryBrief = "summary-brief"
    case summaryFile = "summary-file"
    case testXcodeCoverage = "test-xcode-coverage"

    public var canonicalRoute: Self {
        switch self {
        case .buildXcode, .buildIOS, .buildUIKit, .buildMacOS: .build
        case .testXcode, .testIOS, .testUIKit, .testMacOS: .test
        case .unitTestXcode, .unitTest, .testUnitIOS, .testUnitMacOS, .replayFixedSemantic: .testUnit
        case .testXcodeFile: .testUnitFile
        case .uiTestXcodeFile: .testUIFile
        case .buildReleaseIOS, .buildReleaseMacOS: .buildRelease
        case .testUIIOS, .testUIMacOS: .testUI
        case .testUIVisual: .testUIOnly
        case .coverageXcodeFile: .coverageFile
        case .coverageXcodeHTML: .coverageHTML
        case .coverageXcodeJSON: .coverageJSON
        case .resultBundle: .resultsBundle
        case .summary: .resultsSummary
        case .summaryBrief: .resultsBrief
        case .summaryFile: .resultsFile
        case .testXcodeCoverage: .testCoverage
        default: self
        }
    }

    /// A platform encoded by the alias, rather than a default chosen by the caller.
    public var requiredPlatform: NotikaPlatform? {
        switch self {
        case .buildIOS, .buildUIKit, .buildReleaseIOS, .testIOS, .testUIKit, .testUnitIOS, .testUIIOS:
            .iPadSimulator
        case .buildMacOS, .buildReleaseMacOS, .testMacOS, .testUnitMacOS, .testUIMacOS,
             .replayFixedSemantic, .testUIVisual:
            .macOS
        default: nil
        }
    }

    public static var canonicalRoutes: [Self] {
        allCases.filter { $0.canonicalRoute == $0 }
    }

    public var isMacOSOnly: Bool {
        switch canonicalRoute {
        case .testUIOnly, .testUIOnlyFile, .testTextInputHeavyDependencyPerformance,
             .testCanvasFramePacingPerformance: true
        default: requiredPlatform == .macOS
        }
    }

    public var acceptsTestFile: Bool {
        [.testUIFile, .testUIOnlyFile, .testUnitFile].contains(canonicalRoute)
    }

    public var acceptsCoverageFile: Bool {
        [.coverageFile, .coverageFileUnit].contains(canonicalRoute)
    }

    public var acceptsTestMethod: Bool {
        [.testUIFile, .testUIOnlyFile].contains(canonicalRoute)
    }

    public var requiresOuterLease: Bool {
        switch canonicalRoute {
        case .buildAndTest, .test, .testShowOnlyErrors, .testUI, .testUIFile, .testUIOnly,
             .testUIOnlyFile, .testTextInputHeavyDependencyPerformance, .testCanvasFramePacingPerformance,
             .coverageFile, .coverageHTML, .coverageJSON, .coverageQuiet, .testCoverage: true
        default: false
        }
    }

    public var expectsResultBundle: Bool {
        canonicalRoute == .buildAndTest || canonicalRoute.rawValue.hasPrefix("test")
            || canonicalRoute.rawValue.hasPrefix("coverage") || canonicalRoute.rawValue.hasPrefix("results-")
    }

    /// Fixed aliases retain their own request identity while selecting these fixtures.
    public var fixedTestFile: String? {
        switch self {
        case .replayFixedSemantic: "CreateTwoRectanglesAndGroupReplayCapsuleTests"
        case .testUIVisual: "NotikaUITests"
        default: nil
        }
    }

    public var fixedTestMethod: String? {
        self == .testUIVisual ? "testFixedWidthTextBoxVisualScreenshot" : nil
    }
}

public enum NotikaRequestError: Error, Equatable, Sendable {
    case invalidUnitSelector(String)
    case emptyFocusedSelection
    case duplicateUnitSelectors
    case mixedFocusedSelection
    case unexpectedUnitSelectors
    case incompatibleModes
    case expectedPlatform(NotikaPlatform)
    case unexpectedTestOrDeviceSelectors
    case invalidTestFile
    case invalidTestMethod
    case unexpectedTestFile
    case unexpectedTestMethod
    case invalidCoverageFile
    case missingDevice
    case invalidDevice
    case unexpectedDevice
    case oversizedSelectorTransport
    case invalidSelectorTransport
    case invalidRequestKind
    case invalidRequestShape
}

/// Immutable, validated Notika action data. This value does not grant execution authority.
public struct NotikaActionRequest: Codable, Equatable, Sendable {
    public static let defaultIPadDevice = "iPad Air 13-inch (M4)"
    public static let maximumSelectorTransportBytes = 64 * 1_024

    public let platform: NotikaPlatform
    public let testFile: String
    public let testMethod: String
    public let device: String?
    public let makeRoute: NotikaMakeRoute?
    public let interactiveMode: NotikaInteractiveMode?
    public let documentationMode: NotikaDocumentationMode?
    public let unitSelectors: [String]

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.platform == rhs.platform && lhs.makeRoute == rhs.makeRoute
            && lhs.interactiveMode == rhs.interactiveMode && lhs.documentationMode == rhs.documentationMode
            && lhs.testFile.utf8.elementsEqual(rhs.testFile.utf8)
            && lhs.testMethod.utf8.elementsEqual(rhs.testMethod.utf8)
            && lhs.device.map { Data($0.utf8) } == rhs.device.map { Data($0.utf8) }
            && lhs.unitSelectors.map { Data($0.utf8) } == rhs.unitSelectors.map { Data($0.utf8) }
    }

    /// Preserves ActionRequest validation: a raw iPad request must supply a device.
    public init(
        platform: NotikaPlatform,
        testFile: String = "",
        testMethod: String = "",
        device: String? = nil,
        makeRoute: NotikaMakeRoute? = nil,
        interactiveMode: NotikaInteractiveMode? = nil,
        documentationMode: NotikaDocumentationMode? = nil,
        unitSelectors: [String] = []
    ) throws {
        self.platform = platform
        self.testFile = testFile
        self.testMethod = testMethod
        self.device = device
        self.makeRoute = makeRoute
        self.interactiveMode = interactiveMode
        self.documentationMode = documentationMode
        self.unitSelectors = unitSelectors
        try validate()
    }

    /// Applies the current public run-make platform and iPad device defaults.
    public init(
        makeRoute: NotikaMakeRoute,
        platform: NotikaPlatform? = nil,
        testFile: String = "",
        testMethod: String = "",
        device: String? = nil,
        unitSelectors: [String] = []
    ) throws {
        let selectedPlatform = platform ?? makeRoute.requiredPlatform ?? .macOS
        let selectedDevice = selectedPlatform == .iPadSimulator && (device == nil || device == "")
            ? Self.defaultIPadDevice : device
        try self.init(platform: selectedPlatform, testFile: testFile, testMethod: testMethod,
                      device: selectedDevice, makeRoute: makeRoute, unitSelectors: unitSelectors)
    }

    public var canonicalMakeRoute: NotikaMakeRoute? { makeRoute?.canonicalRoute }
    public var isLegacyMake: Bool { makeRoute != nil }
    public var isInteractive: Bool { interactiveMode != nil }
    public var isDocumentation: Bool { documentationMode != nil }

    /// Matches the reference property. Focused macOS UI execution acquires its
    /// outer lease independently; this property is not a universal admission rule.
    public var requiresOuterLease: Bool {
        isInteractive || platform == .iPadSimulator || (makeRoute?.requiresOuterLease ?? false)
    }

    public var expectsResultBundle: Bool {
        (makeRoute?.expectsResultBundle ?? false) || (makeRoute == nil && !isInteractive && !isDocumentation)
    }

    /// Carries exact native identifiers as canonical, whitespace-separated Make tokens.
    public static func encodeUnitSelectors(_ selectors: [String]) throws -> String {
        try validateUnitSelectors(selectors)
        let encoded = selectors.map { $0.replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "`", with: "%60") }.joined(separator: " ")
        guard encoded.utf8.count <= maximumSelectorTransportBytes else {
            throw NotikaRequestError.oversizedSelectorTransport
        }
        return encoded
    }

    public static func decodeUnitSelectors(_ encoded: String) throws -> [String] {
        guard encoded.utf8.count <= maximumSelectorTransportBytes else {
            throw NotikaRequestError.oversizedSelectorTransport
        }
        let selectors = encoded.isEmpty ? [] : encoded.components(separatedBy: " ").map {
            $0.replacingOccurrences(of: "%20", with: " ").replacingOccurrences(of: "%60", with: "`")
        }
        guard try encodeUnitSelectors(selectors) == encoded else {
            throw NotikaRequestError.invalidSelectorTransport
        }
        return selectors
    }

    private func validate() throws {
        // Preserve reference validation ordering as well as accepted requests.
        for selector in unitSelectors where !Self.matches(Self.unitSelectorPattern, selector) {
            throw NotikaRequestError.invalidUnitSelector(selector)
        }
        if canonicalMakeRoute == .testUnitFocused {
            guard !unitSelectors.isEmpty else { throw NotikaRequestError.emptyFocusedSelection }
            guard testFile.isEmpty && testMethod.isEmpty else { throw NotikaRequestError.mixedFocusedSelection }
            guard Set(unitSelectors).count == unitSelectors.count else { throw NotikaRequestError.duplicateUnitSelectors }
        } else if !unitSelectors.isEmpty {
            throw NotikaRequestError.unexpectedUnitSelectors
        }
        if isInteractive {
            guard platform == .macOS else { throw NotikaRequestError.expectedPlatform(.macOS) }
            guard makeRoute == nil && documentationMode == nil else { throw NotikaRequestError.incompatibleModes }
            guard testFile.isEmpty && testMethod.isEmpty && device == nil else {
                throw NotikaRequestError.unexpectedTestOrDeviceSelectors
            }
        } else if isDocumentation {
            guard platform == .macOS else { throw NotikaRequestError.expectedPlatform(.macOS) }
            guard makeRoute == nil else { throw NotikaRequestError.incompatibleModes }
            guard testFile.isEmpty && testMethod.isEmpty && device == nil else {
                throw NotikaRequestError.unexpectedTestOrDeviceSelectors
            }
        } else if let route = makeRoute {
            if let required = route.requiredPlatform, platform != required {
                throw NotikaRequestError.expectedPlatform(required)
            }
            if route.isMacOSOnly && platform != .macOS {
                throw NotikaRequestError.expectedPlatform(.macOS)
            }
            if route.acceptsTestFile {
                guard Self.matches(Self.identifierPattern, testFile) else { throw NotikaRequestError.invalidTestFile }
            } else if route.acceptsCoverageFile {
                guard Self.matches(#"[A-Za-z0-9_+./-]+\.swift"#, testFile), !testFile.hasPrefix("/"),
                      !testFile.split(separator: "/").contains("..") else { throw NotikaRequestError.invalidCoverageFile }
            } else if !testFile.isEmpty {
                throw NotikaRequestError.unexpectedTestFile
            }
            if !testMethod.isEmpty {
                guard route.acceptsTestMethod else { throw NotikaRequestError.unexpectedTestMethod }
                guard Self.matches(Self.identifierPattern, testMethod) else { throw NotikaRequestError.invalidTestMethod }
            }
        } else {
            guard Self.matches(Self.identifierPattern, testFile) else { throw NotikaRequestError.invalidTestFile }
            guard Self.matches(Self.identifierPattern, testMethod) else { throw NotikaRequestError.invalidTestMethod }
        }
        if platform == .iPadSimulator && (device == nil || device == "") { throw NotikaRequestError.missingDevice }
        if let device, !Self.matches(#"[A-Za-z0-9][A-Za-z0-9 ._()-]*"#, device) { throw NotikaRequestError.invalidDevice }
        if platform == .macOS && device != nil { throw NotikaRequestError.unexpectedDevice }
    }

    private static let identifierPattern = #"[A-Za-z_][A-Za-z0-9_]*"#
    private static let unitSelectorPattern = #"[A-Za-z_][A-Za-z0-9_]*(?:/(?:[A-Za-z_][A-Za-z0-9_]*|`[A-Za-z_](?:[A-Za-z0-9_ ,-]*[A-Za-z0-9_,-])?`)\((?:[A-Za-z_][A-Za-z0-9_]*:)*\))?"#

    private static func matches(_ pattern: String, _ value: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: "^(?:" + pattern + ")$") else { return false }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.firstMatch(in: value, range: range)?.range == range
    }

    private static func validateUnitSelectors(_ selectors: [String]) throws {
        for selector in selectors where !matches(unitSelectorPattern, selector) {
            throw NotikaRequestError.invalidUnitSelector(selector)
        }
        guard Set(selectors).count == selectors.count else { throw NotikaRequestError.duplicateUnitSelectors }
    }

    private enum CodingKeys: String, CodingKey {
        case platform, device, kind, route, mode, unitSelectors
        case testFile = "file"
        case testMethod = "method"
    }

    private struct AnyRequestKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(platform, forKey: .platform)
        try container.encode(testFile, forKey: .testFile)
        try container.encode(testMethod, forKey: .testMethod)
        if let device { try container.encode(device, forKey: .device) }
        else { try container.encodeNil(forKey: .device) }
        if !unitSelectors.isEmpty { try container.encode(unitSelectors, forKey: .unitSelectors) }
        if let makeRoute {
            try container.encode("legacy-make", forKey: .kind)
            try container.encode(makeRoute, forKey: .route)
        } else if let interactiveMode {
            try container.encode("interactive-macos", forKey: .kind)
            try container.encode(interactiveMode, forKey: .mode)
        } else if let documentationMode {
            try container.encode("docc", forKey: .kind)
            try container.encode(documentationMode, forKey: .mode)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decodeIfPresent(String.self, forKey: .kind)
        if let kind, !["legacy-make", "interactive-macos", "docc"].contains(kind) {
            throw NotikaRequestError.invalidRequestKind
        }
        var requiredKeys: Set<String> = ["platform", "file", "method", "device"]
        if let kind {
            requiredKeys.formUnion(["kind", kind == "legacy-make" ? "route" : "mode"])
        }
        let observedKeys = Set(try decoder.container(keyedBy: AnyRequestKey.self).allKeys.map(\.stringValue))
        guard requiredKeys.isSubset(of: observedKeys),
              observedKeys.isSubset(of: requiredKeys.union(["unitSelectors"])) else {
            throw NotikaRequestError.invalidRequestShape
        }
        try self.init(
            platform: container.decode(NotikaPlatform.self, forKey: .platform),
            testFile: container.decode(String.self, forKey: .testFile),
            testMethod: container.decode(String.self, forKey: .testMethod),
            device: container.decodeIfPresent(String.self, forKey: .device),
            makeRoute: kind == "legacy-make" ? container.decode(NotikaMakeRoute.self, forKey: .route) : nil,
            interactiveMode: kind == "interactive-macos" ? container.decode(NotikaInteractiveMode.self, forKey: .mode) : nil,
            documentationMode: kind == "docc" ? container.decode(NotikaDocumentationMode.self, forKey: .mode) : nil,
            unitSelectors: container.decodeIfPresent([String].self, forKey: .unitSelectors) ?? []
        )
    }
}
