import AgentLeaseCore
import Darwin
import Foundation

public enum NotikaCacheRetentionRootState: String, Codable, Sendable { case ready, absent, busy, unsafe, entryBoundExceeded }
public enum NotikaCacheRetentionClassification: String, Codable, Sendable { case eligible, retained, unmanaged, invalid, busy }
public enum NotikaCacheRetentionAction: String, Codable, Sendable { case none, wouldTrash, trashed, skippedBusy, skippedRevalidation, trashFailed }
public enum NotikaCacheRetentionReason: String, Codable, Sendable {
    case beforeLocalDay, currentLocalDay, lastUseInFuture, metadataAbsent, metadataInvalid
    case entryUnsafe, nameUnsafe, finderMetadata, finderMetadataUnsafe, cacheBusy
    case evidenceChanged, sizeUnavailable, wouldMoveToTrash, movedToTrash, trashFailed
    case rootUnsafe, rootChanged, policyBusy, policyUnavailable, rootEntryBoundExceeded, pendingTrashClaims
}

public struct NotikaCacheRetentionEvidence: Equatable, Codable, Sendable {
    public let deviceID: UInt64
    public let inode: UInt64
    public let metadataDigest: String
    public let schemaVersion: Int
    public let lastUsedAtMicrosecondsSince1970: Int64
}

public struct NotikaCacheRetentionEntry: Equatable, Codable, Sendable {
    public let name: String
    public let classification: NotikaCacheRetentionClassification
    public let action: NotikaCacheRetentionAction
    public let reason: NotikaCacheRetentionReason
    /// Allocated source blocks observed under custody. Moving to Trash does not
    /// establish that these bytes have been freed from the disk.
    public let allocatedBytes: UInt64?
    public let evidence: NotikaCacheRetentionEvidence?
    public let detail: String?
}

public struct NotikaCacheRetentionReport: Equatable, Codable, Sendable {
    public let policy: ArtifactRetentionPolicy
    public let execute: Bool
    public let evaluatedAt: Date
    public let localDayCutoff: Date
    public let timeZoneIdentifier: String
    public let rootState: NotikaCacheRetentionRootState
    public let rootReason: NotikaCacheRetentionReason?
    public let scanComplete: Bool
    public let entries: [NotikaCacheRetentionEntry]
    public let trashOperatorIdentifier: String?

    public var movedToTrashAllocatedBytes: UInt64 {
        entries.filter { $0.action == .trashed }.reduce(0) { total, entry in
            let next = total.addingReportingOverflow(entry.allocatedBytes ?? 0)
            return next.overflow ? UInt64.max : next.partialValue
        }
    }
}

public enum NotikaCacheRetentionError: Error, Equatable, Sendable {
    case absentRoot
    case unsafeEntry
    case evidenceChanged
    case traversalBoundExceeded
    case retiredSource
    case trashFailed
    case systemCall(String, Int32)
}

/// Today-only Xcode-cache collection. The exclusive repository policy is the
/// same resource producers hold shared throughout their native child lifetime;
/// per-key exclusive admission additionally protects older producers. No session
/// or Rust namespace is inspected. Missing/odd evidence is retained, not adopted.
public struct NotikaCacheRetentionCollector: Sendable {
    public static let maximumRootEntries = 1_024
    public static let maximumCacheNodes = 1_000_000
    public static let maximumCacheDepth = 256
    private let repository: String
    private let registryRoot: String
    private let calendar: LocalCalendarRetention
    private let trash: any ArtifactTrashOperator
    private let beforeRevalidation: @Sendable (String) async throws -> Void
    private let claimDirectoryFactory: @Sendable (String) throws -> RetainedArtifactDirectory

    public init(
        canonicalRepository: String, registryRoot: String,
        evaluatedAt: Date = Date(), timeZone: TimeZone = .current,
        trashOperator: any ArtifactTrashOperator = SystemArtifactTrashOperator(),
        beforeRevalidation: @escaping @Sendable (String) async throws -> Void = { _ in }
    ) throws {
        try self.init(
            canonicalRepository: canonicalRepository, registryRoot: registryRoot,
            evaluatedAt: evaluatedAt, timeZone: timeZone, trashOperator: trashOperator,
            beforeRevalidation: beforeRevalidation,
            claimDirectoryFactory: { try RetainedArtifactDirectory(path: $0, requiredPermissions: 0o700) }
        )
    }

