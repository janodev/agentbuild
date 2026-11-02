import AgentLeaseCore
import Darwin
import Foundation

public enum NotikaSessionRetentionRootState: String, Codable, Sendable {
    case ready, absent, busy, unsafe, entryBoundExceeded
}

public enum NotikaSessionRetentionClassification: String, Codable, Sendable {
    case eligible, retained, incomplete, invalid, ignored
}

public enum NotikaSessionRetentionAction: String, Codable, Sendable {
    case none, wouldTrash, trashed, skippedRevalidation, trashFailed
}

public enum NotikaSessionRetentionSource: String, Codable, Sendable { case manifest, todayOnly, keep }

public enum NotikaSessionRetentionReason: String, Codable, Sendable {
    case namespaceBusy, namespaceUnavailable, cachePolicyBusy, cachePolicyUnavailable, rootUnsafe, rootChanged, entryBoundExceeded, pendingTrashClaims
    case entryUnsafe, manifestMissing, manifestInvalid, unknownSchema, lifecycleInFuture, keepInvalid, ownerLive, ownerUnobservable, activityUncertain
    case beforeLocalDay, abandonedBeforeLocalDay, expiryReached, keepExpiryReached, expiryNotReached, finderMetadata
    case evidenceChanged, movedToTrash, trashFailed
}

public struct NotikaSessionRetentionEntry: Equatable, Codable, Sendable {
    public let name: String
    public let classification: NotikaSessionRetentionClassification
    public let action: NotikaSessionRetentionAction
    public let reason: NotikaSessionRetentionReason
    public let manifestDigest: String?
    public let keepDigest: String?
    public let effectiveExpiresAt: Date?
    public let retentionSource: NotikaSessionRetentionSource?
    public let detail: String?
}

public struct NotikaSessionRetentionReport: Equatable, Codable, Sendable {
    public let policy: ArtifactRetentionPolicy
    public let execute: Bool
    public let evaluatedAt: Date
    public let localDayCutoff: Date
    public let timeZoneIdentifier: String
    public let rootState: NotikaSessionRetentionRootState
    public let rootReason: NotikaSessionRetentionReason?
    public let scanComplete: Bool
    public let entries: [NotikaSessionRetentionEntry]
    public let trashOperatorIdentifier: String?
}

public enum NotikaSessionRetentionError: Error, Equatable, Sendable {
    case absentRoot, unsafeEntry, incomplete, unknownSchema, evidenceChanged, entryBoundExceeded, invalidManifest, invalidKeep, ownerLive, ownerUnobservable, activityUncertain
    case systemCall(String, Int32)
}

/// Nonblocking exclusive session, Xcode-policy and Rust-policy leases precede
/// every scan in that order. Legacy orphan children retain the cache-policy
/// descriptors even when their parent loses its session-writer descriptor.
/// Manifest lifecycle is eligibility evidence, never a substitute for custody.
public struct NotikaSessionRetentionCollector: Sendable {
    public static let maximumRootEntries = 1_024
    public static let maximumManifestBytes = 256 * 1_024
    public static let maximumKeepBytes = 16 * 1_024
    public static let maximumInactiveEntries = 10_000
    public static let maximumInactiveDirectories = 256
    public static let maximumInactiveDepth = 32
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
        try self.init(canonicalRepository: canonicalRepository, registryRoot: registryRoot,
            evaluatedAt: evaluatedAt, timeZone: timeZone, trashOperator: trashOperator,
            beforeRevalidation: beforeRevalidation,
            claimDirectoryFactory: { try RetainedArtifactDirectory(path: $0, requiredPermissions: 0o700) })
    }

    internal init(
        canonicalRepository: String, registryRoot: String, evaluatedAt: Date, timeZone: TimeZone,
        trashOperator: any ArtifactTrashOperator,
        beforeRevalidation: @escaping @Sendable (String) async throws -> Void = { _ in },
        claimDirectoryFactory: @escaping @Sendable (String) throws -> RetainedArtifactDirectory
    ) throws {
        _ = try CacheCompatibilityIdentity.graphResourceName(canonicalWorktree: canonicalRepository)
        repository = canonicalRepository
        self.registryRoot = registryRoot
        calendar = try LocalCalendarRetention(evaluatedAt: evaluatedAt, timeZone: timeZone)
        trash = trashOperator
        self.beforeRevalidation = beforeRevalidation
        self.claimDirectoryFactory = claimDirectoryFactory
    }

    public func run(execute: Bool) async throws -> NotikaSessionRetentionReport {
        try Task.checkCancellation()
        let paths: AgentLeasePaths
        let lease: FileLock
        do {
            paths = try AgentLeasePaths.open(selectedRoot: registryRoot)
            lease = try FileLock(resource: ResourceName("notika:sessions:" + repository), paths: paths)
            guard try lease.tryAcquire() else { return report(execute, root: .busy, reason: .namespaceBusy) }
        } catch { return report(execute, root: .unsafe, reason: .namespaceUnavailable) }
        defer { lease.release() }
        var policies: [FileLock] = []
        defer { for policy in policies.reversed() { policy.release() } }
        do {
            let resources = [
                try CacheCompatibilityIdentity.cachePolicyResourceName(canonicalWorktree: repository),
                try NotikaRustCacheRetentionCollector.policyResource(canonicalRepository: repository),
            ]
            for resource in resources {
                let policy = try FileLock(resource: ResourceName(resource), paths: paths)
                guard try policy.tryAcquire() else { return report(execute, root: .busy, reason: .cachePolicyBusy) }
                policies.append(policy)
            }
        } catch { return report(execute, root: .unsafe, reason: .cachePolicyUnavailable) }
        let ownedLeases = [lease] + policies
        let root: SessionRetentionRoot
        do {
            root = try SessionRetentionRoot(repository: repository)
            if try root.hasPendingClaims() { return report(execute, root: .unsafe, reason: .pendingTrashClaims) }
        } catch NotikaSessionRetentionError.absentRoot { return report(execute, root: .absent, complete: true) }
        catch { return report(execute, root: .unsafe, reason: .rootUnsafe) }
        let names: [String]
        do { names = try sessionRetentionNames(root.descriptor.value, maximum: Self.maximumRootEntries) }
        catch NotikaSessionRetentionError.entryBoundExceeded {
            return report(execute, root: .entryBoundExceeded, reason: .entryBoundExceeded)
        } catch { return report(execute, root: .unsafe, reason: .rootUnsafe) }
        var entries: [NotikaSessionRetentionEntry] = []
        for name in names.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            try Task.checkCancellation()
            do {
                for ownedLease in ownedLeases { try sessionRetentionValidateLease(ownedLease, registryRoot: registryRoot) }
                try root.revalidate()
            }
            catch { return report(execute, root: .unsafe, reason: .rootChanged, entries: entries) }
            if name == ".DS_Store", let status = try? sessionRetentionStatus(at: name, parent: root.descriptor.value),
               status.st_mode & S_IFMT == S_IFREG, status.st_uid == geteuid(), status.st_mode & 0o022 == 0 {
                entries.append(entry(name, .ignored, .finderMetadata))
                continue
            }
            let admission: SessionRetentionAdmission
            do { admission = try SessionRetentionAdmission(root: root, name: name, evaluatedAt: calendar.evaluatedAt) }
            catch NotikaSessionRetentionError.incomplete { entries.append(entry(name, .incomplete, .manifestMissing)); continue }
            catch NotikaSessionRetentionError.ownerLive { entries.append(entry(name, .incomplete, .ownerLive)); continue }
            catch NotikaSessionRetentionError.ownerUnobservable { entries.append(entry(name, .incomplete, .ownerUnobservable)); continue }
            catch NotikaSessionRetentionError.activityUncertain { entries.append(entry(name, .incomplete, .activityUncertain)); continue }
            catch NotikaSessionRetentionError.unknownSchema { entries.append(entry(name, .invalid, .unknownSchema)); continue }
            catch NotikaSessionRetentionError.invalidKeep { entries.append(entry(name, .invalid, .keepInvalid)); continue }
            catch NotikaSessionRetentionError.invalidManifest { entries.append(entry(name, .invalid, .manifestInvalid)); continue }
            catch { entries.append(entry(name, .invalid, .entryUnsafe, error: error)); continue }
            guard admission.startedAt <= calendar.evaluatedAt,
                  admission.completedAt.map({ $0 <= calendar.evaluatedAt }) ?? true else {
                entries.append(entry(name, .invalid, .lifecycleInFuture, admission: admission)); continue
            }
            let assessment: SessionRetentionEvaluation
            if admission.inactiveProgress {
                // Exclusive writer ownership proves quiescence for admitted
                // producers. Start time is age evidence, not an invented native
                // completion; no successful terminal manifest is synthesized.
                assessment = SessionRetentionEvaluation(eligibility: calendar.cacheEligibility(lastUsedAt: admission.lastActivityAt),
                    effectiveExpiresAt: calendar.localDayStart, source: .todayOnly)
            } else {
                assessment = calendar.sessionEligibility(completedAt: admission.completedAt,
                    manifestExpiresAt: admission.expiresAt, keep: admission.keepPolicy)
            }
            guard assessment.eligibility == .eligible else {
                entries.append(entry(name, assessment.eligibility == .invalid ? .invalid : .retained,
                                     assessment.eligibility == .invalid ? .keepInvalid : .expiryNotReached,
                                     admission: admission, evaluation: assessment)); continue
            }
            do {
                try await beforeRevalidation(root.path + "/" + name)
                for ownedLease in ownedLeases { try sessionRetentionValidateLease(ownedLease, registryRoot: registryRoot) }
                try admission.revalidateOriginal(root: root)
            } catch is CancellationError { throw CancellationError() }
            catch {
                entries.append(entry(name, .eligible, .evidenceChanged, action: .skippedRevalidation,
                                     admission: admission, evaluation: assessment, error: error)); continue
            }
            let reason: NotikaSessionRetentionReason = admission.inactiveProgress ? .abandonedBeforeLocalDay
                : assessment.source == .keep ? .keepExpiryReached
                : assessment.source == .todayOnly ? .beforeLocalDay : .expiryReached
            if !execute {
                entries.append(entry(name, .eligible, reason, action: .wouldTrash, admission: admission, evaluation: assessment))
                continue
            }
            do {
                try await root.move(admission, leases: ownedLeases, registryRoot: registryRoot,
                                    trash: trash, claimDirectoryFactory: claimDirectoryFactory)
                entries.append(entry(name, .eligible, .movedToTrash, action: .trashed,
                                     admission: admission, evaluation: assessment))
            } catch is CancellationError { throw CancellationError() }
            catch {
                entries.append(entry(name, .eligible, .trashFailed, action: .trashFailed,
                                     admission: admission, evaluation: assessment, error: error))
            }
        }
        do { try root.revalidate() }
        catch { return report(execute, root: .unsafe, reason: .rootChanged, entries: entries) }
        return report(execute, root: .ready, complete: true, entries: entries)
    }

    private func entry(
        _ name: String, _ classification: NotikaSessionRetentionClassification, _ reason: NotikaSessionRetentionReason,
        action: NotikaSessionRetentionAction = .none, admission: SessionRetentionAdmission? = nil,
        evaluation: SessionRetentionEvaluation? = nil, error: (any Error)? = nil
    ) -> NotikaSessionRetentionEntry {
        NotikaSessionRetentionEntry(name: name, classification: classification, action: action, reason: reason,
            manifestDigest: admission.flatMap { $0.manifest.name == "manifest.json" ? $0.manifest.digest : nil }, keepDigest: admission?.keep?.digest,
            effectiveExpiresAt: evaluation?.effectiveExpiresAt, retentionSource: evaluation?.source.map {
                switch $0 { case .manifest: .manifest; case .todayOnly: .todayOnly; case .keep: .keep }
            },
            detail: error.map { String(String(describing: $0).prefix(256)) }
                ?? admission.flatMap { $0.nativeUnknown ? "Native outcome unknown; retained lifecycle evidence: " + $0.manifest.name + "; sha256:" + $0.manifest.digest : nil })
    }

    private func report(
        _ execute: Bool, root: NotikaSessionRetentionRootState, reason: NotikaSessionRetentionReason? = nil,
        complete: Bool = false, entries: [NotikaSessionRetentionEntry] = []
    ) -> NotikaSessionRetentionReport {
        NotikaSessionRetentionReport(policy: .todayOnlySessions, execute: execute, evaluatedAt: calendar.evaluatedAt,
            localDayCutoff: calendar.localDayStart, timeZoneIdentifier: calendar.timeZone.identifier,
            rootState: root, rootReason: reason, scanComplete: complete, entries: entries,
            trashOperatorIdentifier: execute ? trash.identifier : nil)
    }
}

