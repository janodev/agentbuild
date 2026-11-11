import AgentBuildCore
import Foundation

public enum NotikaCacheUsageError: Error, Equatable, Sendable {
    case invalidDirectoryObservation(String)
    case invalidField(String)
    case invalidSchemaVersion
    case invalidTimeRange
}

/// Caller-supplied directory facts for Notika's fixed Xcode-cache namespace.
/// This checks path and owner bindings; it neither observes a descriptor nor
/// establishes custody, liveness, metadata-file permissions, or deletion authority.
public struct NotikaCacheDirectoryObservation: Equatable, Sendable {
    public let canonicalRepository: String
    public let canonicalCacheRoot: String
    public let canonicalCachePath: String
    public let cacheKey: String
    public let deviceID: UInt64
    public let inode: UInt64
    public let ownerUID: UInt32
    public let effectiveUserID: UInt32

    public init(
        canonicalRepository: String,
        canonicalCacheRoot: String,
        canonicalCachePath: String,
        deviceID: UInt64,
        inode: UInt64,
        ownerUID: UInt32,
        effectiveUserID: UInt32
    ) throws {
        do {
            _ = try CacheCompatibilityIdentity.graphResourceName(canonicalWorktree: canonicalRepository)
            _ = try CacheCompatibilityIdentity.cacheResourceName(
                canonicalWorktree: canonicalRepository, canonicalCachePath: canonicalCachePath
            )
        } catch {
            throw NotikaCacheUsageError.invalidDirectoryObservation("canonicalPath")
        }
        let expectedRoot = (canonicalRepository == "/" ? "" : canonicalRepository) + "/DerivedData/AgentCaches"
        guard sameUsageUTF8(canonicalCacheRoot, expectedRoot) else {
            throw NotikaCacheUsageError.invalidDirectoryObservation("cacheRoot")
        }
        let key = String(canonicalCachePath.split(separator: "/").last ?? "")
        guard usageLowercaseHex(key, length: 24), sameUsageUTF8(canonicalCachePath, expectedRoot + "/" + key) else {
            throw NotikaCacheUsageError.invalidDirectoryObservation("cachePath")
        }
        guard ownerUID == effectiveUserID else {
            throw NotikaCacheUsageError.invalidDirectoryObservation("ownerUID")
        }
        self.canonicalRepository = canonicalRepository
        self.canonicalCacheRoot = canonicalCacheRoot
        self.canonicalCachePath = canonicalCachePath
        cacheKey = key
        self.deviceID = deviceID
        self.inode = inode
        self.ownerUID = ownerUID
        self.effectiveUserID = effectiveUserID
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        sameUsageUTF8(lhs.canonicalRepository, rhs.canonicalRepository)
            && sameUsageUTF8(lhs.canonicalCacheRoot, rhs.canonicalCacheRoot)
            && sameUsageUTF8(lhs.canonicalCachePath, rhs.canonicalCachePath)
            && lhs.deviceID == rhs.deviceID && lhs.inode == rhs.inode
            && lhs.ownerUID == rhs.ownerUID && lhs.effectiveUserID == rhs.effectiveUserID
    }
}

/// An immutable admission of Xcode usage schemas 1, 2, or 3 against supplied
/// directory facts. Raw bytes and their digest remain distinct from compatibility
/// hashes. Descriptor custody and the current retention policy are separate;
/// successful schema admission does not authorize a filesystem mutation.
///
/// Timestamps accept timezone-aware RFC3339 with uppercase T/Z or ±HH:MM and
/// zero to six fractional-second digits. This preserves Python producer seconds
/// and microseconds, while conservatively rejecting its broader fromisoformat
/// grammar (such as compact dates, week dates, or missing timezone offsets).
public struct NotikaCacheUsageRecord: Equatable, Sendable {
    public static let maximumBytes = 32 * 1_024

