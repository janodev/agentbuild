@testable import AgentBuildCore
import Foundation
import Testing

@Suite("Notika cache profile reference parity")
struct NotikaCacheProfileTests {
    @Test(arguments: cacheProfileCases)
    func closedFamiliesMatchThePythonReference(_ fixture: CacheProfileCase) throws {
        let profile = NotikaCacheProfile(request: try fixture.request())
        #expect(profile.scheme.rawValue == fixture.scheme)
        #expect(profile.configuration.rawValue == fixture.configuration)
        #expect(profile.destinationFamily.rawValue == fixture.destinationFamily)
        #expect(profile.buildFlags == fixture.buildFlags)
    }

    @Test func sourceAndToolObservationsProduceTheExactCompatibilityMaterial() throws {
        let source = profileSource()
        let toolchain = NotikaToolchainIdentity(keyMaterial: .object(["versions": .object(["swift": .string("fixture swift")])]))
        let profile = NotikaCacheProfile(request: try NotikaActionRequest(makeRoute: .testUIOnly))
        let identity = try profile.identity(source: source, toolchain: toolchain)
        #expect(identity.keyMaterial == .object([
            "canonicalWorktree": .string("/tmp/profile-worktree"),
            "toolchainHash": .string(try toolchain.digest()),
            "gitlinks": .array([]),
            "submoduleStatusDigest": .string(String(repeating: "1", count: 64)),
            "submoduleWorktreeDigest": .string(String(repeating: "2", count: 64)),
            "projectGraphDigest": .string(String(repeating: "3", count: 64)),
            "generatedGraphDigest": .string(String(repeating: "4", count: 64)),
            "resolvedDependenciesDigest": .string(String(repeating: "5", count: 64)),
            "scheme": .string("NotikaUITestsOnly"),
            "configuration": .string("Debug"),
            "destinationFamily": .string("macos-arm64"),
            "buildFlags": .array([.string("-disableAutomaticPackageResolution")]),
        ]))
        #expect(identity.purpose == nil)
    }

    @Test func ordinaryAppAndUIRequestsShareStorageButRetainExecutionIdentities() throws {
        let source = profileSource()
        let toolchain = NotikaToolchainIdentity(keyMaterial: .object([:]))
        let app = try NotikaCacheProfile(request: NotikaActionRequest(makeRoute: .build))
            .identity(source: source, toolchain: toolchain)
        let ui = try NotikaCacheProfile(request: NotikaActionRequest(makeRoute: .testUIOnly))
            .identity(source: source, toolchain: toolchain)
        #expect(try app.currentStorageDigest() == ui.currentStorageDigest())
        #expect(try app.cacheKey() == ui.cacheKey())
        #expect(try app.executionDigest() != ui.executionDigest())
        let release = try NotikaCacheProfile(request: NotikaActionRequest(makeRoute: .buildRelease))
            .identity(source: source, toolchain: toolchain)
        #expect(try release.cacheKey() != app.cacheKey())
        let ipad = try NotikaCacheProfile(request: NotikaActionRequest(makeRoute: .buildIOS))
            .identity(source: source, toolchain: toolchain)
        #expect(try ipad.cacheKey() != app.cacheKey())
    }

    @Test func sourceChangesRemainSeparateFromTheCompatibleBuildFamily() throws {
        let toolchain = NotikaToolchainIdentity(keyMaterial: .object([:]))
        let profile = NotikaCacheProfile(request: try NotikaActionRequest(makeRoute: .build))
        let initial = try profile.identity(source: profileSource(), toolchain: toolchain)
        let changedHead = try profile.identity(source: profileSource(head: String(repeating: "b", count: 40)), toolchain: toolchain)
        #expect(initial == changedHead)
        let changedGraph = try profile.identity(source: profileSource(graph: String(repeating: "6", count: 64)), toolchain: toolchain)
        #expect(try initial.cacheKey() != changedGraph.cacheKey())
        let changedGenerated = try profile.identity(source: profileSource(generated: String(repeating: "7", count: 64)), toolchain: toolchain)
        #expect(try initial.cacheKey() == changedGenerated.cacheKey())
        #expect(try initial.executionDigest() != changedGenerated.executionDigest())
    }
}

