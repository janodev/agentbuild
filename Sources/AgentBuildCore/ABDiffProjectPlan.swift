import Foundation

public enum ABDiffProjectAction: String, Codable, Sendable {
    case build, generate, run
}

public enum ABDiffProjectError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidRequest(String)
    case unsupportedRoute(String)
    case invalidRepository(String)
    case invalidToolObservation(String)
    case missingSimulator

    public var description: String {
        switch self {
        case .invalidRequest(let detail): "invalid ABDiff request: \(detail)"
        case .unsupportedRoute(let route): "ABDiff route has no managed implementation: \(route)"
        case .invalidRepository(let detail): "invalid ABDiff repository: \(detail)"
        case .invalidToolObservation(let detail): "invalid ABDiff tool observation: \(detail)"
        case .missingSimulator: "ABDiff simulator execution requires an outer SimLease SIMULATOR_ID"
        }
    }
}

/// A closed native workflow request. Selectors are literal UTF-8 argument data;
/// validation never evaluates them as shell text or substitutes Unicode spelling.
public struct ABDiffProjectRequest: Encodable, Sendable {
    public let repository: String
    public let action: ABDiffProjectAction
    public let route: String
    public let platform: String
    public let configuration: String
    public let file: String?
    public let method: String?
    public let onlyTesting: [String]
    public let device: String?
    public let cached: Bool

    public init(
        repository: String,
        action: ABDiffProjectAction = .build,
        route: String = "build",
        platform: String = "macos",
        configuration: String? = nil,
        file: String? = nil,
        method: String? = nil,
        onlyTesting: [String] = [],
        device: String? = nil,
        cached: Bool = false
    ) throws {
        guard Self.validAbsolutePath(repository) else {
            throw ABDiffProjectError.invalidRequest("repository must be an absolute path without control characters")
        }
        let canonicalPlatform: String
        switch platform.lowercased() {
        case "macos": canonicalPlatform = "macos"
        case "ios", "ipad", "ipad-simulator", "uikit": canonicalPlatform = "ipad-simulator"
        default: throw ABDiffProjectError.invalidRequest("unsupported platform \(platform)")
        }
        let selectedPlatform = Self.platformOverrides[route] ?? canonicalPlatform
        let canonicalRoute: String
        if action == .generate {
            guard ["build", "generate", "generate-cached"].contains(route) else {
                throw ABDiffProjectError.unsupportedRoute(route)
            }
            canonicalRoute = "generate"
        } else if action == .run {
            guard ["build", "run", "run-macos", "run-ios", "run-uikit", "run-ipad"].contains(route) else {
                throw ABDiffProjectError.unsupportedRoute(route)
            }
            canonicalRoute = "build"
        } else {
            canonicalRoute = Self.aliases[route] ?? route
            guard Self.nativeRoutes.contains(canonicalRoute) else {
                throw ABDiffProjectError.unsupportedRoute(route)
            }
        }
        if canonicalRoute == "cli-build", selectedPlatform != "macos" {
            throw ABDiffProjectError.invalidRequest("cli-build supports macos only")
        }
        let testing = Self.testRoutes.contains(canonicalRoute)
        let resolvedConfiguration = configuration ?? (canonicalRoute == "build-release" ? "Release"
            : testing ? "DebugUITests" : "Debug")
        guard ["Debug", "DebugUITests", "Release"].contains(resolvedConfiguration) else {
            throw ABDiffProjectError.invalidRequest("configuration must be Debug, DebugUITests, or Release")
        }
        let fileRoute = canonicalRoute == "test-unit-file" || canonicalRoute == "test-ui-file"
        if fileRoute {
            guard let file, Self.validSelectorComponent(file), !file.hasSuffix(".swift") else {
                throw ABDiffProjectError.invalidRequest("\(canonicalRoute) requires a test suite name in file, without .swift")
            }
        } else if file != nil {
            throw ABDiffProjectError.invalidRequest("file is supported only by test-unit-file and test-ui-file")
        }
        if let method {
            guard fileRoute, Self.validSelectorComponent(method) else {
                throw ABDiffProjectError.invalidRequest("method requires a focused test file and a literal method name")
            }
        }
        if canonicalRoute == "test-unit-focused" {
            guard !onlyTesting.isEmpty else {
                throw ABDiffProjectError.invalidRequest("test-unit-focused requires at least one only-testing selector")
            }
        } else if !onlyTesting.isEmpty {
            throw ABDiffProjectError.invalidRequest("only-testing selectors require test-unit-focused")
        }
        for selector in onlyTesting {
            let components = selector.split(separator: "/", omittingEmptySubsequences: false)
            guard (1...3).contains(components.count),
                  components.allSatisfy({ Self.validSelectorComponent(String($0)) }) else {
                throw ABDiffProjectError.invalidRequest("invalid only-testing selector")
            }
            if components.count == 3,
               components.first.map(String.init) != (selectedPlatform == "macos" ? "ABDiffTests" : "ABDiffIPadTests") {
                throw ABDiffProjectError.invalidRequest("only-testing selector names an unsupported target")
            }
        }
        if let device {
            guard selectedPlatform == "ipad-simulator", !device.isEmpty, Self.validText(device), !device.hasPrefix("-") else {
                throw ABDiffProjectError.invalidRequest("device must be an iPad simulator model name")
            }
        }
        guard action == .generate || !cached else {
            throw ABDiffProjectError.invalidRequest("cached is supported only by generation")
        }
        self.repository = repository
        self.action = action
        self.route = canonicalRoute
        self.platform = selectedPlatform
        self.configuration = resolvedConfiguration
        self.file = file
        self.method = method
        self.onlyTesting = onlyTesting
        self.device = device
        self.cached = cached || route == "generate-cached"
    }

