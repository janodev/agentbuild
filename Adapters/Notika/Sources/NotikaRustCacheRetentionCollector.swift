import AgentBuildCore
import AgentLeaseCore
import Darwin
import Foundation

public enum NotikaRustCacheRetentionPolicy: String, Codable, Sendable { case todayOnlyRustCaches }

public struct NotikaRustCacheRetentionReport: Equatable, Codable, Sendable {
    public let policy: NotikaRustCacheRetentionPolicy
    public let execute: Bool
    public let evaluatedAt: Date
    public let localDayCutoff: Date
    public let timeZoneIdentifier: String
    public let rootState: NotikaCacheRetentionRootState
    public let rootReason: NotikaCacheRetentionReason?
    public let scanComplete: Bool
    public let entries: [NotikaCacheRetentionEntry]
    public let trashOperatorIdentifier: String?

    /// Source allocation moved to Trash, never a claim of freed disk space.
    public var movedToTrashAllocatedBytes: UInt64 {
        entries.filter { $0.action == .trashed }.reduce(0) { total, entry in
            let next = total.addingReportingOverflow(entry.allocatedBytes ?? 0)
            return next.overflow ? UInt64.max : next.partialValue
        }
    }
}

public enum NotikaRustCacheRetentionError: Error, Equatable, Sendable {
    case absentRoot, unsafeEntry, evidenceChanged, traversalBoundExceeded, unknownMetadataSchema, trashFailed
    case systemCall(String, Int32)
}

private let rustRetentionMetadataFilename = ".notika-cache-usage.json"

/// Today-only schema-1 Rust family-cache collection. The exclusive repository policy is the
/// same resource Rust producers hold shared throughout their native child lifetime;
/// per-key exclusive admission additionally protects older producers. Xcode and
/// session namespaces are untouched. Missing/odd evidence is retained, not adopted.
public struct NotikaRustCacheRetentionCollector: Sendable {
    public static let maximumRootEntries = 1_024
    public static let maximumCacheNodes = 1_000_000
    public static let maximumCacheDepth = 256

    public static func policyResource(canonicalRepository: String) throws -> String {
        _ = try CacheCompatibilityIdentity.graphResourceName(canonicalWorktree: canonicalRepository)
        return "notika:rust-test-cache-policy:" + CanonicalJSONDigest.digest(Data(canonicalRepository.utf8))
    }