    public let document: StrictJSONDocument
    public let directoryObservation: NotikaCacheDirectoryObservation
    public let schemaVersion: Int
    public let compatibilityIdentity: CacheCompatibilityIdentity
    public let compatibilityFamily: CanonicalJSONValue
    public let compatibilityFamilySHA256: String
    public let compatibilityIdentitySHA256: String
    public let storageIdentitySHA256: String?
    public let agentLeaseResource: String
    public let createdAt: Date
    public let lastUsedAt: Date
    /// Exact producer precision, independent of Date's rounding at distant years.
    public let createdAtMicrosecondsSince1970: Int64
    public let lastUsedAtMicrosecondsSince1970: Int64
    public let lastSessionID: String

    public var cacheKey: String { directoryObservation.cacheKey }
    public var metadataDigest: String { document.digest }
    public var originalData: Data { document.originalData }

    /// Without `boot`, the stored device and inode must equal the observation.
    /// With the current boot, a record last written during an earlier boot is
    /// admitted by its inode alone, because its device number may be stale.
    public init(
        data: Data, directoryObservation: NotikaCacheDirectoryObservation, boot: DirectoryIdentityBoot? = nil
    ) throws {
        let limits = try StrictJSONLimits(maximumBytes: Self.maximumBytes)
        try self.init(
            document: StrictJSONDocument(data: data, limits: limits), directoryObservation: directoryObservation, boot: boot
        )
    }

    public init(
        document: StrictJSONDocument, directoryObservation: NotikaCacheDirectoryObservation,
        boot: DirectoryIdentityBoot? = nil
    ) throws {
        guard document.originalData.count <= Self.maximumBytes else {
            throw StrictJSONError.byteBudgetExceeded(Self.maximumBytes)
        }
        let object = try document.root.requireObject()
        let rawVersion = try usageUnsigned("schemaVersion", in: object)
        guard (1...4).contains(rawVersion) else { throw NotikaCacheUsageError.invalidSchemaVersion }
        let version = Int(rawVersion)
        var keys = [
            "schemaVersion", "resourceID", "repository", "cacheRoot", "cacheKey", "cachePath",
            "directoryIdentity", "ownerUID", "ownershipAuthority", "agentLeaseResource",
            "compatibilityFamily", "compatibilityFamilySHA256", "compatibilityKeyMaterial",
            "compatibilityIdentitySHA256", "createdAt", "lastUsedAt", "lastSessionID",
        ]
        if version != 1 { keys.append("storageIdentitySHA256") }
        _ = try object.project(requiredKeys: keys)
        try usageRequireString("resourceID", in: object, equals: "notika.agent-cache-usage")
        try usageRequireString("repository", in: object, equals: directoryObservation.canonicalRepository)
        try usageRequireString("cacheRoot", in: object, equals: directoryObservation.canonicalCacheRoot)
        try usageRequireString("cachePath", in: object, equals: directoryObservation.canonicalCachePath)
        try usageRequireString("cacheKey", in: object, equals: directoryObservation.cacheKey)
        try usageRequireString("ownershipAuthority", in: object, equals: "agentlease-kernel-lock")
        guard try usageUnsigned("ownerUID", in: object) == UInt64(directoryObservation.effectiveUserID) else {
            throw NotikaCacheUsageError.invalidField("ownerUID")
        }
        let directory = try object.requiredValue(forKey: "directoryIdentity").requireObject()
        _ = try directory.project(requiredKeys: ["deviceID", "inode"])
        let storedDeviceID = try usageUnsigned("deviceID", in: directory)
        let storedInode = try usageUnsigned("inode", in: directory)
        guard storedInode == directoryObservation.inode else {
            throw NotikaCacheUsageError.invalidField("directoryIdentity")
        }
        let expectedResource = try CacheCompatibilityIdentity.cacheResourceName(
            canonicalWorktree: directoryObservation.canonicalRepository,
            canonicalCachePath: directoryObservation.canonicalCachePath
        )
        try usageRequireString("agentLeaseResource", in: object, equals: expectedResource)

        let rawMaterial = try object.requiredValue(forKey: "compatibilityKeyMaterial")
        let identity = try CacheCompatibilityIdentity(
            keyMaterial: usageCanonicalJSON(rawMaterial), expectedRepository: directoryObservation.canonicalRepository
        )
        let expectedFamily = try identity.compatibilityFamily(metadataSchemaVersion: version)
        let rawFamily = try usageCanonicalJSON(object.requiredValue(forKey: "compatibilityFamily"))
        guard rawFamily == expectedFamily else { throw NotikaCacheUsageError.invalidField("compatibilityFamily") }
        let familyDigest = try CanonicalJSONDigest.sha256(expectedFamily)
        let executionDigest = try identity.executionDigest()
        try usageRequireString("compatibilityFamilySHA256", in: object, equals: familyDigest)
        try usageRequireString("compatibilityIdentitySHA256", in: object, equals: executionDigest)
        guard try identity.cacheKey(metadataSchemaVersion: version) == directoryObservation.cacheKey else {
            throw NotikaCacheUsageError.invalidField("cacheKey")
        }
        let storageDigest: String?
        switch version {
        case 1: storageDigest = nil
        case 2: storageDigest = try identity.legacyStorageDigest()
        case 3: storageDigest = try identity.schema3StorageDigest()
        default: storageDigest = try identity.currentStorageDigest()
        }
        if let storageDigest {
            try usageRequireString("storageIdentitySHA256", in: object, equals: storageDigest)
        }
        let session = try usageString("lastSessionID", in: object)
        guard usageSafeSessionID(session) else { throw NotikaCacheUsageError.invalidField("lastSessionID") }
        let created = try usageTimestamp(usageString("createdAt", in: object), field: "createdAt")
        let lastUsed = try usageTimestamp(usageString("lastUsedAt", in: object), field: "lastUsedAt")
        guard created.microsecondsSince1970 <= lastUsed.microsecondsSince1970 else {
            throw NotikaCacheUsageError.invalidTimeRange
        }
        // Every publication rewrites the directory identity, so the last use
        // is when the stored device number was observed.
        let sameDirectory = boot?.admits(
            storedDeviceID: storedDeviceID, storedInode: storedInode,
            recordedAtMicrosecondsSince1970: lastUsed.microsecondsSince1970,
            observedDeviceID: directoryObservation.deviceID, observedInode: directoryObservation.inode
        ) ?? (storedDeviceID == directoryObservation.deviceID)
        guard sameDirectory else { throw NotikaCacheUsageError.invalidField("directoryIdentity") }

        self.document = document
        self.directoryObservation = directoryObservation
        schemaVersion = version
        compatibilityIdentity = identity
        compatibilityFamily = expectedFamily
        compatibilityFamilySHA256 = familyDigest
        compatibilityIdentitySHA256 = executionDigest
        storageIdentitySHA256 = storageDigest
        agentLeaseResource = expectedResource
        createdAt = created.date
        lastUsedAt = lastUsed.date
        createdAtMicrosecondsSince1970 = created.microsecondsSince1970
        lastUsedAtMicrosecondsSince1970 = lastUsed.microsecondsSince1970
        lastSessionID = session
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.document == rhs.document && lhs.directoryObservation == rhs.directoryObservation
    }
}

