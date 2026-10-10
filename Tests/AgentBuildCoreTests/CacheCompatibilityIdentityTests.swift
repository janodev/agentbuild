import AgentBuildCore
import Foundation
import Testing

@Suite("Notika cache compatibility")
struct CacheCompatibilityIdentityTests {
    // These digests come directly from Notika's Python compatibility_digest,
    // cache_storage_digest, legacy_cache_storage_digest and family helpers.
    @Test(arguments: cacheOracles)
    func profilesAndHistoricalProjectionsMatchPython(_ oracle: CacheOracle) throws {
        let identity = try fixtureIdentity(overrides: oracle.overrides)
        #expect(try identity.executionDigest() == oracle.execution, "\(oracle.name)")
        #expect(try identity.currentStorageDigest() == oracle.currentStorage, "\(oracle.name)")
        #expect(try identity.legacyStorageDigest() == oracle.legacyStorage, "\(oracle.name)")
        #expect(try CanonicalJSONDigest.sha256(identity.compatibilityFamily()) == oracle.currentFamily, "\(oracle.name)")
        #expect(try CanonicalJSONDigest.sha256(identity.compatibilityFamily(metadataSchemaVersion: 2)) == oracle.legacyFamily, "\(oracle.name)")
        #expect(try identity.cacheKey() == String(oracle.currentStorage.prefix(24)))
        #expect(try identity.cacheKey(metadataSchemaVersion: 2) == String(oracle.legacyStorage.prefix(24)))
        #expect(try identity.cacheKey(metadataSchemaVersion: 1) == String(oracle.execution.prefix(24)))
        #expect(try CacheCompatibilityIdentity(keyMaterial: identity.keyMaterial) == identity)
    }