    public static func cacheResource(canonicalRepository: String, cacheKey: String) throws -> String {
        _ = try policyResource(canonicalRepository: canonicalRepository)
        guard rustRetentionSafeKey(cacheKey) else { throw NotikaRustCacheRetentionError.unsafeEntry }
        return "notika:rust-test-cache:" + CanonicalJSONDigest.digest(Data(canonicalRepository.utf8)) + ":" + cacheKey
    }
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
        _ = try Self.policyResource(canonicalRepository: canonicalRepository)
        repository = canonicalRepository; self.registryRoot = registryRoot
        calendar = try LocalCalendarRetention(evaluatedAt: evaluatedAt, timeZone: timeZone)
        trash = trashOperator; self.beforeRevalidation = beforeRevalidation
        self.claimDirectoryFactory = claimDirectoryFactory
    }

    public func run(execute: Bool) async throws -> NotikaRustCacheRetentionReport {
        try Task.checkCancellation()
        let paths: AgentLeasePaths
        let policy: FileLock
        do {
            paths = try AgentLeasePaths.open(selectedRoot: registryRoot)
            policy = try FileLock(resource: ResourceName(Self.policyResource(canonicalRepository: repository)), paths: paths)
            guard try policy.tryAcquire() else { return report(execute, root: .busy, reason: .policyBusy) }
        } catch { return report(execute, root: .unsafe, reason: .policyUnavailable) }
        defer { policy.release() }
        let root: RustRetentionRoot
        do {
            root = try RustRetentionRoot(repository: repository)
            if try root.hasPendingClaims() { return report(execute, root: .unsafe, reason: .pendingTrashClaims) }
        } catch NotikaRustCacheRetentionError.absentRoot {
            return report(execute, root: .absent, complete: true)
        } catch { return report(execute, root: .unsafe, reason: .rootUnsafe) }
        let names: [String]
        do { names = try rustRetentionNames(root.rootDescriptor.value, maximum: Self.maximumRootEntries) }
        catch NotikaRustCacheRetentionError.traversalBoundExceeded { return report(execute, root: .entryBoundExceeded, reason: .rootEntryBoundExceeded) }
        catch { return report(execute, root: .unsafe, reason: .rootUnsafe) }
        var entries: [NotikaCacheRetentionEntry] = []
        for name in names.sorted() {
            try Task.checkCancellation()
            do { try root.revalidate() }
            catch { return report(execute, root: .unsafe, reason: .rootChanged, entries: entries) }
            if name == ".DS_Store" {
                entries.append(root.finderMetadata())
            } else if !rustRetentionSafeKey(name) {
                entries.append(rustRetentionEntry(name, .invalid, .nameUnsafe))
            } else {
                entries.append(try await assess(name, root: root, paths: paths, policy: policy, execute: execute))
            }
        }
        do { try root.revalidate() }
        catch { return report(execute, root: .unsafe, reason: .rootChanged, entries: entries) }
        return report(execute, root: .ready, complete: true, entries: entries)
    }

    private func assess(
        _ name: String, root: RustRetentionRoot, paths: AgentLeasePaths, policy: FileLock, execute: Bool
    ) async throws -> NotikaCacheRetentionEntry {
        let cachePath = root.path + "/" + name
        let cacheLock: FileLock
        do {
            cacheLock = try FileLock(resource: ResourceName(Self.cacheResource(canonicalRepository: repository, cacheKey: name)), paths: paths)
            guard try cacheLock.tryAcquire() else { return rustRetentionEntry(name, .busy, .cacheBusy, action: .skippedBusy) }
        } catch { return rustRetentionEntry(name, .invalid, .entryUnsafe, detail: error) }
        defer { cacheLock.release() }
        let admission: RustRetentionAdmission
        do { admission = try RustRetentionAdmission(root: root, name: name, repository: repository) }
        catch NotikaRustCacheRetentionError.absentRoot { return rustRetentionEntry(name, .unmanaged, .metadataAbsent) }
        catch let error as NotikaRustTestError { return rustRetentionEntry(name, .invalid, .metadataInvalid, detail: error) }
        catch NotikaRustCacheRetentionError.unknownMetadataSchema { return rustRetentionEntry(name, .unmanaged, .metadataInvalid, detail: NotikaRustCacheRetentionError.unknownMetadataSchema) }
        catch let error as StrictJSONError { return rustRetentionEntry(name, .invalid, .metadataInvalid, detail: error) }
        catch { return rustRetentionEntry(name, .invalid, .entryUnsafe, detail: error) }
        let eligibility = calendar.cacheEligibility(lastUsedAt: admission.lastUsedAt)
        if eligibility == .invalid { return rustRetentionEntry(name, .invalid, .lastUseInFuture, evidence: admission.evidence) }
        if eligibility != .eligible { return rustRetentionEntry(name, .retained, .currentLocalDay, evidence: admission.evidence) }
        let bytes: UInt64
        do { bytes = try rustRetentionAllocatedSize(admission.cache.value) }
        catch { return rustRetentionEntry(name, .invalid, .sizeUnavailable, evidence: admission.evidence, detail: error) }
        let bindings: [InheritedLeaseDescriptor]
        do {
            bindings = [try rustRetentionLockBinding(policy), try rustRetentionLockBinding(cacheLock)]
            try await beforeRevalidation(cachePath)
            try rustRetentionValidateLocks(bindings, registryRoot: registryRoot)
            try admission.revalidate(root: root)
            guard calendar.cacheEligibility(lastUsedAt: admission.lastUsedAt) == .eligible,
                  try rustRetentionAllocatedSize(admission.cache.value) == bytes else { throw NotikaRustCacheRetentionError.evidenceChanged }
            try admission.revalidate(root: root)
        } catch is CancellationError { throw CancellationError() }
        catch { return rustRetentionEntry(name, .eligible, .evidenceChanged, action: .skippedRevalidation, evidence: admission.evidence, detail: error) }
        if !execute { return rustRetentionEntry(name, .eligible, .wouldMoveToTrash, action: .wouldTrash, bytes: bytes, evidence: admission.evidence) }
        do {
            try await root.move(admission, locks: bindings, registryRoot: registryRoot, trash: trash, claimDirectoryFactory: claimDirectoryFactory)
            return rustRetentionEntry(name, .eligible, .movedToTrash, action: .trashed, bytes: bytes, evidence: admission.evidence)
        } catch is CancellationError { throw CancellationError() }
        catch { return rustRetentionEntry(name, .eligible, .trashFailed, action: .trashFailed, evidence: admission.evidence, detail: error) }
    }

    private func report(
        _ execute: Bool, root: NotikaCacheRetentionRootState, reason: NotikaCacheRetentionReason? = nil,
        complete: Bool = false, entries: [NotikaCacheRetentionEntry] = []
    ) -> NotikaRustCacheRetentionReport {
        NotikaRustCacheRetentionReport(
            policy: .todayOnlyRustCaches, execute: execute, evaluatedAt: calendar.evaluatedAt,
            localDayCutoff: calendar.localDayStart, timeZoneIdentifier: calendar.timeZone.identifier,
            rootState: root, rootReason: reason, scanComplete: complete, entries: entries,
            trashOperatorIdentifier: execute ? trash.identifier : nil
        )
    }
}

