import AgentBuildCore
import CryptoKit
import Foundation
@testable import NotikaAdapter
import Testing

@Suite("Notika native invocation reference parity")
struct NotikaXcodeInvocationPlanTests {
    @Test func oracleCoversTheWholeClosedCatalog() {
        #expect(Set(notikaPlanOracles.map(\.route)) == Set(NotikaMakeRoute.allCases))
        #expect(notikaPlanOracles.count == 90)
    }

    @Test(arguments: notikaPlanOracles)
    func everyAcceptedRouteAndPlatformMatchesStaticPythonOracle(_ oracle: NotikaPlanOracle) throws {
        let request = try oracle.request()
        let plan = try fixturePlan(request)
        #expect(plan.effectiveMakeRoute == oracle.route)
        #expect(try planDigest(plan) == oracle.sha256)
    }

    @Test(arguments: notikaAuxiliaryPlanOracles)
    func focusedUIAndInteractivePlansUseTheReferenceEffectiveRoute(_ oracle: NotikaAuxiliaryPlanOracle) throws {
        let request = try JSONDecoder().decode(NotikaActionRequest.self, from: Data(oracle.requestJSON.utf8))
        let plan = try fixturePlan(request)
        #expect(plan.request.makeRoute == nil)
        #expect(plan.effectiveMakeRoute == oracle.effectiveRoute)
        #expect(try planDigest(plan) == oracle.sha256)
    }

