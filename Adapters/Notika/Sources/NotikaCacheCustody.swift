import AgentBuildCore
import AgentLeaseCore
import Darwin
import Foundation
import Synchronization

public enum NotikaCacheCustodyError: Error, Equatable, Sendable {
    case ownershipMismatch
    case unsafeEntry(String)
    case identityChanged(String)
    case invalidTimestamp
    case io(operation: String, code: Int32)
}

/// Diagnostic observations only; the live borrowed ownership and descriptors
/// remain the authority for operations on the compatible cache.
public struct NotikaCacheCustodyFacts: Encodable, Equatable, Sendable {
    public let canonicalRepository: String
    public let cacheRoot: String
    public let cacheDirectory: String
    public let cacheKey: String
    public let metadataSchemaVersion: Int
    public let directoryDeviceID: UInt64
    public let directoryInode: UInt64
    public let ownerUID: UInt32
    public let agentLeaseResource: String
}

/// Produces the exact current/historical Xcode usage schema for one admitted
/// directory. The returned record validates every binding and preserves literal
/// UTF-8. This pure factory does not publish bytes or acquire ownership.
public enum NotikaCacheUsageFactory {
    public static func make(
        identity: CacheCompatibilityIdentity,
        directoryObservation: NotikaCacheDirectoryObservation,
        sessionID: String,
        usedAt: Date,
        createdAt: String? = nil
    ) throws -> NotikaCacheUsageRecord {
        let schema = try schemaVersion(identity: identity, cacheKey: directoryObservation.cacheKey)
        let used = try cacheTimestamp(usedAt)
        let family = try identity.compatibilityFamily(metadataSchemaVersion: schema)
        let resource = try CacheCompatibilityIdentity.cacheResourceName(
            canonicalWorktree: directoryObservation.canonicalRepository,
            canonicalCachePath: directoryObservation.canonicalCachePath
        )
        var value: [String: CanonicalJSONValue] = [
            "schemaVersion": .integer(Int64(schema)),
            "resourceID": .string("notika.agent-cache-usage"),
            "repository": .string(directoryObservation.canonicalRepository),
            "cacheRoot": .string(directoryObservation.canonicalCacheRoot),
            "cacheKey": .string(directoryObservation.cacheKey),
            "cachePath": .string(directoryObservation.canonicalCachePath),
            "directoryIdentity": .object([
                "deviceID": .unsignedInteger(directoryObservation.deviceID),
                "inode": .unsignedInteger(directoryObservation.inode),
            ]),
            "ownerUID": .unsignedInteger(UInt64(directoryObservation.effectiveUserID)),
            "ownershipAuthority": .string("agentlease-kernel-lock"),
            "agentLeaseResource": .string(resource),
            "compatibilityFamily": family,
            "compatibilityFamilySHA256": .string(try CanonicalJSONDigest.sha256(family)),
            "compatibilityKeyMaterial": identity.keyMaterial,
            "compatibilityIdentitySHA256": .string(try identity.executionDigest()),
            "createdAt": .string(createdAt ?? used),
            "lastUsedAt": .string(used),
            "lastSessionID": .string(sessionID),
        ]
        if schema != 1 {
            let storage: String
            switch schema {
            case 4: storage = try identity.currentStorageDigest()
            case 3: storage = try identity.schema3StorageDigest()
            default: storage = try identity.legacyStorageDigest()
            }
            value["storageIdentitySHA256"] = .string(storage)
        }
        var bytes = try CanonicalJSONDigest.encode(.object(value))
        bytes.append(10)
        return try NotikaCacheUsageRecord(data: bytes, directoryObservation: directoryObservation)
    }

    fileprivate static func schemaVersion(identity: CacheCompatibilityIdentity, cacheKey: String) throws -> Int {
        for version in [4, 3, 2, 1] where try identity.cacheKey(metadataSchemaVersion: version) == cacheKey { return version }
        throw CacheCompatibilityError.incompatibleAdmission
    }
}