private final class RustRetentionDescriptor: Sendable {
    let value: Int32
    init(_ value: Int32) { self.value = value }
    deinit { _ = Darwin.close(value) }
}

private struct RustRetentionDirectoryIdentity: Equatable, Sendable {
    let device: Int64
    let inode: UInt64
    let owner: UInt32
    let group: UInt32
    let mode: UInt16
}

private final class RustRetentionRoot: Sendable {
    let repository: String
    let path: String
    let repositoryDirectory: RetainedArtifactDirectory
    let derivedDirectory: RetainedArtifactDirectory
    let rootDirectory: RetainedArtifactDirectory
    let derivedDescriptor: RustRetentionDescriptor
    let rootDescriptor: RustRetentionDescriptor
    let device: Int64
    var borrowedDescriptors: [Int32] { [derivedDescriptor.value, rootDescriptor.value] }

    init(repository: String) throws {
        self.repository = repository
        repositoryDirectory = try RetainedArtifactDirectory(path: repository)
        device = repositoryDirectory.fingerprint.device
        let base = repository == "/" ? "" : repository
        path = base + "/DerivedData/RustTestCaches"
        do {
            derivedDirectory = try RetainedArtifactDirectory(path: base + "/DerivedData")
            rootDirectory = try RetainedArtifactDirectory(path: path, requiredPermissions: 0o700)
        } catch RetainedArtifactError.systemCall(_, ENOENT) { throw NotikaRustCacheRetentionError.absentRoot }
        guard derivedDirectory.fingerprint.device == device, rootDirectory.fingerprint.device == device else {
            throw NotikaRustCacheRetentionError.unsafeEntry
        }
        derivedDescriptor = try rustRetentionOpenDirectory(derivedDirectory.path, expected: rustRetentionIdentity(derivedDirectory.fingerprint))
        rootDescriptor = try rustRetentionOpenDirectory(path, expected: rustRetentionIdentity(rootDirectory.fingerprint))
        try revalidate()
    }

    func revalidate() throws {
        try repositoryDirectory.revalidate(); try derivedDirectory.revalidate(); try rootDirectory.revalidate()
        guard try rustRetentionIdentity(rustRetentionStatus(derivedDescriptor.value)) == rustRetentionIdentity(derivedDirectory.fingerprint),
              try rustRetentionIdentity(rustRetentionStatus(rootDescriptor.value)) == rustRetentionIdentity(rootDirectory.fingerprint) else {
            throw NotikaRustCacheRetentionError.evidenceChanged
        }
    }

