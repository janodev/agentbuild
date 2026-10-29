@testable import AgentBuildCore
import Darwin
import Foundation
import Testing

@Suite("ABDiff native command planning")
struct ABDiffProjectPlanTests {
    @Test(arguments: ABDiffPlanCase.all)
    func projectRoutesSelectRealSchemesAndTestTargets(_ scenario: ABDiffPlanCase) async throws {
        let fixture = try ABDiffPlanFixture()
        defer { fixture.remove() }
        let capture = ABDiffToolCapture()
        let request = try ABDiffProjectRequest(repository: fixture.path, route: scenario.route, platform: scenario.platform)
        let plan = try await ABDiffProjectPlanner.plan(request: request, environment: fixture.environment, capture: capture)
        #expect(plan.scheme == scenario.scheme)
        #expect(plan.request.configuration == scenario.configuration)
        #expect(argument("-configuration", in: plan.logicalArguments) == scenario.configuration)
        #expect(argument("-scheme", in: plan.logicalArguments) == scenario.scheme)
        #expect(argument("-workspace", in: plan.logicalArguments)?.hasSuffix("ABDiff.xcworkspace") == true)
        #expect(plan.needsOuterLease == scenario.needsLease)
        #expect(plan.requiresMacUI == scenario.macUI)
        #expect(plan.logicalArguments.contains("-allowProvisioningUpdates") == (scenario.platform == "macos"))
        #expect(ABDiffLeaseBoundary.requiresOuterLease(for: request) == scenario.needsLease)
        if let selector = scenario.selector {
            #expect(plan.logicalArguments.contains("-only-testing:" + selector))
        }
        let physical = try #require(plan.xcodePlan)
        #expect(physical.phases.map(\.requiresCompilation) == (scenario.isTest ? [true, false] : [true]))
        if scenario.isTest {
            #expect(physical.phases[0].arguments.contains("build-for-testing"))
            #expect(physical.phases[1].arguments.contains("test-without-building"))
            #expect(!physical.phases[0].arguments.contains("-resultBundlePath"))
            #expect(physical.phases[1].compilationResource == nil)
        }
        let probes = await capture.arguments
        #expect(!probes.isEmpty)
        #expect(probes.allSatisfy { !$0.contains("build") && !$0.contains("test") && !$0.contains("generate") })
        #expect(!probes.flatMap { $0 }.contains { $0.lowercased().contains("simslim") || $0.lowercased().contains("simlease") })
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "/Artifacts"))
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "/DerivedData"))
    }

    @Test(arguments: ["Debug", "DebugUITests", "Release"])
    func explicitConfigurationsRemainInTheNativeInvocation(_ configuration: String) async throws {
        let fixture = try ABDiffPlanFixture()
        defer { fixture.remove() }
        for platform in ["macos", "ipad-simulator"] {
            let request = try ABDiffProjectRequest(repository: fixture.path, platform: platform, configuration: configuration)
            let plan = try await ABDiffProjectPlanner.plan(request: request, environment: fixture.environment, capture: ABDiffToolCapture())
            #expect(argument("-configuration", in: plan.logicalArguments) == configuration)
            #expect(plan.request.configuration == configuration)
            #expect(plan.destination == (platform == "macos" ? "platform=macOS" : "generic/platform=iOS Simulator"))
        }
    }

    @Test func focusedSwiftTestingSelectorsAreLiteralOrderedArgumentsInBothPhysicalPhases() async throws {
        let fixture = try ABDiffPlanFixture()
        defer { fixture.remove() }
        let selectors = ["FeatureTests/run(value:_:)", "LiteralTests/`café $(touch pwn) words`()"]
        let request = try ABDiffProjectRequest(repository: fixture.path, route: "test-unit-focused", platform: "ipad-simulator", onlyTesting: selectors)
        let plan = try await ABDiffProjectPlanner.plan(request: request, environment: fixture.environment, capture: ABDiffToolCapture())
        let expected = selectors.map { "-only-testing:ABDiffIPadTests/" + $0 }
        #expect(plan.logicalArguments.filter { $0.hasPrefix("-only-testing:") } == expected)
        for phase in try #require(plan.xcodePlan).phases {
            #expect(phase.arguments.filter { $0.hasPrefix("-only-testing:") } == expected)
        }
        #expect(plan.destination == "platform=iOS Simulator,id=" + ABDiffPlanFixture.simulatorID)
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "/pwn"))
    }

    @Test(arguments: ["test-unit", "test-unit-coverage"])
    func broadMacUnitRunsIncludeTheIndependentTextCoreWhenPresent(_ route: String) async throws {
        let fixture = try ABDiffPlanFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.directory.appendingPathComponent("Tests/ABDiffTextCoreTests"),
            withIntermediateDirectories: true
        )
        let request = try ABDiffProjectRequest(repository: fixture.path, route: route)
        let plan = try await ABDiffProjectPlanner.plan(request: request, environment: fixture.environment, capture: ABDiffToolCapture())
        let expected = ["-only-testing:ABDiffTests", "-only-testing:ABDiffTextCoreTests"]
        for phase in try #require(plan.xcodePlan).phases {
            #expect(phase.arguments.filter { $0.hasPrefix("-only-testing:") } == expected)
        }
        let focused = try ABDiffProjectRequest(repository: fixture.path, route: "test-unit-file", file: "ParserTests")
        let focusedPlan = try await ABDiffProjectPlanner.plan(request: focused, environment: fixture.environment, capture: ABDiffToolCapture())
        #expect(focusedPlan.logicalArguments.filter { $0.hasPrefix("-only-testing:") } == ["-only-testing:ABDiffTests/ParserTests"])
    }

    @Test func focusedMacSelectorsCanNameTheIndependentTextCore() async throws {
        let fixture = try ABDiffPlanFixture()
        defer { fixture.remove() }
        let selectors = ["ABDiffTextCoreTests/KernelTests/comparesUnicode()", "ABDiffTests/ParserTests/parses()"]
        let request = try ABDiffProjectRequest(repository: fixture.path, route: "test-unit-focused", onlyTesting: selectors)
        let plan = try await ABDiffProjectPlanner.plan(request: request, environment: fixture.environment, capture: ABDiffToolCapture())
        for phase in try #require(plan.xcodePlan).phases {
            #expect(phase.arguments.filter { $0.hasPrefix("-only-testing:") } == selectors.map { "-only-testing:" + $0 })
        }
    }

    @Test func transportTestsRejectTheIPadPlatformBeforePlanning() {
        #expect(throws: (any Error).self) {
            try ABDiffProjectRequest(repository: "/fixture/ABDiff", route: "test-transport", platform: "ipad-simulator")
        }
    }

    @Test func fileAndMethodBecomeOneTargetQualifiedSelector() async throws {
        let fixture = try ABDiffPlanFixture()
        defer { fixture.remove() }
        let request = try ABDiffProjectRequest(repository: fixture.path, route: "test-unit-file", file: "ParserTests", method: "parses(value:_:)")
        let plan = try await ABDiffProjectPlanner.plan(request: request, environment: fixture.environment, capture: ABDiffToolCapture())
        #expect(plan.logicalArguments.filter { $0.hasPrefix("-only-testing:") } == ["-only-testing:ABDiffTests/ParserTests/parses(value:_:)"])
    }

    @Test func generationHasNoXcodePhasesAndInteractiveRunNeedsMacUIOwnership() async throws {
        let fixture = try ABDiffPlanFixture()
        defer { fixture.remove() }
        let generate = try await ABDiffProjectPlanner.plan(
            request: ABDiffProjectRequest(repository: fixture.path, action: .generate, cached: true),
            environment: fixture.environment, capture: ABDiffToolCapture())
        #expect(generate.request.cached)
        #expect(generate.xcodePlan == nil)
        #expect(!generate.needsOuterLease)
        #expect(!generate.requiresMacUI)
        #expect(generate.generatedPaths.contains { $0.hasSuffix("ABDiff.xcodeproj") })
        #expect(generate.generatedPaths.contains { $0.hasSuffix("ABDiff.xcworkspace") })
        let run = try await ABDiffProjectPlanner.plan(
            request: ABDiffProjectRequest(repository: fixture.path, action: .run),
            environment: fixture.environment, capture: ABDiffToolCapture())
        #expect(run.needsOuterLease)
        #expect(run.requiresMacUI)
        #expect(run.scheme == "ABDiff")
        #expect(try #require(run.xcodePlan).phases.map(\.requiresCompilation) == [true])
    }

    @Test func readOnlyPlanJSONCannotBeMistakenForOwnedExecution() async throws {
        let fixture = try ABDiffPlanFixture()
        defer { fixture.remove() }
        let plan = try await ABDiffProjectPlanner.plan(
            request: ABDiffProjectRequest(repository: fixture.path), environment: fixture.environment, capture: ABDiffToolCapture())
        let object = try #require(JSONSerialization.jsonObject(with: plan.jsonData()) as? [String: Any])
        #expect(object["admissionEstablished"] as? Bool == false)
        #expect(object["repository"] as? String == fixture.path)
        #expect(object["exitCode"] == nil)
        #expect(object["status"] as? String != "succeeded")
        let request = try #require(object["request"] as? [String: Any])
        #expect(request["allowedSourceChanges"] as? [String] == [])
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.path).sorted() == ["Makefile", "Project.swift"])
    }

    @Test func sourceAllowancesRemainInPlanEvidenceWithoutChangingNativeInputsOrCacheCompatibility() async throws {
        let fixture = try ABDiffPlanFixture()
        defer { fixture.remove() }
        let strict = try await ABDiffProjectPlanner.plan(
            request: ABDiffProjectRequest(repository: fixture.path, route: "build-release"),
            environment: fixture.environment, capture: ABDiffToolCapture())
        let paths = ["Versions/z.xcconfig", "Versions/[a] $(touch pwn).xcconfig", "Versions/z.xcconfig"]
        let allowed = try await ABDiffProjectPlanner.plan(
            request: ABDiffProjectRequest(repository: fixture.path, route: "build-release", allowedSourceChanges: paths),
            environment: fixture.environment, capture: ABDiffToolCapture())
        #expect(allowed.request.allowedSourceChanges == [paths[1], paths[0]])
        #expect(allowed.logicalArguments == strict.logicalArguments)
        #expect(allowed.cacheKey == strict.cacheKey)
        let object = try #require(JSONSerialization.jsonObject(with: allowed.jsonData()) as? [String: Any])
        let request = try #require(object["request"] as? [String: Any])
        #expect(request["allowedSourceChanges"] as? [String] == [paths[1], paths[0]])
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "/pwn"))
    }

    @Test(arguments: ["", "/tmp/version", ".", "..", "./version", "../version", "Versions/../version",
                      "Versions/./version", "Versions//version", "Versions/", "Versions/line\nfeed", ".git/config"])
    func malformedSourceAllowanceCannotReachPlanning(_ path: String) {
        #expect(throws: (any Error).self) {
            try ABDiffProjectRequest(repository: "/fixture/ABDiff", allowedSourceChanges: [path])
        }
    }

    @Test func generationCannotUseSourceAllowances() {
        #expect(throws: (any Error).self) {
            try ABDiffProjectRequest(repository: "/fixture/ABDiff", action: .generate,
                                    allowedSourceChanges: ["BuildNumber.xcconfig"])
        }
    }

    @Test(arguments: ["not-a-route", "test-unit-file --file Injected", "build; touch pwn"])
    func unknownRoutesNeverBecomeCommands(_ route: String) {
        #expect(throws: (any Error).self) { try ABDiffProjectRequest(repository: "/fixture/ABDiff", route: route) }
    }

    @Test(arguments: ["Suite\nInjected", "Suite\0Injected", "-Suite", "Suite//Other"])
    func malformedFileOrMethodIsRejectedBeforePlanning(_ value: String) {
        #expect(throws: (any Error).self) {
            try ABDiffProjectRequest(repository: "/fixture/ABDiff", route: "test-unit-file", file: value)
        }
        #expect(throws: (any Error).self) {
            try ABDiffProjectRequest(repository: "/fixture/ABDiff", route: "test-unit-file", file: "Suite", method: value)
        }
    }

    @Test func ambiguousOrIncompleteSelectorsCannotExpandIntoAnUnfocusedTestRun() {
        #expect(throws: (any Error).self) { try ABDiffProjectRequest(repository: "/fixture/ABDiff", route: "test-unit-file") }
        #expect(throws: (any Error).self) { try ABDiffProjectRequest(repository: "/fixture/ABDiff", route: "test-unit-file", method: "testExample") }
        #expect(throws: (any Error).self) { try ABDiffProjectRequest(repository: "/fixture/ABDiff", route: "test-unit-focused") }
        #expect(throws: (any Error).self) {
            try ABDiffProjectRequest(repository: "/fixture/ABDiff", route: "test-unit-file", file: "Suite", onlyTesting: ["OtherSuite"])
        }
        #expect(throws: (any Error).self) { try ABDiffProjectRequest(repository: "/fixture/ABDiff", route: "build", file: "Suite") }
        #expect(throws: (any Error).self) { try ABDiffProjectRequest(repository: "/fixture/ABDiff", configuration: "Unknown") }
        #expect(throws: (any Error).self) { try ABDiffProjectRequest(repository: "/fixture/ABDiff", platform: "watchos") }
    }

    @Test func repositoryMarkersAreCheckedBeforeToolProbes() async throws {
        let fixture = try ABDiffPlanFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(atPath: fixture.path + "/Project.swift")
        let capture = ABDiffToolCapture()
        await #expect(throws: (any Error).self) {
            try await ABDiffProjectPlanner.plan(request: ABDiffProjectRequest(repository: fixture.path), environment: fixture.environment, capture: capture)
        }
        #expect(await capture.arguments.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "/Artifacts"))
    }

    @Test func repositoryAliasesResolveToPhysicalPathsAcceptedByArtifactCustody() async throws {
        let fixture = try ABDiffPlanFixture()
        defer { fixture.remove() }
        let alias = fixture.path + "/repository-alias"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: ".")
        let plan = try await ABDiffProjectPlanner.plan(
            request: ABDiffProjectRequest(repository: alias),
            environment: fixture.environment, capture: ABDiffToolCapture())
        #expect(plan.repository == fixture.path)
        let retained = try RetainedArtifactDirectory(path: plan.repository)
        defer { try? retained.close() }
        try retained.revalidate()
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "/Artifacts"))
    }

    @Test func uiAdmissionRequiresOneMatchingOuterLease() throws {
        let mac = try ABDiffProjectRequest(repository: "/fixture/ABDiff", route: "test-ui")
        let simulator = try ABDiffProjectRequest(repository: "/fixture/ABDiff", route: "test-unit", platform: "ipad-simulator")
        #expect(throws: (any Error).self) { try ABDiffLeaseBoundary.admit(request: mac, environment: [:]) }
        #expect(throws: (any Error).self) { try ABDiffLeaseBoundary.admit(request: simulator, environment: [:]) }
        let macEnvironment = ["SIMLEASE_SESSION_ID": "fixture", "SIMLEASE_MACOS_UI": "1", "SIMLEASE_HOST_RESOURCE": "macos-ui"]
        try ABDiffLeaseBoundary.admit(request: mac, environment: macEnvironment)
        #expect(throws: (any Error).self) {
            try ABDiffLeaseBoundary.admit(request: mac, environment: macEnvironment.merging(["SIMULATOR_ID": ABDiffPlanFixture.simulatorID]) { _, new in new })
        }
        let simulatorEnvironment = ["SIMLEASE_SESSION_ID": "fixture", "SIMULATOR_ID": ABDiffPlanFixture.simulatorID, "SIMULATOR_UDID": ABDiffPlanFixture.simulatorID]
        try ABDiffLeaseBoundary.admit(request: simulator, environment: simulatorEnvironment)
        for conflict in [["SIMULATOR_UDID": "22222222-2222-3333-4444-555555555555"], ["SIMLEASE_MACOS_UI": "1"], ["SIMULATOR_ID": "not-a-uuid"]] {
            #expect(throws: (any Error).self) {
                try ABDiffLeaseBoundary.admit(request: simulator, environment: simulatorEnvironment.merging(conflict) { _, new in new })
            }
        }
        let unit = try ABDiffProjectRequest(repository: "/fixture/ABDiff", route: "test-unit")
        try ABDiffLeaseBoundary.admit(request: unit, environment: [:])
    }

    @Test func toolResolutionPreservesTheAliasUsedByDispatchingShims() async throws {
        let fixture = try ABDiffPlanFixture()
        defer { fixture.remove() }
        let dispatcher = fixture.directory.appendingPathComponent("mise")
        let alias = fixture.directory.appendingPathComponent("tuist")
        let script = #"""
        #!/bin/sh
        case "${0##*/}" in
          tuist) printf '%s\n' "tuist:$1" ;;
          *) printf '%s\n' "wrong-dispatch:${0##*/}:$1"; exit 64 ;;
        esac
        """#
        try Data((script + "\n").utf8).write(to: dispatcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dispatcher.path)
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "mise")
        let resolved = try abdiffResolveTool("tuist", environment: ["PATH": fixture.path])
        #expect(resolved == alias.path)
        #expect(resolved != alias.resolvingSymlinksInPath().path)
        let result = try await CommandRunner().run(executable: resolved, arguments: ["generate"], workingDirectory: fixture.path)
        #expect(result.termination == .exited(0))
        #expect(result.standardOutput == "tuist:generate\n")
        #expect(result.standardError.isEmpty)
    }

    private func argument(_ option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

struct ABDiffPlanCase: Sendable {
    let route: String
    let platform: String
    let scheme: String
    let configuration: String
    let selector: String?
    let isTest: Bool
    let needsLease: Bool
    let macUI: Bool

    static let all: [Self] = [
        .init(route: "build", platform: "macos", scheme: "ABDiff", configuration: "Debug", selector: nil, isTest: false, needsLease: false, macUI: false),
        .init(route: "build-release", platform: "macos", scheme: "ABDiff", configuration: "Release", selector: nil, isTest: false, needsLease: false, macUI: false),
        .init(route: "test-unit", platform: "macos", scheme: "ABDiffTests", configuration: "DebugUITests", selector: "ABDiffTests", isTest: true, needsLease: false, macUI: false),
        .init(route: "test-transport", platform: "macos", scheme: "ABDiffMergetoolTests", configuration: "DebugUITests", selector: "ABDiffMergetoolTests/SemanticControlTransportTests", isTest: true, needsLease: true, macUI: true),
        .init(route: "test-ui", platform: "macos", scheme: "ABDiff", configuration: "DebugUITests", selector: "ABDiffUITests", isTest: true, needsLease: true, macUI: true),
        .init(route: "test", platform: "macos", scheme: "ABDiff", configuration: "DebugUITests", selector: nil, isTest: true, needsLease: true, macUI: true),
        .init(route: "build-and-test", platform: "macos", scheme: "ABDiff", configuration: "DebugUITests", selector: nil, isTest: true, needsLease: true, macUI: true),
        .init(route: "test-coverage", platform: "macos", scheme: "ABDiff", configuration: "DebugUITests", selector: nil, isTest: true, needsLease: true, macUI: true),
        .init(route: "test-unit-coverage", platform: "macos", scheme: "ABDiffTests", configuration: "DebugUITests", selector: "ABDiffTests", isTest: true, needsLease: false, macUI: false),
        .init(route: "build", platform: "ipad-simulator", scheme: "ABDiffIPad", configuration: "Debug", selector: nil, isTest: false, needsLease: false, macUI: false),
        .init(route: "test-unit", platform: "ipad-simulator", scheme: "ABDiffIPad", configuration: "DebugUITests", selector: "ABDiffIPadTests", isTest: true, needsLease: true, macUI: false),
        .init(route: "test-ui", platform: "ipad-simulator", scheme: "ABDiffIPad", configuration: "DebugUITests", selector: "ABDiffIPadUITests", isTest: true, needsLease: true, macUI: false),
        .init(route: "cli-build", platform: "macos", scheme: "ABDiffCLI", configuration: "Debug", selector: nil, isTest: false, needsLease: false, macUI: false),
        .init(route: "docbuild", platform: "macos", scheme: "ABDiff", configuration: "Debug", selector: nil, isTest: false, needsLease: false, macUI: false),
    ]
}

struct ABDiffPlanFixture: Sendable {
    static let simulatorID = "11111111-2222-3333-4444-555555555555"
    let directory: URL
    var path: String { directory.path }
    var environment: [String: String] { ["DEVELOPER_DIR": "/Fixture/Xcode/Developer", "SIMULATOR_ID": Self.simulatorID, "PATH": "/usr/bin:/bin"] }

    init() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentbuild-abdiff-" + UUID().uuidString + " café $(literal) `argv`", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        guard let resolved = temporary.path.withCString({ realpath($0, nil) }) else {
            try? FileManager.default.removeItem(at: temporary)
            throw ABDiffProjectError.invalidRepository("cannot resolve fixture directory")
        }
        defer { free(resolved) }
        directory = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        try Data("// Isolated ABDiff manifest fixture\n".utf8).write(to: directory.appendingPathComponent("Project.swift"))
        try Data("# Isolated ABDiff Make fixture\n".utf8).write(to: directory.appendingPathComponent("Makefile"))
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

actor ABDiffToolCapture: RepositoryCommandCapturing {
    private(set) var arguments: [[String]] = []

    func capture(arguments: [String], workingDirectory: String, environment: [String: String]) async throws -> Data {
        self.arguments.append(arguments)
        let value: String
        switch arguments {
        case ["xcode-select", "-p"]: value = "/Fixture/Xcode/Developer"
        case ["xcrun", "--find", "xcodebuild"]: value = "/Fixture/Xcode/Developer/usr/bin/xcodebuild"
        case ["xcrun", "--find", "swift"]: value = "/Fixture/Xcode/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
        case ["/Fixture/Xcode/Developer/usr/bin/xcodebuild", "-version"]: value = "Xcode 27.0\nBuild version 18A123"
        case ["/Fixture/Xcode/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift", "--version"]: value = "Apple Swift version 6.4"
        case ["xcrun", "--sdk", "macosx", "--show-sdk-path"]: value = "/Fixture/Xcode/Developer/SDKs/MacOSX27.sdk"
        case ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"]: value = "/Fixture/Xcode/Developer/SDKs/iPhoneSimulator27.sdk"
        case ["xcrun", "--sdk", "macosx", "--show-sdk-version"], ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"]: value = "27.0"
        default: throw ABDiffFixtureError.unexpectedProbe(arguments)
        }
        return Data((value + "\n").utf8)
    }
}

enum ABDiffFixtureError: Error {
    case unexpectedProbe([String])
}
