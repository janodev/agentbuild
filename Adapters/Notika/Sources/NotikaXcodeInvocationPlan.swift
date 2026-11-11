import AgentBuildCore
import Foundation

public enum NotikaXcodePlanError: Error, Equatable, Sendable {
    case unsupportedRequest
    case invalidDestination
    case invalidCacheDirectory
    case invalidResultBundle
}

public enum NotikaXcodeAction: String, Codable, Sendable {
    case build
    case test
}

public enum NotikaXcodeTestSelector: Equatable, Sendable, Encodable {
    case onlyTesting(String)
    case onlyTestingBatch([String])
    case testPlan(String)

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.onlyTesting(let left), .onlyTesting(let right)), (.testPlan(let left), .testPlan(let right)):
            left.utf8.elementsEqual(right.utf8)
        case (.onlyTestingBatch(let left), .onlyTestingBatch(let right)):
            left.map { Data($0.utf8) } == right.map { Data($0.utf8) }
        default: false
        }
    }

    public var arguments: [String] {
        switch self {
        case .onlyTesting(let value): ["-only-testing:\(value)"]
        case .onlyTestingBatch(let values): values.map { "-only-testing:\($0)" }
        case .testPlan(let value): ["-testPlan", value]
        }
    }

    private enum CodingKeys: String, CodingKey { case option, value, values }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .onlyTesting(let value):
            try container.encode("-only-testing", forKey: .option)
            try container.encode(value, forKey: .value)
        case .onlyTestingBatch(let values):
            try container.encode("-only-testing", forKey: .option)
            try container.encode(values, forKey: .values)
        case .testPlan(let value):
            try container.encode("-testPlan", forKey: .option)
            try container.encode(value, forKey: .value)
        }
    }
}

/// One logical native invocation, before XcodeExecutionPlan splits test into
/// compilation and execution phases. Metadata matches Notika's reference plan.
public struct NotikaXcodeInvocation: Equatable, Sendable, Encodable {
    public let ordinal: Int
    public let segment: String
    public let action: NotikaXcodeAction
    public let workspace: String
    public let destination: String
    public let scheme: String
    public let configuration: String?
    public let testSelector: NotikaXcodeTestSelector?
    public let cacheDirectory: String
    public let resultBundle: String?
    public let arguments: [String]

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.ordinal == rhs.ordinal && lhs.action == rhs.action
            && lhs.segment.utf8.elementsEqual(rhs.segment.utf8)
            && lhs.workspace.utf8.elementsEqual(rhs.workspace.utf8)
            && lhs.destination.utf8.elementsEqual(rhs.destination.utf8)
            && lhs.scheme.utf8.elementsEqual(rhs.scheme.utf8)
            && lhs.configuration.map { Data($0.utf8) } == rhs.configuration.map { Data($0.utf8) }
            && lhs.testSelector == rhs.testSelector
            && lhs.cacheDirectory.utf8.elementsEqual(rhs.cacheDirectory.utf8)
            && lhs.resultBundle.map { Data($0.utf8) } == rhs.resultBundle.map { Data($0.utf8) }
            && lhs.arguments.map { Data($0.utf8) } == rhs.arguments.map { Data($0.utf8) }
    }

    private enum CodingKeys: String, CodingKey {
        case ordinal, segment, action, workspace, destination, scheme, configuration
        case testSelector, cacheDirectory, resultBundle, arguments
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ordinal, forKey: .ordinal)
        try container.encode(segment, forKey: .segment)
        try container.encode(action, forKey: .action)
        try container.encode(workspace, forKey: .workspace)
        try container.encode(destination, forKey: .destination)
        try container.encode(scheme, forKey: .scheme)
        if let configuration { try container.encode(configuration, forKey: .configuration) }
        else { try container.encodeNil(forKey: .configuration) }
        if let testSelector { try container.encode(testSelector, forKey: .testSelector) }
        else { try container.encodeNil(forKey: .testSelector) }
        try container.encode(cacheDirectory, forKey: .cacheDirectory)
        if let resultBundle { try container.encode(resultBundle, forKey: .resultBundle) }
        else { try container.encodeNil(forKey: .resultBundle) }
        try container.encode(arguments, forKey: .arguments)
    }
}

