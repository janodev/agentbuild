import AgentBuildCore
import Foundation
@testable import NotikaAdapter
import Testing

@Suite("Notika request reference parity")
struct NotikaActionRequestTests {
    @Test func closedCatalogMatchesPythonCanonicalRoutesAndAliases() throws {
        // Captured from LEGACY_MAKE_CANONICAL_ROUTES and LEGACY_MAKE_ROUTE_ALIASES.
        let canonical = [
            "build", "build-and-test", "build-release", "coverage", "coverage-file", "coverage-file-unit",
            "coverage-html", "coverage-json", "coverage-quiet", "results-brief", "results-bundle",
            "results-file", "results-summary", "test", "test-canvas-frame-pacing-performance", "test-coverage",
            "test-show-only-errors", "test-text-input-heavy-dependency-performance", "test-ui", "test-ui-file",
            "test-ui-only", "test-ui-only-file", "test-unit", "test-unit-coverage", "test-unit-file", "test-unit-focused",
        ]
        let aliases: [(String, String, NotikaPlatform?)] = [
            ("build-ios", "build", .iPadSimulator), ("build-macos", "build", .macOS),
            ("build-release-ios", "build-release", .iPadSimulator), ("build-release-macos", "build-release", .macOS),
            ("build-uikit", "build", .iPadSimulator), ("build-xcode", "build", nil),
            ("coverage-xcode-file", "coverage-file", nil), ("coverage-xcode-html", "coverage-html", nil),
            ("coverage-xcode-json", "coverage-json", nil), ("replay-fixed-semantic", "test-unit", .macOS),
            ("result-bundle", "results-bundle", nil), ("summary", "results-summary", nil),
            ("summary-brief", "results-brief", nil), ("summary-file", "results-file", nil),
            ("test-ios", "test", .iPadSimulator), ("test-macos", "test", .macOS),
            ("test-ui-ios", "test-ui", .iPadSimulator), ("test-ui-macos", "test-ui", .macOS),
            ("test-ui-visual", "test-ui-only", .macOS), ("test-uikit", "test", .iPadSimulator),
            ("test-unit-ios", "test-unit", .iPadSimulator), ("test-unit-macos", "test-unit", .macOS),
            ("test-xcode", "test", nil), ("test-xcode-coverage", "test-coverage", nil),
            ("test-xcode-file", "test-unit-file", nil), ("uitest-xcode-file", "test-ui-file", nil),
            ("unit-test", "test-unit", nil), ("unit-test-xcode", "test-unit", nil),
        ]
        #expect(NotikaMakeRoute.canonicalRoutes.map(\.rawValue).sorted() == canonical)
        #expect(Set(NotikaMakeRoute.allCases.map(\.rawValue)) == Set(canonical + aliases.map(\.0)))
        for (raw, expectedCanonical, expectedPlatform) in aliases {
            let route = try #require(NotikaMakeRoute(rawValue: raw))
            #expect(route.canonicalRoute.rawValue == expectedCanonical)
            #expect(route.requiredPlatform == expectedPlatform)
        }
        #expect(NotikaMakeRoute(rawValue: "shell") == nil)
        #expect(NotikaMakeRoute(rawValue: "docc-archive") == nil)
        #expect(NotikaMakeRoute.replayFixedSemantic.fixedTestFile == "CreateTwoRectanglesAndGroupReplayCapsuleTests")
        #expect(NotikaMakeRoute.testUIVisual.fixedTestFile == "NotikaUITests")
        #expect(NotikaMakeRoute.testUIVisual.fixedTestMethod == "testFixedWidthTextBoxVisualScreenshot")
    }

    @Test(arguments: requestOracles)
    func requestPayloadAndPropertiesMatchStaticPythonOracle(_ oracle: NotikaRequestOracle) throws {
        let expectedData = Data(oracle.json.utf8)
        let request = try JSONDecoder().decode(NotikaActionRequest.self, from: expectedData)
        #expect(request.canonicalMakeRoute?.rawValue == oracle.canonical)
        #expect(request.requiresOuterLease == oracle.lease)
        #expect(request.expectsResultBundle == oracle.result)
        let expected = try #require(JSONSerialization.jsonObject(with: expectedData) as? NSDictionary)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? NSDictionary)
        #expect(encoded.isEqual(expected))
        #expect(try JSONDecoder().decode(NotikaActionRequest.self, from: JSONEncoder().encode(request)) == request)
    }