struct CacheProfileCase: Sendable {
    let route: NotikaMakeRoute?
    let platform: NotikaPlatform
    let mode: String?
    let scheme: String
    let configuration: String
    let destinationFamily: String
    let buildFlags: [String]

    init(route: NotikaMakeRoute? = nil, platform: NotikaPlatform = .macOS, mode: String? = nil,
         scheme: String, configuration: String = "Debug", flags: [String] = []) {
        self.route = route
        self.platform = platform
        self.mode = mode
        self.scheme = scheme
        self.configuration = configuration
        destinationFamily = platform == .iPadSimulator ? "ios-simulator-arm64" : "macos-arm64"
        buildFlags = ["-disableAutomaticPackageResolution"] + flags
    }

    func request() throws -> NotikaActionRequest {
        if let route {
            return try NotikaActionRequest(makeRoute: route, platform: platform,
                                           testFile: route.acceptsTestFile ? "FeatureTests" : "")
        }
        if mode == "run" { return try NotikaActionRequest(platform: .macOS, interactiveMode: .run) }
        if let mode, let documentation = NotikaDocumentationMode(rawValue: mode) {
            return try NotikaActionRequest(platform: .macOS, documentationMode: documentation)
        }
        return try NotikaActionRequest(platform: platform, testFile: "FeatureTests", testMethod: "testExample",
                                       device: platform == .iPadSimulator ? NotikaActionRequest.defaultIPadDevice : nil)
    }
}

private let cacheProfileCases: [CacheProfileCase] = [
    .init(route: .build, scheme: "Notika"),
    .init(route: .buildIOS, platform: .iPadSimulator, scheme: "NotikaiPad"),
    .init(route: .testUIOnly, scheme: "NotikaUITestsOnly"),
    .init(route: .testUIOnlyFile, scheme: "NotikaUITestsOnly"),
    .init(route: .testUIIOS, platform: .iPadSimulator, scheme: "NotikaiPadUITestsOnly"),
    .init(route: .buildReleaseMacOS, scheme: "Notika", configuration: "Release"),
    .init(route: .buildReleaseIOS, platform: .iPadSimulator, scheme: "NotikaiPad", configuration: "Release"),
    .init(route: .testTextInputHeavyDependencyPerformance, scheme: "NotikaTextPerformanceTests", configuration: "Release",
          flags: ["ENABLE_TESTABILITY=YES"]),
    .init(route: .testCanvasFramePacingPerformance, scheme: "NotikaCanvasPerformance",
          flags: ["SWIFT_OPTIMIZATION_LEVEL=-O", "SWIFT_COMPILATION_MODE=wholemodule"]),
    .init(scheme: "NotikaUITestsOnly"),
    .init(platform: .iPadSimulator, scheme: "NotikaiPadUITestsOnly"),
    .init(mode: "run", scheme: "Notika"),
    .init(mode: "archive", scheme: "Notika"),
    .init(mode: "rendered", scheme: "Notika"),
    .init(mode: "preview", scheme: "Notika"),
]

private func profileSource(head: String = String(repeating: "a", count: 40),
                           graph: String = String(repeating: "3", count: 64),
                           generated: String = String(repeating: "4", count: 64)) -> NotikaSourceIdentity {
    NotikaSourceIdentity(
        canonicalWorktree: "/tmp/profile-worktree", head: head, gitlinks: [],
        statusDigest: String(repeating: "a", count: 64), stagedDiffDigest: String(repeating: "b", count: 64),
        unstagedDiffDigest: String(repeating: "c", count: 64),
        submoduleStatusDigest: String(repeating: "1", count: 64),
        submoduleWorktreeDigest: String(repeating: "2", count: 64),
        projectGraphDigest: graph, generatedGraphDigest: generated,
        resolvedDependenciesDigest: String(repeating: "5", count: 64), keyMaterial: .object([:])
    )
}