private final class SessionRetentionDescriptor: Sendable {
    let value: Int32
    init(_ value: Int32) { self.value = value }
    deinit { _ = Darwin.close(value) }
}

private struct SessionRetentionIdentity: Equatable, Sendable {
    let device: Int64, inode: UInt64
    let mode: UInt16, owner: UInt32, group: UInt32
    init(_ value: stat) {
        device = Int64(value.st_dev); inode = value.st_ino; mode = value.st_mode
        owner = value.st_uid; group = value.st_gid
    }
    init(_ value: ArtifactFileFingerprint) {
        device = value.device; inode = value.inode; mode = value.mode; owner = value.owner; group = value.group
    }
}

private struct SessionRetentionFingerprint: Equatable, Sendable {
    let identity: SessionRetentionIdentity
    let size: Int64, links: UInt64
    let modifiedSeconds: Int64, modifiedNanoseconds: Int64, changedSeconds: Int64, changedNanoseconds: Int64
    init(_ value: stat) {
        identity = SessionRetentionIdentity(value); size = value.st_size; links = UInt64(value.st_nlink)
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }
}

private final class SessionRetentionRoot: Sendable {
    let repository: RetainedArtifactDirectory
    let artifacts: RetainedArtifactDirectory
    let directory: RetainedArtifactDirectory
    let artifactsDescriptor: SessionRetentionDescriptor
    let descriptor: SessionRetentionDescriptor
    let path: String
    init(repository path: String) throws {
        repository = try RetainedArtifactDirectory(path: path)
        self.path = path + "/Artifacts/AgentSessions"
        do {
            artifacts = try RetainedArtifactDirectory(path: path + "/Artifacts")
            directory = try RetainedArtifactDirectory(path: self.path, requiredPermissions: 0o700)
        } catch RetainedArtifactError.systemCall(_, let code) where code == ENOENT {
            throw NotikaSessionRetentionError.absentRoot
        }
        guard artifacts.fingerprint.device == repository.fingerprint.device,
              directory.fingerprint.device == repository.fingerprint.device else {
            throw NotikaSessionRetentionError.unsafeEntry
        }
        artifactsDescriptor = try sessionRetentionOpen(artifacts)
        descriptor = try sessionRetentionOpen(directory)
        try revalidate()
    }
    func revalidate() throws {
        try repository.revalidate(); try artifacts.revalidate(); try directory.revalidate()
        guard try SessionRetentionIdentity(sessionRetentionStatus(descriptor.value)) == SessionRetentionIdentity(directory.fingerprint),
              try SessionRetentionIdentity(sessionRetentionStatus(artifactsDescriptor.value)) == SessionRetentionIdentity(artifacts.fingerprint) else {
            throw NotikaSessionRetentionError.evidenceChanged
        }
    }
    func hasPendingClaims() throws -> Bool {
        guard try sessionRetentionStatusIfPresent(at: "AgentSessionTrashClaims", parent: artifactsDescriptor.value) != nil else { return false }
        let claims = try RetainedArtifactDirectory(path: artifacts.path + "/AgentSessionTrashClaims", requiredPermissions: 0o700)
        guard claims.fingerprint.device == repository.fingerprint.device else { throw NotikaSessionRetentionError.unsafeEntry }
        let fd = try sessionRetentionOpen(claims)
        let names = try sessionRetentionNames(fd.value, maximum: NotikaSessionRetentionCollector.maximumRootEntries)
        try claims.revalidate(); try revalidate()
        return !names.isEmpty
    }
    func move(
        _ admission: SessionRetentionAdmission, leases: [FileLock], registryRoot: String,
        trash: any ArtifactTrashOperator,
        claimDirectoryFactory: @Sendable (String) throws -> RetainedArtifactDirectory
    ) async throws {
        for lease in leases { try sessionRetentionValidateLease(lease, registryRoot: registryRoot) }
        try admission.revalidateOriginal(root: self)
        if mkdirat(artifactsDescriptor.value, "AgentSessionTrashClaims", 0o700) != 0, errno != EEXIST {
            throw sessionRetentionIO("create session Trash claims")
        }
        let claims = try RetainedArtifactDirectory(path: artifacts.path + "/AgentSessionTrashClaims", requiredPermissions: 0o700)
        guard claims.fingerprint.device == repository.fingerprint.device else { throw NotikaSessionRetentionError.unsafeEntry }
        let claimsFD = try sessionRetentionOpen(claims)
        let claimName = "." + admission.name + "." + UUID().uuidString + ".claim"
        guard mkdirat(claimsFD.value, claimName, 0o700) == 0 else { throw sessionRetentionIO("create private session Trash claim") }
        // Cleanup exists before any descriptor allocation. If even the initial
        // nonallocating identity observation fails, preserve the unknown name.
        var placeholder: SessionRetentionIdentity?
        var claimed = false
        defer {
            if !claimed, let placeholder,
               (try? claims.revalidate()) != nil,
               let current = try? sessionRetentionStatus(at: claimName, parent: claimsFD.value),
               SessionRetentionIdentity(current) == placeholder {
                // AT_REMOVEDIR can retire only this exact empty placeholder.
                _ = unlinkat(claimsFD.value, claimName, AT_REMOVEDIR)
            }
        }
        placeholder = SessionRetentionIdentity(try sessionRetentionStatus(at: claimName, parent: claimsFD.value))
        let claim = try claimDirectoryFactory(claims.path + "/" + claimName)
        guard claim.path.utf8.elementsEqual((claims.path + "/" + claimName).utf8),
              SessionRetentionIdentity(claim.fingerprint) == placeholder else {
            throw NotikaSessionRetentionError.evidenceChanged
        }
        let claimFD = try sessionRetentionOpen(claim)
        try claims.revalidate(); try claim.revalidate(); try admission.revalidateOriginal(root: self)
        guard renameatx_np(descriptor.value, admission.name, claimFD.value, admission.name, UInt32(RENAME_EXCL)) == 0 else {
            throw sessionRetentionIO("claim session for Trash")
        }
        claimed = true
        do {
            // Every fallible step after the rename is covered by exact-source
            // restoration, including constructing its retained directory.
            let claimedDirectory = try claimDirectoryFactory(claim.path + "/" + admission.name)
            guard claimedDirectory.path.utf8.elementsEqual((claim.path + "/" + admission.name).utf8),
                  SessionRetentionIdentity(claimedDirectory.fingerprint) == admission.identity else {
                throw NotikaSessionRetentionError.evidenceChanged
            }
            let bindings = try leases.map(sessionRetentionLeaseBinding)
            let source = ArtifactTrashSource(directory: claimedDirectory, originalPath: path + "/" + admission.name,
                inheritedDescriptors: bindings.map(\.descriptor) + [descriptor.value, artifactsDescriptor.value, claimsFD.value,
                                       claimFD.value, admission.descriptor.value, admission.manifest.descriptor.value]
                    + (admission.keep.map { [$0.descriptor.value] } ?? [])
                    + (admission.authority.map { [$0.descriptor.value] } ?? []),
                revalidate: {
                    for binding in bindings { try sessionRetentionValidateBinding(binding, registryRoot: registryRoot) }
                    try self.revalidate(); try claims.revalidate(); try claim.revalidate()
                    guard try SessionRetentionIdentity(sessionRetentionStatus(at: admission.name, parent: claimFD.value)) == admission.identity else {
                        throw NotikaSessionRetentionError.evidenceChanged
                    }
                    try admission.revalidateContents()
                })
            defer { source.retire() }
            try source.revalidateBeforeMove()
            try await trash.moveToTrash(source)
            try revalidate(); try claims.revalidate(); try claim.revalidate()
            guard try sessionRetentionStatusIfPresent(at: admission.name, parent: claimFD.value) == nil,
                  try sessionRetentionStatusIfPresent(at: admission.name, parent: descriptor.value) == nil,
                  try SessionRetentionIdentity(sessionRetentionStatus(admission.descriptor.value)) == admission.identity else {
                throw ArtifactTrashError.failed
            }
            claimed = false
        } catch {
            // Restore only the retained exact inode into an absent original name.
            // Any uncertainty leaves the private claim protected for recovery.
            if (try? revalidate()) != nil,
               let current = try? sessionRetentionStatus(at: admission.name, parent: claimFD.value),
               SessionRetentionIdentity(current) == admission.identity,
               renameatx_np(claimFD.value, admission.name, descriptor.value, admission.name, UInt32(RENAME_EXCL)) == 0 {
                claimed = false
            }
            throw error
        }
    }
}