    @Test func testHasTwoLogicalSegmentsWithExactArgumentOrderAndNullMetadata() throws {
        let plan = try fixturePlan(NotikaActionRequest(makeRoute: .test))
        #expect(plan.invocations.map(\.segment) == ["build", "test"])
        #expect(plan.invocations.map(\.ordinal) == [0, 1])
        #expect(plan.invocations[0].arguments == [
            "-derivedDataPath", notikaPlanCache, "-disableAutomaticPackageResolution", "build",
            "-workspace", "Notika.xcworkspace", "-scheme", "Notika", "-configuration", "Debug",
            "-destination", "platform=macOS,arch=arm64",
        ])
        #expect(plan.invocations[1].arguments == [
            "-derivedDataPath", notikaPlanCache, "-disableAutomaticPackageResolution", "test",
            "-parallel-testing-enabled", "NO", "-resultBundlePath", notikaPlanResult,
            "-workspace", "Notika.xcworkspace", "-scheme", "Notika",
            "-destination", "platform=macOS,arch=arm64", "-testPlan", "Notika",
        ])
        let objects = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [[String: Any]])
        #expect(objects[0]["testSelector"] is NSNull)
        #expect(objects[0]["resultBundle"] is NSNull)
        #expect(objects[1]["configuration"] is NSNull)
        #expect(plan.invocations[0].resultBundle == nil)
        #expect(plan.invocations[1].configuration == nil)
    }

    @Test func focusedSelectorsStayLiteralOrderedAndTargetQualified() throws {
        let request = try NotikaActionRequest(makeRoute: .testUnitFocused, platform: .iPadSimulator,
                                             unitSelectors: notikaPlanSelectors)
        let plan = try fixturePlan(request)
        let invocation = try #require(plan.invocations.first)
        let expected = notikaPlanSelectors.map { "NotikaiPadTests/\($0)" }
        #expect(invocation.testSelector == .onlyTestingBatch(expected))
        #expect(Array(invocation.arguments.suffix(2)) == expected.map { "-only-testing:\($0)" })
        #expect(invocation.configuration == nil)
        #expect(invocation.scheme == "NotikaiPad")
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [[String: Any]])
        let selector = try #require(encoded[0]["testSelector"] as? [String: Any])
        #expect(selector["value"] == nil)
        #expect(selector["values"] as? [String] == expected)
    }

    @Test func literalAbsolutePathsRemainSingleUnmodifiedArguments() throws {
        let cache = "/tmp/$(whoami) `literal` café"
        let result = "/tmp/Session $literal/result.xcresult"
        let plan = try NotikaXcodeInvocationPlan(request: NotikaActionRequest(makeRoute: .testUnit),
                                                destination: "platform=macOS,arch=arm64",
                                                cacheDirectory: cache, resultBundle: result)
        #expect(plan.invocations[0].arguments[1] == cache)
        #expect(plan.invocations[0].arguments[7] == result)
    }

    @Test func planEqualityPreservesUnicodePathSpelling() throws {
        let request = try NotikaActionRequest(makeRoute: .testUnit)
        let composed = try NotikaXcodeInvocationPlan(
            request: request, destination: "platform=macOS,arch=arm64",
            cacheDirectory: "/tmp/caf\u{e9}", resultBundle: notikaPlanResult
        )
        let decomposed = try NotikaXcodeInvocationPlan(
            request: request, destination: "platform=macOS,arch=arm64",
            cacheDirectory: "/tmp/cafe\u{301}", resultBundle: notikaPlanResult
        )
        #expect(composed != decomposed)
        #expect(composed.invocations[0] != decomposed.invocations[0])
        #expect(NotikaXcodeTestSelector.testPlan("caf\u{e9}") != .testPlan("cafe\u{301}"))
    }

    @Test(arguments: ["relative/cache", "/tmp/../cache", "/tmp/./cache", "/tmp//cache", "/tmp/cache/",
                      "/tmp/cache\0suffix", "/tmp/cache\nsuffix"])
    func malformedCachePathsAreRejected(_ path: String) throws {
        let request = try NotikaActionRequest(makeRoute: .build)
        #expect(throws: NotikaXcodePlanError.invalidCacheDirectory) {
            try NotikaXcodeInvocationPlan(request: request, destination: "platform=macOS,arch=arm64",
                                          cacheDirectory: path, resultBundle: notikaPlanResult)
        }
    }

    @Test(arguments: ["result.xcresult", "/tmp/../result.xcresult", "/tmp/result\0.xcresult"])
    func malformedResultPathsAreRejectedEvenForBuilds(_ path: String) throws {
        let request = try NotikaActionRequest(makeRoute: .build)
        #expect(throws: NotikaXcodePlanError.invalidResultBundle) {
            try NotikaXcodeInvocationPlan(request: request, destination: "platform=macOS,arch=arm64",
                                          cacheDirectory: notikaPlanCache, resultBundle: path)
        }
    }

    @Test(arguments: ["platform=macOS", "platform=macOS,arch=x86_64", "platform=macOS,arch=arm64\n",
                      "platform=iOS Simulator,id=ABC-123"])
    func macDestinationMustMatchThePlatformProfile(_ destination: String) throws {
        let request = try NotikaActionRequest(makeRoute: .build)
        #expect(throws: NotikaXcodePlanError.invalidDestination) {
            try NotikaXcodeInvocationPlan(request: request, destination: destination,
                                          cacheDirectory: notikaPlanCache, resultBundle: notikaPlanResult)
        }
    }

    @Test(arguments: ["platform=iOS Simulator,name=iPad Pro", "platform=iOS Simulator,id=",
                      "platform=iOS Simulator,id=ABC-123,arch=arm64", "platform=iOS Simulator,id=ABC/123",
                      "platform=iOS Simulator,id=ABC-123\0", "platform=macOS,arch=arm64"])
    func simulatorDestinationMustBindOneLiteralIdentifier(_ destination: String) throws {
        let request = try NotikaActionRequest(makeRoute: .buildIOS)
        #expect(throws: NotikaXcodePlanError.invalidDestination) {
            try NotikaXcodeInvocationPlan(request: request, destination: destination,
                                          cacheDirectory: notikaPlanCache, resultBundle: notikaPlanResult)
        }
    }

    @Test(arguments: NotikaDocumentationMode.allCases)
    func docsRemainOutsideThisReferencePlan(_ mode: NotikaDocumentationMode) throws {
        let request = try NotikaActionRequest(platform: .macOS, documentationMode: mode)
        #expect(throws: NotikaXcodePlanError.unsupportedRequest) { try fixturePlan(request) }
    }
}

struct NotikaPlanOracle: Sendable {
    let route: NotikaMakeRoute
    let platform: NotikaPlatform
    let sha256: String

    func request() throws -> NotikaActionRequest {
        try NotikaActionRequest(
            platform: platform,
            testFile: route.acceptsTestFile ? "FeatureTests" : route.acceptsCoverageFile ? "Sources/Feature+Helpers.swift" : "",
            testMethod: route.acceptsTestMethod ? "testExample" : "",
            device: platform == .iPadSimulator ? NotikaActionRequest.defaultIPadDevice : nil,
            makeRoute: route,
            unitSelectors: route.canonicalRoute == .testUnitFocused ? notikaPlanSelectors : []
        )
    }
}