/// Borrows a live Notika project scope; it never extends or releases its leases.
/// The cache namespace is retained through nofollow, close-on-exec descriptors.
/// Each operation revalidates the exact ownership and directory chain. Callers
/// must retain this object and await their native child before leaving ownership.
/// Cooperative leases exclude other producers; this is not a hostile same-UID
/// isolation boundary or a collector/deletion capability.
public final class NotikaCacheCustody: Sendable {
    public static let metadataFilename = ".notika-cache-usage.json"
    public static let derivedDataEnvironmentKey = "NOTIKA_DERIVED_DATA"

    public let identity: CacheCompatibilityIdentity
    public let facts: NotikaCacheCustodyFacts
    public let directoryObservation: NotikaCacheDirectoryObservation
    public var cacheDirectory: String { facts.cacheDirectory }
    public var environment: [String: String] { [Self.derivedDataEnvironmentKey: cacheDirectory] }

    private let ownership: ProjectOwnership
    private let directories: [CacheDirectoryPin]
    private let boot: DirectoryIdentityBoot
    private let operation = Mutex(())

    public init(identity: CacheCompatibilityIdentity, ownership: ProjectOwnership) throws {
        guard let cacheDirectory = ownership.plan.cacheDirectory,
              cacheSameUTF8(ownership.plan.canonicalWorktree, identity.canonicalWorktree) else {
            throw NotikaCacheCustodyError.ownershipMismatch
        }
        let key = String(cacheDirectory.split(separator: "/").last ?? "")
        let expectedPlan = try NotikaProjectOwnershipPlan(identity: identity, admittedCacheKey: key)
        guard ownership.plan == expectedPlan else { throw NotikaCacheCustodyError.ownershipMismatch }
        let resource = try CacheCompatibilityIdentity.cacheResourceName(
            canonicalWorktree: identity.canonicalWorktree, canonicalCachePath: cacheDirectory
        )
        try Self.requireOwnership(ownership, resource: resource)
        let chain = try Self.openDirectoryChain(repository: identity.canonicalWorktree, cacheKey: key)
        let cache = chain.last!
        guard let deviceID = UInt64(exactly: cache.identity.device) else {
            throw NotikaCacheCustodyError.unsafeEntry("cache device")
        }
        let rootPath = (identity.canonicalWorktree == "/" ? "" : identity.canonicalWorktree) + "/DerivedData/AgentCaches"
        let observation = try NotikaCacheDirectoryObservation(
            canonicalRepository: identity.canonicalWorktree, canonicalCacheRoot: rootPath,
            canonicalCachePath: cacheDirectory, deviceID: deviceID, inode: UInt64(cache.identity.inode),
            ownerUID: cache.identity.owner, effectiveUserID: geteuid()
        )
        self.identity = identity
        self.ownership = ownership
        directories = chain
        boot = try DirectoryIdentityBoot.current()
        directoryObservation = observation
        facts = NotikaCacheCustodyFacts(
            canonicalRepository: identity.canonicalWorktree, cacheRoot: rootPath,
            cacheDirectory: cacheDirectory, cacheKey: key,
            metadataSchemaVersion: try NotikaCacheUsageFactory.schemaVersion(identity: identity, cacheKey: key),
            directoryDeviceID: observation.deviceID, directoryInode: observation.inode,
            ownerUID: observation.ownerUID, agentLeaseResource: resource
        )
        try revalidateBeforeOperation()
    }

    public func revalidateBeforeOperation() throws {
        try operation.withLock { _ in
            try validateNamespaceAndOwnership()
            _ = try readUsageAdmission()
            try validateNamespaceAndOwnership()
        }
    }

    public func readUsage() throws -> NotikaCacheUsageRecord? {
        try operation.withLock { _ in
            try validateNamespaceAndOwnership()
            let record = try readUsageAdmission()?.record
            try validateNamespaceAndOwnership()
            return record
        }
    }