private final class SessionRetentionFile: Sendable {
    let name: String
    let descriptor: SessionRetentionDescriptor
    let fingerprint: SessionRetentionFingerprint
    let bytes: Data
    let digest: String
    init(name: String, parent: Int32, maximum: Int) throws {
        let observed = try sessionRetentionStatus(at: name, parent: parent)
        guard observed.st_mode & S_IFMT == S_IFREG, observed.st_uid == geteuid(),
              observed.st_mode & 0o7777 == 0o400, observed.st_size > 0, observed.st_size <= maximum,
              observed.st_nlink == 1 || observed.st_nlink == 2 else { throw NotikaSessionRetentionError.unsafeEntry }
        let opened = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard opened >= 0 else { throw sessionRetentionIO("open session evidence") }
        descriptor = SessionRetentionDescriptor(opened)
        fingerprint = SessionRetentionFingerprint(observed)
        guard try SessionRetentionFingerprint(sessionRetentionStatus(opened)) == fingerprint else {
            throw NotikaSessionRetentionError.evidenceChanged
        }
        self.name = name
        bytes = try sessionRetentionRead(opened, count: Int(observed.st_size))
        digest = CanonicalJSONDigest.digest(bytes)
        try revalidate(parent: parent)
    }
    func revalidate(parent: Int32) throws {
        guard try SessionRetentionFingerprint(sessionRetentionStatus(descriptor.value)) == fingerprint,
              try SessionRetentionFingerprint(sessionRetentionStatus(at: name, parent: parent)) == fingerprint,
              try sessionRetentionRead(descriptor.value, count: bytes.count) == bytes,
              try SessionRetentionFingerprint(sessionRetentionStatus(descriptor.value)) == fingerprint else {
            throw NotikaSessionRetentionError.evidenceChanged
        }
    }

    /// The Python publisher retained its private, sealed staging link after
    /// publishing the public name. Admit that exact sibling for retention only;
    /// an unknown or external second link cannot establish owned custody.
    func legacyStageName(parent: Int32) throws -> String? {
        if fingerprint.links == 1 { return nil }
        guard fingerprint.links == 2 else { throw NotikaSessionRetentionError.invalidManifest }
        let prefix = "." + name + "."
        let names = try sessionRetentionNames(parent, maximum: NotikaSessionRetentionCollector.maximumRootEntries)
        let matches = try names.filter { candidate in
            guard candidate.hasPrefix(prefix), candidate.hasSuffix(".stage") else { return false }
            let fields = candidate.dropFirst(prefix.utf8.count).dropLast(".stage".utf8.count).split(separator: ".", omittingEmptySubsequences: false)
            guard fields.count == 2, let processID = Int32(fields[0]), processID > 0,
                  String(processID) == fields[0], sessionRetentionHex(String(fields[1]), count: 32),
                  let current = try sessionRetentionStatusIfPresent(at: candidate, parent: parent) else { return false }
            return SessionRetentionFingerprint(current) == fingerprint
        }
        guard matches.count == 1 else { throw NotikaSessionRetentionError.invalidManifest }
        try revalidate(parent: parent)
        return matches[0]
    }
}

/// Iterative nofollow age observation, used only for admitted unfinished work.
/// Recent nested logs count as today's activity. Missing, nonregular, oversized or
/// changing traversal cannot turn an uncertain session into an old one.
private final class SessionRetentionInactiveInventory: Sendable {
    private struct Entry: Sendable {
        let parent: SessionRetentionDescriptor
        let name: String
        let fingerprint: SessionRetentionFingerprint
    }
    private let root: SessionRetentionDescriptor
    private let rootFingerprint: SessionRetentionFingerprint
    private let directories: [SessionRetentionDescriptor]
    private let entries: [Entry]
    let lastModifiedAt: Date