struct NotikaAuxiliaryPlanOracle: Sendable {
    let requestJSON: String
    let effectiveRoute: NotikaMakeRoute
    let sha256: String
}

private let notikaPlanCache = "/tmp/Notika Agent Cache"
private let notikaPlanResult = "/tmp/Notika Session/result.xcresult"
private let notikaPlanSelectors = ["FeatureTests/run(target:_:)", "FeatureTests/`Words and spaces`()"]

private func fixturePlan(_ request: NotikaActionRequest) throws -> NotikaXcodeInvocationPlan {
    let destination = request.platform == .macOS ? "platform=macOS,arch=arm64" : "platform=iOS Simulator,id=ABC-123"
    return try NotikaXcodeInvocationPlan(request: request, destination: destination,
                                        cacheDirectory: notikaPlanCache, resultBundle: notikaPlanResult)
}

private func planDigest(_ plan: NotikaXcodeInvocationPlan) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return SHA256.hash(data: try encoder.encode(plan)).map { String(format: "%02x", $0) }.joined()
}

// Static SHA-256 vectors cover the complete sorted, compact Python plan JSON:
// every argv element, selector shape, segment, nullable field, and metadata value.
// Generated once from _xcode_invocation_plan; tests require no Python runtime.
private let notikaPlanOracles = [
    NotikaPlanOracle(route: .build, platform: .macOS, sha256: "404f494bf0c7cf8247eda8755ff4067407672fb74f42d83fa62ca348b3c7126b"),
    NotikaPlanOracle(route: .build, platform: .iPadSimulator, sha256: "72696f35c60cf6b8ac1ae8471c90a3c74503a92715f3a9aecdc528e39a1f6f70"),
    NotikaPlanOracle(route: .buildAndTest, platform: .macOS, sha256: "37f3f6173a275a637cc46a8c869a3762e17286dfa62657ad360f05016b9346ff"),
    NotikaPlanOracle(route: .buildAndTest, platform: .iPadSimulator, sha256: "13ea2b62f87ad1165ceb0b09d7e6e2fb84e3eb643477d1b156e068ded454439b"),
    NotikaPlanOracle(route: .buildIOS, platform: .iPadSimulator, sha256: "72696f35c60cf6b8ac1ae8471c90a3c74503a92715f3a9aecdc528e39a1f6f70"),
    NotikaPlanOracle(route: .buildMacOS, platform: .macOS, sha256: "404f494bf0c7cf8247eda8755ff4067407672fb74f42d83fa62ca348b3c7126b"),
    NotikaPlanOracle(route: .buildRelease, platform: .macOS, sha256: "ed18fcf5233d6c95001f9288fff749ceee97f34e3d2b31d790c306c5f384fd4b"),
    NotikaPlanOracle(route: .buildRelease, platform: .iPadSimulator, sha256: "fa44a331108d00cd689d09fe267e11c5f0d0ef8939d57d68872fdf0f27b2cce5"),
    NotikaPlanOracle(route: .buildReleaseIOS, platform: .iPadSimulator, sha256: "fa44a331108d00cd689d09fe267e11c5f0d0ef8939d57d68872fdf0f27b2cce5"),
    NotikaPlanOracle(route: .buildReleaseMacOS, platform: .macOS, sha256: "ed18fcf5233d6c95001f9288fff749ceee97f34e3d2b31d790c306c5f384fd4b"),
    NotikaPlanOracle(route: .buildUIKit, platform: .iPadSimulator, sha256: "72696f35c60cf6b8ac1ae8471c90a3c74503a92715f3a9aecdc528e39a1f6f70"),
    NotikaPlanOracle(route: .buildXcode, platform: .macOS, sha256: "404f494bf0c7cf8247eda8755ff4067407672fb74f42d83fa62ca348b3c7126b"),
    NotikaPlanOracle(route: .buildXcode, platform: .iPadSimulator, sha256: "72696f35c60cf6b8ac1ae8471c90a3c74503a92715f3a9aecdc528e39a1f6f70"),
    NotikaPlanOracle(route: .coverage, platform: .macOS, sha256: "ecc7212752d47dfa7ade1d23348e91617d4aa0ba33a049eb4e7379067cca9bbd"),
    NotikaPlanOracle(route: .coverage, platform: .iPadSimulator, sha256: "9489ec096e228f0c1d8cc62545187de8ee703e8047b35841b86f9cbdb6324d9a"),
    NotikaPlanOracle(route: .coverageFile, platform: .macOS, sha256: "3079dc18baa9227df584cd1e74abd5e65f8b7c35ae746d60a2b1d838557070a2"),
    NotikaPlanOracle(route: .coverageFile, platform: .iPadSimulator, sha256: "6813560fd4475081eb38ab9d1b627ad09a3be3265edaf3bfafd7e230b56c7a5b"),
    NotikaPlanOracle(route: .coverageFileUnit, platform: .macOS, sha256: "ec53b5bd3b8b52a32513a45491f9b78c90ed31a6203cde4dd34042e0d167c595"),
    NotikaPlanOracle(route: .coverageFileUnit, platform: .iPadSimulator, sha256: "75a058863b72d1194428dddfb3b284ee5ac794d85c71deeb5c81ece0f687a22b"),
    NotikaPlanOracle(route: .coverageHTML, platform: .macOS, sha256: "aed9fe0b52957cfb5b21ef6341bcbebe47293edb38f82bfce6a11b49733de52b"),
    NotikaPlanOracle(route: .coverageHTML, platform: .iPadSimulator, sha256: "2a4953e8b1e9a1964b27b03d1e48eea517d0aa41b950a304c2ae3c253687a755"),
    NotikaPlanOracle(route: .coverageJSON, platform: .macOS, sha256: "a5e2458942526fd6e0cf0424fdbf258241b319c42fb67580d85c9550a9be6627"),
    NotikaPlanOracle(route: .coverageJSON, platform: .iPadSimulator, sha256: "7ad897eb7bba0e0e653efe43a058695a013bb9708c6787b2b20a9b297e4b81f2"),
    NotikaPlanOracle(route: .coverageQuiet, platform: .macOS, sha256: "285ffb240c7d5a4ed86a452beb0e984b2a922489debfb5a0ce7a227d81e2767b"),
    NotikaPlanOracle(route: .coverageQuiet, platform: .iPadSimulator, sha256: "8ceeaa0a73dc2e06a0243adc9c6d946bcf132c18d291a3dd959e274e258fbab9"),
    NotikaPlanOracle(route: .coverageXcodeFile, platform: .macOS, sha256: "3079dc18baa9227df584cd1e74abd5e65f8b7c35ae746d60a2b1d838557070a2"),
    NotikaPlanOracle(route: .coverageXcodeFile, platform: .iPadSimulator, sha256: "6813560fd4475081eb38ab9d1b627ad09a3be3265edaf3bfafd7e230b56c7a5b"),
    NotikaPlanOracle(route: .coverageXcodeHTML, platform: .macOS, sha256: "aed9fe0b52957cfb5b21ef6341bcbebe47293edb38f82bfce6a11b49733de52b"),
    NotikaPlanOracle(route: .coverageXcodeHTML, platform: .iPadSimulator, sha256: "2a4953e8b1e9a1964b27b03d1e48eea517d0aa41b950a304c2ae3c253687a755"),
    NotikaPlanOracle(route: .coverageXcodeJSON, platform: .macOS, sha256: "a5e2458942526fd6e0cf0424fdbf258241b319c42fb67580d85c9550a9be6627"),
    NotikaPlanOracle(route: .coverageXcodeJSON, platform: .iPadSimulator, sha256: "7ad897eb7bba0e0e653efe43a058695a013bb9708c6787b2b20a9b297e4b81f2"),
    NotikaPlanOracle(route: .replayFixedSemantic, platform: .macOS, sha256: "d2a5a74219adf1ad7c29139800e577493f5eb172df3aceda69ce5c2509ba3b2b"),
    NotikaPlanOracle(route: .resultBundle, platform: .macOS, sha256: "670459ca1803b04c137143aedf6d08ca67457a20c0dde98ba778b48d1ed74433"),
    NotikaPlanOracle(route: .resultBundle, platform: .iPadSimulator, sha256: "2606adacf578598d9b1a32cd13c0e5194e7abb9646f84945e803b1f986e7dbaf"),
    NotikaPlanOracle(route: .resultsBrief, platform: .macOS, sha256: "0e8fedc7c5a6ff58d767979ba1301d62b81fc754d364da5b7ee4f4d53e2e832e"),
    NotikaPlanOracle(route: .resultsBrief, platform: .iPadSimulator, sha256: "009d5b6d560c377333042ccf63ad5aa9a11c9f7de2b1bec79e86e837bb5e6bdc"),
    NotikaPlanOracle(route: .resultsBundle, platform: .macOS, sha256: "670459ca1803b04c137143aedf6d08ca67457a20c0dde98ba778b48d1ed74433"),
    NotikaPlanOracle(route: .resultsBundle, platform: .iPadSimulator, sha256: "2606adacf578598d9b1a32cd13c0e5194e7abb9646f84945e803b1f986e7dbaf"),
    NotikaPlanOracle(route: .resultsFile, platform: .macOS, sha256: "28b276aa56e254d1fcd109da8a3a2206052bec9f5bd136e62709c99c099d82ea"),
    NotikaPlanOracle(route: .resultsFile, platform: .iPadSimulator, sha256: "64335eae39fa0dc3fe53fcd7915b125a0e4ee3c8410f069b47073c59ad3d8961"),
    NotikaPlanOracle(route: .resultsSummary, platform: .macOS, sha256: "26975813a7d349f170e0c03c3dd9b071bf90b72ea58550c6a5b2b68388940949"),
    NotikaPlanOracle(route: .resultsSummary, platform: .iPadSimulator, sha256: "797938a08fd17d1df8d8d732b855f9212136d56bdcb2cadca9613b3e93cbfc02"),
    NotikaPlanOracle(route: .summary, platform: .macOS, sha256: "26975813a7d349f170e0c03c3dd9b071bf90b72ea58550c6a5b2b68388940949"),
    NotikaPlanOracle(route: .summary, platform: .iPadSimulator, sha256: "797938a08fd17d1df8d8d732b855f9212136d56bdcb2cadca9613b3e93cbfc02"),
    NotikaPlanOracle(route: .summaryBrief, platform: .macOS, sha256: "0e8fedc7c5a6ff58d767979ba1301d62b81fc754d364da5b7ee4f4d53e2e832e"),
    NotikaPlanOracle(route: .summaryBrief, platform: .iPadSimulator, sha256: "009d5b6d560c377333042ccf63ad5aa9a11c9f7de2b1bec79e86e837bb5e6bdc"),
    NotikaPlanOracle(route: .summaryFile, platform: .macOS, sha256: "28b276aa56e254d1fcd109da8a3a2206052bec9f5bd136e62709c99c099d82ea"),
    NotikaPlanOracle(route: .summaryFile, platform: .iPadSimulator, sha256: "64335eae39fa0dc3fe53fcd7915b125a0e4ee3c8410f069b47073c59ad3d8961"),
    NotikaPlanOracle(route: .test, platform: .macOS, sha256: "37f3f6173a275a637cc46a8c869a3762e17286dfa62657ad360f05016b9346ff"),
    NotikaPlanOracle(route: .test, platform: .iPadSimulator, sha256: "13ea2b62f87ad1165ceb0b09d7e6e2fb84e3eb643477d1b156e068ded454439b"),
    NotikaPlanOracle(route: .testCanvasFramePacingPerformance, platform: .macOS, sha256: "43d287086bcb9231985dff15e6ff6db320c72b8b7d733cb098c40bd8bf3d1717"),
    NotikaPlanOracle(route: .testCoverage, platform: .macOS, sha256: "f7f9e139cbfb80a14cddb9e3e65897b32793c6f65671db8acb23216542bc19e1"),
    NotikaPlanOracle(route: .testCoverage, platform: .iPadSimulator, sha256: "14561f10f78c8772cf21ec047b802651bab514a36ff87854aa1984ef8afdf6c9"),
    NotikaPlanOracle(route: .testIOS, platform: .iPadSimulator, sha256: "13ea2b62f87ad1165ceb0b09d7e6e2fb84e3eb643477d1b156e068ded454439b"),
    NotikaPlanOracle(route: .testMacOS, platform: .macOS, sha256: "37f3f6173a275a637cc46a8c869a3762e17286dfa62657ad360f05016b9346ff"),
    NotikaPlanOracle(route: .testShowOnlyErrors, platform: .macOS, sha256: "37f3f6173a275a637cc46a8c869a3762e17286dfa62657ad360f05016b9346ff"),
    NotikaPlanOracle(route: .testShowOnlyErrors, platform: .iPadSimulator, sha256: "13ea2b62f87ad1165ceb0b09d7e6e2fb84e3eb643477d1b156e068ded454439b"),
    NotikaPlanOracle(route: .testTextInputHeavyDependencyPerformance, platform: .macOS, sha256: "22b9b3faea9d4660e5608a3f0c6e11572f34a69c58fcf659c7a955bc3133c25d"),
    NotikaPlanOracle(route: .testUI, platform: .macOS, sha256: "71c414431607c8ca251c95ab2d5ea6a473ec2f7aa62dbdf1fdccc08eb4d6fdaf"),
    NotikaPlanOracle(route: .testUI, platform: .iPadSimulator, sha256: "0a286a0ef33e4f29e02f91b693ab729ad26f13f734f522cfad8acd1b8bcf7d62"),
    NotikaPlanOracle(route: .testUIFile, platform: .macOS, sha256: "8c0bd9b7a55451bae95f8817530f5c8f6fa1912d93d8bbf0ebeaa87969ddf958"),
    NotikaPlanOracle(route: .testUIFile, platform: .iPadSimulator, sha256: "5fdb8b8b93af1a9d17be4d4b79068639bf8cf0f6ac637959ab789dda1f6c9c3f"),
    NotikaPlanOracle(route: .testUIIOS, platform: .iPadSimulator, sha256: "0a286a0ef33e4f29e02f91b693ab729ad26f13f734f522cfad8acd1b8bcf7d62"),
    NotikaPlanOracle(route: .testUIMacOS, platform: .macOS, sha256: "71c414431607c8ca251c95ab2d5ea6a473ec2f7aa62dbdf1fdccc08eb4d6fdaf"),
    NotikaPlanOracle(route: .testUIOnly, platform: .macOS, sha256: "40913a23b3bede6eb4c9a3893bdb34407590acab0854ef2d1dcc3825fb60b15f"),
    NotikaPlanOracle(route: .testUIOnlyFile, platform: .macOS, sha256: "2652771db9e1e2eeda4f1f8700fc5c4c5282785f67040a8c2d0dbd88fdf758b0"),
    NotikaPlanOracle(route: .testUIVisual, platform: .macOS, sha256: "d8b62d06ba264bb7578c62cce6f5b8df4e951093a3e3f97381dd8315aea19a10"),
    NotikaPlanOracle(route: .testUIKit, platform: .iPadSimulator, sha256: "13ea2b62f87ad1165ceb0b09d7e6e2fb84e3eb643477d1b156e068ded454439b"),
    NotikaPlanOracle(route: .testUnit, platform: .macOS, sha256: "50e1a48fbebee72a3c4c7e002da27da0735c9ec41a52e0dc7fcb36aedf380275"),
    NotikaPlanOracle(route: .testUnit, platform: .iPadSimulator, sha256: "f2dfd8ab87fcdf23a2e3b7927d682993f4a670853393fe5d72dc081045cba7f3"),
    NotikaPlanOracle(route: .testUnitCoverage, platform: .macOS, sha256: "a28266fe2502680a294b20b3faf6afb08c3e34b1ec77dee76de8baca366dcce2"),
    NotikaPlanOracle(route: .testUnitCoverage, platform: .iPadSimulator, sha256: "924ed1cd5c7df9ccf9314c5be418bb3972ddba11e1fa5495e05e086d56c53e4d"),
    NotikaPlanOracle(route: .testUnitFile, platform: .macOS, sha256: "fce6adb74265d12693bcbd4d60e8960af38fa43ce65070ffe02e1456740580a2"),
    NotikaPlanOracle(route: .testUnitFile, platform: .iPadSimulator, sha256: "98b4e65aee5f5097522abcb3b7f5b880d2bdd5370e217caeaa7a047a2a8ab3b4"),
    NotikaPlanOracle(route: .testUnitFocused, platform: .macOS, sha256: "24898ad8e6cc28b17876d51ced2d0d66af9a8872b76079126b89a7c564c44c67"),
    NotikaPlanOracle(route: .testUnitFocused, platform: .iPadSimulator, sha256: "3a24fb66298c27ba80b938707288e3fcbcf1e3a8ccb2eefc1c77366985dcab74"),
    NotikaPlanOracle(route: .testUnitIOS, platform: .iPadSimulator, sha256: "f2dfd8ab87fcdf23a2e3b7927d682993f4a670853393fe5d72dc081045cba7f3"),
    NotikaPlanOracle(route: .testUnitMacOS, platform: .macOS, sha256: "50e1a48fbebee72a3c4c7e002da27da0735c9ec41a52e0dc7fcb36aedf380275"),
    NotikaPlanOracle(route: .testXcode, platform: .macOS, sha256: "37f3f6173a275a637cc46a8c869a3762e17286dfa62657ad360f05016b9346ff"),
    NotikaPlanOracle(route: .testXcode, platform: .iPadSimulator, sha256: "13ea2b62f87ad1165ceb0b09d7e6e2fb84e3eb643477d1b156e068ded454439b"),
    NotikaPlanOracle(route: .testXcodeCoverage, platform: .macOS, sha256: "f7f9e139cbfb80a14cddb9e3e65897b32793c6f65671db8acb23216542bc19e1"),
    NotikaPlanOracle(route: .testXcodeCoverage, platform: .iPadSimulator, sha256: "14561f10f78c8772cf21ec047b802651bab514a36ff87854aa1984ef8afdf6c9"),
    NotikaPlanOracle(route: .testXcodeFile, platform: .macOS, sha256: "fce6adb74265d12693bcbd4d60e8960af38fa43ce65070ffe02e1456740580a2"),
    NotikaPlanOracle(route: .testXcodeFile, platform: .iPadSimulator, sha256: "98b4e65aee5f5097522abcb3b7f5b880d2bdd5370e217caeaa7a047a2a8ab3b4"),
    NotikaPlanOracle(route: .uiTestXcodeFile, platform: .macOS, sha256: "8c0bd9b7a55451bae95f8817530f5c8f6fa1912d93d8bbf0ebeaa87969ddf958"),
    NotikaPlanOracle(route: .uiTestXcodeFile, platform: .iPadSimulator, sha256: "5fdb8b8b93af1a9d17be4d4b79068639bf8cf0f6ac637959ab789dda1f6c9c3f"),
    NotikaPlanOracle(route: .unitTest, platform: .macOS, sha256: "50e1a48fbebee72a3c4c7e002da27da0735c9ec41a52e0dc7fcb36aedf380275"),
    NotikaPlanOracle(route: .unitTest, platform: .iPadSimulator, sha256: "f2dfd8ab87fcdf23a2e3b7927d682993f4a670853393fe5d72dc081045cba7f3"),
    NotikaPlanOracle(route: .unitTestXcode, platform: .macOS, sha256: "50e1a48fbebee72a3c4c7e002da27da0735c9ec41a52e0dc7fcb36aedf380275"),
    NotikaPlanOracle(route: .unitTestXcode, platform: .iPadSimulator, sha256: "f2dfd8ab87fcdf23a2e3b7927d682993f4a670853393fe5d72dc081045cba7f3"),
]

private let notikaAuxiliaryPlanOracles = [
    NotikaAuxiliaryPlanOracle(requestJSON: #"{"device":null,"file":"FeatureTests","method":"testExample","platform":"macos-ui"}"#, effectiveRoute: .testUIOnlyFile, sha256: "2652771db9e1e2eeda4f1f8700fc5c4c5282785f67040a8c2d0dbd88fdf758b0"),
    NotikaAuxiliaryPlanOracle(requestJSON: #"{"device":"iPad Air 13-inch (M4)","file":"FeatureTests","method":"testExample","platform":"ipad-simulator"}"#, effectiveRoute: .testUIFile, sha256: "5fdb8b8b93af1a9d17be4d4b79068639bf8cf0f6ac637959ab789dda1f6c9c3f"),
    NotikaAuxiliaryPlanOracle(requestJSON: #"{"device":null,"file":"","kind":"interactive-macos","method":"","mode":"run","platform":"macos-ui"}"#, effectiveRoute: .build, sha256: "404f494bf0c7cf8247eda8755ff4067407672fb74f42d83fa62ca348b3c7126b"),
]