    /// Borrowed for native child inheritance; retain custody and await the child
    /// inside the project scope. Callers must not close these descriptors or
    /// change their flags. Owner descriptors remain close-on-exec.
    public func inheritedDirectoryDescriptors() throws -> [Int32] {
        try operation.withLock { _ in
            try validateNamespaceAndOwnership()
            return directories.map { $0.descriptor.value }
        }
    }

    /// Write only after admitting any existing usage. Unknown/unsafe evidence is
    /// preserved. Initial publication never replaces a newly appeared pathname.
    @discardableResult
    public func publishUsage(sessionID: String, usedAt: Date = Date()) throws -> NotikaCacheUsageRecord {
        try operation.withLock { _ in
            try validateNamespaceAndOwnership()
            let previous = try readUsageAdmission()
            let created: String?
            if let previous {
                guard case .string(let value) = try previous.record.document.root.requireObject().requiredValue(forKey: "createdAt") else {
                    throw NotikaCacheUsageError.invalidField("createdAt")
                }
                created = value
            } else {
                created = nil
            }
            let record = try NotikaCacheUsageFactory.make(
                identity: identity, directoryObservation: directoryObservation,
                sessionID: sessionID, usedAt: usedAt, createdAt: created
            )
            let directory = directories.last!.descriptor.value
            let temporary = "." + Self.metadataFilename + "." + UUID().uuidString + ".tmp"
            var writer = Darwin.openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard writer >= 0 else { throw cacheFailure("create usage stage") }
            let stageIdentity: CacheDirectoryIdentity
            do { stageIdentity = CacheDirectoryIdentity(try cacheStatus(writer)) }
            catch { Darwin.close(writer); throw error }
            var stageExists = true
            defer {
                if writer >= 0 { let retiring = writer; writer = -1; Darwin.close(retiring) }
                if stageExists, let status = try? cacheStatus(at: temporary, directory: directory),
                   CacheDirectoryIdentity(status).sameInode(as: stageIdentity) {
                    Darwin.unlinkat(directory, temporary, 0)
                }
            }
            guard Darwin.fchmod(writer, 0o600) == 0 else { throw cacheFailure("set usage stage mode") }
            try cacheWrite(record.originalData, descriptor: writer)
            try cacheSynchronize(writer, operation: "synchronize usage stage")
            let retiring = writer
            writer = -1
            guard Darwin.close(retiring) == 0 else { throw cacheFailure("retire usage writer") }
            guard let stage = try readUsageAdmission(named: temporary) else {
                throw NotikaCacheCustodyError.identityChanged("usage stage disappeared")
            }
            guard stage.record.originalData == record.originalData,
                  stage.fingerprint.identity.sameInode(as: stageIdentity) else {
                throw NotikaCacheCustodyError.identityChanged("usage stage")
            }
            try validateNamespaceAndOwnership()
            if let previous {
                try previous.revalidate(directory: directory, name: Self.metadataFilename)
            } else if try cacheStatusIfPresent(at: Self.metadataFilename, directory: directory) != nil {
                throw NotikaCacheCustodyError.identityChanged("usage appeared")
            }
            try stage.revalidate(directory: directory, name: temporary)
            let renamed = previous == nil
                ? Darwin.renameatx_np(directory, temporary, directory, Self.metadataFilename, UInt32(RENAME_EXCL))
                : Darwin.renameat(directory, temporary, directory, Self.metadataFilename)
            guard renamed == 0 else { throw cacheFailure("publish usage metadata") }
            stageExists = false
            try cacheSynchronize(directory, operation: "synchronize cache directory")
            try validateNamespaceAndOwnership()
            guard let published = try readUsageAdmission() else {
                throw NotikaCacheCustodyError.identityChanged("published usage disappeared")
            }
            guard published.fingerprint.identity.sameInode(as: stage.fingerprint.identity),
                  published.record.originalData == record.originalData else {
                throw NotikaCacheCustodyError.identityChanged("published usage")
            }
            return published.record
        }
    }