    func hasPendingClaims() throws -> Bool {
        guard try rustRetentionStatusIfPresent(at: "RustTestCacheTrashClaims", directory: derivedDescriptor.value) != nil else { return false }
        let claims = try RetainedArtifactDirectory(path: derivedDirectory.path + "/RustTestCacheTrashClaims", requiredPermissions: 0o700)
        guard claims.fingerprint.device == device else { throw NotikaRustCacheRetentionError.unsafeEntry }
        let descriptor = try rustRetentionOpenDirectory(claims.path, expected: rustRetentionIdentity(claims.fingerprint))
        let names = try rustRetentionNames(descriptor.value, maximum: NotikaRustCacheRetentionCollector.maximumRootEntries)
        try claims.revalidate(); try revalidate()
        return !names.isEmpty
    }

    func finderMetadata() -> NotikaCacheRetentionEntry {
        do {
            let observed = try rustRetentionStatus(at: ".DS_Store", directory: rootDescriptor.value)
            guard observed.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), observed.st_uid == geteuid(),
                  observed.st_nlink == 1, observed.st_mode & 0o7022 == 0,
                  Int64(observed.st_dev) == device else { throw NotikaRustCacheRetentionError.unsafeEntry }
            let opened = Darwin.openat(rootDescriptor.value, ".DS_Store", O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
            guard opened >= 0 else { throw rustRetentionFailure("open Finder metadata") }
            let retained = RustRetentionDescriptor(opened)
            guard try rustRetentionSameFile(rustRetentionStatus(retained.value), observed),
                  try rustRetentionSameFile(rustRetentionStatus(at: ".DS_Store", directory: rootDescriptor.value), observed) else {
                throw NotikaRustCacheRetentionError.evidenceChanged
            }
            try revalidate()
            return rustRetentionEntry(".DS_Store", .retained, .finderMetadata)
        } catch { return rustRetentionEntry(".DS_Store", .invalid, .finderMetadataUnsafe, detail: error) }
    }