    @Test func sharedStorageKeepsExactExecutionProfiles() throws {
        let app = try fixtureIdentity()
        let ui = try fixtureIdentity(overrides: ["scheme": .string("NotikaUITestsOnly")])
        let regenerated = try fixtureIdentity(overrides: ["generatedGraphDigest": .string(zeroDigest)])
        #expect(try app.cacheKey() == ui.cacheKey())
        #expect(try app.cacheKey() == regenerated.cacheKey())
        #expect(try app.executionDigest() != ui.executionDigest())
        #expect(try app.executionDigest() != regenerated.executionDigest())
        #expect(ui.scheme == .notikaUI)
        #expect(ui.generatedGraphDigest == String(repeating: "e", count: 64))
        let admitted = try app.executionDigest()
        let storage = try app.cacheKey()
        #expect(throws: CacheCompatibilityError.incompatibleAdmission) {
            try ui.validateAdmission(admittedExecutionDigest: admitted, cacheKey: storage)
        }
        #expect(throws: CacheCompatibilityError.incompatibleAdmission) {
            try regenerated.validateAdmission(admittedExecutionDigest: admitted, cacheKey: storage)
        }
    }

    @Test func storageRetainsEveryOtherCompatibilityInput() throws {
        let baseline = try fixtureIdentity().currentStorageDigest()
        let variants: [[String: CanonicalJSONValue]] = [
            ["canonicalWorktree": .string("/Users/jano/Projects/Other/Notika")],
            ["toolchainHash": .string(zeroDigest)],
            ["gitlinks": .array([.object(["path": .string("mk/漢字"), "commit": .string(String(repeating: "2", count: 40))])])],
            ["submoduleStatusDigest": .string(zeroDigest)],
            ["submoduleWorktreeDigest": .string(zeroDigest)],
            ["projectGraphDigest": .string(zeroDigest)],
            ["resolvedDependenciesDigest": .string(zeroDigest)],
            ["configuration": .string("Release")],
            ["scheme": .string("NotikaiPad"), "destinationFamily": .string("ios-simulator-arm64")],
            ["purpose": .string("agent-loop-composite-acceptance")],
        ]
        for variant in variants {
            #expect(try fixtureIdentity(overrides: variant).currentStorageDigest() != baseline)
        }
    }

    @Test func historicalKeysRequireTheExactAdmittedProfile() throws {
        let identity = try fixtureIdentity()
        let admitted = try identity.executionDigest()
        for version in 1...3 {
            try identity.validateAdmission(admittedExecutionDigest: admitted,
                                           cacheKey: identity.cacheKey(metadataSchemaVersion: version))
        }
        #expect(throws: CacheCompatibilityError.incompatibleAdmission) {
            try identity.validateAdmission(admittedExecutionDigest: admitted, cacheKey: String(repeating: "f", count: 24))
        }
        #expect(throws: CacheCompatibilityError.unsupportedMetadataSchema(4)) {
            try identity.cacheKey(metadataSchemaVersion: 4)
        }
        #expect(throws: CacheCompatibilityError.unsupportedMetadataSchema(0)) {
            try identity.compatibilityFamily(metadataSchemaVersion: 0)
        }
    }

    @Test func invalidOrIncompleteMaterialIsRejectedBeforeHashing() throws {
        #expect(throws: CacheCompatibilityError.invalidSchema) {
            try CacheCompatibilityIdentity(keyMaterial: fixtureMaterial(removing: ["generatedGraphDigest"]))
        }
        #expect(throws: CacheCompatibilityError.invalidSchema) {
            try fixtureIdentity(overrides: ["statusDigest": .string(zeroDigest)])
        }
        let variants: [[String: CanonicalJSONValue]] = [
            ["toolchainHash": .string(String(repeating: "A", count: 64))],
            ["generatedGraphDigest": .string("short")],
            ["projectGraphDigest": .bool(true)],
            ["gitlinks": .bool(true)],
            ["buildFlags": .array([.integer(1)])],
            ["purpose": .null],
            ["canonicalWorktree": .string("relative")],
        ]
        for variant in variants {
            #expect(throws: CacheCompatibilityError.self) { try fixtureIdentity(overrides: variant) }
        }
    }

    @Test func gitlinkSchemaAndCountAreBounded() throws {
        for path in ["", "/absolute", "../outside", "folder/../outside"] {
            #expect(throws: CacheCompatibilityError.invalidField("gitlinks")) {
                try CacheGitlink(path: path, commit: String(repeating: "1", count: 40))
            }
        }
        #expect(throws: CacheCompatibilityError.invalidField("gitlinks")) {
            try CacheGitlink(path: "mk", commit: String(repeating: "A", count: 40))
        }
        #expect(throws: CacheCompatibilityError.self) {
            try fixtureIdentity(overrides: ["gitlinks": .array([.object([
                "path": .string("mk"), "commit": .string(String(repeating: "1", count: 40)), "extra": .null,
            ])])])
        }
        let link: CanonicalJSONValue = .object(["path": .string("mk"), "commit": .string(String(repeating: "1", count: 40))])
        #expect(throws: CacheCompatibilityError.invalidField("gitlinks")) {
            try fixtureIdentity(overrides: ["gitlinks": .array(Array(repeating: link, count: 129))])
        }
    }

    @Test func unsupportedBuildFamiliesCannotAcquireACompatibleKey() throws {
        let variants: [[String: CanonicalJSONValue]] = [
            ["scheme": .string("Unknown")],
            ["scheme": .string("NotikaUITestsOnly"), "configuration": .string("Release")],
            ["scheme": .string("NotikaiPad"), "destinationFamily": .string("macos-arm64")],
            ["configuration": .string("Other")],
            ["scheme": .string("NotikaTextPerformanceTests"), "buildFlags": .array([
                .string("-disableAutomaticPackageResolution"), .string("ENABLE_TESTABILITY=YES"),
            ])],
            ["scheme": .string("NotikaCanvasPerformance"), "configuration": .string("Release")],
            ["buildFlags": .array([.string("ENABLE_TESTABILITY=YES"), .string("-disableAutomaticPackageResolution")])],
            ["scheme": .string("NotikaUITestsOnly"), "purpose": .string("agent-loop-composite-acceptance")],
            ["purpose": .string("unknown")],
        ]
        for variant in variants {
            #expect(throws: CacheCompatibilityError.self) { try fixtureIdentity(overrides: variant) }
        }
    }

    @Test func worktreeBindingsUseExactUTF8Spelling() throws {
        let decomposed = "/Users/jano/Projects/Cafe\u{0301} 🧭/Notika"
        #expect(throws: CacheCompatibilityError.invalidField("canonicalWorktree")) {
            try CacheCompatibilityIdentity(keyMaterial: fixtureMaterial(), expectedRepository: decomposed)
        }
        let identity = try CacheCompatibilityIdentity(keyMaterial: fixtureMaterial(), expectedRepository: oracleWorktree)
        #expect(identity.canonicalWorktree == oracleWorktree)
        let otherIdentity = try fixtureIdentity(overrides: ["canonicalWorktree": .string(decomposed)])
        #expect(identity != otherIdentity)
        #expect(try identity.executionDigest() != otherIdentity.executionDigest())
        #expect(try identity.currentStorageDigest() != otherIdentity.currentStorageDigest())
        let composedLink = try CacheGitlink(path: "mk/\u{00E9}", commit: String(repeating: "1", count: 40))
        let decomposedLink = try CacheGitlink(path: "mk/e\u{0301}", commit: String(repeating: "1", count: 40))
        #expect(composedLink != decomposedLink)
    }

    @Test func resourceNamesKeepExistingPythonNamespacesAndPathHashes() throws {
        let worktreeDigest = "1fd29eb2c39d91f277009ae20ff688d5e5f5c6803d9b2b375c07bac346e9b2fb"
        let cacheDigest = "4227e151a7e61a69b9107ae20b78653e7732dcdee57a96a0babfb40b00f0e615"
        let cachePath = oracleWorktree + "/DerivedData/AgentCaches/0123456789abcdef01234567"
        let graph = try CacheCompatibilityIdentity.graphResourceName(canonicalWorktree: oracleWorktree)
        let cache = try CacheCompatibilityIdentity.cacheResourceName(canonicalWorktree: oracleWorktree,
                                                                    canonicalCachePath: cachePath)
        #expect(graph == "notika:generated-xcode-graph:" + worktreeDigest)
        #expect(cache == "notika:derived-data:" + worktreeDigest + ":" + cacheDigest)
        #expect(try CacheCompatibilityIdentity.cachePolicyResourceName(canonicalWorktree: oracleWorktree)
            == "notika:derived-data-policy:" + worktreeDigest)
        #expect(CanonicalJSONDigest.digest(Data(cache.utf8)) + ".lock"
            == "2e5fbae757c7e42884c1c5c32fe9539fedabdc4cf9e34bc81218ecf116f24014.lock")
        for path in ["/worktree/.", "/worktree/../other", "/worktree//other", "/worktree/"] {
            #expect(throws: CacheCompatibilityError.invalidField("canonicalPath")) {
                try CacheCompatibilityIdentity.graphResourceName(canonicalWorktree: path)
            }
        }
    }
}