    private func validateNamespaceAndOwnership() throws {
        try Self.requireOwnership(ownership, resource: facts.agentLeaseResource)
        try Self.validateDirectoryChain(directories)
    }

    private static func validateDirectoryChain(_ chain: [CacheDirectoryPin]) throws {
        for (index, directory) in chain.enumerated() {
            guard CacheDirectoryIdentity(try cacheStatus(directory.descriptor.value)) == directory.identity else {
                throw NotikaCacheCustodyError.identityChanged(directory.name)
            }
            if index > 0 {
                let observed = try cacheStatus(at: directory.name, directory: chain[index - 1].descriptor.value)
                guard CacheDirectoryIdentity(observed) == directory.identity else {
                    throw NotikaCacheCustodyError.identityChanged(directory.name)
                }
            }
        }
    }

    private static func requireOwnership(_ ownership: ProjectOwnership, resource: String) throws {
        let leases = try ownership.inheritedLeaseDescriptors()
        guard leases.count == 3, leases[0].mode == .shared, leases[1].mode == .shared,
              leases[2].mode == .exclusive, leases[2].resource == resource else {
            throw NotikaCacheCustodyError.ownershipMismatch
        }
        for lease in leases { _ = try cacheStatus(lease.descriptor) }
        let lease = leases[2]
        let manifest = try InheritedLeaseManifest(leases: [lease]).environmentValue()
        try InheritedExclusiveLeaseGuard.establish(resource: resource, environment: [
            AgentLeasePaths.homeEnvironmentKey: ownership.registryRoot,
            ChildEnvironment.heldResourcesKey: resource,
            InheritedLeaseManifest.environmentKey: manifest,
        ])
    }

    private static func openDirectoryChain(repository: String, cacheKey: String) throws -> [CacheDirectoryPin] {
        let root = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw cacheFailure("open filesystem root") }
        let rootDescriptor = CacheDescriptor(root)
        var chain = [CacheDirectoryPin(name: "/", descriptor: rootDescriptor, identity: CacheDirectoryIdentity(try cacheStatus(root)))]
        let components = repository.split(separator: "/").map(String.init)
        for component in components {
            chain.append(try openDirectory(component, parent: chain.last!, create: false, permissions: nil, requiredDevice: nil))
        }
        let repositoryStatus = try cacheStatus(chain.last!.descriptor.value)
        guard repositoryStatus.st_uid == geteuid(), repositoryStatus.st_mode & 0o7022 == 0 else {
            throw NotikaCacheCustodyError.unsafeEntry("repository")
        }
        let device = repositoryStatus.st_dev
        for (name, mode) in [("DerivedData", UInt16(0)), ("AgentCaches", UInt16(0o700)), (cacheKey, UInt16(0o700))] {
            try validateDirectoryChain(chain)
            chain.append(try openDirectory(name, parent: chain.last!, create: true, permissions: mode, requiredDevice: device))
            try validateDirectoryChain(chain)
        }
        return chain
    }

    private static func openDirectory(
        _ name: String, parent: CacheDirectoryPin, create: Bool, permissions: UInt16?, requiredDevice: dev_t?
    ) throws -> CacheDirectoryPin {
        guard CacheDirectoryIdentity(try cacheStatus(parent.descriptor.value)) == parent.identity else {
            throw NotikaCacheCustodyError.identityChanged(parent.name)
        }
        if create, Darwin.mkdirat(parent.descriptor.value, name, 0o700) != 0, errno != EEXIST {
            throw cacheFailure("create " + name)
        }
        let pathStatus = try cacheStatus(at: name, directory: parent.descriptor.value)
        guard pathStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw NotikaCacheCustodyError.unsafeEntry(name) }
        let descriptor = Darwin.openat(parent.descriptor.value, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw cacheFailure("open " + name) }
        let retained = CacheDescriptor(descriptor)
        let status = try cacheStatus(descriptor)
        let identity = CacheDirectoryIdentity(status)
        guard identity == CacheDirectoryIdentity(pathStatus) else { throw NotikaCacheCustodyError.identityChanged(name) }
        if let permissions {
            guard status.st_uid == geteuid(), status.st_mode & 0o7022 == 0,
                  permissions == 0 || status.st_mode & 0o777 == mode_t(permissions) else {
                throw NotikaCacheCustodyError.unsafeEntry(name)
            }
        }
        if let requiredDevice, status.st_dev != requiredDevice { throw NotikaCacheCustodyError.unsafeEntry(name) }
        return CacheDirectoryPin(name: name, descriptor: retained, identity: identity)
    }

    private func readUsageAdmission(named name: String = NotikaCacheCustody.metadataFilename) throws -> CacheUsageAdmission? {
        let directory = directories.last!.descriptor.value
        guard let status = try cacheStatusIfPresent(at: name, directory: directory) else { return nil }
        try cacheValidateMetadata(status, name: name, device: directories.last!.identity.device)
        let descriptor = Darwin.openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw cacheFailure("open usage metadata") }
        let retained = CacheDescriptor(descriptor)
        let fingerprint = CacheMetadataFingerprint(status)
        guard CacheMetadataFingerprint(try cacheStatus(descriptor)) == fingerprint else {
            throw NotikaCacheCustodyError.identityChanged(name)
        }
        let data = try cacheRead(descriptor, size: Int(status.st_size))
        let record = try NotikaCacheUsageRecord(data: data, directoryObservation: directoryObservation, boot: boot)
        let admission = CacheUsageAdmission(descriptor: retained, fingerprint: fingerprint, record: record)
        try admission.revalidate(directory: directory, name: name)
        return admission
    }
}