    internal init(
        canonicalRepository: String, registryRoot: String,
        evaluatedAt: Date, timeZone: TimeZone,
        trashOperator: any ArtifactTrashOperator,
        beforeRevalidation: @escaping @Sendable (String) async throws -> Void,
        claimDirectoryFactory: @escaping @Sendable (String) throws -> RetainedArtifactDirectory
    ) throws {
        _ = try CacheCompatibilityIdentity.cachePolicyResourceName(canonicalWorktree: canonicalRepository)
        repository = canonicalRepository; self.registryRoot = registryRoot
        calendar = try LocalCalendarRetention(evaluatedAt: evaluatedAt, timeZone: timeZone)
        trash = trashOperator; self.beforeRevalidation = beforeRevalidation
        self.claimDirectoryFactory = claimDirectoryFactory
    }

    public func run(execute: Bool) async throws -> NotikaCacheRetentionReport {
        try Task.checkCancellation()
        let paths: AgentLeasePaths
        let policy: FileLock
        do {
            paths = try AgentLeasePaths.open(selectedRoot: registryRoot)
            policy = try FileLock(resource: ResourceName(CacheCompatibilityIdentity.cachePolicyResourceName(canonicalWorktree: repository)), paths: paths)
            guard try policy.tryAcquire() else { return report(execute, root: .busy, reason: .policyBusy) }
        } catch { return report(execute, root: .unsafe, reason: .policyUnavailable) }
        defer { policy.release() }
        let root: CacheRetentionRoot
        do {
            root = try CacheRetentionRoot(repository: repository)
            if try root.hasPendingClaims() { return report(execute, root: .unsafe, reason: .pendingTrashClaims) }
        } catch NotikaCacheRetentionError.absentRoot {
            return report(execute, root: .absent, complete: true)
        } catch { return report(execute, root: .unsafe, reason: .rootUnsafe) }
        let names: [String]
        do { names = try retentionNames(root.rootDescriptor.value, maximum: Self.maximumRootEntries) }
        catch NotikaCacheRetentionError.traversalBoundExceeded { return report(execute, root: .entryBoundExceeded, reason: .rootEntryBoundExceeded) }
        catch { return report(execute, root: .unsafe, reason: .rootUnsafe) }
        var entries: [NotikaCacheRetentionEntry] = []
        for name in names.sorted() {
            try Task.checkCancellation()
            do { try root.revalidate() }
            catch { return report(execute, root: .unsafe, reason: .rootChanged, entries: entries) }
            if name == ".DS_Store" {
                entries.append(root.finderMetadata())
            } else if !retentionSafeKey(name) {
                entries.append(retentionEntry(name, .invalid, .nameUnsafe))
            } else {
                entries.append(try await assess(name, root: root, paths: paths, policy: policy, execute: execute))
            }
        }
        do { try root.revalidate() }
        catch { return report(execute, root: .unsafe, reason: .rootChanged, entries: entries) }
        return report(execute, root: .ready, complete: true, entries: entries)
    }