    init(root: SessionRetentionDescriptor, evaluatedAt: Date) throws {
        self.root = root
        rootFingerprint = SessionRetentionFingerprint(try sessionRetentionStatus(root.value))
        var newest = try Self.modification(rootFingerprint, evaluatedAt: evaluatedAt)
        var retained = [root]
        var collected: [Entry] = []
        var pending = [(root, 0)]
        while let (directory, depth) = pending.popLast() {
            let names = try sessionRetentionNames(directory.value,
                maximum: NotikaSessionRetentionCollector.maximumInactiveEntries - collected.count)
            for name in names {
                guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
                      !name.utf8.contains(0), !name.utf8.contains(47),
                      collected.count < NotikaSessionRetentionCollector.maximumInactiveEntries else {
                    throw NotikaSessionRetentionError.activityUncertain
                }
                let observed = try sessionRetentionStatus(at: name, parent: directory.value)
                let fingerprint = SessionRetentionFingerprint(observed)
                guard observed.st_uid == geteuid(), fingerprint.identity.device == rootFingerprint.identity.device,
                      observed.st_mode & S_IFMT == S_IFDIR || observed.st_mode & S_IFMT == S_IFREG else {
                    throw NotikaSessionRetentionError.activityUncertain
                }
                newest = max(newest, try Self.modification(fingerprint, evaluatedAt: evaluatedAt))
                collected.append(Entry(parent: directory, name: name, fingerprint: fingerprint))
                if observed.st_mode & S_IFMT == S_IFDIR {
                    guard depth < NotikaSessionRetentionCollector.maximumInactiveDepth,
                          retained.count < NotikaSessionRetentionCollector.maximumInactiveDirectories else {
                        throw NotikaSessionRetentionError.activityUncertain
                    }
                    let opened = openat(directory.value, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                    guard opened >= 0 else { throw sessionRetentionIO("open inactive artifact directory") }
                    let child = SessionRetentionDescriptor(opened)
                    guard try SessionRetentionFingerprint(sessionRetentionStatus(opened)) == fingerprint else {
                        throw NotikaSessionRetentionError.evidenceChanged
                    }
                    retained.append(child)
                    pending.append((child, depth + 1))
                }
            }
        }
        directories = retained
        entries = collected
        lastModifiedAt = newest
        try revalidate()
    }

    func revalidate() throws {
        let current = SessionRetentionFingerprint(try sessionRetentionStatus(root.value))
        // Claiming the root may change its ctime. Child inventory, root names,
        // mtime, size, mode and identity must still be the admitted observations.
        guard current.identity == rootFingerprint.identity, current.size == rootFingerprint.size,
              current.links == rootFingerprint.links, current.modifiedSeconds == rootFingerprint.modifiedSeconds,
              current.modifiedNanoseconds == rootFingerprint.modifiedNanoseconds else {
            throw NotikaSessionRetentionError.evidenceChanged
        }
        for entry in entries {
            guard try SessionRetentionFingerprint(sessionRetentionStatus(at: entry.name, parent: entry.parent.value)) == entry.fingerprint else {
                throw NotikaSessionRetentionError.evidenceChanged
            }
        }
    }

    private static func modification(_ fingerprint: SessionRetentionFingerprint, evaluatedAt: Date) throws -> Date {
        guard fingerprint.modifiedNanoseconds >= 0, fingerprint.modifiedNanoseconds < 1_000_000_000 else {
            throw NotikaSessionRetentionError.activityUncertain
        }
        let value = Date(timeIntervalSince1970: Double(fingerprint.modifiedSeconds) + Double(fingerprint.modifiedNanoseconds) / 1_000_000_000)
        guard value.timeIntervalSince1970.isFinite, value <= evaluatedAt else { throw NotikaSessionRetentionError.activityUncertain }
        return value
    }
}

private final class SessionRetentionAdmission: Sendable {
    let name: String
    let descriptor: SessionRetentionDescriptor
    let identity: SessionRetentionIdentity
    let directoryFingerprint: SessionRetentionFingerprint
    let manifest: SessionRetentionFile
    let privateManifestName: String?
    let authority: SessionRetentionFile?
    let privateAuthorityName: String?
    let legacyOwner: SessionRetentionOwner?
    let inactiveProgress: Bool
    let nativeUnknown: Bool
    let inactiveInventory: SessionRetentionInactiveInventory?
    let lastActivityAt: Date
    let keep: SessionRetentionFile?
    let keepPolicy: SessionRetentionKeep
    let startedAt: Date
    let completedAt: Date?, expiresAt: Date?