    @Test func publicMakeDefaultsKeepPlatformAliasesAndExplicitOverrides() throws {
        let ordinary = try NotikaActionRequest(makeRoute: .build)
        #expect(ordinary.platform == .macOS)
        #expect(ordinary.device == nil)
        let ipad = try NotikaActionRequest(makeRoute: .buildIOS)
        #expect(ipad.platform == .iPadSimulator)
        #expect(ipad.device == NotikaActionRequest.defaultIPadDevice)
        #expect(try NotikaActionRequest(makeRoute: .build, platform: .iPadSimulator, device: "").device
                == NotikaActionRequest.defaultIPadDevice)
        #expect(try NotikaActionRequest(makeRoute: .build, platform: .iPadSimulator, device: "iPad Pro").device == "iPad Pro")
        #expect(throws: NotikaRequestError.expectedPlatform(.iPadSimulator)) {
            try NotikaActionRequest(makeRoute: .buildIOS, platform: .macOS)
        }
    }

    @Test(arguments: invalidRequests)
    func invalidRequestsFailAtTheReferenceBoundary(_ invalid: NotikaInvalidRequest) {
        #expect(throws: invalid.error) { try invalid.input.request() }
    }

    @Test func selectorTransportPreservesOrderSignaturesAndEscapedNames() throws {
        let selectors = ["ExampleTests/run(target:_:)", "ExampleTests/`Words and spaces`()", "OtherTests"]
        let transport = "ExampleTests/run(target:_:) ExampleTests/%60Words%20and%20spaces%60() OtherTests"
        #expect(try NotikaActionRequest.encodeUnitSelectors(selectors) == transport)
        #expect(try NotikaActionRequest.decodeUnitSelectors(transport) == selectors)
        #expect(try NotikaActionRequest.decodeUnitSelectors("") == [])
        #expect(try NotikaActionRequest.encodeUnitSelectors([]) == "")
        #expect(try NotikaActionRequest.encodeUnitSelectors(Array(selectors.reversed())) != transport)
    }

    @Test(arguments: ["ExampleTests/method", " ExampleTests", "ExampleTests ", "ExampleTests  OtherTests",
                      "ExampleTests\tOtherTests", "ExampleTests\n", "ExampleTests/%60Words%20%60()",
                      "ExampleTests/%60Words%2fmore%60()", "ExampleTests/`Words`()", "ExampleTests;exit 0",
                      "ExampleTests ExampleTests"])
    func noncanonicalOrHostileTransportIsRejected(_ transport: String) {
        #expect(throws: (any Error).self) { try NotikaActionRequest.decodeUnitSelectors(transport) }
    }

    @Test func transportByteLimitIsInclusiveAndIndependentOfRequestValidation() throws {
        let maximum = String(repeating: "a", count: NotikaActionRequest.maximumSelectorTransportBytes)
        #expect(try NotikaActionRequest.encodeUnitSelectors([maximum]) == maximum)
        #expect(try NotikaActionRequest.decodeUnitSelectors(maximum) == [maximum])
        let oversized = maximum + "a"
        #expect(throws: NotikaRequestError.oversizedSelectorTransport) {
            try NotikaActionRequest.encodeUnitSelectors([oversized])
        }
        #expect(throws: NotikaRequestError.oversizedSelectorTransport) {
            try NotikaActionRequest.decodeUnitSelectors(oversized)
        }
        // Python validates the request separately from its bounded Make transport.
        #expect(try NotikaActionRequest(makeRoute: .testUnitFocused, unitSelectors: [oversized]).unitSelectors == [oversized])
    }

    @Test(arguments: [#"{"platform":"macos-ui","file":"Tests","method":"test","device":null,"kind":"foreign"}"#,
                      #"{"platform":"macos","file":"Tests","method":"test","device":null}"#,
                      #"{"platform":"macos-ui","file":"","method":"","device":null,"kind":"legacy-make","route":"shell"}"#,
                      #"{"platform":"macos-ui","file":"","method":"","device":null,"kind":"interactive-macos","mode":"foreign"}"#,
                      #"{"platform":"macos-ui","file":"","method":"","device":null,"kind":"docc","mode":"foreign"}"#,
                      #"{"platform":"macos-ui","file":"","method":"","device":null,"kind":"legacy-make","route":"test-unit-focused","unitSelectors":[17]}"#,
                      #"{"platform":"macos-ui","file":"Tests","method":"test","device":null,"route":"build"}"#,
                      #"{"platform":"macos-ui","file":"","method":"","device":null,"kind":"legacy-make","route":"build","mode":"run"}"#,
                      #"{"platform":"macos-ui","kind":"legacy-make","route":"build"}"#])
    func decodingCannotCreateAnUnvalidatedTypedRequest(_ json: String) {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(NotikaActionRequest.self, from: Data(json.utf8)) }
    }
}