    private func assess(
        _ name: String, root: CacheRetentionRoot, paths: AgentLeasePaths, policy: FileLock, execute: Bool
    ) async throws -> NotikaCacheRetentionEntry {
        let cachePath = root.path + "/" + name
        let cacheLock: FileLock
        do {
            cacheLock = try FileLock(resource: ResourceName(CacheCompatibilityIdentity.cacheResourceName(canonicalWorktree: repository, canonicalCachePath: cachePath)), paths: paths)
            guard try cacheLock.tryAcquire() else { return retentionEntry(name, .busy, .cacheBusy, action: .skippedBusy) }
        } catch { return retentionEntry(name, .invalid, .entryUnsafe, detail: error) }
        defer { cacheLock.release() }
        let admission: CacheRetentionAdmission
        do { admission = try CacheRetentionAdmission(root: root, name: name, repository: repository) }
        catch NotikaCacheRetentionError.absentRoot { return retentionEntry(name, .unmanaged, .metadataAbsent) }
        catch let error as NotikaCacheUsageError { return retentionEntry(name, .invalid, .metadataInvalid, detail: error) }
        catch let error as StrictJSONError { return retentionEntry(name, .invalid, .metadataInvalid, detail: error) }
        catch { return retentionEntry(name, .invalid, .entryUnsafe, detail: error) }
        let eligibility = calendar.cacheEligibility(lastUsedAt: admission.record.lastUsedAt)
        if eligibility == .invalid { return retentionEntry(name, .invalid, .lastUseInFuture, evidence: admission.evidence) }
        if eligibility != .eligible { return retentionEntry(name, .retained, .currentLocalDay, evidence: admission.evidence) }
        let bytes: UInt64
        do { bytes = try retentionAllocatedSize(admission.cache.value) }
        catch { return retentionEntry(name, .invalid, .sizeUnavailable, evidence: admission.evidence, detail: error) }
        let bindings: [InheritedLeaseDescriptor]
        do {
            bindings = [try retentionLockBinding(policy), try retentionLockBinding(cacheLock)]
            try await beforeRevalidation(cachePath)
            try retentionValidateLocks(bindings, registryRoot: registryRoot)
            try admission.revalidate(root: root)
            guard calendar.cacheEligibility(lastUsedAt: admission.record.lastUsedAt) == .eligible,
                  try retentionAllocatedSize(admission.cache.value) == bytes else { throw NotikaCacheRetentionError.evidenceChanged }
            try admission.revalidate(root: root)
        } catch is CancellationError { throw CancellationError() }
        catch { return retentionEntry(name, .eligible, .evidenceChanged, action: .skippedRevalidation, evidence: admission.evidence, detail: error) }
        if !execute { return retentionEntry(name, .eligible, .wouldMoveToTrash, action: .wouldTrash, bytes: bytes, evidence: admission.evidence) }
        do {
            try await root.move(admission, locks: bindings, registryRoot: registryRoot, trash: trash, claimDirectoryFactory: claimDirectoryFactory)
            return retentionEntry(name, .eligible, .movedToTrash, action: .trashed, bytes: bytes, evidence: admission.evidence)
        } catch is CancellationError { throw CancellationError() }
        catch { return retentionEntry(name, .eligible, .trashFailed, action: .trashFailed, evidence: admission.evidence, detail: error) }
    }

    private func report(
        _ execute: Bool, root: NotikaCacheRetentionRootState, reason: NotikaCacheRetentionReason? = nil,
        complete: Bool = false, entries: [NotikaCacheRetentionEntry] = []
    ) -> NotikaCacheRetentionReport {
        NotikaCacheRetentionReport(
            policy: .todayOnlyCaches, execute: execute, evaluatedAt: calendar.evaluatedAt,
            localDayCutoff: calendar.localDayStart, timeZoneIdentifier: calendar.timeZone.identifier,
            rootState: root, rootReason: reason, scanComplete: complete, entries: entries,
            trashOperatorIdentifier: execute ? trash.identifier : nil
        )
    }
}

private final class CacheRetentionDescriptor: Sendable {
    let value: Int32
    init(_ value: Int32) { self.value = value }
    deinit { _ = Darwin.close(value) }
}

private struct CacheRetentionDirectoryIdentity: Equatable, Sendable {
    let device: Int64
    let inode: UInt64
    let owner: UInt32
    let group: UInt32
    let mode: UInt16
}

private final class CacheRetentionRoot: Sendable {
    let repository: String
    let path: String
    let repositoryDirectory: RetainedArtifactDirectory
    let derivedDirectory: RetainedArtifactDirectory
    let rootDirectory: RetainedArtifactDirectory
    let derivedDescriptor: CacheRetentionDescriptor
    let rootDescriptor: CacheRetentionDescriptor
    let device: Int64
    var borrowedDescriptors: [Int32] { [derivedDescriptor.value, rootDescriptor.value] }

    init(repository: String) throws {
        self.repository = repository
        repositoryDirectory = try RetainedArtifactDirectory(path: repository)
        device = repositoryDirectory.fingerprint.device
        let base = repository == "/" ? "" : repository
        path = base + "/DerivedData/AgentCaches"
        do {
            derivedDirectory = try RetainedArtifactDirectory(path: base + "/DerivedData")
            rootDirectory = try RetainedArtifactDirectory(path: path, requiredPermissions: 0o700)
        } catch RetainedArtifactError.systemCall(_, ENOENT) { throw NotikaCacheRetentionError.absentRoot }
        guard derivedDirectory.fingerprint.device == device, rootDirectory.fingerprint.device == device else {
            throw NotikaCacheRetentionError.unsafeEntry
        }
        derivedDescriptor = try retentionOpenDirectory(derivedDirectory.path, expected: retentionIdentity(derivedDirectory.fingerprint))
        rootDescriptor = try retentionOpenDirectory(path, expected: retentionIdentity(rootDirectory.fingerprint))
        try revalidate()
    }