    init(root: SessionRetentionRoot, name: String, evaluatedAt: Date) throws {
        guard sessionRetentionSafeName(name) else { throw NotikaSessionRetentionError.unsafeEntry }
        let observed = try sessionRetentionStatus(at: name, parent: root.descriptor.value)
        guard observed.st_mode & S_IFMT == S_IFDIR, observed.st_uid == geteuid(),
              observed.st_mode & 0o7777 == 0o700, Int64(observed.st_dev) == root.repository.fingerprint.device else {
            throw NotikaSessionRetentionError.unsafeEntry
        }
        let opened = openat(root.descriptor.value, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard opened >= 0 else { throw sessionRetentionIO("open retained session") }
        descriptor = SessionRetentionDescriptor(opened)
        directoryFingerprint = SessionRetentionFingerprint(observed)
        identity = directoryFingerprint.identity
        self.name = name
        guard try SessionRetentionFingerprint(sessionRetentionStatus(opened)) == directoryFingerprint else {
            throw NotikaSessionRetentionError.evidenceChanged
        }
        let evidenceName: String
        if try sessionRetentionStatusIfPresent(at: "manifest.json", parent: opened) != nil { evidenceName = "manifest.json" }
        else if try sessionRetentionStatusIfPresent(at: "in-progress.json", parent: opened) != nil { evidenceName = "in-progress.json" }
        else if try sessionRetentionStatusIfPresent(at: "development-session.json", parent: opened) != nil { evidenceName = "development-session.json" }
        else { throw NotikaSessionRetentionError.incomplete }
        do { manifest = try SessionRetentionFile(name: evidenceName, parent: opened,
                                                maximum: NotikaSessionRetentionCollector.maximumManifestBytes) }
        catch { throw NotikaSessionRetentionError.invalidManifest }
        let object: StrictJSONObject
        do { object = try StrictJSONDocument(data: manifest.bytes).root.requireObject() }
        catch { throw NotikaSessionRetentionError.invalidManifest }
        var retainedAuthority: SessionRetentionFile?
        var retainedAuthorityPrivateName: String?
        var owner: SessionRetentionOwner?
        inactiveProgress = evidenceName != "manifest.json"
        nativeUnknown = inactiveProgress || object.value(forKey: "resourceID") == .string("notika.abandoned-development-session")
        if object.value(forKey: "namespace") == .string(NotikaBuildSessionReport.namespace) {
            do {
                let report = try NotikaBuildSessionReport(data: manifest.bytes, expectedRepository: root.repository.path,
                    expectedSessionID: name, captureAdmissionPolicy: inactiveProgress ? .current : .historicalRetention)
                guard report.lifecycle == (inactiveProgress ? "inProgress" : "terminal"),
                      evidenceName == (inactiveProgress ? "in-progress.json" : "manifest.json"),
                      try sessionRetentionUInt(object, "ownerUID") == UInt64(geteuid()) else {
                    throw NotikaSessionRetentionError.invalidManifest
                }
                let directory = try object.requiredValue(forKey: "directoryIdentity").requireObject()
                startedAt = try sessionRetentionDate(object, "startedAt")
                // A session records its directory identity once, when it starts.
                guard try DirectoryIdentityBoot.current().admits(
                          storedDeviceID: sessionRetentionUInt(directory, "deviceID"),
                          storedInode: sessionRetentionUInt(directory, "inode"), recordedAt: startedAt,
                          observedDeviceID: UInt64(observed.st_dev), observedInode: UInt64(observed.st_ino)
                      ), manifest.fingerprint.links == 2 else {
                    throw NotikaSessionRetentionError.invalidManifest
                }
                completedAt = inactiveProgress ? nil : try sessionRetentionDate(object, "completedAt")
                expiresAt = inactiveProgress ? nil : try sessionRetentionDate(object, "expiresAt")
                let names = try sessionRetentionNames(opened, maximum: NotikaSessionRetentionCollector.maximumRootEntries)
                let peers = names.filter { $0.hasPrefix(".agentbuild-" + evidenceName + "-") && $0.hasSuffix(".sealed") }
                let boundManifest = manifest.fingerprint
                let matches = try peers.filter { peer in
                    guard let current = try sessionRetentionStatusIfPresent(at: peer, parent: opened) else { return false }
                    return SessionRetentionFingerprint(current) == boundManifest
                }
                guard matches.count == 1 else { throw NotikaSessionRetentionError.invalidManifest }
                privateManifestName = matches[0]
            } catch { throw NotikaSessionRetentionError.invalidManifest }
        } else if object.value(forKey: "namespace") == .string(NotikaGenerationSessionReport.namespace)
                    || object.value(forKey: "namespace") == .string(NotikaRustTestSessionReport.namespace)
                    || object.value(forKey: "namespace") == .string(NotikaPreflightSessionReport.namespace)
                    || object.value(forKey: "namespace") == .string(NotikaDocumentationSessionReport.namespace) {
            do {
                // Each standalone reader owns its distinct phase/receipt schema;
                // retention only adds actual folder/file custody and age policy.
                let lifecycle: String
                if object.value(forKey: "namespace") == .string(NotikaGenerationSessionReport.namespace) {
                    lifecycle = try NotikaGenerationSessionReport(data: manifest.bytes,
                        expectedRepository: root.repository.path, expectedSessionID: name,
                        captureAdmissionPolicy: inactiveProgress ? .current : .historicalRetention).lifecycle
                } else if object.value(forKey: "namespace") == .string(NotikaRustTestSessionReport.namespace) {
                    lifecycle = try NotikaRustTestSessionReport(data: manifest.bytes,
                        expectedRepository: root.repository.path, expectedSessionID: name,
                        captureAdmissionPolicy: inactiveProgress ? .current : .historicalRetention).lifecycle
                } else if object.value(forKey: "namespace") == .string(NotikaPreflightSessionReport.namespace) {
                    lifecycle = try NotikaPreflightSessionReport(data: manifest.bytes,
                        expectedRepository: root.repository.path, expectedSessionID: name,
                        captureAdmissionPolicy: inactiveProgress ? .current : .historicalRetention).lifecycle
                } else {
                    lifecycle = try NotikaDocumentationSessionReport(data: manifest.bytes,
                        expectedRepository: root.repository.path, expectedSessionID: name,
                        captureAdmissionPolicy: inactiveProgress ? .current : .historicalRetention).lifecycle
                }
                guard lifecycle == (inactiveProgress ? "inProgress" : "terminal"),
                      evidenceName == (inactiveProgress ? "in-progress.json" : "manifest.json") else {
                    throw NotikaSessionRetentionError.incomplete
                }
                guard try sessionRetentionUInt(object, "ownerUID") == UInt64(geteuid()),
                      manifest.fingerprint.links == 1 else { throw NotikaSessionRetentionError.invalidManifest }
                let directory = try object.requiredValue(forKey: "directoryIdentity").requireObject()
                startedAt = try sessionRetentionDate(object, "startedAt")
                guard try DirectoryIdentityBoot.current().admits(
                          storedDeviceID: sessionRetentionUInt(directory, "deviceID"),
                          storedInode: sessionRetentionUInt(directory, "inode"), recordedAt: startedAt,
                          observedDeviceID: UInt64(observed.st_dev), observedInode: UInt64(observed.st_ino)
                      ) else {
                    throw NotikaSessionRetentionError.invalidManifest
                }
                completedAt = inactiveProgress ? nil : try sessionRetentionDate(object, "completedAt")
                expiresAt = inactiveProgress ? nil : try sessionRetentionDate(object, "expiresAt")
                // Standalone publication removes its private temporary name;
                // unlike build reports, no second link is admitted or needed.
                privateManifestName = nil
            } catch NotikaSessionRetentionError.incomplete { throw NotikaSessionRetentionError.incomplete }
            catch { throw NotikaSessionRetentionError.invalidManifest }
        } else if evidenceName == "development-session.json" {
            do {
                owner = try sessionRetentionValidateAuthority(object, repository: root.repository.path, name: name, directory: observed)
                privateManifestName = try manifest.legacyStageName(parent: opened)
                startedAt = try sessionRetentionDate(object, "createdAt")
                completedAt = nil; expiresAt = nil
            } catch { throw NotikaSessionRetentionError.invalidManifest }
        } else if object.value(forKey: "resourceID") == .string("notika.abandoned-development-session") {
            guard !inactiveProgress else { throw NotikaSessionRetentionError.invalidManifest }
            do {
                let retained = try SessionRetentionFile(name: "development-session.json", parent: opened,
                    maximum: NotikaSessionRetentionCollector.maximumManifestBytes)
                retainedAuthorityPrivateName = try retained.legacyStageName(parent: opened)
                owner = try sessionRetentionValidateAbandoned(object, authority: retained,
                    repository: root.repository.path, name: name, directory: observed)
                retainedAuthority = retained
                privateManifestName = try manifest.legacyStageName(parent: opened)
                startedAt = try sessionRetentionDate(object, "createdAt")
                completedAt = try sessionRetentionDate(object, "completedAt")
                expiresAt = try sessionRetentionDate(object, "expiresAt")
            } catch { throw NotikaSessionRetentionError.invalidManifest }
        } else {
            guard !inactiveProgress, object.value(forKey: "namespace") == nil, object.value(forKey: "resourceID") == nil else {
                throw NotikaSessionRetentionError.unknownSchema
            }
            do {
                try sessionRetentionValidateLegacy(object, repository: root.repository.path, name: name)
                privateManifestName = try manifest.legacyStageName(parent: opened)
                startedAt = try sessionRetentionDate(object, "createdAt")
                completedAt = try sessionRetentionDate(object, "completedAt")
                expiresAt = try sessionRetentionDate(object, "expiresAt")
            } catch { throw NotikaSessionRetentionError.invalidManifest }
        }
        authority = retainedAuthority
        privateAuthorityName = retainedAuthorityPrivateName
        legacyOwner = owner
        if let completedAt, let expiresAt {
            guard startedAt <= completedAt, completedAt <= expiresAt else { throw NotikaSessionRetentionError.invalidManifest }
        } else if !inactiveProgress { throw NotikaSessionRetentionError.invalidManifest }
        if try sessionRetentionStatusIfPresent(at: "retention-keep.json", parent: opened) != nil {
            do {
                guard let expiresAt, !inactiveProgress else { throw NotikaSessionRetentionError.invalidKeep }
                let keep = try SessionRetentionFile(name: "retention-keep.json", parent: opened,
                                                    maximum: NotikaSessionRetentionCollector.maximumKeepBytes)
                guard keep.fingerprint.links == 1 else { throw NotikaSessionRetentionError.invalidKeep }
                let expiry = try sessionRetentionValidateKeep(StrictJSONDocument(data: keep.bytes).root.requireObject(),
                    repository: root.repository.path, name: name, manifestDigest: manifest.digest,
                    originalExpiresAt: expiresAt, evaluatedAt: evaluatedAt)
                self.keep = keep
                keepPolicy = .validated(expiresAt: expiry)
            } catch { throw NotikaSessionRetentionError.invalidKeep }
        } else { keep = nil; keepPolicy = .absent }
        do {
            inactiveInventory = inactiveProgress && startedAt <= evaluatedAt
                ? try SessionRetentionInactiveInventory(root: descriptor, evaluatedAt: evaluatedAt) : nil
            lastActivityAt = max(startedAt, inactiveInventory?.lastModifiedAt ?? startedAt)
        } catch { throw NotikaSessionRetentionError.activityUncertain }
        try revalidateOriginal(root: root)
    }
    func revalidateOriginal(root: SessionRetentionRoot) throws {
        try root.revalidate()
        guard try SessionRetentionFingerprint(sessionRetentionStatus(descriptor.value)) == directoryFingerprint,
              try SessionRetentionFingerprint(sessionRetentionStatus(at: name, parent: root.descriptor.value)) == directoryFingerprint else {
            throw NotikaSessionRetentionError.evidenceChanged
        }
        try revalidateContents()
        try root.revalidate()
    }
    func revalidateContents() throws {
        guard try SessionRetentionIdentity(sessionRetentionStatus(descriptor.value)) == identity else {
            throw NotikaSessionRetentionError.evidenceChanged
        }
        try manifest.revalidate(parent: descriptor.value)
        if let authority { try authority.revalidate(parent: descriptor.value) }
        if inactiveProgress, try sessionRetentionStatusIfPresent(at: "manifest.json", parent: descriptor.value) != nil {
            throw NotikaSessionRetentionError.evidenceChanged
        }
        if let legacyOwner { try legacyOwner.requireInactive() }
        try inactiveInventory?.revalidate()
        if let privateManifestName {
            guard try SessionRetentionFingerprint(sessionRetentionStatus(at: privateManifestName, parent: descriptor.value)) == manifest.fingerprint else {
                throw NotikaSessionRetentionError.evidenceChanged
            }
        }
        if let privateAuthorityName, let authority {
            guard try SessionRetentionFingerprint(sessionRetentionStatus(at: privateAuthorityName, parent: descriptor.value)) == authority.fingerprint else {
                throw NotikaSessionRetentionError.evidenceChanged
            }
        }
        if let keep { try keep.revalidate(parent: descriptor.value) }
        else if try sessionRetentionStatusIfPresent(at: "retention-keep.json", parent: descriptor.value) != nil {
            throw NotikaSessionRetentionError.evidenceChanged
        }
        try manifest.revalidate(parent: descriptor.value)
    }
}

/// A recorded PID alone never proves inactivity. Exact process birth includes
/// executable spelling; parent PID is mutable and deliberately not authority.
private struct SessionRetentionOwner: Sendable {
    let processID: Int32
    let ownerUID: UInt32
    let executable: String
    let startSeconds: UInt64, startMicroseconds: UInt64

    init(_ value: StrictJSONValue) throws {
        let object = try value.requireObject().project(requiredKeys: ["processID", "parentProcessID", "ownerUserID",
                                                                    "executable", "startTimeSeconds", "startTimeMicroseconds"])
        let pid = try sessionRetentionUInt(object, "processID"), parent = try sessionRetentionUInt(object, "parentProcessID")
        let uid = try sessionRetentionUInt(object, "ownerUserID")
        startSeconds = try sessionRetentionUInt(object, "startTimeSeconds")
        startMicroseconds = try sessionRetentionUInt(object, "startTimeMicroseconds")
        executable = try sessionRetentionString(object, "executable")
        guard pid > 0, pid <= UInt64(Int32.max), parent > 0, parent <= UInt64(Int32.max), uid == UInt64(geteuid()),
              startSeconds > 0, startMicroseconds < 1_000_000, sessionRetentionAbsolutePath(executable) else {
            throw NotikaSessionRetentionError.invalidManifest
        }
        processID = Int32(pid); ownerUID = UInt32(uid)
    }