    func move(
        _ admission: RustRetentionAdmission, locks: [InheritedLeaseDescriptor], registryRoot: String,
        trash: any ArtifactTrashOperator,
        claimDirectoryFactory: @Sendable (String) throws -> RetainedArtifactDirectory
    ) async throws {
        try rustRetentionValidateLocks(locks, registryRoot: registryRoot)
        try admission.revalidate(root: self)
        if Darwin.mkdirat(derivedDescriptor.value, "RustTestCacheTrashClaims", 0o700) != 0, errno != EEXIST {
            throw rustRetentionFailure("create cache Trash claims")
        }
        let claims = try RetainedArtifactDirectory(path: derivedDirectory.path + "/RustTestCacheTrashClaims", requiredPermissions: 0o700)
        guard claims.fingerprint.device == device else { throw NotikaRustCacheRetentionError.unsafeEntry }
        let claimsFD = try rustRetentionOpenDirectory(claims.path, expected: rustRetentionIdentity(claims.fingerprint))
        let name = "." + admission.name + "." + UUID().uuidString + ".claim"
        guard Darwin.mkdirat(claimsFD.value, name, 0o700) == 0 else { throw rustRetentionFailure("create private Trash claim") }
        var placeholderIdentity: RustRetentionDirectoryIdentity?
        var claimed = false
        // Installed before descriptor allocation: an EMFILE/open failure must
        // not leave an empty placeholder that blocks every following run.
        defer {
            if !claimed, let placeholderIdentity,
               let current = try? rustRetentionStatus(at: name, directory: claimsFD.value),
               rustRetentionIdentity(current) == placeholderIdentity {
                _ = Darwin.unlinkat(claimsFD.value, name, AT_REMOVEDIR)
            }
        }
        let placeholder = try rustRetentionStatus(at: name, directory: claimsFD.value)
        guard placeholder.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), placeholder.st_uid == geteuid(),
              placeholder.st_mode & 0o7777 == 0o700, Int64(placeholder.st_dev) == device else {
            throw NotikaRustCacheRetentionError.unsafeEntry
        }
        placeholderIdentity = rustRetentionIdentity(placeholder)
        let claim = try claimDirectoryFactory(claims.path + "/" + name)
        guard rustRetentionIdentity(claim.fingerprint) == placeholderIdentity else { throw NotikaRustCacheRetentionError.evidenceChanged }
        let claimFD = try rustRetentionOpenDirectory(claim.path, expected: rustRetentionIdentity(claim.fingerprint))
        try claims.revalidate(); try claim.revalidate(); try admission.revalidate(root: self)
        guard Darwin.renameatx_np(rootDescriptor.value, admission.name, claimFD.value, admission.name, UInt32(RENAME_EXCL)) == 0 else {
            throw rustRetentionFailure("claim cache for Trash")
        }
        claimed = true
        var source: ArtifactTrashSource?
        defer { source?.retire() }
        do {
            let directory = try claimDirectoryFactory(claim.path + "/" + admission.name)
            guard rustRetentionIdentity(directory.fingerprint) == admission.identity else { throw NotikaRustCacheRetentionError.evidenceChanged }
            let capability = ArtifactTrashSource(
                directory: directory, originalPath: admission.path,
                inheritedDescriptors: locks.map(\.descriptor) + borrowedDescriptors + [admission.cache.value, claimFD.value],
                revalidate: {
                    try rustRetentionValidateLocks(locks, registryRoot: registryRoot)
                    try self.revalidate(); try claim.revalidate()
                    guard try rustRetentionIdentity(rustRetentionStatus(admission.cache.value)) == admission.identity,
                          try rustRetentionIdentity(rustRetentionStatus(at: admission.name, directory: claimFD.value)) == admission.identity else {
                        throw NotikaRustCacheRetentionError.evidenceChanged
                    }
                    let file = try directory.openFile(named: rustRetentionMetadataFilename, policy: rustRetentionMetadataPolicy())
                    defer { try? file.close() }
                    guard file.fingerprint == admission.metadata.fingerprint,
                          try file.readBounded() == admission.record.document.originalData else { throw NotikaRustCacheRetentionError.evidenceChanged }
                    try self.revalidate(); try claim.revalidate()
                }
            )
            source = capability
            try capability.revalidateBeforeMove()
            try await trash.moveToTrash(capability)
            try revalidate(); try claims.revalidate(); try claim.revalidate()
            guard try rustRetentionIdentity(rustRetentionStatus(admission.cache.value)) == admission.identity,
                  try rustRetentionStatusIfPresent(at: admission.name, directory: claimFD.value) == nil,
                  try rustRetentionStatusIfPresent(at: admission.name, directory: rootDescriptor.value) == nil else {
                throw NotikaRustCacheRetentionError.trashFailed
            }
            claimed = false
        } catch {
            // Restore only the admitted inode, into an absent original name.
            // On uncertainty the private claim remains evidence for recovery.
            if (try? revalidate()) != nil,
               let observed = try? rustRetentionStatus(at: admission.name, directory: claimFD.value),
               rustRetentionIdentity(observed) == admission.identity,
               Darwin.renameatx_np(claimFD.value, admission.name, rootDescriptor.value, admission.name, UInt32(RENAME_EXCL)) == 0 {
                claimed = false
            }
            throw error
        }
    }
}

private struct RustRetentionAdmission: Sendable {
    let name: String
    let path: String
    let directory: RetainedArtifactDirectory
    let cache: RustRetentionDescriptor
    let identity: RustRetentionDirectoryIdentity
    let metadata: RetainedArtifactFile
    let record: NotikaRustCacheUsageRecord
    let lastUsedAt: Date
    let lastUsedAtMicroseconds: Int64
    var evidence: NotikaCacheRetentionEvidence {
        NotikaCacheRetentionEvidence(deviceID: UInt64(identity.device), inode: identity.inode,
            metadataDigest: record.document.digest, schemaVersion: 1,
            lastUsedAtMicrosecondsSince1970: lastUsedAtMicroseconds)
    }