private let oracleWorktree = "/Users/jano/Projects/Café 🧭/Notika"
private let zeroDigest = String(repeating: "0", count: 64)

private func fixtureMaterial(
    overrides: [String: CanonicalJSONValue] = [:], removing: Set<String> = []
) -> CanonicalJSONValue {
    var values: [String: CanonicalJSONValue] = [
        "canonicalWorktree": .string(oracleWorktree),
        "toolchainHash": .string(String(repeating: "a", count: 64)),
        "gitlinks": .array([.object(["path": .string("mk/漢字"), "commit": .string(String(repeating: "1", count: 40))])]),
        "submoduleStatusDigest": .string(String(repeating: "b", count: 64)),
        "submoduleWorktreeDigest": .string(String(repeating: "c", count: 64)),
        "projectGraphDigest": .string(String(repeating: "d", count: 64)),
        "generatedGraphDigest": .string(String(repeating: "e", count: 64)),
        "resolvedDependenciesDigest": .string(String(repeating: "f", count: 64)),
        "scheme": .string("Notika"), "configuration": .string("Debug"),
        "destinationFamily": .string("macos-arm64"),
        "buildFlags": .array([.string("-disableAutomaticPackageResolution")]),
    ]
    for name in removing { values.removeValue(forKey: name) }
    values.merge(overrides) { _, replacement in replacement }
    return .object(values)
}