/// Pure Notika adapter planning. Inputs must already be admitted by the caller;
/// syntactic validation here grants no path custody, device lease, or authority.
/// DocC uses a separate reference pipeline and is deliberately outside this plan.
public struct NotikaXcodeInvocationPlan: Equatable, Sendable, Encodable {
    public let request: NotikaActionRequest
    public let effectiveMakeRoute: NotikaMakeRoute
    public let invocations: [NotikaXcodeInvocation]

    public init(
        request: NotikaActionRequest,
        destination: String,
        cacheDirectory: String,
        resultBundle: String
    ) throws {
        guard !request.isDocumentation else { throw NotikaXcodePlanError.unsupportedRequest }
        guard Self.validDestination(destination, platform: request.platform) else {
            throw NotikaXcodePlanError.invalidDestination
        }
        guard Self.validAbsolutePath(cacheDirectory) else { throw NotikaXcodePlanError.invalidCacheDirectory }
        guard Self.validAbsolutePath(resultBundle) else { throw NotikaXcodePlanError.invalidResultBundle }
        let route = request.makeRoute ?? (request.isInteractive ? .build
            : request.platform == .iPadSimulator ? .testUIFile : .testUIOnlyFile)
        let canonical = route.canonicalRoute
        let segments: [NotikaMakeRoute] = [.buildAndTest, .test, .testShowOnlyErrors].contains(canonical)
            ? [.build, .test] : [canonical]
        self.request = request
        effectiveMakeRoute = route
        invocations = segments.enumerated().map { ordinal, segment in
            Self.invocation(request: request, route: route, segment: segment, ordinal: ordinal,
                            destination: destination, cacheDirectory: cacheDirectory, resultBundle: resultBundle)
        }
    }