    init(root: RustRetentionRoot, name: String, repository: String) throws {
        self.name = name; path = root.path + "/" + name
        let observed = try rustRetentionStatus(at: name, directory: root.rootDescriptor.value)
        guard observed.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), observed.st_uid == geteuid(),
              observed.st_mode & 0o7777 == 0o700, Int64(observed.st_dev) == root.device else { throw NotikaRustCacheRetentionError.unsafeEntry }
        identity = rustRetentionIdentity(observed)
        let descriptor = Darwin.openat(root.rootDescriptor.value, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw rustRetentionFailure("open cache entry") }
        cache = RustRetentionDescriptor(descriptor)
        guard try rustRetentionIdentity(rustRetentionStatus(descriptor)) == identity else { throw NotikaRustCacheRetentionError.evidenceChanged }
        directory = try RetainedArtifactDirectory(path: path, requiredPermissions: 0o700)
        guard rustRetentionIdentity(directory.fingerprint) == identity else { throw NotikaRustCacheRetentionError.evidenceChanged }
        do { metadata = try directory.openFile(named: rustRetentionMetadataFilename, policy: rustRetentionMetadataPolicy()) }
        catch RetainedArtifactError.systemCall(_, ENOENT) { throw NotikaRustCacheRetentionError.absentRoot }
        guard metadata.fingerprint.device == root.device, let deviceID = UInt64(exactly: root.device) else { throw NotikaRustCacheRetentionError.unsafeEntry }
        let data = try metadata.readBounded()
        let material = try rustRetentionDiscoverIdentity(data, repository: repository)
        let observation = try NotikaRustCacheObservation(identity: material, deviceID: deviceID, inode: identity.inode, ownerUID: identity.owner)
        guard observation.cacheKey == name, observation.cacheRoot.utf8.elementsEqual(root.path.utf8),
              observation.cachePath.utf8.elementsEqual(path.utf8) else { throw NotikaRustTestError.unsafeMetadata }
        record = try NotikaRustCacheUsageRecord(
            data: data, identity: material, observation: observation, boot: DirectoryIdentityBoot.current()
        )
        lastUsedAtMicroseconds = try rustRetentionExactTime(record.lastUsedAt)
        lastUsedAt = Date(timeIntervalSince1970: Double(lastUsedAtMicroseconds) / 1_000_000)
        try revalidate(root: root)
    }

    func revalidate(root: RustRetentionRoot) throws {
        try root.revalidate(); try directory.revalidate(); try metadata.revalidateBeforeMutation()
        guard try rustRetentionIdentity(rustRetentionStatus(cache.value)) == identity,
              try rustRetentionIdentity(rustRetentionStatus(at: name, directory: root.rootDescriptor.value)) == identity,
              try metadata.readBounded() == record.document.originalData else { throw NotikaRustCacheRetentionError.evidenceChanged }
        try root.revalidate(); try metadata.revalidate()
    }
}

private func rustRetentionMetadataPolicy() throws -> ArtifactFilePolicy {
    try ArtifactFilePolicy(minimumBytes: 1, maximumBytes: NotikaRustCacheUsageRecord.maximumBytes, requiredPermissions: 0o600)
}