private func sameUsageUTF8(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.elementsEqual(rhs.utf8)
}

private func usageLowercaseHex(_ value: String, length: Int) -> Bool {
    value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}

private func usageSafeSessionID(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    func alphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }
    guard let first = bytes.first, bytes.count <= 128, alphanumeric(first) else { return false }
    return bytes.dropFirst().allSatisfy { alphanumeric($0) || $0 == 46 || $0 == 95 || $0 == 45 }
}

private func usageString(_ key: String, in object: StrictJSONObject) throws -> String {
    guard case .string(let value) = try object.requiredValue(forKey: key) else {
        throw NotikaCacheUsageError.invalidField(key)
    }
    return value
}

private func usageRequireString(_ key: String, in object: StrictJSONObject, equals expected: String) throws {
    guard try sameUsageUTF8(usageString(key, in: object), expected) else {
        throw NotikaCacheUsageError.invalidField(key)
    }
}

private func usageUnsigned(_ key: String, in object: StrictJSONObject) throws -> UInt64 {
    guard case .number(let number) = try object.requiredValue(forKey: key) else {
        throw NotikaCacheUsageError.invalidField(key)
    }
    return try number.uint64()
}

/// Preserve raw object-member keys through conversion rather than passing
/// evidence through Foundation's JSON dictionaries or NSNumber coercion.
private func usageCanonicalJSON(_ value: StrictJSONValue) throws -> CanonicalJSONValue {
    switch value {
    case .array(let values): return .array(try values.map(usageCanonicalJSON))
    case .bool(let value): return .bool(value)
    case .null: return .null
    case .number(let value):
        if value.lexicalValue.hasPrefix("-") { return .integer(try value.int64()) }
        return .unsignedInteger(try value.uint64())
    case .object(let object):
        return .object(try object.members.map { CanonicalJSONMember(key: $0.key, value: try usageCanonicalJSON($0.value)) })
    case .string(let value): return .string(value)
    }
}