    public var isTesting: Bool { Self.testRoutes.contains(route) }

    /// Broad routes include UI tests. Unit-only routes do not acquire desktop UI.
    public var requiresMacUI: Bool {
        platform == "macos" && (action == .run || Self.uiRoutes.contains(route))
    }

    public var needsOuterLease: Bool {
        requiresMacUI || (platform == "ipad-simulator" && (isTesting || action == .run))
    }

    private static let nativeRoutes: Set<String> = [
        "build", "build-and-test", "build-release", "cli-build", "docbuild",
        "test", "test-show-only-errors", "test-unit", "test-unit-file", "test-unit-focused",
        "test-ui", "test-ui-file", "test-ui-safe", "test-coverage", "test-unit-coverage",
    ]

    private static let testRoutes: Set<String> = [
        "build-and-test", "test", "test-show-only-errors", "test-unit", "test-unit-file",
        "test-unit-focused", "test-ui", "test-ui-file", "test-ui-safe", "test-coverage", "test-unit-coverage",
    ]

    private static let uiRoutes: Set<String> = [
        "build-and-test", "test", "test-show-only-errors", "test-ui", "test-ui-file", "test-ui-safe", "test-coverage",
    ]

    private static let aliases: [String: String] = [
        "build-xcode": "build", "build-ios": "build", "build-uikit": "build", "build-macos": "build",
        "build-release-ios": "build-release", "build-release-macos": "build-release",
        "test-xcode": "test", "test-ios": "test", "test-uikit": "test", "test-macos": "test",
        "unit-test": "test-unit", "unit-test-xcode": "test-unit",
        "test-unit-ios": "test-unit", "test-unit-macos": "test-unit", "test-xcode-file": "test-unit-file",
        "test-ui-ios": "test-ui", "test-ui-macos": "test-ui", "uitest-xcode-file": "test-ui-file",
        "test-xcode-coverage": "test-coverage",
    ]

    private static let platformOverrides: [String: String] = [
        "build-ios": "ipad-simulator", "build-uikit": "ipad-simulator", "build-release-ios": "ipad-simulator",
        "test-ios": "ipad-simulator", "test-uikit": "ipad-simulator", "test-unit-ios": "ipad-simulator",
        "test-ui-ios": "ipad-simulator", "run-ios": "ipad-simulator", "run-uikit": "ipad-simulator",
        "run-ipad": "ipad-simulator", "build-macos": "macos", "build-release-macos": "macos",
        "test-macos": "macos", "test-unit-macos": "macos", "test-ui-macos": "macos", "run-macos": "macos",
    ]

    fileprivate static func validText(_ value: String) -> Bool {
        !value.utf8.contains(where: { $0 < 32 || $0 == 127 })
    }

    fileprivate static func validAbsolutePath(_ value: String) -> Bool {
        value.hasPrefix("/") && validText(value)
    }

    private static func validSelectorComponent(_ value: String) -> Bool {
        !value.isEmpty && validText(value) && !value.hasPrefix("-") && !value.contains("/")
            && value != "." && value != ".."
    }
}

/// Read-only observations and exact native arguments. This value establishes no
/// lease, graph freshness, source custody, cache custody, or native outcome.
public struct ABDiffProjectPlan: Sendable {
    public let request: ABDiffProjectRequest
    public let repository: String
    public let cacheKey: String
    public let cacheDirectory: String
    public let workspace: String
    public let scheme: String
    public let destination: String
    public let needsOuterLease: Bool
    public let requiresMacUI: Bool
    public let logicalArguments: [String]
    public let xcodePlan: XcodeExecutionPlan?
    public let generatedPaths: [String]
    public let productPath: String
    public let toolIdentity: [String: String]