private final class CacheDescriptor: Sendable {
    let value: Int32
    init(_ value: Int32) { self.value = value }
    deinit { Darwin.close(value) }
}

private struct CacheDirectoryPin: Sendable {
    let name: String
    let descriptor: CacheDescriptor
    let identity: CacheDirectoryIdentity
}

private struct CacheDirectoryIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let owner: uid_t
    let group: gid_t
    let mode: mode_t
    init(_ status: stat) {
        device = status.st_dev; inode = status.st_ino; owner = status.st_uid
        group = status.st_gid; mode = status.st_mode
    }
    func sameInode(as other: Self) -> Bool { device == other.device && inode == other.inode }
}

private struct CacheMetadataFingerprint: Equatable, Sendable {
    let identity: CacheDirectoryIdentity
    let links: nlink_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
    init(_ status: stat) {
        identity = CacheDirectoryIdentity(status); links = status.st_nlink; size = status.st_size
        modifiedSeconds = status.st_mtimespec.tv_sec; modifiedNanoseconds = status.st_mtimespec.tv_nsec
        changedSeconds = status.st_ctimespec.tv_sec; changedNanoseconds = status.st_ctimespec.tv_nsec
    }
}

private struct CacheUsageAdmission {
    let descriptor: CacheDescriptor
    let fingerprint: CacheMetadataFingerprint
    let record: NotikaCacheUsageRecord
    func revalidate(directory: Int32, name: String) throws {
        guard CacheMetadataFingerprint(try cacheStatus(descriptor.value)) == fingerprint,
              CacheMetadataFingerprint(try cacheStatus(at: name, directory: directory)) == fingerprint,
              try cacheRead(descriptor.value, size: Int(fingerprint.size)) == record.originalData else {
            throw NotikaCacheCustodyError.identityChanged(name)
        }
        guard CacheMetadataFingerprint(try cacheStatus(descriptor.value)) == fingerprint,
              CacheMetadataFingerprint(try cacheStatus(at: name, directory: directory)) == fingerprint else {
            throw NotikaCacheCustodyError.identityChanged(name)
        }
    }
}

private func cacheSameUTF8(_ left: String, _ right: String) -> Bool { left.utf8.elementsEqual(right.utf8) }
private func cacheFailure(_ operation: String) -> NotikaCacheCustodyError { .io(operation: operation, code: errno) }