    func requireInactive() throws {
        let observed: NotikaInteractiveProcessIdentity
        do { observed = try NotikaInteractiveProcessIdentity.observe(processID) }
        catch {
            // Failure to observe is not absence. Only ESRCH from a read-only
            // existence probe permits the absent-owner case; uncertainty stays.
            if kill(processID, 0) != 0, errno == ESRCH { return }
            throw NotikaSessionRetentionError.ownerUnobservable
        }
        guard observed.ownerUID != ownerUID || observed.startSeconds != startSeconds
                || observed.startMicroseconds != startMicroseconds
                || !observed.executable.utf8.elementsEqual(executable.utf8) else {
            throw NotikaSessionRetentionError.ownerLive
        }
    }
}

private func sessionRetentionValidateAuthority(
    _ root: StrictJSONObject, repository: String, name: String, directory: stat
) throws -> SessionRetentionOwner {
    _ = try root.project(requiredKeys: ["schemaVersion", "resourceID", "sessionID", "repository", "createdAt", "sourceBeforeHash",
                                        "request", "ownerProcess", "artifacts", "lease", "cache", "cleanupPolicy"])
    guard root.value(forKey: "resourceID") == .string("notika.development-session-authority"),
          try sessionRetentionUInt(root, "schemaVersion") == 1,
          try sessionRetentionString(root, "sessionID").utf8.elementsEqual(name.utf8),
          try sessionRetentionString(root, "repository").utf8.elementsEqual(repository.utf8),
          sessionRetentionHex(try sessionRetentionString(root, "sourceBeforeHash"), count: 64) else {
        throw NotikaSessionRetentionError.invalidManifest
    }
    let createdAt = try sessionRetentionDate(root, "createdAt")
    let requestValue = try root.requiredValue(forKey: "request")
    let encodedRequest = try CanonicalJSONDigest.encode(sessionRetentionCanonical(requestValue))
    let request = try JSONDecoder().decode(NotikaActionRequest.self, from: encodedRequest)
    guard try CanonicalJSONDigest.encode(sessionRetentionCanonical(StrictJSONDocument(data: JSONEncoder().encode(request)).root)) == encodedRequest else {
        throw NotikaSessionRetentionError.invalidManifest
    }
    let artifacts = try root.requiredValue(forKey: "artifacts").requireObject().project(requiredKeys: ["deviceID", "inode", "root"])
    guard try sessionRetentionString(artifacts, "root").utf8.elementsEqual((repository + "/Artifacts/AgentSessions/" + name).utf8),
          try DirectoryIdentityBoot.current().admits(
              storedDeviceID: sessionRetentionUInt(artifacts, "deviceID"),
              storedInode: sessionRetentionUInt(artifacts, "inode"), recordedAt: createdAt,
              observedDeviceID: UInt64(directory.st_dev), observedInode: UInt64(directory.st_ino)
          ) else { throw NotikaSessionRetentionError.invalidManifest }
    let cache = try root.requiredValue(forKey: "cache").requireObject().project(requiredKeys: ["key", "path", "lockPath", "ownershipAuthority"])
    let key = try sessionRetentionString(cache, "key")
    guard sessionRetentionHex(key, count: 24),
          try sessionRetentionString(cache, "path").utf8.elementsEqual((repository + "/DerivedData/AgentCaches/" + key).utf8),
          sessionRetentionAbsolutePath(try sessionRetentionString(cache, "lockPath")),
          cache.value(forKey: "ownershipAuthority") == .string("agentlease-kernel-lock") else {
        throw NotikaSessionRetentionError.invalidManifest
    }
    let lease = try root.requiredValue(forKey: "lease").requireObject().project(requiredKeys: ["platform", "required", "cleanupAuthority"])
    let required = request.requiresOuterLease || (request.makeRoute == nil && !request.isInteractive && !request.isDocumentation)
    guard lease.value(forKey: "platform") == .string(request.platform.rawValue),
          lease.value(forKey: "required") == .bool(required),
          lease.value(forKey: "cleanupAuthority") == .string("simlease-supervisor") else { throw NotikaSessionRetentionError.invalidManifest }
    let policy = try root.requiredValue(forKey: "cleanupPolicy").requireObject().project(requiredKeys: ["artifacts", "cache", "lease", "process"])
    guard policy.value(forKey: "artifacts") == .string("retain-then-trash-after-final-expiry"),
          policy.value(forKey: "cache") == .string("never-delete-or-unlock"),
          policy.value(forKey: "lease") == .string("never-adopt-or-release"),
          policy.value(forKey: "process") == .string("observe-only-never-signal") else { throw NotikaSessionRetentionError.invalidManifest }
    return try SessionRetentionOwner(root.requiredValue(forKey: "ownerProcess"))
}

/// Retention-only admission of the finalized legacy abandonment receipt. The
/// original sealed authority is retained and bound; no native success follows.
private func sessionRetentionValidateAbandoned(
    _ root: StrictJSONObject, authority: SessionRetentionFile, repository: String, name: String, directory: stat
) throws -> SessionRetentionOwner {
    _ = try root.project(requiredKeys: ["schemaVersion", "resourceID", "sessionID", "createdAt", "completedAt", "expiresAt", "status",
                                        "repository", "sourceBeforeHash", "request", "cache", "artifacts", "abandonment"])
    let authorityObject = try StrictJSONDocument(data: authority.bytes).root.requireObject()
    let owner = try sessionRetentionValidateAuthority(authorityObject, repository: repository, name: name, directory: directory)
    guard try sessionRetentionUInt(root, "schemaVersion") == 1,
          root.value(forKey: "resourceID") == .string("notika.abandoned-development-session"),
          root.value(forKey: "status") == .string("inconclusive"),
          try sessionRetentionString(root, "sessionID").utf8.elementsEqual(name.utf8),
          try sessionRetentionString(root, "repository").utf8.elementsEqual(repository.utf8),
          root.value(forKey: "createdAt") == authorityObject.value(forKey: "createdAt"),
          root.value(forKey: "sourceBeforeHash") == authorityObject.value(forKey: "sourceBeforeHash"),
          root.value(forKey: "request") == authorityObject.value(forKey: "request"),
          root.value(forKey: "cache") == authorityObject.value(forKey: "cache") else { throw NotikaSessionRetentionError.invalidManifest }
    let artifacts = try root.requiredValue(forKey: "artifacts").requireObject().project(requiredKeys: ["root", "retained", "inventory"])
    guard try sessionRetentionString(artifacts, "root").utf8.elementsEqual((repository + "/Artifacts/AgentSessions/" + name).utf8),
          artifacts.value(forKey: "retained") == .bool(true) else { throw NotikaSessionRetentionError.invalidManifest }
    let inventory = try artifacts.requiredValue(forKey: "inventory").requireObject().project(requiredKeys: ["algorithm", "entries", "sha256"])
    guard inventory.value(forKey: "algorithm") == .string("notika.session-entry-metadata.sha256.v1"),
          try sessionRetentionUInt(inventory, "entries") > 0,
          sessionRetentionHex(try sessionRetentionString(inventory, "sha256"), count: 64) else { throw NotikaSessionRetentionError.invalidManifest }
    let abandonment = try root.requiredValue(forKey: "abandonment").requireObject().project(requiredKeys: ["adjudicatedAt", "authority", "directory",
                                                                                                       "ownerProcess", "observedLiveness", "custody"])
    guard abandonment.value(forKey: "adjudicatedAt") == root.value(forKey: "completedAt"),
          abandonment.value(forKey: "ownerProcess") == authorityObject.value(forKey: "ownerProcess"),
          ["owner-process-absent", "owner-identity-replaced"].contains(try sessionRetentionString(abandonment, "observedLiveness")) else {
        throw NotikaSessionRetentionError.invalidManifest
    }
    // Adjudication recorded both identities when the session completed.
    let adjudicatedAt = try sessionRetentionDate(root, "completedAt")
    let boot = try DirectoryIdentityBoot.current()
    let binding = try abandonment.requiredValue(forKey: "authority").requireObject().project(requiredKeys: ["path", "deviceID", "inode", "sha256"])
    guard try sessionRetentionString(binding, "path").utf8.elementsEqual((repository + "/Artifacts/AgentSessions/" + name + "/development-session.json").utf8),
          try boot.admits(
              storedDeviceID: sessionRetentionUInt(binding, "deviceID"), storedInode: sessionRetentionUInt(binding, "inode"),
              recordedAt: adjudicatedAt, observedDeviceID: UInt64(authority.fingerprint.identity.device),
              observedInode: UInt64(authority.fingerprint.identity.inode)
          ),
          binding.value(forKey: "sha256") == .string(authority.digest) else { throw NotikaSessionRetentionError.invalidManifest }
    let originalDirectory = try abandonment.requiredValue(forKey: "directory").requireObject().project(requiredKeys: ["deviceID", "inode"])
    guard try boot.admits(
              storedDeviceID: sessionRetentionUInt(originalDirectory, "deviceID"),
              storedInode: sessionRetentionUInt(originalDirectory, "inode"), recordedAt: adjudicatedAt,
              observedDeviceID: UInt64(directory.st_dev), observedInode: UInt64(directory.st_ino)
          ) else { throw NotikaSessionRetentionError.invalidManifest }
    let custody = try abandonment.requiredValue(forKey: "custody").requireObject().project(requiredKeys: ["process", "lease", "cache", "artifacts"])
    guard custody.value(forKey: "process") == .string("not-signaled"), custody.value(forKey: "lease") == .string("not-adopted-or-released"),
          custody.value(forKey: "cache") == .string("not-deleted-or-unlocked"), custody.value(forKey: "artifacts") == .string("retained-in-place") else {
        throw NotikaSessionRetentionError.invalidManifest
    }
    return owner
}

private func sessionRetentionHex(_ value: String, count: Int) -> Bool {
    value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}

private func sessionRetentionAbsolutePath(_ value: String) -> Bool {
    value.hasPrefix("/") && value.utf8.count <= 4_096 && !value.utf8.contains(0)
        && value.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
}

/// Recognizes only the ordinary current Python terminal schema. Other Python
/// artifact families deliberately remain protected until their adapters exist.
private func sessionRetentionValidateLegacy(_ root: StrictJSONObject, repository: String, name: String) throws {
    _ = try root.project(requiredKeys: [
        "schemaVersion", "sessionID", "createdAt", "completedAt", "expiresAt", "status", "failureDiagnosis", "request",
        "repository", "sourceBefore", "sourceBeforeHash", "sourceAfter", "sourceAfterHash", "sourceChangedDuringExecution",
        "privateSourceDriftObserved", "sourceObservationError", "evidenceValidated", "generatedGraphLock", "toolchain",
        "toolchainHash", "cache", "environmentBindings", "environmentPolicy", "artifacts", "outerExecution",
        "leasedExecution", "replayOf", "replayCommand",
    ])
    guard try sessionRetentionUInt(root, "schemaVersion") == 1,
          try sessionRetentionString(root, "sessionID").utf8.elementsEqual(name.utf8),
          try sessionRetentionString(root, "repository").utf8.elementsEqual(repository.utf8),
          ["failed", "inconclusive", "succeeded"].contains(try sessionRetentionString(root, "status")) else {
        throw NotikaSessionRetentionError.invalidManifest
    }
    let request = try root.requiredValue(forKey: "request")
    _ = try JSONDecoder().decode(NotikaActionRequest.self, from: CanonicalJSONDigest.encode(sessionRetentionCanonical(request)))
    let source = try root.requiredValue(forKey: "sourceBefore").requireObject()
    guard try sessionRetentionString(source, "canonicalWorktree").utf8.elementsEqual(repository.utf8),
          try sessionRetentionString(root, "sourceBeforeHash") == CanonicalJSONDigest.sha256(sessionRetentionCanonical(.object(source))),
          try sessionRetentionString(root, "toolchainHash") == CanonicalJSONDigest.sha256(sessionRetentionCanonical(root.requiredValue(forKey: "toolchain"))) else {
        throw NotikaSessionRetentionError.invalidManifest
    }
    let after = try root.requiredValue(forKey: "sourceAfter")
    if after == .null {
        guard root.value(forKey: "sourceAfterHash") == .null else { throw NotikaSessionRetentionError.invalidManifest }
    } else {
        guard try sessionRetentionString(after.requireObject(), "canonicalWorktree").utf8.elementsEqual(repository.utf8),
              try sessionRetentionString(root, "sourceAfterHash") == CanonicalJSONDigest.sha256(sessionRetentionCanonical(after)) else {
            throw NotikaSessionRetentionError.invalidManifest
        }
    }
    for key in ["sourceChangedDuringExecution", "privateSourceDriftObserved", "evidenceValidated"] {
        guard case .bool = try root.requiredValue(forKey: key) else { throw NotikaSessionRetentionError.invalidManifest }
    }
    for key in ["sourceObservationError", "replayOf"] {
        let value = try root.requiredValue(forKey: key)
        guard value == .null || { if case .string = value { return true }; return false }() else {
            throw NotikaSessionRetentionError.invalidManifest
        }
    }
    for key in ["failureDiagnosis", "leasedExecution"] {
        let value = try root.requiredValue(forKey: key)
        guard value == .null || { if case .object = value { return true }; return false }() else {
            throw NotikaSessionRetentionError.invalidManifest
        }
    }
    _ = try root.requiredValue(forKey: "generatedGraphLock").requireObject()
    _ = try root.requiredValue(forKey: "outerExecution").requireObject()
    let cache = try root.requiredValue(forKey: "cache").requireObject().project(requiredKeys: ["key", "path", "lock"])
    let key = try sessionRetentionString(cache, "key")
    guard key.utf8.count == 24, key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
          try sessionRetentionString(cache, "path").utf8.elementsEqual((repository + "/DerivedData/AgentCaches/" + key).utf8) else {
        throw NotikaSessionRetentionError.invalidManifest
    }
    _ = try sessionRetentionString(cache, "lock")
    let bindings = try root.requiredValue(forKey: "environmentBindings").requireObject().project(requiredKeys: ["derivedData", "sessionDirectory"])
    let sessionPath = repository + "/Artifacts/AgentSessions/" + name
    guard try sessionRetentionString(bindings, "sessionDirectory").utf8.elementsEqual(sessionPath.utf8),
          bindings.value(forKey: "derivedData") == cache.value(forKey: "path") else {
        throw NotikaSessionRetentionError.invalidManifest
    }
    let policy = try root.requiredValue(forKey: "environmentPolicy").requireObject().project(requiredKeys: ["inheritedAllowlist", "makeOverridesArePinned"])
    guard policy.value(forKey: "makeOverridesArePinned") == .bool(true),
          case .array(let allowlist) = try policy.requiredValue(forKey: "inheritedAllowlist"),
          allowlist.allSatisfy({ if case .string = $0 { return true }; return false }) else {
        throw NotikaSessionRetentionError.invalidManifest
    }
    let artifacts = try root.requiredValue(forKey: "artifacts").requireObject().project(requiredKeys: [
        "root", "workflowLog", "workflowLogEvidence", "rawXcodeLog", "processEvidence", "reports", "resultCustody",
        "resultBundle", "resultBundlePresent", "resultBundleValidated",
    ])
    guard try sessionRetentionString(artifacts, "root").utf8.elementsEqual(sessionPath.utf8),
          try sessionRetentionString(artifacts, "workflowLog").utf8.elementsEqual((sessionPath + "/workflow.log").utf8),
          try sessionRetentionString(artifacts, "resultBundle").hasPrefix(sessionPath + "/"),
          case .bool = try artifacts.requiredValue(forKey: "resultBundlePresent") else {
        throw NotikaSessionRetentionError.invalidManifest
    }
    let validated = try artifacts.requiredValue(forKey: "resultBundleValidated")
    guard validated == .null || { if case .bool = validated { return true }; return false }() else {
        throw NotikaSessionRetentionError.invalidManifest
    }
    for key in ["workflowLogEvidence", "rawXcodeLog", "processEvidence", "reports", "resultCustody"] {
        let value = try artifacts.requiredValue(forKey: key)
        guard value == .null || { if case .object = value { return true }; return false }() else {
            throw NotikaSessionRetentionError.invalidManifest
        }
    }
    guard case .array(let replay) = try root.requiredValue(forKey: "replayCommand"), replay.count == 3,
          replay[1] == .string("replay"), replay[2] == .string(sessionPath + "/manifest.json"),
          { if case .string(let executable) = replay[0] { return executable.hasPrefix("/") }; return false }() else {
        throw NotikaSessionRetentionError.invalidManifest
    }
}

private func sessionRetentionValidateKeep(
    _ root: StrictJSONObject, repository: String, name: String, manifestDigest: String,
    originalExpiresAt: Date, evaluatedAt: Date
) throws -> Date {
    _ = try root.project(requiredKeys: ["durablePromotion", "expiresAt", "issuedAt", "manifestDigest", "originalExpiresAt",
        "owner", "reason", "repository", "resourceID", "retentionClass", "schemaVersion", "sessionID"])
    guard try sessionRetentionUInt(root, "schemaVersion") == 1,
          root.value(forKey: "resourceID") == .string("notika.agent-session-keep"),
          root.value(forKey: "durablePromotion") == .bool(false),
          root.value(forKey: "retentionClass") == .string("extended-ephemeral"),
          try sessionRetentionString(root, "repository").utf8.elementsEqual(repository.utf8),
          try sessionRetentionString(root, "sessionID").utf8.elementsEqual(name.utf8),
          root.value(forKey: "manifestDigest") == .string("sha256:" + manifestDigest),
          try sessionRetentionDate(root, "originalExpiresAt") == originalExpiresAt else {
        throw NotikaSessionRetentionError.invalidKeep
    }
    let owner = try root.requiredValue(forKey: "owner").requireObject().project(requiredKeys: ["account", "kind", "uid"])
    guard owner.value(forKey: "kind") == .string("local-user"),
          try sessionRetentionUInt(owner, "uid") == UInt64(geteuid()),
          try sessionRetentionString(owner, "account").utf8.elementsEqual(sessionRetentionAccount().utf8) else {
        throw NotikaSessionRetentionError.invalidKeep
    }
    let reason = try sessionRetentionString(root, "reason")
    guard !reason.isEmpty, reason.utf8.count <= 512, reason == reason.trimmingCharacters(in: .whitespacesAndNewlines),
          reason.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else {
        throw NotikaSessionRetentionError.invalidKeep
    }
    let issued = try sessionRetentionDate(root, "issuedAt"), expires = try sessionRetentionDate(root, "expiresAt")
    guard issued <= evaluatedAt, issued < expires, expires > originalExpiresAt,
          expires.timeIntervalSince(originalExpiresAt) <= 30 * 24 * 60 * 60 else {
        throw NotikaSessionRetentionError.invalidKeep
    }
    return expires
}

private func sessionRetentionAccount() throws -> String {
    var entry = passwd(), result: UnsafeMutablePointer<passwd>?
    var buffer = [CChar](repeating: 0, count: 16 * 1_024)
    return try buffer.withUnsafeMutableBufferPointer { storage in
        let code = getpwuid_r(geteuid(), &entry, storage.baseAddress!, storage.count, &result)
        guard code == 0, result != nil, let name = entry.pw_name else { throw NotikaSessionRetentionError.invalidKeep }
        let account = String(cString: name)
        guard !account.isEmpty, account.utf8.count <= 128 else { throw NotikaSessionRetentionError.invalidKeep }
        return account
    }
}

private func sessionRetentionCanonical(_ value: StrictJSONValue) throws -> CanonicalJSONValue {
    switch value {
    case .array(let values): return .array(try values.map(sessionRetentionCanonical))
    case .bool(let value): return .bool(value)
    case .null: return .null
    case .number(let number):
        if let value = try? number.int64() { return .integer(value) }
        return .unsignedInteger(try number.uint64())
    case .object(let object): return .object(try object.members.map { CanonicalJSONMember(key: $0.key, value: try sessionRetentionCanonical($0.value)) })
    case .string(let value): return .string(value)
    }
}

private func sessionRetentionString(_ object: StrictJSONObject, _ key: String) throws -> String {
    guard case .string(let value) = try object.requiredValue(forKey: key), !value.utf8.contains(0) else {
        throw NotikaSessionRetentionError.invalidManifest
    }
    return value
}
private func sessionRetentionUInt(_ object: StrictJSONObject, _ key: String) throws -> UInt64 {
    guard case .number(let value) = try object.requiredValue(forKey: key) else { throw NotikaSessionRetentionError.invalidManifest }
    return try value.uint64()
}
private func sessionRetentionDate(_ object: StrictJSONObject, _ key: String) throws -> Date {
    let text = try sessionRetentionString(object, key)
    guard text.utf8.count <= 64,
          text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?(Z|[+-][0-9]{2}:[0-9]{2})$"#, options: .regularExpression) != nil else {
        throw NotikaSessionRetentionError.invalidManifest
    }
    // Parse the producer's full microsecond precision. ISO8601DateFormatter
    // truncates some fractional inputs to milliseconds and can normalize invalid
    // dates; neither behavior may authorize earlier retirement.
    let bytes = Array(text.utf8)
    func integer(_ range: Range<Int>) throws -> Int {
        guard let value = Int(String(decoding: bytes[range], as: UTF8.self)) else {
            throw NotikaSessionRetentionError.invalidManifest
        }
        return value
    }
    let year = try integer(0..<4), month = try integer(5..<7), day = try integer(8..<10)
    let hour = try integer(11..<13), minute = try integer(14..<16), second = try integer(17..<19)
    guard year > 0, (1...12).contains(month), (1...31).contains(day),
          (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else {
        throw NotikaSessionRetentionError.invalidManifest
    }
    var index = 19, microseconds = 0
    if bytes[index] == 46 {
        index += 1
        let start = index
        while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
        let digits = String(decoding: bytes[start..<index], as: UTF8.self)
        guard let value = Int(digits + String(repeating: "0", count: 6 - digits.utf8.count)) else {
            throw NotikaSessionRetentionError.invalidManifest
        }
        microseconds = value
    }
    let offset: Int
    if bytes[index] == 90 { offset = 0 }
    else {
        let hours = try integer((index + 1)..<(index + 3)), minutes = try integer((index + 4)..<(index + 6))
        guard hours <= 23, minutes <= 59 else { throw NotikaSessionRetentionError.invalidManifest }
        offset = (hours * 3_600 + minutes * 60) * (bytes[index] == 45 ? -1 : 1)
    }
    guard let zone = TimeZone(secondsFromGMT: offset) else { throw NotikaSessionRetentionError.invalidManifest }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let components = DateComponents(timeZone: zone, year: year, month: month, day: day,
                                    hour: hour, minute: minute, second: second)
    guard let base = calendar.date(from: components) else { throw NotikaSessionRetentionError.invalidManifest }
    let checked = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: base)
    guard checked.year == year, checked.month == month, checked.day == day,
          checked.hour == hour, checked.minute == minute, checked.second == second else {
        throw NotikaSessionRetentionError.invalidManifest
    }
    let date = base.addingTimeInterval(Double(microseconds) / 1_000_000)
    guard date.timeIntervalSinceReferenceDate.isFinite else {
        throw NotikaSessionRetentionError.invalidManifest
    }
    return date
}
private func sessionRetentionSafeName(_ name: String) -> Bool {
    let bytes = Array(name.utf8)
    guard (1...128).contains(bytes.count), let first = bytes.first,
          (48...57).contains(first) || (65...90).contains(first) || (97...122).contains(first) else { return false }
    return bytes.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }
}
private func sessionRetentionLeaseBinding(_ lease: FileLock) throws -> InheritedLeaseDescriptor {
    guard lease.mode == .exclusive, let descriptor = lease.inheritedDescriptor else { throw NotikaSessionRetentionError.evidenceChanged }
    return InheritedLeaseDescriptor(resource: lease.resource.value, mode: .exclusive, descriptor: descriptor, path: lease.persistentPath)
}
private func sessionRetentionValidateLease(_ lease: FileLock, registryRoot: String) throws {
    try sessionRetentionValidateBinding(sessionRetentionLeaseBinding(lease), registryRoot: registryRoot)
}
private func sessionRetentionValidateBinding(_ binding: InheritedLeaseDescriptor, registryRoot: String) throws {
    try InheritedExclusiveLeaseGuard.establish(resource: binding.resource, environment: [
        AgentLeasePaths.homeEnvironmentKey: registryRoot, ChildEnvironment.heldResourcesKey: binding.resource,
        InheritedLeaseManifest.environmentKey: try InheritedLeaseManifest(leases: [binding]).environmentValue(),
    ])
}
private func sessionRetentionOpen(_ directory: RetainedArtifactDirectory) throws -> SessionRetentionDescriptor {
    let opened = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard opened >= 0 else { throw sessionRetentionIO("open retained session directory") }
    let owned = SessionRetentionDescriptor(opened)
    guard try SessionRetentionIdentity(sessionRetentionStatus(opened)) == SessionRetentionIdentity(directory.fingerprint) else {
        throw NotikaSessionRetentionError.evidenceChanged
    }
    try directory.revalidate()
    return owned
}
private func sessionRetentionStatus(_ descriptor: Int32) throws -> stat {
    var value = stat()
    guard fstat(descriptor, &value) == 0 else { throw sessionRetentionIO("fstat retained session") }
    return value
}
private func sessionRetentionStatus(at name: String, parent: Int32) throws -> stat {
    guard let value = try sessionRetentionStatusIfPresent(at: name, parent: parent) else {
        throw NotikaSessionRetentionError.systemCall("fstatat session evidence", ENOENT)
    }
    return value
}
private func sessionRetentionStatusIfPresent(at name: String, parent: Int32) throws -> stat? {
    var value = stat()
    if fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 { return value }
    if errno == ENOENT { return nil }
    throw sessionRetentionIO("fstatat session evidence")
}
private func sessionRetentionRead(_ descriptor: Int32, count: Int) throws -> Data {
    var bytes = Data(count: count + 1)
    let observed = try bytes.withUnsafeMutableBytes { buffer -> Int in
        var offset = 0
        while offset < buffer.count {
            let read = pread(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, off_t(offset))
            if read < 0, errno == EINTR { continue }
            guard read >= 0 else { throw sessionRetentionIO("pread session evidence") }
            if read == 0 { break }
            offset += read
        }
        return offset
    }
    guard observed == count else { throw NotikaSessionRetentionError.evidenceChanged }
    bytes.count = observed
    return bytes
}
private func sessionRetentionNames(_ parent: Int32, maximum: Int) throws -> [String] {
    let scan = openat(parent, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard scan >= 0 else { throw sessionRetentionIO("open session scan") }
    guard let stream = fdopendir(scan) else {
        let error = sessionRetentionIO("fdopendir session scan"); _ = Darwin.close(scan); throw error
    }
    defer { _ = closedir(stream) }
    var names: [String] = []
    while true {
        errno = 0
        guard let next = readdir(stream) else {
            guard errno == 0 else { throw sessionRetentionIO("readdir session scan") }
            return names
        }
        var raw = next.pointee.d_name
        let name = withUnsafeBytes(of: &raw) { bytes -> String? in
            guard let end = bytes.firstIndex(of: 0) else { return nil }
            return String(bytes: bytes.prefix(end), encoding: .utf8)
        }
        guard let name else { throw NotikaSessionRetentionError.unsafeEntry }
        if name == "." || name == ".." { continue }
        names.append(name)
        guard names.count <= maximum else { throw NotikaSessionRetentionError.entryBoundExceeded }
    }
}
private func sessionRetentionIO(_ operation: String) -> NotikaSessionRetentionError { .systemCall(operation, errno) }