    public var admissionEstablished: Bool { false }

    public func jsonData() throws -> Data {
        struct Phase: Encodable {
            let arguments: [String]
            let requiresCompilation: Bool
        }
        struct Report: Encodable {
            let schemaVersion = 1
            let admissionEstablished = false
            let request: ABDiffProjectRequest
            let repository: String
            let cacheKey: String
            let cacheDirectory: String
            let workspace: String
            let scheme: String
            let destination: String
            let needsOuterLease: Bool
            let requiresMacUI: Bool
            let logicalArguments: [String]
            let phases: [Phase]
            let generatedPaths: [String]
            let productPath: String
            let toolIdentity: [String: String]
        }
        let report = Report(request: request, repository: repository, cacheKey: cacheKey,
                            cacheDirectory: cacheDirectory, workspace: workspace, scheme: scheme,
                            destination: destination, needsOuterLease: needsOuterLease, requiresMacUI: requiresMacUI,
                            logicalArguments: logicalArguments,
                            phases: xcodePlan?.phases.map { Phase(arguments: $0.arguments, requiresCompilation: $0.requiresCompilation) } ?? [],
                            generatedPaths: generatedPaths, productPath: productPath, toolIdentity: toolIdentity)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }
}

public enum ABDiffProjectPlanner {
    /// Observes only version and SDK metadata. Injected capture supports isolated
    /// contract fixtures; execution must admit this plan again beneath live locks.
    public static func plan(
        request: ABDiffProjectRequest,
        environment: [String: String],
        capture: (any RepositoryCommandCapturing)? = nil
    ) async throws -> ABDiffProjectPlan {
        let repository = try canonicalRepository(request.repository)
        let observer: any RepositoryCommandCapturing
        if let capture { observer = capture }
        else {
            observer = try RepositoryCommandCapture(outputLimit: 64 * 1_024, diagnosticLimit: 16 * 1_024,
                                                     timeout: .seconds(10))
        }
        let identity = try await toolIdentity(repository: repository, platform: request.platform,
                                              environment: environment, capture: observer)
        let unit = request.route.hasPrefix("test-unit")
        let scheme = request.route == "cli-build" ? "ABDiffCLI"
            : request.platform == "ipad-simulator" ? "ABDiffIPad" : unit ? "ABDiffTests" : "ABDiff"
        let key = try CanonicalJSONDigest.sha256(.object([
            "schemaVersion": .integer(1), "repository": .string(repository), "platform": .string(request.platform),
            "scheme": .string(scheme), "configuration": .string(request.configuration),
            "toolchain": .object(identity.mapValues { .string($0) }),
        ]))
        let cacheDirectory = repository + "/DerivedData/AgentCaches/abdiff-" + key
        let workspace = repository + "/ABDiff.xcworkspace"
        let destination = try destination(request: request, environment: environment)
        let generatedPaths = [repository + "/ABDiff.xcodeproj", workspace]
        let products = cacheDirectory + "/Build/Products/" + request.configuration
            + (request.platform == "ipad-simulator" ? "-iphonesimulator" : "")
        let product = products + (request.route == "cli-build" ? "/abd"
            : request.route == "docbuild" ? "/\(scheme).doccarchive" : "/\(request.platform == "ipad-simulator" ? "ABDiffIPad" : "ABDiff").app")
        let arguments: [String]
        let xcodePlan: XcodeExecutionPlan?
        if request.action == .generate {
            arguments = ["generate", "--no-open"]
            xcodePlan = nil
        } else {
            var native = ["-derivedDataPath", cacheDirectory, "-disableAutomaticPackageResolution",
                          request.isTesting ? "test" : request.route == "docbuild" ? "docbuild" : "build",
                          "-workspace", workspace, "-scheme", scheme, "-configuration", request.configuration,
                          "-destination", destination, "SDKROOT=\(identity["sdkPath"]!)"]
            if request.isTesting {
                let resultBundle = environment["AGENTBUILD_ABDIFF_RESULT_BUNDLE"]
                    ?? repository + "/Artifacts/AgentSessions/PLAN/Tests.xcresult"
                guard ABDiffProjectRequest.validAbsolutePath(resultBundle) else {
                    throw ABDiffProjectError.invalidRequest("result bundle must be an absolute path")
                }
                native += ["-parallel-testing-enabled", "NO", "-resultBundlePath", resultBundle]
                if request.route == "test-coverage" || request.route == "test-unit-coverage" {
                    native += ["-enableCodeCoverage", "YES"]
                }
                native += testSelectors(request: request)
            }
            arguments = native
            xcodePlan = try XcodeExecutionPlan(arguments: native)
        }
        return ABDiffProjectPlan(request: request, repository: repository, cacheKey: key, cacheDirectory: cacheDirectory,
                                 workspace: workspace, scheme: scheme, destination: destination,
                                 needsOuterLease: request.needsOuterLease, requiresMacUI: request.requiresMacUI,
                                 logicalArguments: arguments, xcodePlan: xcodePlan, generatedPaths: generatedPaths,
                                 productPath: product, toolIdentity: identity)
    }