    func revalidate() throws {
        try repositoryDirectory.revalidate(); try derivedDirectory.revalidate(); try rootDirectory.revalidate()
        guard try retentionIdentity(retentionStatus(derivedDescriptor.value)) == retentionIdentity(derivedDirectory.fingerprint),
              try retentionIdentity(retentionStatus(rootDescriptor.value)) == retentionIdentity(rootDirectory.fingerprint) else {
            throw NotikaCacheRetentionError.evidenceChanged
        }
    }

    func hasPendingClaims() throws -> Bool {
        guard try retentionStatusIfPresent(at: "AgentCacheTrashClaims", directory: derivedDescriptor.value) != nil else { return false }
        let claims = try RetainedArtifactDirectory(path: derivedDirectory.path + "/AgentCacheTrashClaims", requiredPermissions: 0o700)
        guard claims.fingerprint.device == device else { throw NotikaCacheRetentionError.unsafeEntry }
        let descriptor = try retentionOpenDirectory(claims.path, expected: retentionIdentity(claims.fingerprint))
        let names = try retentionNames(descriptor.value, maximum: NotikaCacheRetentionCollector.maximumRootEntries)
        try claims.revalidate(); try revalidate()
        return !names.isEmpty
    }

    func finderMetadata() -> NotikaCacheRetentionEntry {
        do {
            let observed = try retentionStatus(at: ".DS_Store", directory: rootDescriptor.value)
            guard observed.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), observed.st_uid == geteuid(),
                  observed.st_nlink == 1, observed.st_mode & 0o7022 == 0,
                  Int64(observed.st_dev) == device else { throw NotikaCacheRetentionError.unsafeEntry }
            let opened = Darwin.openat(rootDescriptor.value, ".DS_Store", O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
            guard opened >= 0 else { throw retentionFailure("open Finder metadata") }
            let retained = CacheRetentionDescriptor(opened)
            guard try retentionSameFile(retentionStatus(retained.value), observed),
                  try retentionSameFile(retentionStatus(at: ".DS_Store", directory: rootDescriptor.value), observed) else {
                throw NotikaCacheRetentionError.evidenceChanged
            }
            try revalidate()
            return retentionEntry(".DS_Store", .retained, .finderMetadata)
        } catch { return retentionEntry(".DS_Store", .invalid, .finderMetadataUnsafe, detail: error) }
    }

