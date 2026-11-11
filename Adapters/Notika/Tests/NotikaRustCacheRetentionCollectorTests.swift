@testable import AgentBuildCore
import AgentBuildTestSupport
import AgentLeaseCore
import Darwin
import Foundation
@testable import NotikaAdapter
import Synchronization
import Testing

@Suite("Today-only Rust family-cache collection")
struct NotikaRustCacheRetentionCollectorTests {
    @Test func absentRootDoesNotCreateRustCacheDirectories() async throws {
        let fixture = try RustRetentionFixture()
        defer { fixture.base.remove() }
        let report = try await fixture.collector().run(execute: true)
        #expect(report.rootState == .absent)
        #expect(report.scanComplete)
        #expect(report.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.path))
    }

    @Test(arguments: NotikaRustTestFamily.allCases)
    func yesterdayFamilyUsesProducerSchemaAndExactResources(_ family: NotikaRustTestFamily) async throws {
        let fixture = try RustRetentionFixture()
        defer { fixture.base.remove() }
        let old = try fixture.seed(family: family, usedAt: fixture.cutoff.addingTimeInterval(-1))
        #expect(try NotikaRustCacheRetentionCollector.policyResource(canonicalRepository: fixture.path) == old.identity.policyResource)
        #expect(try NotikaRustCacheRetentionCollector.cacheResource(canonicalRepository: fixture.path, cacheKey: old.key) == old.identity.cacheResource())
        let before = try Data(contentsOf: old.usage)
        let mover = try fixture.mover()
        let report = try await fixture.collector(trash: mover).run(execute: true)
        let entry = try #require(report.entries.first)
        #expect(report.policy == .todayOnlyRustCaches)
        #expect(report.rootState == .ready)
        #expect(report.scanComplete)
        #expect(entry.action == .trashed)
        #expect(entry.evidence?.schemaVersion == 1)
        #expect(entry.evidence?.inode == old.observation.inode)
        #expect(entry.evidence?.metadataDigest == CanonicalJSONDigest.digest(before))
        #expect(entry.allocatedBytes != nil)
        #expect(report.movedToTrashAllocatedBytes == entry.allocatedBytes)
        #expect(!FileManager.default.fileExists(atPath: old.directory.path))
        #expect(try Data(contentsOf: mover.destination.appendingPathComponent(old.key).appendingPathComponent(rustRetentionUsageName)) == before)
        let source = try #require(mover.sources.withLock { $0.first })
        #expect(source.originalPath == old.directory.path)
        #expect(source.path.contains("/DerivedData/RustTestCacheTrashClaims/"))
        #expect(throws: ArtifactTrashError.retiredSource) { try source.revalidateBeforeMove() }
        #expect(throws: ArtifactTrashError.retiredSource) { try source.inheritedDescriptors() }
    }

    @Test func previewPreservesBytesAndSkipsTodayFutureAndUnknownPayloadWalks() async throws {
        let fixture = try RustRetentionFixture()
        defer { fixture.base.remove() }
        let old = try fixture.seed(usedAt: fixture.cutoff.addingTimeInterval(-0.000_001), token: "a")
        let today = try fixture.seed(usedAt: fixture.cutoff, token: "b")
        let future = try fixture.seed(usedAt: fixture.now.addingTimeInterval(1), token: "c")
        let unknown = try fixture.seed(usedAt: fixture.cutoff.addingTimeInterval(-1), token: "d")
        try rustRetentionTamper(unknown.usage) { $0["schemaVersion"] = 2 }
        for directory in [today.directory, future.directory, unknown.directory] { try rustRetentionDeepPayload(directory) }
        let bytes = try Data(contentsOf: old.usage)
        let report = try await fixture.collector().run(execute: false)
        let entries = Dictionary(uniqueKeysWithValues: report.entries.map { ($0.name, $0) })
        #expect(entries[old.key]?.action == .wouldTrash)
        #expect(entries[old.key]?.allocatedBytes != nil)
        #expect(entries[old.key]?.evidence?.lastUsedAtMicrosecondsSince1970 == Int64(try fixture.cutoff.timeIntervalSince1970) * 1_000_000 - 1)
        #expect(entries[today.key]?.reason == .currentLocalDay)
        #expect(entries[today.key]?.allocatedBytes == nil)
        #expect(entries[future.key]?.reason == .lastUseInFuture)
        #expect(entries[future.key]?.allocatedBytes == nil)
        #expect(entries[unknown.key]?.classification == .unmanaged)
        #expect(entries[unknown.key]?.allocatedBytes == nil)
        #expect(report.movedToTrashAllocatedBytes == 0)
        #expect(try Data(contentsOf: old.usage) == bytes)
        #expect(!FileManager.default.fileExists(atPath: fixture.claims.path))
    }