private struct UsageTimestamp {
    let date: Date
    let microsecondsSince1970: Int64
}

private func usageTimestamp(_ value: String, field: String) throws -> UsageTimestamp {
    let bytes = Array(value.utf8)
    func invalid() -> NotikaCacheUsageError { .invalidField(field) }
    guard (20...32).contains(bytes.count), bytes[4] == 45, bytes[7] == 45,
          bytes[10] == 84, bytes[13] == 58, bytes[16] == 58 else { throw invalid() }
    func number(_ start: Int, _ count: Int) throws -> Int {
        guard start + count <= bytes.count else { throw invalid() }
        var value = 0
        for byte in bytes[start..<(start + count)] {
            guard (48...57).contains(byte) else { throw invalid() }
            value = value * 10 + Int(byte - 48)
        }
        return value
    }
    let year = try number(0, 4)
    let month = try number(5, 2)
    let day = try number(8, 2)
    let hour = try number(11, 2)
    let minute = try number(14, 2)
    let second = try number(17, 2)
    guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
          (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { throw invalid() }
    var index = 19
    var microseconds = 0
    if bytes[index] == 46 {
        index += 1
        let start = index
        while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
        let digits = index - start
        guard (1...6).contains(digits) else { throw invalid() }
        microseconds = try number(start, digits)
        for _ in digits..<6 { microseconds *= 10 }
    }
    guard index < bytes.count else { throw invalid() }
    let offsetSeconds: Int
    if bytes[index] == 90, index + 1 == bytes.count {
        offsetSeconds = 0
    } else {
        guard (bytes[index] == 43 || bytes[index] == 45), index + 6 == bytes.count,
              bytes[index + 3] == 58 else { throw invalid() }
        let offsetHour = try number(index + 1, 2)
        let offsetMinute = try number(index + 4, 2)
        guard (0...23).contains(offsetHour), (0...59).contains(offsetMinute) else { throw invalid() }
        offsetSeconds = (offsetHour * 3600 + offsetMinute * 60) * (bytes[index] == 43 ? 1 : -1)
    }
    // Python datetime uses proleptic Gregorian dates. Foundation's Gregorian
    // calendar has a historical Julian cutover, so civil-date arithmetic is
    // explicit here. All admitted years fit exact signed 64-bit microseconds.
    let leap = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
    let monthDays = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    guard day <= monthDays[month - 1] else { throw invalid() }
    func daysBeforeYear(_ value: Int) -> Int {
        let previous = value - 1
        return previous * 365 + previous / 4 - previous / 100 + previous / 400
    }
    let epochDays = daysBeforeYear(1970)
    let dayNumber = daysBeforeYear(year) + monthDays.prefix(month - 1).reduce(0, +) + day - 1
    let utcSeconds = Int64(dayNumber - epochDays) * 86_400
        + Int64(hour * 3600 + minute * 60 + second - offsetSeconds)
    let minimumUTC = -Int64(epochDays) * 86_400
    let maximumUTC = Int64(daysBeforeYear(10_000) - epochDays) * 86_400 - 1
    guard (minimumUTC...maximumUTC).contains(utcSeconds) else { throw invalid() }
    let exactMicroseconds = utcSeconds * 1_000_000 + Int64(microseconds)
    return UsageTimestamp(
        date: Date(timeIntervalSince1970: Double(utcSeconds) + Double(microseconds) / 1_000_000),
        microsecondsSince1970: exactMicroseconds
    )
}