    /// Encodes the exact reference list, without adding request or wrapper fields.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for invocation in invocations { try container.encode(invocation) }
    }

    private static func invocation(
        request: NotikaActionRequest,
        route: NotikaMakeRoute,
        segment: NotikaMakeRoute,
        ordinal: Int,
        destination: String,
        cacheDirectory: String,
        resultBundle: String
    ) -> NotikaXcodeInvocation {
        let canonical = route.canonicalRoute
        let action: NotikaXcodeAction = [.build, .buildRelease].contains(segment) ? .build : .test
        let ipad = request.platform == .iPadSimulator
        let appScheme = ipad ? "NotikaiPad" : "Notika"
        let uiScheme = ipad ? "NotikaiPadUITestsOnly" : "NotikaUITestsOnly"
        let textPerformance = canonical == .testTextInputHeavyDependencyPerformance
        let canvasPerformance = canonical == .testCanvasFramePacingPerformance
        let uiTest = action == .test && [.testUI, .testUIFile, .testUIOnly, .testUIOnlyFile].contains(canonical)
        let scheme = textPerformance ? "NotikaTextPerformanceTests"
            : canvasPerformance ? "NotikaCanvasPerformance" : uiTest ? uiScheme : appScheme
        let configuration: String? = action == .build
            ? (segment == .buildRelease || textPerformance ? "Release" : "Debug")
            : textPerformance ? "Release" : canvasPerformance ? "Debug" : nil
        let selector = action == .test ? testSelector(request: request, route: route) : nil
        let result = action == .test ? resultBundle : nil
        var arguments = ["-derivedDataPath", cacheDirectory, "-disableAutomaticPackageResolution", action.rawValue]
        if action == .test {
            arguments += ["-parallel-testing-enabled", "NO", "-resultBundlePath", resultBundle]
            if allCoverageRoutes.contains(canonical) || unitCoverageRoutes.contains(canonical) {
                arguments += ["-enableCodeCoverage", "YES"]
            }
        }
        arguments += ["-workspace", "Notika.xcworkspace", "-scheme", scheme]
        if let configuration { arguments += ["-configuration", configuration] }
        arguments += ["-destination", destination]
        if let selector { arguments += selector.arguments }
        if textPerformance { arguments += ["ENABLE_TESTABILITY=YES"] }
        if canvasPerformance { arguments += ["SWIFT_OPTIMIZATION_LEVEL=-O", "SWIFT_COMPILATION_MODE=wholemodule"] }
        if [.testUIOnly, .testUIOnlyFile].contains(canonical) {
            arguments += ["CODE_SIGNING_ALLOWED=NO", "CODE_SIGN_IDENTITY=", "DEVELOPMENT_TEAM="]
        }
        return NotikaXcodeInvocation(ordinal: ordinal, segment: segment.rawValue, action: action,
                                     workspace: "Notika.xcworkspace", destination: destination, scheme: scheme,
                                     configuration: configuration, testSelector: selector,
                                     cacheDirectory: cacheDirectory, resultBundle: result, arguments: arguments)
    }

    private static func testSelector(request: NotikaActionRequest, route: NotikaMakeRoute) -> NotikaXcodeTestSelector {
        let canonical = route.canonicalRoute
        let ipad = request.platform == .iPadSimulator
        let appScheme = ipad ? "NotikaiPad" : "Notika"
        let unitTarget = ipad ? "NotikaiPadTests" : "NotikaTests"
        let uiTarget = ipad ? "NotikaiPadUITests" : "NotikaUITests"
        if canonical == .testUnitFocused {
            return .onlyTestingBatch(request.unitSelectors.map { "\(unitTarget)/\($0)" })
        }
        if canonical == .testTextInputHeavyDependencyPerformance {
            return .onlyTesting("NotikaTextPerformanceTests/MacTextInputHeavyDependencyPerformanceTests")
        }
        if canonical == .testCanvasFramePacingPerformance {
            return .onlyTesting("NotikaCanvasPerformanceUITests/CanvasPerformanceUITests/testFramePacingMatrix")
        }
        if route == .replayFixedSemantic {
            return .onlyTesting("\(unitTarget)/CreateTwoRectanglesAndGroupReplayCapsuleTests")
        }
        if route == .testUIVisual {
            return .onlyTesting("\(uiTarget)/NotikaUITests/testFixedWidthTextBoxVisualScreenshot")
        }
        if [.buildAndTest, .test, .testShowOnlyErrors].contains(canonical) || allCoverageRoutes.contains(canonical) {
            return .testPlan(appScheme)
        }
        if canonical == .testUnit || unitCoverageRoutes.contains(canonical)
            || [.resultsBrief, .resultsBundle, .resultsFile, .resultsSummary].contains(canonical) {
            return .onlyTesting(unitTarget)
        }
        if canonical == .testUnitFile { return .onlyTesting("\(unitTarget)/\(request.testFile)") }
        if [.testUI, .testUIOnly].contains(canonical) { return .onlyTesting(uiTarget) }
        // Only validated UI file routes reach this final selection branch.
        let suffix = request.testMethod.isEmpty ? "" : "/\(request.testMethod)"
        return .onlyTesting("\(uiTarget)/\(request.testFile)\(suffix)")
    }

    private static let allCoverageRoutes: Set<NotikaMakeRoute> = [.coverageFile, .coverageHTML, .coverageJSON, .coverageQuiet, .testCoverage]
    private static let unitCoverageRoutes: Set<NotikaMakeRoute> = [.coverage, .coverageFileUnit, .testUnitCoverage]

    private static func validDestination(_ destination: String, platform: NotikaPlatform) -> Bool {
        if platform == .macOS { return destination == "platform=macOS,arch=arm64" }
        let prefix = "platform=iOS Simulator,id="
        guard destination.hasPrefix(prefix) else { return false }
        let identifier = destination.dropFirst(prefix.count)
        guard let first = identifier.utf8.first, asciiAlphanumeric(first) else { return false }
        return identifier.utf8.allSatisfy { asciiAlphanumeric($0) || $0 == 45 }
    }

    private static func asciiAlphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    private static func validAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.utf8.contains(where: { $0 < 32 || $0 == 127 })
            && !path.contains("//") && (path == "/" || !path.hasSuffix("/"))
            && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }
}
