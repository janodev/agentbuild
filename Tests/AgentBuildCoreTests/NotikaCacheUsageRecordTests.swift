import AgentBuildCore
import Foundation
import Testing

@Suite("Notika Xcode cache usage admission")
struct NotikaCacheUsageRecordTests {
    @Test(arguments: usageOracles)
    func pythonProducedHistoricalAndCurrentRecordsAreAdmitted(_ oracle: UsageRecordOracle) throws {
        let data = Data((oracle.json + "\n").utf8)
        let observation = try usageObservation(key: oracle.key)
        let document = try StrictJSONDocument(data: data)
        let record = try NotikaCacheUsageRecord(document: document, directoryObservation: observation)
        #expect(record == (try NotikaCacheUsageRecord(data: data, directoryObservation: observation)))
        #expect(record.schemaVersion == oracle.version)
        #expect(record.cacheKey == oracle.key)
        #expect(record.metadataDigest == oracle.rawDigest)
        #expect(record.originalData == data)
        #expect(record.compatibilityIdentity.scheme == .notikaUI)
        #expect(record.compatibilityIdentitySHA256 == usageExecutionDigest)
        #expect(record.compatibilityFamilySHA256 == oracle.familyDigest)
        #expect(record.storageIdentitySHA256 == oracle.storageDigest)
        #expect(record.createdAt == Date(timeIntervalSince1970: 1_788_256_800))
        #expect(abs(record.lastUsedAt.timeIntervalSince1970 - 1_788_352_496.123456) < 0.000001)
        #expect(record.lastSessionID == "abc-session_2026")
        #expect(record.agentLeaseResource == oracle.resource)
    }

    @Test func originalJSONBytesAreCommittedSeparatelyFromCompatibility() throws {
        let original = try admitUsage()
        let spaced = try admitUsage(" \n" + usageSchema3 + "\n\t")
        #expect(original.compatibilityIdentity == spaced.compatibilityIdentity)
        #expect(original.document.root == spaced.document.root)
        #expect(original.metadataDigest != spaced.metadataDigest)
        #expect(original != spaced)
        #expect(spaced.originalData == Data((" \n" + usageSchema3 + "\n\t").utf8))
        #expect(original.metadataDigest == "9e8d80bb01f66f856fa8676f1703dba88a3264e98fb9311ed756687b708a22e6")
    }