private func fixtureIdentity(overrides: [String: CanonicalJSONValue] = [:]) throws -> CacheCompatibilityIdentity {
    try CacheCompatibilityIdentity(keyMaterial: fixtureMaterial(overrides: overrides))
}

struct CacheOracle: Sendable {
    let name: String
    let overrides: [String: CanonicalJSONValue]
    let execution: String
    let currentStorage: String
    let legacyStorage: String
    let currentFamily: String
    let legacyFamily: String
}

private let cacheOracles: [CacheOracle] = [
    CacheOracle(
        name: "mac-app", overrides: [:],
        execution: "972eddd769359a2d3b59acd1601f3d8b6ae72a8aad00a21ef12e6ac73a7722ff",
        currentStorage: "07df63eb19993cdf8c515c2f3ea5ce455bf4cb198a815f29dde67f2f6b708ee8",
        legacyStorage: "2a26ee09eafad5e8d69162b6c346a080e6929d59ffbb1032ea023d1b9574d0f6",
        currentFamily: "01f0b82ec3562f2d91c2b19a9470ad7ae4a411bd7feae5085e37472cf5e6ff56",
        legacyFamily: "01f0b82ec3562f2d91c2b19a9470ad7ae4a411bd7feae5085e37472cf5e6ff56"
    ),
    CacheOracle(
        name: "mac-ui", overrides: ["scheme": .string("NotikaUITestsOnly")],
        execution: "1cddffe40907fc816251d2fe0961604012fc57446e16ee757facd71e40332c9a",
        currentStorage: "07df63eb19993cdf8c515c2f3ea5ce455bf4cb198a815f29dde67f2f6b708ee8",
        legacyStorage: "c9a0e1d91158cd4cc1797791f187c6907f96b86812dbd693dae433a3d15eecf7",
        currentFamily: "01f0b82ec3562f2d91c2b19a9470ad7ae4a411bd7feae5085e37472cf5e6ff56",
        legacyFamily: "6d320853f44b6638e1d6e9faff1f5fba8c6dc40ef8eea8bd1b13018e92269b88"
    ),
    CacheOracle(
        name: "ipad-app", overrides: ["scheme": .string("NotikaiPad"), "destinationFamily": .string("ios-simulator-arm64")],
        execution: "5a714bf4eea407264eb1e981b2f4b3299f51652b8257ff5a171a70e25eaabf9b",
        currentStorage: "90dac06b9efde9f6ee9410a00d27bb557cd443712784a1e2b6065b75ab725a6e",
        legacyStorage: "2068ff860c4e54308a0493a29a939f384914fd39e9c5f83ec23084c0ff135061",
        currentFamily: "7b62b2530d53c9ccd827f65bb8a0d355f8d4b604edc9dfce4ba6349c5f00c658",
        legacyFamily: "7b62b2530d53c9ccd827f65bb8a0d355f8d4b604edc9dfce4ba6349c5f00c658"
    ),
    CacheOracle(
        name: "ipad-ui", overrides: ["scheme": .string("NotikaiPadUITestsOnly"), "destinationFamily": .string("ios-simulator-arm64")],
        execution: "bbbabb200953b4752d6fcb976489613462913b70ad45c370da281f34cbd7bf81",
        currentStorage: "90dac06b9efde9f6ee9410a00d27bb557cd443712784a1e2b6065b75ab725a6e",
        legacyStorage: "32ca504591cd888e3586f9ad18f8a998955b404689519a29ff6544287ba414d0",
        currentFamily: "7b62b2530d53c9ccd827f65bb8a0d355f8d4b604edc9dfce4ba6349c5f00c658",
        legacyFamily: "4777fd1e19dd09b9de0f48043aa4bcb425edceb69d403d8576bef9dabd68df38"
    ),
    CacheOracle(
        name: "release", overrides: ["configuration": .string("Release")],
        execution: "c98c62a1ed5288d976955cd196db1329349d70cfe796ba0db7089e1987f3aea2",
        currentStorage: "2bf888ea007bde3083ee00b08b72c3f38841820b934eb77718ba4f4788725798",
        legacyStorage: "e67affa808215166325cdd1c948a6649bfe4d113cc9a395a50317dc4b413a252",
        currentFamily: "e70877e443bf8dac3cb3eafe7a6d281a4c1dc00ceb0bc38e03273366933a7365",
        legacyFamily: "e70877e443bf8dac3cb3eafe7a6d281a4c1dc00ceb0bc38e03273366933a7365"
    ),
    CacheOracle(
        name: "purpose", overrides: ["purpose": .string("agent-loop-composite-acceptance")],
        execution: "665682955b495cce51ac8653f6e1aa771acf6c543e80ff22930ac1b6706e1bbb",
        currentStorage: "5ae019422efe7cdd9e4ae335c5a2f52bace9cc112ab6e5f002b04f663d202f09",
        legacyStorage: "a94e78e437fc637bcab6129fc6520d73a1e0f5d267197ec5a4951eff567f42ea",
        currentFamily: "6de84e124f4e49f333d2fa4d67c8979dba8e1e564f303e336581c94a71fbc79a",
        legacyFamily: "6de84e124f4e49f333d2fa4d67c8979dba8e1e564f303e336581c94a71fbc79a"
    ),
    CacheOracle(
        name: "text-performance", overrides: [
            "scheme": .string("NotikaTextPerformanceTests"), "configuration": .string("Release"),
            "buildFlags": .array([.string("-disableAutomaticPackageResolution"), .string("ENABLE_TESTABILITY=YES")]),
        ],
        execution: "76bcb955f0755325aa003c0df6355b9e3285e37f76811944ea46461b6c980c65",
        currentStorage: "fd739dacbcca2b82e6ee3dd124795a845d07e130d86d04cde1b8ca16c309a963",
        legacyStorage: "d8074bee4749612b485e9abc34b0be81bf528356b801c2f66a7a289b470542cf",
        currentFamily: "31e1d2114291a6841eeeb8a397ae82172d1ae052f290ec5cd9bfc3fb9e24bfda",
        legacyFamily: "31e1d2114291a6841eeeb8a397ae82172d1ae052f290ec5cd9bfc3fb9e24bfda"
    ),
    CacheOracle(
        name: "canvas-performance", overrides: [
            "scheme": .string("NotikaCanvasPerformance"),
            "buildFlags": .array([.string("-disableAutomaticPackageResolution"),
                                  .string("SWIFT_OPTIMIZATION_LEVEL=-O"), .string("SWIFT_COMPILATION_MODE=wholemodule")]),
        ],
        execution: "db4a7bf019ad9f8d86c1c5dd8a8e725f48e3500862175dba349b8bbfebe6cffe",
        currentStorage: "980856ced42c145b7ee9cfc5dc377ed37bfe609570a01b5f10a759ba13ff4134",
        legacyStorage: "52c776ea902ab74a06161a12c9fac53e2fe61f212e3fbb973f963657b17f1164",
        currentFamily: "aad07db634add0ba77cc51a63b7710cc75a5dbd98ab25274d53f146bb80ceac8",
        legacyFamily: "aad07db634add0ba77cc51a63b7710cc75a5dbd98ab25274d53f146bb80ceac8"
    ),
    CacheOracle(
        name: "changed-graph", overrides: ["generatedGraphDigest": .string(zeroDigest)],
        execution: "7e9dddce11da12aa165294419e03d36ac1a3c4151b824ed8a50cbde2e6466be5",
        currentStorage: "07df63eb19993cdf8c515c2f3ea5ce455bf4cb198a815f29dde67f2f6b708ee8",
        legacyStorage: "2a26ee09eafad5e8d69162b6c346a080e6929d59ffbb1032ea023d1b9574d0f6",
        currentFamily: "01f0b82ec3562f2d91c2b19a9470ad7ae4a411bd7feae5085e37472cf5e6ff56",
        legacyFamily: "01f0b82ec3562f2d91c2b19a9470ad7ae4a411bd7feae5085e37472cf5e6ff56"
    ),
]