    func move(
        _ admission: CacheRetentionAdmission, locks: [InheritedLeaseDescriptor], registryRoot: String,
        trash: any ArtifactTrashOperator,
        claimDirectoryFactory: @Sendable (String) throws -> RetainedArtifactDirectory
    ) async throws {
        try retentionValidateLocks(locks, registryRoot: registryRoot)
        try admission.revalidate(root: self)
        if Darwin.mkdirat(derivedDescriptor.value, "AgentCacheTrashClaims", 0o700) != 0, errno != EEXIST {
            throw retentionFailure("create cache Trash claims")
        }
        let claims = try RetainedArtifactDirectory(path: derivedDirectory.path + "/AgentCacheTrashClaims", requiredPermissions: 0o700)
        guard claims.fingerprint.device == device else { throw NotikaCacheRetentionError.unsafeEntry }
        let claimsFD = try retentionOpenDirectory(claims.path, expected: retentionIdentity(claims.fingerprint))
        let name = "." + admission.name + "." + UUID().uuidString + ".claim"
        guard Darwin.mkdirat(claimsFD.value, name, 0o700) == 0 else { throw retentionFailure("create private Trash claim") }
        var placeholderIdentity: CacheRetentionDirectoryIdentity?
        var claimed = false
        // Installed before descriptor allocation: an EMFILE/open failure must
        // not leave an empty placeholder that blocks every following run.
        defer {
            if !claimed, let placeholderIdentity,
               let current = try? retentionStatus(at: name, directory: claimsFD.value),
               retentionIdentity(current) == placeholderIdentity {
                _ = Darwin.unlinkat(claimsFD.value, name, AT_REMOVEDIR)
            }
        }
        let placeholder = try retentionStatus(at: name, directory: claimsFD.value)
        guard placeholder.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), placeholder.st_uid == geteuid(),
              placeholder.st_mode & 0o7777 == 0o700, Int64(placeholder.st_dev) == device else {
            throw NotikaCacheRetentionError.unsafeEntry
        }
        placeholderIdentity = retentionIdentity(placeholder)
        let claim = try claimDirectoryFactory(claims.path + "/" + name)
        guard retentionIdentity(claim.fingerprint) == placeholderIdentity else { throw NotikaCacheRetentionError.evidenceChanged }
        let claimFD = try retentionOpenDirectory(claim.path, expected: retentionIdentity(claim.fingerprint))
        try claims.revalidate(); try claim.revalidate(); try admission.revalidate(root: self)
        guard Darwin.renameatx_np(rootDescriptor.value, admission.name, claimFD.value, admission.name, UInt32(RENAME_EXCL)) == 0 else {
            throw retentionFailure("claim cache for Trash")
        }
        claimed = true
        var source: ArtifactTrashSource?
        defer { source?.retire() }
        do {
            let directory = try RetainedArtifactDirectory(path: claim.path + "/" + admission.name, requiredPermissions: 0o700)
            guard retentionIdentity(directory.fingerprint) == admission.identity else { throw NotikaCacheRetentionError.evidenceChanged }
            let capability = ArtifactTrashSource(
                directory: directory, originalPath: admission.path,
                inheritedDescriptors: locks.map(\.descriptor) + borrowedDescriptors + [admission.cache.value, claimFD.value],
                revalidate: {
                    try retentionValidateLocks(locks, registryRoot: registryRoot)
                    try self.revalidate(); try claim.revalidate()
                    guard try retentionIdentity(retentionStatus(admission.cache.value)) == admission.identity,
                          try retentionIdentity(retentionStatus(at: admission.name, directory: claimFD.value)) == admission.identity else {
                        throw NotikaCacheRetentionError.evidenceChanged
                    }
                    let file = try directory.openFile(named: NotikaCacheCustody.metadataFilename, policy: retentionMetadataPolicy())
                    defer { try? file.close() }
                    guard file.fingerprint == admission.metadata.fingerprint,
                          try file.readBounded() == admission.record.originalData else { throw NotikaCacheRetentionError.evidenceChanged }
                    try self.revalidate(); try claim.revalidate()
                }
            )
            source = capability
            try capability.revalidateBeforeMove()
            try await trash.moveToTrash(capability)
            try revalidate(); try claims.revalidate(); try claim.revalidate()
            guard try retentionIdentity(retentionStatus(admission.cache.value)) == admission.identity,
                  try retentionStatusIfPresent(at: admission.name, directory: claimFD.value) == nil,
                  try retentionStatusIfPresent(at: admission.name, directory: rootDescriptor.value) == nil else {
                throw NotikaCacheRetentionError.trashFailed
            }
            claimed = false
        } catch {
            // Restore only the admitted inode, into an absent original name.
            // On uncertainty the private claim remains evidence for recovery.
            if (try? revalidate()) != nil,
               let observed = try? retentionStatus(at: admission.name, directory: claimFD.value),
               retentionIdentity(observed) == admission.identity,
               Darwin.renameatx_np(claimFD.value, admission.name, rootDescriptor.value, admission.name, UInt32(RENAME_EXCL)) == 0 {
                claimed = false
            }
            throw error
        }
    }
}

private struct CacheRetentionAdmission: Sendable {
    let name: String
    let path: String
    let directory: RetainedArtifactDirectory
    let cache: CacheRetentionDescriptor
    let identity: CacheRetentionDirectoryIdentity
    let metadata: RetainedArtifactFile
    let record: NotikaCacheUsageRecord
    var evidence: NotikaCacheRetentionEvidence {
        NotikaCacheRetentionEvidence(deviceID: record.directoryObservation.deviceID, inode: identity.inode,
            metadataDigest: record.metadataDigest, schemaVersion: record.schemaVersion,
            lastUsedAtMicrosecondsSince1970: record.lastUsedAtMicrosecondsSince1970)
    }