    @Test(arguments: [
        UsageRecordTamper(from: #""resourceID":"notika.agent-cache-usage""#, to: #""resourceID":"notika.rust-test-cache-usage""#, field: "resourceID"),
        UsageRecordTamper(from: #""repository":"/Users/jano/Projects/Café 🧭/Notika""#, to: #""repository":"/other/Notika""#, field: "repository"),
        UsageRecordTamper(from: #""cacheRoot":"/Users/jano/Projects/Café 🧭/Notika/DerivedData/AgentCaches""#, to: #""cacheRoot":"/other/AgentCaches""#, field: "cacheRoot"),
        UsageRecordTamper(from: #""cachePath":"/Users/jano/Projects/Café 🧭/Notika/DerivedData/AgentCaches/07df63eb19993cdf8c515c2f""#, to: #""cachePath":"/other/cache""#, field: "cachePath"),
        UsageRecordTamper(from: #""cacheKey":"07df63eb19993cdf8c515c2f""#, to: #""cacheKey":"000000000000000000000000""#, field: "cacheKey"),
        UsageRecordTamper(from: #""ownerUID":501"#, to: #""ownerUID":502"#, field: "ownerUID"),
        UsageRecordTamper(from: #""ownershipAuthority":"agentlease-kernel-lock""#, to: #""ownershipAuthority":"process-name""#, field: "ownershipAuthority"),
        UsageRecordTamper(from: #""agentLeaseResource":"notika:derived-data:1fd29eb2c39d91f277009ae20ff688d5e5f5c6803d9b2b375c07bac346e9b2fb:15c5c732d5a31291c73bb0c1ef8e9e49defa35929dad90792a5d4df48eed4d1a""#, to: #""agentLeaseResource":"foreign-resource""#, field: "agentLeaseResource"),
        UsageRecordTamper(from: #""deviceID":16777234"#, to: #""deviceID":16777235"#, field: "directoryIdentity"),
        UsageRecordTamper(from: #""inode":81234567"#, to: #""inode":81234568"#, field: "directoryIdentity"),
        UsageRecordTamper(from: #""scheme":"Notika""#, to: #""scheme":"NotikaUITestsOnly""#, field: "compatibilityFamily"),
        UsageRecordTamper(from: #""compatibilityFamilySHA256":"01f0b82ec3562f2d91c2b19a9470ad7ae4a411bd7feae5085e37472cf5e6ff56""#, to: #""compatibilityFamilySHA256":"0000000000000000000000000000000000000000000000000000000000000000""#, field: "compatibilityFamilySHA256"),
        UsageRecordTamper(from: #""compatibilityIdentitySHA256":"1cddffe40907fc816251d2fe0961604012fc57446e16ee757facd71e40332c9a""#, to: #""compatibilityIdentitySHA256":"0000000000000000000000000000000000000000000000000000000000000000""#, field: "compatibilityIdentitySHA256"),
        UsageRecordTamper(from: #""storageIdentitySHA256":"07df63eb19993cdf8c515c2f3ea5ce455bf4cb198a815f29dde67f2f6b708ee8""#, to: #""storageIdentitySHA256":"c9a0e1d91158cd4cc1797791f187c6907f96b86812dbd693dae433a3d15eecf7""#, field: "storageIdentitySHA256"),
        UsageRecordTamper(from: #""generatedGraphDigest":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee""#, to: #""generatedGraphDigest":"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff""#, field: "compatibilityIdentitySHA256"),
    ])
    func schemaBindingsRejectIndependentTampering(_ tamper: UsageRecordTamper) {
        let input = usageSchema3.replacingOccurrences(of: tamper.from, with: tamper.to)
        #expect(input != usageSchema3)
        #expect(throws: NotikaCacheUsageError.invalidField(tamper.field)) { try admitUsage(input) }
    }

    @Test func coherentPhysicalBindingsStillRequireTheProfilesSchemaSpecificKey() throws {
        let foreignKey = String(repeating: "0", count: 24)
        let observation = try usageObservation(key: foreignKey)
        let resource = try CacheCompatibilityIdentity.cacheResourceName(
            canonicalWorktree: usageRepository, canonicalCachePath: observation.canonicalCachePath
        )
        let input = usageSchema3
            .replacingOccurrences(of: "\"cacheKey\":\"" + usageCurrentKey + "\"", with: "\"cacheKey\":\"" + foreignKey + "\"")
            .replacingOccurrences(of: "\"cachePath\":\"" + usageRoot + "/" + usageCurrentKey + "\"",
                                  with: "\"cachePath\":\"" + observation.canonicalCachePath + "\"")
            .replacingOccurrences(of: usageOracles[2].resource, with: resource)
        #expect(throws: NotikaCacheUsageError.invalidField("cacheKey")) {
            try NotikaCacheUsageRecord(data: Data(input.utf8), directoryObservation: observation)
        }
    }

    @Test func closedSchemasRejectMissingForeignAndDuplicateKeys() {
        #expect(throws: StrictJSONError.missingField("lastSessionID")) {
            try admitUsage(usageSchema3.replacingOccurrences(of: #""lastSessionID":"abc-session_2026","#, with: ""))
        }
        #expect(throws: StrictJSONError.unexpectedField("extra")) {
            try admitUsage(usageSchema3.replacingOccurrences(of: #""schemaVersion":3"#, with: #""schemaVersion":3,"extra":null"#))
        }
        #expect(throws: StrictJSONError.unexpectedField("extra")) {
            try admitUsage(usageSchema3.replacingOccurrences(of: #""inode":81234567"#, with: #""inode":81234567,"extra":null"#))
        }
        #expect(throws: CacheCompatibilityError.invalidSchema) {
            try admitUsage(usageSchema3.replacingOccurrences(of: #""toolchainHash":"#, with: #""extra":null,"toolchainHash":"#))
        }
        #expect(throws: StrictJSONError.self) {
            try admitUsage(usageSchema3.replacingOccurrences(of: #""schemaVersion":3"#, with: #""schemaVersion":3,"\u0073chemaVersion":3"#))
        }
        #expect(throws: StrictJSONError.self) {
            try admitUsage(usageSchema3.replacingOccurrences(of: #""deviceID":16777234"#, with: #""deviceID":16777234,"deviceID":16777234"#))
        }
        let oldest = usageOracles[0]
        #expect(throws: StrictJSONError.unexpectedField("storageIdentitySHA256")) {
            let extra = oldest.json.replacingOccurrences(of: #""schemaVersion":1"#, with: #""schemaVersion":1,"storageIdentitySHA256":"foreign""#)
            _ = try admitUsage(extra, key: oldest.key)
        }
        #expect(throws: StrictJSONError.missingField("storageIdentitySHA256")) {
            try admitUsage(usageSchema3.replacingOccurrences(
                of: #","storageIdentitySHA256":"07df63eb19993cdf8c515c2f3ea5ce455bf4cb198a815f29dde67f2f6b708ee8""#,
                with: ""
            ))
        }
    }

    @Test func booleansNeverBecomeDirectoryOrOwnerIntegers() throws {
        let zeroOwner = try usageObservation(ownerUID: 0)
        #expect(throws: NotikaCacheUsageError.invalidField("ownerUID")) {
            try NotikaCacheUsageRecord(
                data: Data(usageSchema3.replacingOccurrences(of: #""ownerUID":501"#, with: #""ownerUID":false"#).utf8),
                directoryObservation: zeroOwner
            )
        }
        let oneDevice = try usageObservation(deviceID: 1)
        #expect(throws: NotikaCacheUsageError.invalidField("deviceID")) {
            try NotikaCacheUsageRecord(
                data: Data(usageSchema3.replacingOccurrences(of: #""deviceID":16777234"#, with: #""deviceID":true"#).utf8),
                directoryObservation: oneDevice
            )
        }
        let zeroInode = try usageObservation(inode: 0)
        #expect(throws: NotikaCacheUsageError.invalidField("inode")) {
            try NotikaCacheUsageRecord(
                data: Data(usageSchema3.replacingOccurrences(of: #""inode":81234567"#, with: #""inode":false"#).utf8),
                directoryObservation: zeroInode
            )
        }
        #expect(throws: NotikaCacheUsageError.invalidField("schemaVersion")) {
            try admitUsage(usageSchema3.replacingOccurrences(of: #""schemaVersion":3"#, with: #""schemaVersion":true"#))
        }
    }

    @Test(arguments: ["3.0", "3e0", "-1", "18446744073709551616"])
    func schemaIntegersRequireCheckedIntegerTokens(_ token: String) {
        #expect(throws: StrictJSONError.integerConversion(token)) {
            try admitUsage(usageSchema3.replacingOccurrences(of: #""schemaVersion":3"#, with: "\"schemaVersion\":" + token))
        }
    }

    @Test(arguments: [0, 4, 9])
    func unsupportedSchemasAreRejected(_ version: Int) {
        #expect(throws: NotikaCacheUsageError.invalidSchemaVersion) {
            try admitUsage(usageSchema3.replacingOccurrences(of: #""schemaVersion":3"#, with: "\"schemaVersion\":" + String(version)))
        }
    }

    @Test func directoryObservationRequiresFixedCanonicalNamespaceAndOwner() {
        #expect(throws: NotikaCacheUsageError.invalidDirectoryObservation("cacheRoot")) {
            try usageObservation(root: usageRepository + "/DerivedData/RustTestCaches")
        }
        #expect(throws: NotikaCacheUsageError.invalidDirectoryObservation("cachePath")) {
            try usageObservation(path: usageRoot + "/nested/" + usageCurrentKey)
        }
        #expect(throws: NotikaCacheUsageError.invalidDirectoryObservation("ownerUID")) {
            try usageObservation(ownerUID: 502, effectiveUserID: 501)
        }
        for path in [usageRoot + "/../AgentCaches/" + usageCurrentKey, usageRoot + "//" + usageCurrentKey] {
            #expect(throws: NotikaCacheUsageError.invalidDirectoryObservation("canonicalPath")) { try usageObservation(path: path) }
        }
    }

    @Test func unicodeBindingsRetainLiteralUTF8RatherThanCanonicalEquivalence() throws {
        let decomposed = usageRepository.replacingOccurrences(of: "é", with: "e\u{0301}")
        #expect(decomposed == usageRepository)
        #expect(Data(decomposed.utf8) != Data(usageRepository.utf8))
        let alteredRepository = usageSchema3.replacingOccurrences(
            of: "\"repository\":\"" + usageRepository + "\"", with: "\"repository\":\"" + decomposed + "\""
        )
        #expect(throws: NotikaCacheUsageError.invalidField("repository")) { try admitUsage(alteredRepository) }
        let decomposedObservation = try NotikaCacheDirectoryObservation(
            canonicalRepository: decomposed, canonicalCacheRoot: decomposed + "/DerivedData/AgentCaches",
            canonicalCachePath: decomposed + "/DerivedData/AgentCaches/" + usageCurrentKey,
            deviceID: 16_777_234, inode: 81_234_567, ownerUID: 501, effectiveUserID: 501
        )
        #expect(decomposedObservation != (try usageObservation()))
        #expect(throws: NotikaCacheUsageError.invalidField("repository")) {
            try NotikaCacheUsageRecord(data: Data(usageSchema3.utf8), directoryObservation: decomposedObservation)
        }
    }

    @Test(arguments: ["", ".hidden", "../other", "first/second", "é", String(repeating: "a", count: 129)])
    func unsafeSessionIDsAreRejected(_ session: String) {
        let input = usageSchema3.replacingOccurrences(of: "abc-session_2026", with: session)
        #expect(throws: NotikaCacheUsageError.invalidField("lastSessionID")) { try admitUsage(input) }
    }

    @Test func timestampsPreserveProducerSecondsMicrosecondsAndOffsetEquivalence() throws {
        let original = try admitUsage()
        let seconds = try admitUsage(usageSchema3.replacingOccurrences(of: usageLastUsed, with: "2026-09-02T12:34:56Z") + "\n")
        #expect(seconds.lastUsedAt == Date(timeIntervalSince1970: 1_788_352_496))
        #expect(seconds.metadataDigest == "cc525ff4c3c2f147bb1d3c4760cd7705db6800eeae0202b5371fee2538191622")
        #expect(original.lastUsedAtMicrosecondsSince1970 == 1_788_352_496_123_456)
        for timestamp in [
            "2026-09-02T14:34:56.123456+02:00",
            "2026-09-02T05:34:56.123456-07:00",
            "2026-09-03T01:34:56.123456+13:00",
        ] {
            let record = try admitUsage(usageSchema3.replacingOccurrences(of: usageLastUsed, with: timestamp))
            #expect(record.lastUsedAt == original.lastUsedAt)
        }
        let future = try admitUsage(usageSchema3.replacingOccurrences(of: usageLastUsed, with: "2036-09-02T12:34:56Z"))
        #expect(future.lastUsedAt > original.lastUsedAt)
        let policy = try LocalCalendarRetention(evaluatedAt: original.lastUsedAt, timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(policy.cacheEligibility(lastUsedAt: future.lastUsedAt) == .invalid)
    }

    @Test(arguments: [
        "2026-09-02T12:34:56", "20260902T123456Z", "2026-W36-3T12:34:56Z",
        "2026-09-02 12:34:56Z", "2026-09-02T12:34:56.1234567Z", "2026-09-02T12:34:56.Z",
        "2026-09-02T12:34:60Z", "2026-02-30T12:34:56Z", "2026-09-02T24:00:00Z",
        "2026-09-02T12:34:56+24:00", "2026-09-02T12:34:56+01:60", "0000-09-02T12:34:56Z",
    ])
    func malformedOrBroaderNonproducerTimestampsAreRejected(_ timestamp: String) {
        #expect(throws: NotikaCacheUsageError.invalidField("lastUsedAt")) {
            try admitUsage(usageSchema3.replacingOccurrences(of: usageLastUsed, with: timestamp))
        }
    }

    @Test func createdTimeCannotFollowLastUse() {
        #expect(throws: NotikaCacheUsageError.invalidTimeRange) {
            try admitUsage(usageSchema3.replacingOccurrences(of: "2026-09-01T10:00:00Z", with: "2026-09-03T10:00:00Z"))
        }
        let distant = usageSchema3
            .replacingOccurrences(of: "2026-09-01T10:00:00Z", with: "9999-12-31T23:59:59.000002Z")
            .replacingOccurrences(of: usageLastUsed, with: "9999-12-31T23:59:59.000001Z")
        #expect(throws: NotikaCacheUsageError.invalidTimeRange) { try admitUsage(distant) }
    }

    @Test func timestampCalendarIsProlepticGregorianAndUTCStaysInsidePythonRange() throws {
        let early = usageSchema3
            .replacingOccurrences(of: "2026-09-01T10:00:00Z", with: "0001-01-01T00:00:00Z")
            .replacingOccurrences(of: usageLastUsed, with: "0001-01-01T00:00:00.000001Z")
        let record = try admitUsage(early)
        #expect(record.createdAtMicrosecondsSince1970 == -62_135_596_800_000_000)
        #expect(record.lastUsedAtMicrosecondsSince1970 == -62_135_596_799_999_999)
        #expect(throws: NotikaCacheUsageError.invalidField("lastUsedAt")) {
            try admitUsage(usageSchema3.replacingOccurrences(of: usageLastUsed, with: "1500-02-29T00:00:00Z"))
        }
        #expect(throws: NotikaCacheUsageError.invalidField("createdAt")) {
            try admitUsage(usageSchema3.replacingOccurrences(of: "2026-09-01T10:00:00Z", with: "0001-01-01T00:00:00+00:01"))
        }
        #expect(throws: NotikaCacheUsageError.invalidField("lastUsedAt")) {
            try admitUsage(usageSchema3.replacingOccurrences(of: usageLastUsed, with: "9999-12-31T23:59:59-00:01"))
        }
    }

    @Test func metadataByteBoundCannotBeWidenedByPreparsedDocument() throws {
        var data = Data(repeating: 32, count: NotikaCacheUsageRecord.maximumBytes)
        data.append(Data(usageSchema3.utf8))
        let observation = try usageObservation()
        #expect(throws: StrictJSONError.byteBudgetExceeded(NotikaCacheUsageRecord.maximumBytes)) {
            try NotikaCacheUsageRecord(data: data, directoryObservation: observation)
        }
        let document = try StrictJSONDocument(data: data, limits: StrictJSONLimits(maximumBytes: 64 * 1_024))
        #expect(throws: StrictJSONError.byteBudgetExceeded(NotikaCacheUsageRecord.maximumBytes)) {
            try NotikaCacheUsageRecord(document: document, directoryObservation: observation)
        }
    }
}

struct UsageRecordTamper: Sendable {
    let from: String
    let to: String
    let field: String
}

struct UsageRecordOracle: Sendable {
    let version: Int
    let key: String
    let rawDigest: String
    let familyDigest: String
    let storageDigest: String?
    let resource: String
    let json: String
}

private func usageObservation(
    key: String = usageCurrentKey, root: String = usageRoot, path: String? = nil,
    deviceID: UInt64 = 16_777_234, inode: UInt64 = 81_234_567,
    ownerUID: UInt32 = 501, effectiveUserID: UInt32? = nil
) throws -> NotikaCacheDirectoryObservation {
    try NotikaCacheDirectoryObservation(
        canonicalRepository: usageRepository, canonicalCacheRoot: root,
        canonicalCachePath: path ?? root + "/" + key, deviceID: deviceID, inode: inode,
        ownerUID: ownerUID, effectiveUserID: effectiveUserID ?? ownerUID
    )
}

private func admitUsage(_ input: String = usageSchema3, key: String = usageCurrentKey) throws -> NotikaCacheUsageRecord {
    try NotikaCacheUsageRecord(data: Data(input.utf8), directoryObservation: usageObservation(key: key))
}

private let usageRepository = "/Users/jano/Projects/Café 🧭/Notika"
private let usageRoot = usageRepository + "/DerivedData/AgentCaches"
private let usageCurrentKey = "07df63eb19993cdf8c515c2f"
private let usageExecutionDigest = "1cddffe40907fc816251d2fe0961604012fc57446e16ee757facd71e40332c9a"
private let usageLastUsed = "2026-09-02T12:34:56.123456Z"

// Static records generated by Notika's Python producer dictionary and actual
// compatibility/family/storage/resource helpers; no Python runs in these tests.
private let usageSchema1 = #"""
{"agentLeaseResource":"notika:derived-data:1fd29eb2c39d91f277009ae20ff688d5e5f5c6803d9b2b375c07bac346e9b2fb:4c7901b761a374856967101642df4b2dca5e771da843c6e626ff793145454b5c","cacheKey":"1cddffe40907fc816251d2fe","cachePath":"/Users/jano/Projects/Café 🧭/Notika/DerivedData/AgentCaches/1cddffe40907fc816251d2fe","cacheRoot":"/Users/jano/Projects/Café 🧭/Notika/DerivedData/AgentCaches","compatibilityFamily":{"buildFlags":["-disableAutomaticPackageResolution"],"canonicalWorktree":"/Users/jano/Projects/Café 🧭/Notika","configuration":"Debug","destinationFamily":"macos-arm64","scheme":"NotikaUITestsOnly"},"compatibilityFamilySHA256":"6d320853f44b6638e1d6e9faff1f5fba8c6dc40ef8eea8bd1b13018e92269b88","compatibilityIdentitySHA256":"1cddffe40907fc816251d2fe0961604012fc57446e16ee757facd71e40332c9a","compatibilityKeyMaterial":{"buildFlags":["-disableAutomaticPackageResolution"],"canonicalWorktree":"/Users/jano/Projects/Café 🧭/Notika","configuration":"Debug","destinationFamily":"macos-arm64","generatedGraphDigest":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","gitlinks":[{"commit":"1111111111111111111111111111111111111111","path":"mk/漢字"}],"projectGraphDigest":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","resolvedDependenciesDigest":"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff","scheme":"NotikaUITestsOnly","submoduleStatusDigest":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","submoduleWorktreeDigest":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","toolchainHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"createdAt":"2026-09-01T10:00:00Z","directoryIdentity":{"deviceID":16777234,"inode":81234567},"lastSessionID":"abc-session_2026","lastUsedAt":"2026-09-02T12:34:56.123456Z","ownerUID":501,"ownershipAuthority":"agentlease-kernel-lock","repository":"/Users/jano/Projects/Café 🧭/Notika","resourceID":"notika.agent-cache-usage","schemaVersion":1}
"""#

private let usageSchema2 = #"""
{"agentLeaseResource":"notika:derived-data:1fd29eb2c39d91f277009ae20ff688d5e5f5c6803d9b2b375c07bac346e9b2fb:36209db4dcea6462cc2ef0c8a33ecc9592149bf3ec0d962f3f778e9230cb5076","cacheKey":"c9a0e1d91158cd4cc1797791","cachePath":"/Users/jano/Projects/Café 🧭/Notika/DerivedData/AgentCaches/c9a0e1d91158cd4cc1797791","cacheRoot":"/Users/jano/Projects/Café 🧭/Notika/DerivedData/AgentCaches","compatibilityFamily":{"buildFlags":["-disableAutomaticPackageResolution"],"canonicalWorktree":"/Users/jano/Projects/Café 🧭/Notika","configuration":"Debug","destinationFamily":"macos-arm64","scheme":"NotikaUITestsOnly"},"compatibilityFamilySHA256":"6d320853f44b6638e1d6e9faff1f5fba8c6dc40ef8eea8bd1b13018e92269b88","compatibilityIdentitySHA256":"1cddffe40907fc816251d2fe0961604012fc57446e16ee757facd71e40332c9a","compatibilityKeyMaterial":{"buildFlags":["-disableAutomaticPackageResolution"],"canonicalWorktree":"/Users/jano/Projects/Café 🧭/Notika","configuration":"Debug","destinationFamily":"macos-arm64","generatedGraphDigest":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","gitlinks":[{"commit":"1111111111111111111111111111111111111111","path":"mk/漢字"}],"projectGraphDigest":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","resolvedDependenciesDigest":"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff","scheme":"NotikaUITestsOnly","submoduleStatusDigest":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","submoduleWorktreeDigest":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","toolchainHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"createdAt":"2026-09-01T10:00:00Z","directoryIdentity":{"deviceID":16777234,"inode":81234567},"lastSessionID":"abc-session_2026","lastUsedAt":"2026-09-02T12:34:56.123456Z","ownerUID":501,"ownershipAuthority":"agentlease-kernel-lock","repository":"/Users/jano/Projects/Café 🧭/Notika","resourceID":"notika.agent-cache-usage","schemaVersion":2,"storageIdentitySHA256":"c9a0e1d91158cd4cc1797791f187c6907f96b86812dbd693dae433a3d15eecf7"}
"""#

private let usageSchema3 = #"""
{"agentLeaseResource":"notika:derived-data:1fd29eb2c39d91f277009ae20ff688d5e5f5c6803d9b2b375c07bac346e9b2fb:15c5c732d5a31291c73bb0c1ef8e9e49defa35929dad90792a5d4df48eed4d1a","cacheKey":"07df63eb19993cdf8c515c2f","cachePath":"/Users/jano/Projects/Café 🧭/Notika/DerivedData/AgentCaches/07df63eb19993cdf8c515c2f","cacheRoot":"/Users/jano/Projects/Café 🧭/Notika/DerivedData/AgentCaches","compatibilityFamily":{"buildFlags":["-disableAutomaticPackageResolution"],"canonicalWorktree":"/Users/jano/Projects/Café 🧭/Notika","configuration":"Debug","destinationFamily":"macos-arm64","scheme":"Notika"},"compatibilityFamilySHA256":"01f0b82ec3562f2d91c2b19a9470ad7ae4a411bd7feae5085e37472cf5e6ff56","compatibilityIdentitySHA256":"1cddffe40907fc816251d2fe0961604012fc57446e16ee757facd71e40332c9a","compatibilityKeyMaterial":{"buildFlags":["-disableAutomaticPackageResolution"],"canonicalWorktree":"/Users/jano/Projects/Café 🧭/Notika","configuration":"Debug","destinationFamily":"macos-arm64","generatedGraphDigest":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","gitlinks":[{"commit":"1111111111111111111111111111111111111111","path":"mk/漢字"}],"projectGraphDigest":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","resolvedDependenciesDigest":"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff","scheme":"NotikaUITestsOnly","submoduleStatusDigest":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","submoduleWorktreeDigest":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","toolchainHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"createdAt":"2026-09-01T10:00:00Z","directoryIdentity":{"deviceID":16777234,"inode":81234567},"lastSessionID":"abc-session_2026","lastUsedAt":"2026-09-02T12:34:56.123456Z","ownerUID":501,"ownershipAuthority":"agentlease-kernel-lock","repository":"/Users/jano/Projects/Café 🧭/Notika","resourceID":"notika.agent-cache-usage","schemaVersion":3,"storageIdentitySHA256":"07df63eb19993cdf8c515c2f3ea5ce455bf4cb198a815f29dde67f2f6b708ee8"}
"""#

private let usageOracles = [
    UsageRecordOracle(version: 1, key: "1cddffe40907fc816251d2fe", rawDigest: "ac0ef668643eb3510d86e95581a2c04af568d34eb8ff9772d95cf00ccf971325",
                      familyDigest: "6d320853f44b6638e1d6e9faff1f5fba8c6dc40ef8eea8bd1b13018e92269b88", storageDigest: nil,
                      resource: "notika:derived-data:1fd29eb2c39d91f277009ae20ff688d5e5f5c6803d9b2b375c07bac346e9b2fb:4c7901b761a374856967101642df4b2dca5e771da843c6e626ff793145454b5c", json: usageSchema1),
    UsageRecordOracle(version: 2, key: "c9a0e1d91158cd4cc1797791", rawDigest: "5f9e29a9d9faab767fa9ab3e1c2106ef5e1fd8f8cd84ef5860ff197054c58e6c",
                      familyDigest: "6d320853f44b6638e1d6e9faff1f5fba8c6dc40ef8eea8bd1b13018e92269b88", storageDigest: "c9a0e1d91158cd4cc1797791f187c6907f96b86812dbd693dae433a3d15eecf7",
                      resource: "notika:derived-data:1fd29eb2c39d91f277009ae20ff688d5e5f5c6803d9b2b375c07bac346e9b2fb:36209db4dcea6462cc2ef0c8a33ecc9592149bf3ec0d962f3f778e9230cb5076", json: usageSchema2),
    UsageRecordOracle(version: 3, key: usageCurrentKey, rawDigest: "2c95987235405592cc3689c67282b04c7d9a2c812e5e1b18850e6fbd16790db0",
                      familyDigest: "01f0b82ec3562f2d91c2b19a9470ad7ae4a411bd7feae5085e37472cf5e6ff56", storageDigest: "07df63eb19993cdf8c515c2f3ea5ce455bf4cb198a815f29dde67f2f6b708ee8",
                      resource: "notika:derived-data:1fd29eb2c39d91f277009ae20ff688d5e5f5c6803d9b2b375c07bac346e9b2fb:15c5c732d5a31291c73bb0c1ef8e9e49defa35929dad90792a5d4df48eed4d1a", json: usageSchema3),
]