private func cacheStatus(_ descriptor: Int32) throws -> stat {
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0 else { throw cacheFailure("fstat") }
    return status
}

private func cacheStatus(at name: String, directory: Int32) throws -> stat {
    guard let status = try cacheStatusIfPresent(at: name, directory: directory) else {
        throw NotikaCacheCustodyError.io(operation: "fstatat " + name, code: ENOENT)
    }
    return status
}

private func cacheStatusIfPresent(at name: String, directory: Int32) throws -> stat? {
    var status = stat()
    if Darwin.fstatat(directory, name, &status, AT_SYMLINK_NOFOLLOW) == 0 { return status }
    if errno == ENOENT { return nil }
    throw cacheFailure("fstatat " + name)
}

private func cacheValidateMetadata(_ status: stat, name: String, device: dev_t) throws {
    guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), status.st_mode & 0o7777 == 0o600,
          status.st_uid == geteuid(), status.st_nlink == 1, status.st_dev == device,
          status.st_size > 0, status.st_size <= NotikaCacheUsageRecord.maximumBytes else {
        throw NotikaCacheCustodyError.unsafeEntry(name)
    }
}

private func cacheRead(_ descriptor: Int32, size: Int) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: size)
    var offset = 0
    while offset < size {
        let count = bytes.withUnsafeMutableBytes {
            Darwin.pread(descriptor, $0.baseAddress!.advanced(by: offset), size - offset, off_t(offset))
        }
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw NotikaCacheCustodyError.io(operation: "read usage metadata", code: count == 0 ? EIO : errno) }
        offset += count
    }
    var extra: UInt8 = 0
    let tail = Darwin.pread(descriptor, &extra, 1, off_t(size))
    guard tail == 0 else { throw NotikaCacheCustodyError.identityChanged("usage size") }
    return Data(bytes)
}

private func cacheWrite(_ data: Data, descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw NotikaCacheCustodyError.io(operation: "write usage metadata", code: count == 0 ? EIO : errno) }
            offset += count
        }
    }
}

private func cacheSynchronize(_ descriptor: Int32, operation: String) throws {
    while Darwin.fsync(descriptor) != 0 { if errno != EINTR { throw cacheFailure(operation) } }
}

private func cacheTimestamp(_ date: Date) throws -> String {
    let scaled = (date.timeIntervalSince1970 * 1_000_000).rounded()
    guard scaled.isFinite, scaled >= -62_135_596_800_000_000, scaled < 253_402_300_800_000_000 else {
        throw NotikaCacheCustodyError.invalidTimestamp
    }
    let microseconds = Int64(scaled)
    func floorDivide(_ value: Int64, by divisor: Int64) -> Int64 {
        let quotient = value / divisor
        return value % divisor < 0 ? quotient - 1 : quotient
    }
    let seconds = floorDivide(microseconds, by: 1_000_000)
    let fraction = microseconds - seconds * 1_000_000
    let days = floorDivide(seconds, by: 86_400)
    let withinDay = seconds - days * 86_400
    let absoluteDay = Int(days) + 719_162
    func daysBeforeYear(_ year: Int) -> Int { let previous = year - 1; return previous * 365 + previous / 4 - previous / 100 + previous / 400 }
    var low = 1
    var high = 10_000
    while low + 1 < high {
        let middle = (low + high) / 2
        if daysBeforeYear(middle) <= absoluteDay { low = middle } else { high = middle }
    }
    let leap = low.isMultiple(of: 4) && (!low.isMultiple(of: 100) || low.isMultiple(of: 400))
    let monthDays = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    var month = 1
    var day = absoluteDay - daysBeforeYear(low)
    while day >= monthDays[month - 1] { day -= monthDays[month - 1]; month += 1 }
    var result = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", low, month, day + 1,
                        Int(withinDay / 3600), Int(withinDay % 3600 / 60), Int(withinDay % 60))
    if fraction != 0 { result += String(format: ".%06d", Int(fraction)) }
    return result + "Z"
}