    @Test func localDayUsesInjectedZoneAcrossDSTInsteadOfAnAgeWindow() async throws {
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        let fixture = try RustRetentionFixture(now: Date(timeIntervalSince1970: 1_762_097_400), timeZone: zone)
        defer { fixture.base.remove() }
        let old = try fixture.seed(usedAt: fixture.cutoff.addingTimeInterval(-1), token: "a")
        let midnight = try fixture.seed(usedAt: fixture.cutoff, token: "b")
        let report = try await fixture.collector().run(execute: false)
        #expect(report.timeZoneIdentifier == zone.identifier)
        #expect(report.localDayCutoff == (try fixture.cutoff))
        #expect(report.entries.first { $0.name == old.key }?.action == .wouldTrash)
        #expect(report.entries.first { $0.name == midnight.key }?.reason == .currentLocalDay)
    }

    @Test func actualRustExecutorHoldsSharedPolicyAcrossBothNativeCommandBoundaries() async throws {
        let fixture = try RustRetentionFixture()
        defer { fixture.base.remove() }
        let identity = try fixture.identity(family: .liteparse)
        let bindings = try NotikaRustTestExecutionBindings(sessionID: "rust-retention-producer", temporaryDirectory: fixture.path + "/Artifacts/AgentSessions/rust-retention-producer/tmp")
        try FileManager.default.createDirectory(atPath: bindings.temporaryDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let digest = String(repeating: "a", count: 64)
        let projectIdentity = try CacheCompatibilityIdentity(canonicalWorktree: fixture.path, toolchainHash: digest, gitlinks: [],
            submoduleStatusDigest: digest, submoduleWorktreeDigest: digest, projectGraphDigest: digest,
            generatedGraphDigest: digest, resolvedDependenciesDigest: digest,
            scheme: "Notika", configuration: "Debug", destinationFamily: "macos-arm64", buildFlags: ["-disableAutomaticPackageResolution"])
        let plan = try NotikaProjectOwnershipPlan(identity: projectIdentity)
        let calls = Mutex(0)
        try await NotikaProjectAdmission().withOwnership(plan, registryRoot: fixture.registry, label: "Rust retention producer fixture") { ownership in
            let context = try NotikaPreflightRustContext(repository: fixture.path, environment: fixture.base.environment,
                ownership: ownership, retainedLockDescriptors: ownership.inheritedDescriptors())
            let result = try await NotikaRustTestExecutor().run(family: .liteparse, context: context, bindings: bindings,
                identityOperation: { identity }, sourceOperation: { String(repeating: "c", count: 64) }, commandOperation: { _, descriptors in
                    #expect(descriptors.allSatisfy { fcntl($0, F_GETFD) >= 0 })
                    let report = try await fixture.collector().run(execute: true)
                    #expect(report.rootState == .busy)
                    #expect(report.rootReason == .policyBusy)
                    #expect(report.entries.isEmpty)
                    #expect(!FileManager.default.fileExists(atPath: fixture.claims.path))
                    calls.withLock { $0 += 1 }
                    return NotikaPreflightCommandOutcome(nativeTermination: .init(kind: .exit, value: 0), retirementProven: true)
                }, usedAt: fixture.cutoff.addingTimeInterval(-1))
            #expect(result.outcome.succeeded)
            #expect(result.usage != nil)
        }
        #expect(calls.withLock { $0 } == 2)
        let after = try await fixture.collector().run(execute: false)
        #expect(after.rootState == .ready)
        #expect(after.entries.first?.action == .wouldTrash)
    }

    @Test func legacyExclusiveFamilyLeaseProtectsBusyCacheWhileOtherKeyIsEligible() async throws {
        let fixture = try RustRetentionFixture()
        defer { fixture.base.remove() }
        let busy = try fixture.seed(usedAt: fixture.cutoff.addingTimeInterval(-1), token: "a")
        let old = try fixture.seed(usedAt: fixture.cutoff.addingTimeInterval(-1), token: "b")
        let lock = try FileLock(resource: ResourceName(busy.identity.cacheResource()), paths: AgentLeasePaths.open(selectedRoot: fixture.registry))
        try #require(try lock.tryAcquire())
        defer { lock.release() }
        let report = try await fixture.collector().run(execute: false)
        #expect(report.entries.first { $0.name == busy.key }?.action == .skippedBusy)
        #expect(report.entries.first { $0.name == busy.key }?.allocatedBytes == nil)
        #expect(report.entries.first { $0.name == old.key }?.action == .wouldTrash)
    }

    @Test(arguments: RustRetentionTamper.allCases)
    fileprivate func malformedAndUnknownEvidenceIsProtectedWithoutBlockingKnownSibling(_ tamper: RustRetentionTamper) async throws {
        let fixture = try RustRetentionFixture()
        defer { fixture.base.remove() }
        let unknown = try fixture.seed(usedAt: fixture.cutoff.addingTimeInterval(-1), token: "a")
        let old = try fixture.seed(usedAt: fixture.cutoff.addingTimeInterval(-1), token: "b")
        try tamper.apply(to: unknown)
        let before = try Data(contentsOf: unknown.usage)
        let mover = try fixture.mover()
        let report = try await fixture.collector(trash: mover).run(execute: true)
        let entry = try #require(report.entries.first { $0.name == unknown.key })
        #expect(entry.action == NotikaCacheRetentionAction.none)
        #expect(entry.classification == (tamper == .schemaTwo || tamper == .schemaThree ? .unmanaged : .invalid))
        #expect(entry.allocatedBytes == nil)
        #expect(entry.evidence == nil)
        #expect(try Data(contentsOf: unknown.usage) == before)
        #expect(report.entries.first { $0.name == old.key }?.action == .trashed)
        #expect(mover.sources.withLock { $0.count } == 1)
    }

    @Test(arguments: ["hardlink", "symlink", "permissions", "fifo", "absent"])
    func unsafeUsageFilesAndMissingEvidenceAreNeverMoved(_ kind: String) async throws {
        let fixture = try RustRetentionFixture()
        defer { fixture.base.remove() }
        let old = try fixture.seed(usedAt: fixture.cutoff.addingTimeInterval(-1))
        switch kind {
        case "hardlink": try #require(link(old.usage.path, old.directory.appendingPathComponent("second-usage-link").path) == 0)
        case "permissions": try #require(chmod(old.usage.path, 0o644) == 0)
        default:
            let original = fixture.base.directory.appendingPathComponent("saved-usage")
            try FileManager.default.moveItem(at: old.usage, to: original)
            if kind == "symlink" { try #require(symlink(original.path, old.usage.path) == 0) }
            if kind == "fifo" { try #require(mkfifo(old.usage.path, 0o600) == 0) }
        }
        let mover = try fixture.mover()
        let report = try await fixture.collector(trash: mover).run(execute: true)
        #expect(report.entries.first?.action == NotikaCacheRetentionAction.none)
        #expect(report.entries.first?.classification == (kind == "absent" ? .unmanaged : .invalid))
        #expect(mover.sources.withLock { $0.isEmpty })
        #expect(FileManager.default.fileExists(atPath: old.directory.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.claims.path))
    }

    @Test(arguments: ["metadata", "cache", "root"])
    func evidenceChangeBeforeClaimProtectsExactNamespace(_ change: String) async throws {
        let fixture = try RustRetentionFixture()
        defer { fixture.base.remove() }
        let old = try fixture.seed(usedAt: fixture.cutoff.addingTimeInterval(-1))
        let retired = fixture.base.directory.appendingPathComponent("retired-cache-evidence")
        let mover = try fixture.mover()
        let collector = try fixture.collector(trash: mover, hook: { _ in
            if change == "metadata" {
                let refreshed = try NotikaRustCacheUsageRecord.make(identity: old.identity, observation: old.observation,
                    sessionID: "refreshed", usedAt: fixture.now)
                try refreshed.document.originalData.write(to: old.usage)
            } else if change == "cache" {
                try FileManager.default.moveItem(at: old.directory, to: retired)
                try #require(symlink(retired.path, old.directory.path) == 0)
            } else {
                try FileManager.default.moveItem(at: fixture.root, to: retired)
                try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
        })
        let report = try await collector.run(execute: true)
        #expect(report.entries.first?.action == .skippedRevalidation)
        #expect(report.entries.first?.reason == .evidenceChanged)
        if change == "root" { #expect(report.rootReason == .rootChanged); #expect(!report.scanComplete) }
        #expect(mover.sources.withLock { $0.isEmpty })
        #expect(!FileManager.default.fileExists(atPath: fixture.claims.path))
    }

    @Test(arguments: [false, true])
    func failedTrashRestoresExactSourceAndNeverOverwritesNewCache(_ replaceOriginal: Bool) async throws {
        let fixture = try RustRetentionFixture()
        defer { fixture.base.remove() }
        let old = try fixture.seed(usedAt: fixture.cutoff.addingTimeInterval(-1))
        let before = try Data(contentsOf: old.usage)
        let report = try await fixture.collector(trash: RustRetentionFailingTrash(replaceOriginal: replaceOriginal)).run(execute: true)
        #expect(report.entries.first?.action == .trashFailed)
        let current = try rustRetentionTestStatus(old.directory.path)
        if replaceOriginal {
            #expect(current.st_ino != old.observation.inode)
            #expect(try String(contentsOf: old.directory.appendingPathComponent("replacement"), encoding: .utf8) == "must stay")
            let next = try await fixture.collector().run(execute: false)
            #expect(next.rootReason == .pendingTrashClaims)
        } else {
            #expect(current.st_ino == old.observation.inode)
            #expect(try Data(contentsOf: old.usage) == before)
            let next = try await fixture.collector().run(execute: false)
            #expect(next.entries.first?.action == .wouldTrash)
        }
    }

    @Test(arguments: [1, 2])
    func claimConstructionFailureLeavesNoBlockingEmptyPlaceholder(_ failingCall: Int) async throws {
        let fixture = try RustRetentionFixture()
        defer { fixture.base.remove() }
        let old = try fixture.seed(usedAt: fixture.cutoff.addingTimeInterval(-1))
        let before = try Data(contentsOf: old.usage)
        let calls = Mutex(0)
        let collector = try fixture.collector(factory: { path in
            let call = calls.withLock { $0 += 1; return $0 }
            if call == failingCall { throw RetainedArtifactError.systemCall("open private claim", EMFILE) }
            return try RetainedArtifactDirectory(path: path, requiredPermissions: 0o700)
        })
        let report = try await collector.run(execute: true)
        #expect(report.entries.first?.action == .trashFailed)
        #expect(try rustRetentionTestStatus(old.directory.path).st_ino == old.observation.inode)
        #expect(try Data(contentsOf: old.usage) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.claims.path).isEmpty)
        let next = try await fixture.collector().run(execute: false)
        #expect(next.entries.first?.action == .wouldTrash)
    }

    @Test func fixedRootSymlinkAndUnrelatedNamespaceAreProtected() async throws {
        let fixture = try RustRetentionFixture()
        defer { fixture.base.remove() }
        let old = try fixture.seed(usedAt: fixture.cutoff.addingTimeInterval(-1))
        let outside = fixture.base.directory.appendingPathComponent("outside-rust")
        try FileManager.default.moveItem(at: fixture.root, to: outside)
        try #require(symlink(outside.path, fixture.root.path) == 0)
        let report = try await fixture.collector().run(execute: true)
        #expect(report.rootState == .unsafe)
        #expect(report.rootReason == .rootUnsafe)
        #expect(report.entries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent(old.key).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.claims.path))
    }

    @Test func eligibleDepthBoundProtectsTheCacheWithoutCreatingTrashClaims() async throws {
        let fixture = try RustRetentionFixture()
        defer { fixture.base.remove() }
        let old = try fixture.seed(usedAt: fixture.cutoff.addingTimeInterval(-1))
        try rustRetentionDeepPayload(old.directory)
        let original = try Data(contentsOf: old.usage)
        let mover = try fixture.mover()
        let report = try await fixture.collector(trash: mover).run(execute: true)
        #expect(report.rootState == .ready)
        #expect(report.entries.first { $0.name == old.key }?.reason == .sizeUnavailable)
        #expect(report.entries.first { $0.name == old.key }?.allocatedBytes == nil)
        #expect(try Data(contentsOf: old.usage) == original)
        #expect(try rustRetentionTestStatus(old.directory.path).st_ino == old.observation.inode)
        #expect(mover.sources.withLock { $0.isEmpty })
        #expect(!FileManager.default.fileExists(atPath: fixture.claims.path))
    }

    @Test func unknownEntryAndFinderMetadataRemainAndOnlyEligiblePayloadIsSized() async throws {
        let fixture = try RustRetentionFixture()
        defer { fixture.base.remove() }
        let old = try fixture.seed(usedAt: fixture.cutoff.addingTimeInterval(-1))
        let outside = fixture.base.directory.appendingPathComponent("outside-payload")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try rustRetentionDeepPayload(outside)
        try #require(symlink(outside.path, old.directory.appendingPathComponent("payload-symlink").path) == 0)
        try #require(link(old.directory.appendingPathComponent("payload").path, old.directory.appendingPathComponent("payload-hardlink").path) == 0)
        let finder = fixture.root.appendingPathComponent(".DS_Store")
        try Data("Finder".utf8).write(to: finder)
        try #require(chmod(finder.path, 0o600) == 0)
        let unknown = fixture.root.appendingPathComponent("unknown-folder")
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: false)
        let report = try await fixture.collector().run(execute: false)
        #expect(report.entries.first { $0.name == old.key }?.action == .wouldTrash)
        #expect(report.entries.first { $0.name == ".DS_Store" }?.reason == .finderMetadata)
        #expect(report.entries.first { $0.name == "unknown-folder" }?.reason == .nameUnsafe)
        #expect(report.entries.first { $0.name == "unknown-folder" }?.allocatedBytes == nil)
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.claims.path))
    }
}

private let rustRetentionUsageName = ".notika-cache-usage.json"

private struct RustRetentionFixture: Sendable {
    let base: CompilationFixture
    let now: Date
    let timeZone: TimeZone
    var path: String { base.directory.path }
    var registry: String { path + "/project-registry" }
    var cutoff: Date { get throws { try LocalCalendarRetention(evaluatedAt: now, timeZone: timeZone).localDayStart } }
    var root: URL { base.directory.appendingPathComponent("DerivedData/RustTestCaches") }
    var claims: URL { base.directory.appendingPathComponent("DerivedData/RustTestCacheTrashClaims") }

    init(now: Date = Date(timeIntervalSince1970: 1_788_256_800), timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!) throws {
        base = try CompilationFixture(); self.now = now; self.timeZone = timeZone
    }

    func identity(family: NotikaRustTestFamily = .liteparse, token: String = "a") throws -> NotikaRustCacheIdentity {
        try NotikaRustCacheIdentity(repository: path, family: family,
            inputs: Dictionary(uniqueKeysWithValues: NotikaRustCacheIdentity.inputPaths(family).map { ($0, String(repeating: token, count: 64)) }),
            misePath: "/fixture/tools/mise", miseDigest: String(repeating: "b", count: 64),
            rustc: "rustc 1.88.0 (fixture)", sysroot: "/fixture/toolchain", cargo: "cargo 1.88.0 (fixture)")
    }

    func seed(family: NotikaRustTestFamily = .liteparse, usedAt: Date, token: String = "a") throws -> RustRetentionSeed {
        let identity = try identity(family: family, token: token)
        let directory = root.appendingPathComponent(try identity.cacheKey())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try #require(chmod(root.path, 0o700) == 0)
        try #require(chmod(directory.path, 0o700) == 0)
        let physical = try rustRetentionTestStatus(directory.path)
        let observation = try NotikaRustCacheObservation(identity: identity, deviceID: UInt64(physical.st_dev), inode: physical.st_ino, ownerUID: physical.st_uid)
        let record = try NotikaRustCacheUsageRecord.make(identity: identity, observation: observation, sessionID: "retention-fixture", usedAt: usedAt)
        let seed = RustRetentionSeed(identity: identity, directory: directory, observation: observation)
        try record.document.originalData.write(to: seed.usage)
        try #require(chmod(seed.usage.path, 0o600) == 0)
        try Data(repeating: 97, count: 8_192).write(to: directory.appendingPathComponent("payload"))
        return seed
    }

    func collector(trash: any ArtifactTrashOperator = SystemArtifactTrashOperator(), hook: @escaping @Sendable (String) async throws -> Void = { _ in }) throws -> NotikaRustCacheRetentionCollector {
        try NotikaRustCacheRetentionCollector(canonicalRepository: path, registryRoot: registry, evaluatedAt: now, timeZone: timeZone,
            trashOperator: trash, beforeRevalidation: hook)
    }

    func collector(factory: @escaping @Sendable (String) throws -> RetainedArtifactDirectory) throws -> NotikaRustCacheRetentionCollector {
        try NotikaRustCacheRetentionCollector(canonicalRepository: path, registryRoot: registry, evaluatedAt: now, timeZone: timeZone,
            trashOperator: SystemArtifactTrashOperator(), beforeRevalidation: { _ in }, claimDirectoryFactory: factory)
    }

    func mover() throws -> RustRetentionRecordingTrash {
        let destination = base.directory.appendingPathComponent("fake-Trash")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        return RustRetentionRecordingTrash(destination: destination)
    }
}

private struct RustRetentionSeed: Sendable {
    let identity: NotikaRustCacheIdentity
    let directory: URL
    let observation: NotikaRustCacheObservation
    var key: String { observation.cacheKey }
    var usage: URL { directory.appendingPathComponent(rustRetentionUsageName) }
}

private enum RustRetentionTamper: CaseIterable, Sendable {
    case schemaTwo, schemaThree, booleanSchema, duplicateKey, missingField, foreignField, wrongInode, wrongFamily, wrongDigest, storageDigest
    func apply(to seed: RustRetentionSeed) throws {
        if self == .duplicateKey {
            let text = try String(contentsOf: seed.usage, encoding: .utf8)
            try Data(("{\"schemaVersion\":1," + text.dropFirst()).utf8).write(to: seed.usage)
            return
        }
        try rustRetentionTamper(seed.usage) { object in
            switch self {
            case .schemaTwo: object["schemaVersion"] = 2
            case .schemaThree: object["schemaVersion"] = 3
            case .booleanSchema: object["schemaVersion"] = true
            case .missingField: object.removeValue(forKey: "lastSessionID")
            case .foreignField: object["unknown"] = "protected"
            case .wrongInode: object["directoryIdentity"] = ["deviceID": seed.observation.deviceID, "inode": seed.observation.inode + 1]
            case .wrongFamily: object["compatibilityFamily"] = ["canonicalWorktree": seed.identity.repository, "family": "svg", "targetKind": "host-debug-cargo-test"]
            case .wrongDigest: object["compatibilityIdentitySHA256"] = String(repeating: "f", count: 64)
            case .storageDigest: object["storageIdentitySHA256"] = String(repeating: "a", count: 64)
            case .duplicateKey: break
            }
        }
    }
}

private final class RustRetentionRecordingTrash: ArtifactTrashOperator {
    let identifier = "temporary-rust-fixture-trash"
    let destination: URL
    let sources = Mutex<[ArtifactTrashSource]>([])
    init(destination: URL) { self.destination = destination }
    func moveToTrash(_ source: ArtifactTrashSource) async throws {
        try source.revalidateBeforeMove()
        let descriptors = try source.inheritedDescriptors()
        #expect(descriptors.count >= 6)
        #expect(descriptors.allSatisfy { fcntl($0, F_GETFD) & FD_CLOEXEC != 0 })
        try FileManager.default.moveItem(atPath: source.path, toPath: destination.appendingPathComponent(URL(fileURLWithPath: source.originalPath).lastPathComponent).path)
        sources.withLock { $0.append(source) }
    }
}

private struct RustRetentionFailingTrash: ArtifactTrashOperator {
    let identifier = "failing-rust-fixture-trash"
    let replaceOriginal: Bool
    func moveToTrash(_ source: ArtifactTrashSource) async throws {
        try source.revalidateBeforeMove()
        if replaceOriginal {
            try FileManager.default.createDirectory(atPath: source.originalPath, withIntermediateDirectories: false)
            try Data("must stay".utf8).write(to: URL(fileURLWithPath: source.originalPath).appendingPathComponent("replacement"))
        }
        throw ArtifactTrashError.failed
    }
}

private func rustRetentionTamper(_ path: URL, operation: (inout [String: Any]) throws -> Void) throws {
    var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
    try operation(&object)
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: path)
}

private func rustRetentionDeepPayload(_ root: URL) throws {
    var path = root
    for _ in 0...NotikaRustCacheRetentionCollector.maximumCacheDepth {
        path.appendPathComponent("d")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
    }
}

private func rustRetentionTestStatus(_ path: String) throws -> stat {
    var status = stat()
    guard lstat(path, &status) == 0 else { throw CompilationFixture.Failure.expected }
    return status
}