/// The profile is data about a past producer. Discover only enough to reconstruct
/// its closed identity, then the existing complete usage model validates every
/// original byte/field/binding; this projection never grants cleanup authority.
private func rustRetentionDiscoverIdentity(_ data: Data, repository: String) throws -> NotikaRustCacheIdentity {
    let document = try StrictJSONDocument(data: data, limits: StrictJSONLimits(maximumBytes: NotikaRustCacheUsageRecord.maximumBytes))
    let object = try document.root.requireObject()
    guard case .number(let schema) = try object.requiredValue(forKey: "schemaVersion") else { throw NotikaRustTestError.unsafeMetadata }
    guard try schema.int64() == 1 else { throw NotikaRustCacheRetentionError.unknownMetadataSchema }
    let profile = try object.requiredValue(forKey: "compatibilityKeyMaterial").requireObject().project(requiredKeys: [
        "schemaVersion", "canonicalWorktree", "family", "targetKind", "inputs", "toolchain",
    ])
    func string(_ object: StrictJSONObject, _ key: String) throws -> String {
        guard case .string(let value) = try object.requiredValue(forKey: key) else { throw NotikaRustTestError.unsafeMetadata }
        return value
    }
    guard case .number(let version) = try profile.requiredValue(forKey: "schemaVersion"), try version.int64() == 1,
          try string(profile, "canonicalWorktree").utf8.elementsEqual(repository.utf8),
          try string(profile, "targetKind") == "host-debug-cargo-test",
          let family = try NotikaRustTestFamily(rawValue: string(profile, "family")) else { throw NotikaRustTestError.unsafeMetadata }
    let inputs = try profile.requiredValue(forKey: "inputs").requireObject().project(requiredKeys: NotikaRustCacheIdentity.inputPaths(family))
    var digests: [String: String] = [:]
    for member in inputs.members {
        guard case .string(let value) = member.value else { throw NotikaRustTestError.unsafeMetadata }
        digests[member.key] = value
    }
    let toolchain = try profile.requiredValue(forKey: "toolchain").requireObject().project(requiredKeys: ["mise", "rustc", "sysroot", "cargo"])
    let mise = try toolchain.requiredValue(forKey: "mise").requireObject().project(requiredKeys: ["path", "sha256"])
    return try NotikaRustCacheIdentity(repository: repository, family: family, inputs: digests,
        misePath: string(mise, "path"), miseDigest: string(mise, "sha256"),
        rustc: string(toolchain, "rustc"), sysroot: string(toolchain, "sysroot"), cargo: string(toolchain, "cargo"))
}

private func rustRetentionEntry(
    _ name: String, _ classification: NotikaCacheRetentionClassification, _ reason: NotikaCacheRetentionReason,
    action: NotikaCacheRetentionAction = .none, bytes: UInt64? = nil,
    evidence: NotikaCacheRetentionEvidence? = nil, detail: (any Error)? = nil
) -> NotikaCacheRetentionEntry {
    NotikaCacheRetentionEntry(name: name, classification: classification, action: action, reason: reason,
        allocatedBytes: bytes, evidence: evidence, detail: detail.map { String(String(describing: $0).prefix(256)) })
}

private func rustRetentionSafeKey(_ value: String) -> Bool {
    value.utf8.count == 24 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}

private func rustRetentionLockBinding(_ lock: FileLock) throws -> InheritedLeaseDescriptor {
    guard let descriptor = lock.inheritedDescriptor, lock.mode == .exclusive else { throw NotikaRustCacheRetentionError.evidenceChanged }
    return InheritedLeaseDescriptor(resource: lock.resource.value, mode: .exclusive, descriptor: descriptor, path: lock.persistentPath)
}

private func rustRetentionValidateLocks(_ locks: [InheritedLeaseDescriptor], registryRoot: String) throws {
    guard locks.count == 2, locks[0].descriptor != locks[1].descriptor, locks[0].resource != locks[1].resource else { throw NotikaRustCacheRetentionError.evidenceChanged }
    for lock in locks {
        try InheritedExclusiveLeaseGuard.establish(resource: lock.resource, environment: [
            AgentLeasePaths.homeEnvironmentKey: registryRoot, ChildEnvironment.heldResourcesKey: lock.resource,
            InheritedLeaseManifest.environmentKey: try InheritedLeaseManifest(leases: [lock]).environmentValue(),
        ])
    }
}