struct NotikaRequestOracle: Sendable {
    let json: String
    let canonical: String?
    let lease: Bool
    let result: Bool
}

private let requestOracles = [
    NotikaRequestOracle(json: #"{"device":null,"file":"ExampleUITests","method":"testExample","platform":"macos-ui"}"#,
                  canonical: nil, lease: false, result: true),
    NotikaRequestOracle(json: #"{"device":"iPad Air 13-inch (M4)","file":"ExampleUITests","method":"testExample","platform":"ipad-simulator"}"#,
                  canonical: nil, lease: true, result: true),
    NotikaRequestOracle(json: #"{"device":null,"file":"","kind":"legacy-make","method":"","platform":"macos-ui","route":"test-unit-focused","unitSelectors":["ExampleTests/run(target:_:)","ExampleTests/`Words and spaces`()"]}"#,
                  canonical: "test-unit-focused", lease: false, result: true),
    NotikaRequestOracle(json: #"{"device":null,"file":"Sources/Feature+Helpers.swift","kind":"legacy-make","method":"","platform":"macos-ui","route":"coverage-file"}"#,
                  canonical: "coverage-file", lease: true, result: true),
    NotikaRequestOracle(json: #"{"device":null,"file":"","kind":"interactive-macos","method":"","mode":"run","platform":"macos-ui"}"#,
                  canonical: nil, lease: true, result: false),
    NotikaRequestOracle(json: #"{"device":null,"file":"","kind":"docc","method":"","mode":"rendered","platform":"macos-ui"}"#,
                  canonical: nil, lease: false, result: false),
]

struct NotikaRequestInput: Sendable {
    var platform: NotikaPlatform = .macOS
    var testFile = ""
    var testMethod = ""
    var device: String? = nil
    var route: NotikaMakeRoute? = .build
    var interactive: NotikaInteractiveMode? = nil
    var documentation: NotikaDocumentationMode? = nil
    var selectors: [String] = []

    func request() throws -> NotikaActionRequest {
        try NotikaActionRequest(platform: platform, testFile: testFile, testMethod: testMethod, device: device,
                                makeRoute: route, interactiveMode: interactive, documentationMode: documentation,
                                unitSelectors: selectors)
    }
}

struct NotikaInvalidRequest: Sendable {
    let input: NotikaRequestInput
    let error: NotikaRequestError
}