    init(root: CacheRetentionRoot, name: String, repository: String) throws {
        self.name = name; path = root.path + "/" + name
        let observed = try retentionStatus(at: name, directory: root.rootDescriptor.value)
        guard observed.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), observed.st_uid == geteuid(),
              observed.st_mode & 0o7777 == 0o700, Int64(observed.st_dev) == root.device else { throw NotikaCacheRetentionError.unsafeEntry }
        identity = retentionIdentity(observed)
        let descriptor = Darwin.openat(root.rootDescriptor.value, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw retentionFailure("open cache entry") }
        cache = CacheRetentionDescriptor(descriptor)
        guard try retentionIdentity(retentionStatus(descriptor)) == identity else { throw NotikaCacheRetentionError.evidenceChanged }
        directory = try RetainedArtifactDirectory(path: path, requiredPermissions: 0o700)
        guard retentionIdentity(directory.fingerprint) == identity else { throw NotikaCacheRetentionError.evidenceChanged }
        do { metadata = try directory.openFile(named: NotikaCacheCustody.metadataFilename, policy: retentionMetadataPolicy()) }
        catch RetainedArtifactError.systemCall(_, ENOENT) { throw NotikaCacheRetentionError.absentRoot }
        guard metadata.fingerprint.device == root.device, let deviceID = UInt64(exactly: root.device) else { throw NotikaCacheRetentionError.unsafeEntry }
        let observation = try NotikaCacheDirectoryObservation(
            canonicalRepository: repository, canonicalCacheRoot: root.path, canonicalCachePath: path,
            deviceID: deviceID, inode: identity.inode, ownerUID: identity.owner, effectiveUserID: geteuid()
        )
        record = try NotikaCacheUsageRecord(data: metadata.readBounded(), directoryObservation: observation)
        try revalidate(root: root)
    }

    func revalidate(root: CacheRetentionRoot) throws {
        try root.revalidate(); try directory.revalidate(); try metadata.revalidateBeforeMutation()
        guard try retentionIdentity(retentionStatus(cache.value)) == identity,
              try retentionIdentity(retentionStatus(at: name, directory: root.rootDescriptor.value)) == identity,
              try metadata.readBounded() == record.originalData else { throw NotikaCacheRetentionError.evidenceChanged }
        try root.revalidate(); try metadata.revalidate()
    }
}

private func retentionMetadataPolicy() throws -> ArtifactFilePolicy {
    try ArtifactFilePolicy(minimumBytes: 1, maximumBytes: NotikaCacheUsageRecord.maximumBytes, requiredPermissions: 0o600)
}

private func retentionEntry(
    _ name: String, _ classification: NotikaCacheRetentionClassification, _ reason: NotikaCacheRetentionReason,
    action: NotikaCacheRetentionAction = .none, bytes: UInt64? = nil,
    evidence: NotikaCacheRetentionEvidence? = nil, detail: (any Error)? = nil
) -> NotikaCacheRetentionEntry {
    NotikaCacheRetentionEntry(name: name, classification: classification, action: action, reason: reason,
        allocatedBytes: bytes, evidence: evidence, detail: detail.map { String(String(describing: $0).prefix(256)) })
}

private func retentionSafeKey(_ value: String) -> Bool {
    value.utf8.count == 24 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}

private func retentionLockBinding(_ lock: FileLock) throws -> InheritedLeaseDescriptor {
    guard let descriptor = lock.inheritedDescriptor, lock.mode == .exclusive else { throw NotikaCacheRetentionError.evidenceChanged }
    return InheritedLeaseDescriptor(resource: lock.resource.value, mode: .exclusive, descriptor: descriptor, path: lock.persistentPath)
}

private func retentionValidateLocks(_ locks: [InheritedLeaseDescriptor], registryRoot: String) throws {
    guard locks.count == 2, locks[0].descriptor != locks[1].descriptor, locks[0].resource != locks[1].resource else { throw NotikaCacheRetentionError.evidenceChanged }
    for lock in locks {
        try InheritedExclusiveLeaseGuard.establish(resource: lock.resource, environment: [
            AgentLeasePaths.homeEnvironmentKey: registryRoot, ChildEnvironment.heldResourcesKey: lock.resource,
            InheritedLeaseManifest.environmentKey: try InheritedLeaseManifest(leases: [lock]).environmentValue(),
        ])
    }
}