private func rustRetentionFailure(_ operation: String) -> NotikaRustCacheRetentionError { .systemCall(operation, errno) }
private func rustRetentionStatus(_ descriptor: Int32) throws -> stat {
    var value = stat()
    guard Darwin.fstat(descriptor, &value) == 0 else { throw rustRetentionFailure("fstat cache custody") }
    return value
}
private func rustRetentionStatus(at name: String, directory: Int32) throws -> stat {
    guard let status = try rustRetentionStatusIfPresent(at: name, directory: directory) else { throw NotikaRustCacheRetentionError.systemCall("fstatat cache entry", ENOENT) }
    return status
}
private func rustRetentionStatusIfPresent(at name: String, directory: Int32) throws -> stat? {
    var value = stat()
    if Darwin.fstatat(directory, name, &value, AT_SYMLINK_NOFOLLOW) == 0 { return value }
    if errno == ENOENT { return nil }
    throw rustRetentionFailure("fstatat cache entry")
}
private func rustRetentionIdentity(_ value: stat) -> RustRetentionDirectoryIdentity {
    RustRetentionDirectoryIdentity(device: Int64(value.st_dev), inode: value.st_ino, owner: value.st_uid, group: value.st_gid, mode: value.st_mode)
}
private func rustRetentionIdentity(_ value: ArtifactFileFingerprint) -> RustRetentionDirectoryIdentity {
    RustRetentionDirectoryIdentity(device: value.device, inode: value.inode, owner: value.owner, group: value.group, mode: value.mode)
}
private func rustRetentionSameFile(_ value: stat, _ expected: stat) -> Bool {
    rustRetentionIdentity(value) == rustRetentionIdentity(expected)
        && value.st_size == expected.st_size && value.st_nlink == expected.st_nlink && value.st_blocks == expected.st_blocks
        && value.st_mtimespec.tv_sec == expected.st_mtimespec.tv_sec && value.st_mtimespec.tv_nsec == expected.st_mtimespec.tv_nsec
        && value.st_ctimespec.tv_sec == expected.st_ctimespec.tv_sec && value.st_ctimespec.tv_nsec == expected.st_ctimespec.tv_nsec
}
private func rustRetentionOpenDirectory(_ path: String, expected: RustRetentionDirectoryIdentity) throws -> RustRetentionDescriptor {
    let opened = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard opened >= 0 else { throw rustRetentionFailure("open retained cache directory") }
    let descriptor = RustRetentionDescriptor(opened)
    guard try rustRetentionIdentity(rustRetentionStatus(opened)) == expected else { throw NotikaRustCacheRetentionError.evidenceChanged }
    return descriptor
}

private func rustRetentionNames(_ directory: Int32, maximum: Int) throws -> [String] {
    let scan = Darwin.openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard scan >= 0 else { throw rustRetentionFailure("open cache scan") }
    guard let stream = Darwin.fdopendir(scan) else { let failure = rustRetentionFailure("fdopendir cache scan"); _ = Darwin.close(scan); throw failure }
    defer { _ = Darwin.closedir(stream) }
    var names: [String] = []
    while true {
        errno = 0
        guard let entry = Darwin.readdir(stream) else {
            guard errno == 0 else { throw rustRetentionFailure("readdir cache scan") }
            return names
        }
        var raw = entry.pointee.d_name
        let name = withUnsafeBytes(of: &raw) { bytes -> String? in
            guard let end = bytes.firstIndex(of: 0) else { return nil }
            return String(bytes: bytes.prefix(end), encoding: .utf8)
        }
        guard let name else { throw NotikaRustCacheRetentionError.unsafeEntry }
        if name == "." || name == ".." { continue }
        names.append(name)
        guard names.count <= maximum else { throw NotikaRustCacheRetentionError.traversalBoundExceeded }
    }
}

/// Both cache families use the same bounded iterative descriptor traversal.
private func rustRetentionAllocatedSize(_ descriptor: Int32) throws -> UInt64 {
    do {
        return try artifactAllocatedSize(descriptor, maximumDepth: NotikaRustCacheRetentionCollector.maximumCacheDepth,
            maximumNodes: NotikaRustCacheRetentionCollector.maximumCacheNodes)
    } catch let error as ArtifactAllocatedSizeError {
        switch error {
        case .unsafeEntry: throw NotikaRustCacheRetentionError.unsafeEntry
        case .evidenceChanged: throw NotikaRustCacheRetentionError.evidenceChanged
        case .traversalBoundExceeded: throw NotikaRustCacheRetentionError.traversalBoundExceeded
        case .systemCall(let operation, let code): throw NotikaRustCacheRetentionError.systemCall(operation, code)
        }
    }
}


// Same exact RFC3339/proleptic-Gregorian interpretation as the producer.
private func rustRetentionExactTime(_ value: String) throws -> Int64 {
    let bytes = Array(value.utf8)
    func invalid() -> NotikaRustTestError { .unsafeMetadata }
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
    return exactMicroseconds
}