    private static func canonicalRepository(_ path: String) throws -> String {
        let canonical = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical, isDirectory: &directory), directory.boolValue else {
            throw ABDiffProjectError.invalidRepository("repository directory does not exist")
        }
        for name in ["Project.swift", "Makefile"] {
            let attributes = try? FileManager.default.attributesOfItem(atPath: canonical + "/" + name)
            guard attributes?[.type] as? FileAttributeType == .typeRegular else {
                throw ABDiffProjectError.invalidRepository("missing regular \(name)")
            }
        }
        return canonical
    }

    private static func destination(request: ABDiffProjectRequest, environment: [String: String]) throws -> String {
        guard request.platform == "ipad-simulator" else { return "platform=macOS" }
        guard request.isTesting || request.action == .run else { return "generic/platform=iOS Simulator" }
        guard let identifier = environment["SIMULATOR_ID"], !identifier.isEmpty else {
            return "platform=iOS Simulator,id=SIMULATOR_ID"
        }
        guard UUID(uuidString: identifier) != nil else {
            throw ABDiffProjectError.invalidRequest("SIMULATOR_ID must be a simulator UUID")
        }
        return "platform=iOS Simulator,id=" + identifier
    }

    private static func testSelectors(request: ABDiffProjectRequest) -> [String] {
        let target = request.platform == "ipad-simulator" ? "ABDiffIPad" : "ABDiff"
        if request.route == "test-unit-focused" {
            return request.onlyTesting.map { selector in
                let prefix = target + "Tests"
                let full = selector == prefix || selector.hasPrefix(prefix + "/") ? selector : prefix + "/" + selector
                return "-only-testing:" + full
            }
        }
        if request.route.hasPrefix("test-unit") || request.route.hasPrefix("test-ui") {
            var selector = target + (request.route.hasPrefix("test-unit") ? "Tests" : "UITests")
            if let file = request.file { selector += "/" + file }
            if let method = request.method { selector += "/" + method }
            return ["-only-testing:" + selector]
        }
        return request.platform == "macos" ? ["-testPlan", "ABDiff"] : []
    }

    private static func toolIdentity(
        repository: String,
        platform: String,
        environment: [String: String],
        capture: any RepositoryCommandCapturing
    ) async throws -> [String: String] {
        func observe(_ arguments: [String], path: Bool = false) async throws -> String {
            let data = try await capture.capture(arguments: arguments, workingDirectory: repository, environment: environment)
            guard let text = String(data: data, encoding: .utf8) else {
                throw ABDiffProjectError.invalidToolObservation("non-UTF-8 response from \(arguments[0])")
            }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !value.utf8.contains(0),
                  !path || ABDiffProjectRequest.validAbsolutePath(value) else {
                throw ABDiffProjectError.invalidToolObservation("empty or invalid response from \(arguments[0])")
            }
            return value
        }
        let developerDirectory: String
        if let selected = environment["DEVELOPER_DIR"], !selected.isEmpty {
            guard ABDiffProjectRequest.validAbsolutePath(selected) else {
                throw ABDiffProjectError.invalidRequest("DEVELOPER_DIR must be an absolute path")
            }
            developerDirectory = selected
        } else {
            developerDirectory = try await observe(["xcode-select", "-p"], path: true)
        }
        let xcodebuild = try await observe(["xcrun", "--find", "xcodebuild"], path: true)
        let swift = try await observe(["xcrun", "--find", "swift"], path: true)
        let xcodeVersion = try await observe([xcodebuild, "-version"])
        let swiftVersion = try await observe([swift, "--version"])
        let sdk = platform == "macos" ? "macosx" : "iphonesimulator"
        let sdkPath = try await observe(["xcrun", "--sdk", sdk, "--show-sdk-path"], path: true)
        let sdkVersion = try await observe(["xcrun", "--sdk", sdk, "--show-sdk-version"])
        var identity = [
            "developerDirectory": developerDirectory, "xcodebuildPath": xcodebuild, "swiftPath": swift,
            "xcodeVersion": xcodeVersion, "swiftVersion": swiftVersion, "sdk": sdk,
            "sdkPath": sdkPath, "sdkVersion": sdkVersion,
        ]
        for name in ["TOOLCHAINS", "SDKROOT", "SWIFT_EXEC", "CC", "CXX", "LD"] {
            if let value = environment[name] { identity["environment." + name] = value }
        }
        return identity
    }
}