private func retentionFailure(_ operation: String) -> NotikaCacheRetentionError { .systemCall(operation, errno) }
private func retentionStatus(_ descriptor: Int32) throws -> stat {
    var value = stat()
    guard Darwin.fstat(descriptor, &value) == 0 else { throw retentionFailure("fstat cache custody") }
    return value
}
private func retentionStatus(at name: String, directory: Int32) throws -> stat {
    guard let status = try retentionStatusIfPresent(at: name, directory: directory) else { throw NotikaCacheRetentionError.systemCall("fstatat cache entry", ENOENT) }
    return status
}
private func retentionStatusIfPresent(at name: String, directory: Int32) throws -> stat? {
    var value = stat()
    if Darwin.fstatat(directory, name, &value, AT_SYMLINK_NOFOLLOW) == 0 { return value }
    if errno == ENOENT { return nil }
    throw retentionFailure("fstatat cache entry")
}
private func retentionIdentity(_ value: stat) -> CacheRetentionDirectoryIdentity {
    CacheRetentionDirectoryIdentity(device: Int64(value.st_dev), inode: value.st_ino, owner: value.st_uid, group: value.st_gid, mode: value.st_mode)
}
private func retentionIdentity(_ value: ArtifactFileFingerprint) -> CacheRetentionDirectoryIdentity {
    CacheRetentionDirectoryIdentity(device: value.device, inode: value.inode, owner: value.owner, group: value.group, mode: value.mode)
}
private func retentionSameFile(_ value: stat, _ expected: stat) -> Bool {
    retentionIdentity(value) == retentionIdentity(expected)
        && value.st_size == expected.st_size && value.st_nlink == expected.st_nlink && value.st_blocks == expected.st_blocks
        && value.st_mtimespec.tv_sec == expected.st_mtimespec.tv_sec && value.st_mtimespec.tv_nsec == expected.st_mtimespec.tv_nsec
        && value.st_ctimespec.tv_sec == expected.st_ctimespec.tv_sec && value.st_ctimespec.tv_nsec == expected.st_ctimespec.tv_nsec
}
private func retentionOpenDirectory(_ path: String, expected: CacheRetentionDirectoryIdentity) throws -> CacheRetentionDescriptor {
    let opened = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard opened >= 0 else { throw retentionFailure("open retained cache directory") }
    let descriptor = CacheRetentionDescriptor(opened)
    guard try retentionIdentity(retentionStatus(opened)) == expected else { throw NotikaCacheRetentionError.evidenceChanged }
    return descriptor
}

private func retentionNames(_ directory: Int32, maximum: Int) throws -> [String] {
    let scan = Darwin.openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard scan >= 0 else { throw retentionFailure("open cache scan") }
    guard let stream = Darwin.fdopendir(scan) else { let failure = retentionFailure("fdopendir cache scan"); _ = Darwin.close(scan); throw failure }
    defer { _ = Darwin.closedir(stream) }
    var names: [String] = []
    while true {
        errno = 0
        guard let entry = Darwin.readdir(stream) else {
            guard errno == 0 else { throw retentionFailure("readdir cache scan") }
            return names
        }
        var raw = entry.pointee.d_name
        let name = withUnsafeBytes(of: &raw) { bytes -> String? in
            guard let end = bytes.firstIndex(of: 0) else { return nil }
            return String(bytes: bytes.prefix(end), encoding: .utf8)
        }
        guard let name else { throw NotikaCacheRetentionError.unsafeEntry }
        if name == "." || name == ".." { continue }
        names.append(name)
        guard names.count <= maximum else { throw NotikaCacheRetentionError.traversalBoundExceeded }
    }
}

/// Both cache families use the same bounded iterative descriptor traversal.
private func retentionAllocatedSize(_ descriptor: Int32) throws -> UInt64 {
    do {
        return try artifactAllocatedSize(descriptor, maximumDepth: NotikaCacheRetentionCollector.maximumCacheDepth,
            maximumNodes: NotikaCacheRetentionCollector.maximumCacheNodes)
    } catch let error as ArtifactAllocatedSizeError {
        switch error {
        case .unsafeEntry: throw NotikaCacheRetentionError.unsafeEntry
        case .evidenceChanged: throw NotikaCacheRetentionError.evidenceChanged
        case .traversalBoundExceeded: throw NotikaCacheRetentionError.traversalBoundExceeded
        case .systemCall(let operation, let code): throw NotikaCacheRetentionError.systemCall(operation, code)
        }
    }
}