private let invalidRequests = [
    NotikaInvalidRequest(input: NotikaRequestInput(route: .testUnitFocused), error: .emptyFocusedSelection),
    NotikaInvalidRequest(input: NotikaRequestInput(route: .testUnitFocused, selectors: ["Tests/method"]), error: .invalidUnitSelector("Tests/method")),
    NotikaInvalidRequest(input: NotikaRequestInput(route: .testUnitFocused, selectors: ["Tests", "Tests"]), error: .duplicateUnitSelectors),
    NotikaInvalidRequest(input: NotikaRequestInput(testFile: "Tests", route: .testUnitFocused, selectors: ["Tests"]), error: .mixedFocusedSelection),
    NotikaInvalidRequest(input: NotikaRequestInput(selectors: ["Tests"]), error: .unexpectedUnitSelectors),
    NotikaInvalidRequest(input: NotikaRequestInput(route: .testUnitFocused, selectors: ["Tests/`Trailing `()"]), error: .invalidUnitSelector("Tests/`Trailing `()")),
    NotikaInvalidRequest(input: NotikaRequestInput(route: .testUnitFocused, selectors: ["Tests/method(label)"]), error: .invalidUnitSelector("Tests/method(label)")),
    NotikaInvalidRequest(input: NotikaRequestInput(route: .testUnitFocused, selectors: ["Tésts"]), error: .invalidUnitSelector("Tésts")),
    NotikaInvalidRequest(input: NotikaRequestInput(testFile: "Tests.swift", route: .testUnitFile), error: .invalidTestFile),
    NotikaInvalidRequest(input: NotikaRequestInput(testFile: "Tests\n", route: .testUnitFile), error: .invalidTestFile),
    NotikaInvalidRequest(input: NotikaRequestInput(testFile: "Tests"), error: .unexpectedTestFile),
    NotikaInvalidRequest(input: NotikaRequestInput(testMethod: "testMethod", route: .testUnit), error: .unexpectedTestMethod),
    NotikaInvalidRequest(input: NotikaRequestInput(testFile: "Tests", testMethod: "test;exit", route: .testUIFile), error: .invalidTestMethod),
    NotikaInvalidRequest(input: NotikaRequestInput(testFile: "../Feature.swift", route: .coverageFile), error: .invalidCoverageFile),
    NotikaInvalidRequest(input: NotikaRequestInput(testFile: "/Feature.swift", route: .coverageFileUnit), error: .invalidCoverageFile),
    NotikaInvalidRequest(input: NotikaRequestInput(testFile: "Sources/Feature.m", route: .coverageFile), error: .invalidCoverageFile),
    NotikaInvalidRequest(input: NotikaRequestInput(route: nil), error: .invalidTestFile),
    NotikaInvalidRequest(input: NotikaRequestInput(testFile: "Tests", route: nil), error: .invalidTestMethod),
    NotikaInvalidRequest(input: NotikaRequestInput(interactive: .run), error: .incompatibleModes),
    NotikaInvalidRequest(input: NotikaRequestInput(documentation: .archive), error: .incompatibleModes),
    NotikaInvalidRequest(input: NotikaRequestInput(platform: .iPadSimulator, route: nil, interactive: .run), error: .expectedPlatform(.macOS)),
    NotikaInvalidRequest(input: NotikaRequestInput(testFile: "Tests", route: nil, documentation: .preview), error: .unexpectedTestOrDeviceSelectors),
    NotikaInvalidRequest(input: NotikaRequestInput(device: "iPad Pro"), error: .unexpectedDevice),
    NotikaInvalidRequest(input: NotikaRequestInput(platform: .iPadSimulator), error: .missingDevice),
    NotikaInvalidRequest(input: NotikaRequestInput(platform: .iPadSimulator, device: "iPad;exit"), error: .invalidDevice),
    NotikaInvalidRequest(input: NotikaRequestInput(route: .buildIOS), error: .expectedPlatform(.iPadSimulator)),
    NotikaInvalidRequest(input: NotikaRequestInput(platform: .iPadSimulator, device: "iPad Pro", route: .testUIOnly), error: .expectedPlatform(.macOS)),
    NotikaInvalidRequest(input: NotikaRequestInput(platform: .iPadSimulator, device: "iPad Pro", route: .testTextInputHeavyDependencyPerformance), error: .expectedPlatform(.macOS)),
    NotikaInvalidRequest(input: NotikaRequestInput(platform: .iPadSimulator, device: "iPad Pro", route: .testCanvasFramePacingPerformance), error: .expectedPlatform(.macOS)),
]
