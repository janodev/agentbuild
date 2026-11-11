@testable import AgentBuildCore
import AgentBuildTestSupport
import AgentLeaseCore
import Darwin
import Foundation
@testable import NotikaAdapter
import Synchronization
import Testing

@Suite("Today-only Xcode cache collection")
struct NotikaCacheRetentionCollectorTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTBUILD_TEST_SYSTEM_TRASH"] == "1",
        "Explicit opt-in: move one uniquely created temporary cache through system Trash"))
    func systemTrashMovesOnlyThePriorDayCacheInAnIsolatedGitRepository() async throws {
        let fixture = try CacheRetentionFixture(now: Date(), timeZone: .current)
        defer { fixture.base.remove() }
        let git = try RepositoryCommandCapture(outputLimit: 16_384, diagnosticLimit: 16_384, timeout: .seconds(10))
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
        _ = try await git.capture(arguments: ["/usr/bin/git", "init", "-q"],
            workingDirectory: fixture.base.directory.path, environment: environment)
        let topLevel = try await git.capture(arguments: ["/usr/bin/git", "rev-parse", "--show-toplevel"],
            workingDirectory: fixture.base.directory.path, environment: environment)
        #expect(String(decoding: topLevel, as: UTF8.self).trimmingCharacters(in: .newlines) == fixture.base.directory.path)
        let old = try await fixture.seed(usedAt: fixture.cutoff.addingTimeInterval(-1), token: "a")
        let today = try await fixture.seed(usedAt: fixture.now, token: "b")
        let oldStatus = try retentionTestStatus(old.directory.path)
        let oldUsage = try Data(contentsOf: old.usage)
        let todayUsage = try Data(contentsOf: today.usage)
        let todayPayload = try Data(contentsOf: today.directory.appendingPathComponent("payload"))
        let markerName = "agentbuild-system-trash-" + UUID().uuidString
        let marker = Data(UUID().uuidString.utf8)
        try marker.write(to: old.directory.appendingPathComponent(markerName))
        let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
            appropriateFor: old.directory, create: false)
        let destination = trash.appendingPathComponent(old.key)
        try #require(!FileManager.default.fileExists(atPath: destination.path))

        // No injected mover: this calls the real, fixed Foundation Trash helper.
        let report = try await fixture.collector().run(execute: true)
        print("⚠️ System Trash operational report: " + String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
        #expect(report.trashOperatorIdentifier == SystemArtifactTrashOperator().identifier)
        #expect(report.rootState == .ready)
        #expect(report.scanComplete)
        try #require(report.entries.first { $0.name == old.key }?.action == .trashed)
        #expect(report.entries.first { $0.name == today.key }?.reason == .currentLocalDay)
        #expect(!FileManager.default.fileExists(atPath: old.directory.path))
        let trashed = try retentionTestStatus(destination.path)
        #expect(trashed.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR))
        #expect(trashed.st_dev == oldStatus.st_dev)
        #expect(trashed.st_ino == old.inode)
        #expect(try Data(contentsOf: destination.appendingPathComponent(NotikaCacheCustody.metadataFilename)) == oldUsage)
        #expect(try Data(contentsOf: destination.appendingPathComponent(markerName)) == marker)
        #expect(try retentionTestStatus(today.directory.path).st_ino == today.inode)
        #expect(try Data(contentsOf: today.usage) == todayUsage)
        #expect(try Data(contentsOf: today.directory.appendingPathComponent("payload")) == todayPayload)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.claims.path).isEmpty)
        print("⚠️ System Trash verified exact inode \(old.inode) at \(destination.path); today cache \(today.key) stayed unchanged. The created Trash fixture is left for inspection.")
    }

    @Test func absentRootDoesNotCreateCacheDirectories() async throws {
        let fixture = try CacheRetentionFixture()
        defer { fixture.base.remove() }
        let report = try await fixture.collector().run(execute: true)
        #expect(report.rootState == .absent)
        #expect(report.scanComplete)
        #expect(report.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.path))
    }

    @Test(arguments: [1, 2, 3])
    func yesterdaySchemasAreTrashedWithExactEvidenceAndNoFreedSpaceClaim(_ schema: Int) async throws {
        let fixture = try CacheRetentionFixture()
        defer { fixture.base.remove() }
        let old = try await fixture.seed(schema: schema, usedAt: fixture.cutoff.addingTimeInterval(-1))
        let mover = try fixture.mover()
        let before = try Data(contentsOf: old.usage)
        let report = try await fixture.collector(trash: mover).run(execute: true)
        let entry = try #require(report.entries.first)
        #expect(report.rootState == .ready)
        #expect(report.scanComplete)
        #expect(report.policy == .todayOnlyCaches)
        #expect(entry.action == .trashed)
        #expect(entry.reason == .movedToTrash)
        #expect(entry.evidence?.schemaVersion == schema)
        #expect(entry.evidence?.inode == old.inode)
        #expect(entry.evidence?.metadataDigest == CanonicalJSONDigest.digest(before))
        #expect(entry.allocatedBytes != nil)
        #expect(report.movedToTrashAllocatedBytes == entry.allocatedBytes)
        #expect(!FileManager.default.fileExists(atPath: old.directory.path))
        #expect(try Data(contentsOf: mover.destination.appendingPathComponent(old.key).appendingPathComponent(NotikaCacheCustody.metadataFilename)) == before)
        let source = try #require(mover.sources.withLock { $0.first })
        #expect(source.originalPath == old.directory.path)
        #expect(source.path.contains("/DerivedData/AgentCacheTrashClaims/"))
        #expect(throws: ArtifactTrashError.retiredSource) { try source.revalidateBeforeMove() }
        #expect(throws: ArtifactTrashError.retiredSource) { try source.inheritedDescriptors() }
    }

    @Test func dryRunPreservesExactBytesAndTodayAndFutureDoNotNeedPayloadWalks() async throws {
        let fixture = try CacheRetentionFixture()
        defer { fixture.base.remove() }
        let old = try await fixture.seed(usedAt: fixture.cutoff.addingTimeInterval(-1), token: "a")
        let today = try await fixture.seed(usedAt: fixture.cutoff, token: "b")
        let future = try await fixture.seed(usedAt: fixture.now.addingTimeInterval(1), token: "c")
        // Ineligible cache payloads exceed the traversal-depth bound. Schema
        // admission still succeeds without walking either payload tree.
        try retentionDeepPayload(today.directory)
        try retentionDeepPayload(future.directory)
        let bytes = try Data(contentsOf: old.usage)
        let report = try await fixture.collector().run(execute: false)
        let values = Dictionary(uniqueKeysWithValues: report.entries.map { ($0.name, $0) })
        #expect(values[old.key]?.action == .wouldTrash)
        #expect(values[old.key]?.allocatedBytes != nil)
        #expect(values[today.key]?.reason == .currentLocalDay)
        #expect(values[today.key]?.allocatedBytes == nil)
        #expect(values[future.key]?.reason == .lastUseInFuture)
        #expect(values[future.key]?.allocatedBytes == nil)
        #expect(report.movedToTrashAllocatedBytes == 0)
        #expect(try Data(contentsOf: old.usage) == bytes)
        #expect(!FileManager.default.fileExists(atPath: fixture.claims.path))
    }

    @Test func liveNativeProjectScopeExcludesCollectorThroughSharedPolicy() async throws {
        let fixture = try CacheRetentionFixture()
        defer { fixture.base.remove() }
        let old = try await fixture.seed(usedAt: fixture.cutoff.addingTimeInterval(-1))
        let plan = try NotikaProjectOwnershipPlan(identity: old.identity)
        let mover = try fixture.mover()
        try await NotikaProjectAdmission().withOwnership(plan, registryRoot: fixture.base.registry.path, label: "live native cache user") { ownership in
            #expect(try ownership.inheritedDescriptors().count == 3)
            let report = try await fixture.collector(trash: mover).run(execute: true)
            #expect(report.rootState == .busy)
            #expect(report.rootReason == .policyBusy)
            #expect(!report.scanComplete)
            #expect(report.entries.isEmpty)
        }
        #expect(mover.sources.withLock { $0.isEmpty })
        #expect(FileManager.default.fileExists(atPath: old.directory.path))
    }

    @Test(arguments: ["2026-03-29T12:00:00Z", "2026-10-25T12:00:00Z"])
    func localCutoffOnDSTTransitionKeepsExactMidnight(_ instant: String) async throws {
        let now = try #require(ISO8601DateFormatter().date(from: instant))
        let zone = try #require(TimeZone(identifier: "Europe/Madrid"))
        let fixture = try CacheRetentionFixture(now: now, timeZone: zone)
        defer { fixture.base.remove() }
        let policy = try LocalCalendarRetention(evaluatedAt: now, timeZone: zone)
        let old = try await fixture.seed(usedAt: policy.localDayStart.addingTimeInterval(-0.000001), token: "a")
        let midnight = try await fixture.seed(usedAt: policy.localDayStart, token: "b")
        let report = try await fixture.collector().run(execute: false)
        #expect(report.localDayCutoff == policy.localDayStart)
        #expect(report.timeZoneIdentifier == "Europe/Madrid")
        #expect(report.entries.first(where: { $0.name == old.key })?.action == .wouldTrash)
        #expect(report.entries.first(where: { $0.name == midnight.key })?.reason == .currentLocalDay)
    }

    @Test func legacyPerCacheExclusiveOwnerIsSkippedWithoutPayloadScan() async throws {
        let fixture = try CacheRetentionFixture()
        defer { fixture.base.remove() }
        let old = try await fixture.seed(usedAt: fixture.cutoff.addingTimeInterval(-1))
        try retentionDeepPayload(old.directory)
        let lock = try FileLock(resource: ResourceName(CacheCompatibilityIdentity.cacheResourceName(
            canonicalWorktree: fixture.base.directory.path, canonicalCachePath: old.directory.path
        )), paths: fixture.base.paths)
        try #require(try lock.tryAcquire())
        defer { lock.release() }
        let report = try await fixture.collector().run(execute: true)
        #expect(report.rootState == .ready)
        #expect(report.entries.first?.action == .skippedBusy)
        #expect(report.entries.first?.allocatedBytes == nil)
        #expect(FileManager.default.fileExists(atPath: old.directory.path))
    }

    @Test func malformedUnknownAndUnsafeSiblingNeverPreventSafeOldMove() async throws {
        let fixture = try CacheRetentionFixture()
        defer { fixture.base.remove() }
        let old = try await fixture.seed(usedAt: fixture.cutoff.addingTimeInterval(-1), token: "a")
        let malformed = try await fixture.seed(usedAt: fixture.cutoff.addingTimeInterval(-1), token: "b")
        let bad = Data("{\"schemaVersion\":3,\"schemaVersion\":3}".utf8)
        try bad.write(to: malformed.usage)
        let unknown = fixture.root.appendingPathComponent(String(repeating: "f", count: 24))
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: false)
        try #require(chmod(unknown.path, 0o700) == 0)
        try retentionDeepPayload(unknown)
        let outside = fixture.base.directory.appendingPathComponent("outside")
        try Data("outside untouched".utf8).write(to: outside)
        try #require(symlink(outside.path, fixture.root.appendingPathComponent(".DS_Store").path) == 0)
        let mover = try fixture.mover()
        let report = try await fixture.collector(trash: mover).run(execute: true)
        let values = Dictionary(uniqueKeysWithValues: report.entries.map { ($0.name, $0) })
        #expect(values[old.key]?.action == .trashed)
        #expect(values[malformed.key]?.reason == .metadataInvalid)
        #expect(values[unknown.lastPathComponent]?.reason == .metadataAbsent)
        #expect(values[unknown.lastPathComponent]?.allocatedBytes == nil)
        #expect(values[".DS_Store"]?.reason == .finderMetadataUnsafe)
        #expect(try Data(contentsOf: malformed.usage) == bad)
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside untouched")
        #expect(FileManager.default.fileExists(atPath: unknown.path))
    }

    @Test(arguments: [mode_t(0o600), mode_t(0o644)])
    func ownedRegularFinderMetadataIsHarmless(_ mode: mode_t) async throws {
        let fixture = try CacheRetentionFixture()
        defer { fixture.base.remove() }
        _ = try await fixture.seed(usedAt: fixture.cutoff)
        let finder = fixture.root.appendingPathComponent(".DS_Store")
        try Data("Finder data".utf8).write(to: finder)
        try #require(chmod(finder.path, mode) == 0)
        let report = try await fixture.collector().run(execute: true)
        #expect(report.entries.first(where: { $0.name == ".DS_Store" })?.reason == .finderMetadata)
        #expect(try String(contentsOf: finder, encoding: .utf8) == "Finder data")
    }

    @Test(arguments: UnsafeCacheUsage.allCases)
    func unsafeUsageFileNeverAuthorizesClaimOrTrash(_ unsafe: UnsafeCacheUsage) async throws {
        let fixture = try CacheRetentionFixture()
        defer { fixture.base.remove() }
        let old = try await fixture.seed(usedAt: fixture.cutoff.addingTimeInterval(-1))
        let outside = fixture.base.directory.appendingPathComponent("protected-usage")
        switch unsafe {
        case .permissions:
            try #require(chmod(old.usage.path, 0o644) == 0)
        case .hardlink:
            try #require(link(old.usage.path, outside.path) == 0)
        case .symlink:
            try FileManager.default.moveItem(at: old.usage, to: outside)
            try #require(symlink(outside.path, old.usage.path) == 0)
        case .fifo:
            try FileManager.default.moveItem(at: old.usage, to: outside)
            try #require(mkfifo(old.usage.path, 0o600) == 0)
        case .directory:
            try FileManager.default.moveItem(at: old.usage, to: outside)
            try FileManager.default.createDirectory(at: old.usage, withIntermediateDirectories: false)
        }
        let mover = try fixture.mover()
        let report = try await fixture.collector(trash: mover).run(execute: true)
        #expect(report.entries.first?.reason == .entryUnsafe)
        #expect(report.entries.first?.action == NotikaCacheRetentionAction.none)
        #expect(mover.sources.withLock { $0.isEmpty })
        #expect(FileManager.default.fileExists(atPath: old.directory.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.claims.path))
    }

    @Test func metadataRefreshBetweenAssessmentAndActionBlocksMove() async throws {
        let fixture = try CacheRetentionFixture()
        defer { fixture.base.remove() }
        let old = try await fixture.seed(usedAt: fixture.cutoff.addingTimeInterval(-1))
        let mover = try fixture.mover()
        let collector = try fixture.collector(trash: mover, hook: { _ in
            let refreshed = try NotikaCacheUsageFactory.make(
                identity: old.identity, directoryObservation: old.observation,
                sessionID: "external-refresh", usedAt: fixture.now
            )
            try refreshed.originalData.write(to: old.usage)
        })
        let report = try await collector.run(execute: true)
        #expect(report.entries.first?.action == .skippedRevalidation)
        #expect(report.entries.first?.reason == .evidenceChanged)
        #expect(mover.sources.withLock { $0.isEmpty })
        #expect(FileManager.default.fileExists(atPath: old.directory.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.claims.path))
    }

    @Test func replacingCachePathWithSymlinkCannotMoveEitherSourceOrTarget() async throws {
        let fixture = try CacheRetentionFixture()
        defer { fixture.base.remove() }
        let old = try await fixture.seed(usedAt: fixture.cutoff.addingTimeInterval(-1))
        let retired = fixture.base.directory.appendingPathComponent("retired-cache")
        let outside = fixture.base.directory.appendingPathComponent("outside-cache")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let mover = try fixture.mover()
        let collector = try fixture.collector(trash: mover, hook: { _ in
            try FileManager.default.moveItem(at: old.directory, to: retired)
            try #require(symlink(outside.path, old.directory.path) == 0)
        })
        let report = try await collector.run(execute: true)
        #expect(report.entries.first?.action == .skippedRevalidation)
        #expect(mover.sources.withLock { $0.isEmpty })
        #expect(FileManager.default.fileExists(atPath: retired.appendingPathComponent(NotikaCacheCustody.metadataFilename).path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(try retentionTestStatus(old.directory.path).st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK))
    }

    @Test func replacingRootDuringRevalidationStopsFurtherActions() async throws {
        let fixture = try CacheRetentionFixture()
        defer { fixture.base.remove() }
        _ = try await fixture.seed(usedAt: fixture.cutoff.addingTimeInterval(-1))
        let retired = fixture.root.appendingPathExtension("retired")
        let mover = try fixture.mover()
        let collector = try fixture.collector(trash: mover, hook: { _ in
            try FileManager.default.moveItem(at: fixture.root, to: retired)
            try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: false)
            try #require(chmod(fixture.root.path, 0o700) == 0)
        })
        let report = try await collector.run(execute: true)
        #expect(report.rootState == .unsafe)
        #expect(report.rootReason == .rootChanged)
        #expect(!report.scanComplete)
        #expect(mover.sources.withLock { $0.isEmpty })
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
    }

    @Test func failedTrashRestoresExactSourceWithoutOverwritingConcurrentReplacement() async throws {
        for replaceOriginal in [false, true] {
            let fixture = try CacheRetentionFixture()
            defer { fixture.base.remove() }
            let old = try await fixture.seed(usedAt: fixture.cutoff.addingTimeInterval(-1))
            let mover = RetentionFailingTrash(replaceOriginal: replaceOriginal)
            let report = try await fixture.collector(trash: mover).run(execute: true)
            #expect(report.entries.first?.action == .trashFailed)
            let current = try retentionTestStatus(old.directory.path)
            if replaceOriginal {
                #expect(current.st_ino != old.inode)
                #expect(try String(contentsOf: old.directory.appendingPathComponent("replacement"), encoding: .utf8) == "must stay")
                let next = try await fixture.collector().run(execute: false)
                #expect(next.rootReason == .pendingTrashClaims)
            } else {
                #expect(current.st_ino == old.inode)
                #expect(FileManager.default.fileExists(atPath: old.usage.path))
                let next = try await fixture.collector().run(execute: false)
                #expect(next.entries.first?.action == .wouldTrash)
            }
        }
    }

    @Test func claimedMetadataMutationIsRejectedAndRestoredInsteadOfTrashed() async throws {
        let fixture = try CacheRetentionFixture()
        defer { fixture.base.remove() }
        let old = try await fixture.seed(usedAt: fixture.cutoff.addingTimeInterval(-1))
        let report = try await fixture.collector(trash: RetentionMutatingTrash()).run(execute: true)
        #expect(report.entries.first?.action == .trashFailed)
        #expect(try retentionTestStatus(old.directory.path).st_ino == old.inode)
        #expect(try String(contentsOf: old.usage, encoding: .utf8) == "changed during claimed operation")
    }

    @Test(arguments: [false, true])
    func failedClaimConstructionCleansOnlyItsOriginalEmptyPlaceholder(_ replacePlaceholder: Bool) async throws {
        let fixture = try CacheRetentionFixture()
        defer { fixture.base.remove() }
        let old = try await fixture.seed(usedAt: fixture.cutoff.addingTimeInterval(-1))
        let originalBytes = try Data(contentsOf: old.usage)
        let captured = Mutex<(path: String, replacementInode: UInt64)?>(nil)
        let retired = fixture.base.directory.appendingPathComponent("retired-empty-placeholder")
        let collector = try fixture.collector(claimDirectoryFactory: { path in
            if replacePlaceholder {
                try FileManager.default.moveItem(atPath: path, toPath: retired.path)
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false,
                                                       attributes: [.posixPermissions: 0o700])
            }
            let inode = try retentionTestStatus(path).st_ino
            captured.withLock { $0 = (path, inode) }
            throw RetainedArtifactError.systemCall("open private claim", EMFILE)
        })
        let report = try await collector.run(execute: true)
        #expect(report.entries.first?.action == .trashFailed)
        #expect(try retentionTestStatus(old.directory.path).st_ino == old.inode)
        #expect(try Data(contentsOf: old.usage) == originalBytes)
        let placeholder = try #require(captured.withLock { $0 })
        if replacePlaceholder {
            #expect(try retentionTestStatus(placeholder.path).st_ino == placeholder.replacementInode)
            #expect(try FileManager.default.contentsOfDirectory(atPath: placeholder.path).isEmpty)
            #expect(FileManager.default.fileExists(atPath: retired.path))
            let protected = try await fixture.collector().run(execute: false)
            #expect(protected.rootReason == .pendingTrashClaims)
        } else {
            #expect(!FileManager.default.fileExists(atPath: placeholder.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.claims.path).isEmpty)
            let next = try await fixture.collector().run(execute: false)
            #expect(next.rootState == .ready)
            #expect(next.entries.first?.action == .wouldTrash)
        }
    }

    @Test func eligibleDepthBoundIsProtectedAndRootEntryBudgetProducesNoSideEffects() async throws {
        let fixture = try CacheRetentionFixture()
        defer { fixture.base.remove() }
        let old = try await fixture.seed(usedAt: fixture.cutoff.addingTimeInterval(-1))
        try retentionDeepPayload(old.directory)
        let mover = try fixture.mover()
        let report = try await fixture.collector(trash: mover).run(execute: true)
        #expect(report.entries.first?.reason == .sizeUnavailable)
        #expect(mover.sources.withLock { $0.isEmpty })
        for index in 0..<NotikaCacheRetentionCollector.maximumRootEntries {
            try Data().write(to: fixture.root.appendingPathComponent("unknown-\(index)"))
        }
        let bounded = try await fixture.collector(trash: mover).run(execute: true)
        #expect(bounded.rootState == .entryBoundExceeded)
        #expect(bounded.entries.isEmpty)
        #expect(!bounded.scanComplete)
        #expect(mover.sources.withLock { $0.isEmpty })
    }

    @Test func sizingNeverFollowsPayloadSymlinksAndDeduplicatesHardlinks() async throws {
        let fixture = try CacheRetentionFixture()
        defer { fixture.base.remove() }
        let old = try await fixture.seed(usedAt: fixture.cutoff.addingTimeInterval(-1))
        let outside = fixture.base.directory.appendingPathComponent("outside-payload")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try retentionDeepPayload(outside)
        let payload = old.directory.appendingPathComponent("payload")
        try #require(link(payload.path, old.directory.appendingPathComponent("hardlink").path) == 0)
        try #require(symlink(outside.path, old.directory.appendingPathComponent("symlink").path) == 0)
        let report = try await fixture.collector().run(execute: false)
        #expect(report.entries.first?.action == .wouldTrash)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }
}

private struct CacheRetentionFixture: Sendable {
    let base: CompilationFixture
    let now: Date
    let timeZone: TimeZone
    var cutoff: Date { get throws { try LocalCalendarRetention(evaluatedAt: now, timeZone: timeZone).localDayStart } }
    var root: URL { base.directory.appendingPathComponent("DerivedData/AgentCaches") }
    var claims: URL { base.directory.appendingPathComponent("DerivedData/AgentCacheTrashClaims") }

    init(now: Date = Date(timeIntervalSince1970: 1_788_256_800), timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!) throws {
        base = try CompilationFixture(); self.now = now; self.timeZone = timeZone
    }

    func seed(schema: Int = 3, usedAt: Date, token: String = "a") async throws -> RetentionSeed {
        let digest = String(repeating: "a", count: 64)
        let identity = try CacheCompatibilityIdentity(
            canonicalWorktree: base.directory.path, toolchainHash: String(repeating: token, count: 64), gitlinks: [],
            submoduleStatusDigest: digest, submoduleWorktreeDigest: digest,
            projectGraphDigest: digest, generatedGraphDigest: digest, resolvedDependenciesDigest: digest,
            scheme: "Notika", configuration: "Debug", destinationFamily: "macos-arm64", buildFlags: ["-disableAutomaticPackageResolution"]
        )
        let plan = try NotikaProjectOwnershipPlan(identity: identity, admittedCacheKey: identity.cacheKey(metadataSchemaVersion: schema))
        return try await NotikaProjectAdmission().withOwnership(plan, registryRoot: base.registry.path, label: "retention fixture seed") { ownership in
            let custody = try NotikaCacheCustody(identity: identity, ownership: ownership)
            try custody.publishUsage(sessionID: "retention-fixture", usedAt: usedAt)
            let directory = URL(fileURLWithPath: custody.cacheDirectory)
            try Data(repeating: 97, count: 8_192).write(to: directory.appendingPathComponent("payload"))
            return RetentionSeed(identity: identity, directory: directory, observation: custody.directoryObservation)
        }
    }

    func collector(
        trash: any ArtifactTrashOperator = SystemArtifactTrashOperator(),
        hook: @escaping @Sendable (String) async throws -> Void = { _ in }
    ) throws -> NotikaCacheRetentionCollector {
        try NotikaCacheRetentionCollector(canonicalRepository: base.directory.path, registryRoot: base.registry.path,
            evaluatedAt: now, timeZone: timeZone, trashOperator: trash, beforeRevalidation: hook)
    }

    func collector(
        claimDirectoryFactory: @escaping @Sendable (String) throws -> RetainedArtifactDirectory
    ) throws -> NotikaCacheRetentionCollector {
        try NotikaCacheRetentionCollector(canonicalRepository: base.directory.path, registryRoot: base.registry.path,
            evaluatedAt: now, timeZone: timeZone, trashOperator: SystemArtifactTrashOperator(),
            beforeRevalidation: { _ in }, claimDirectoryFactory: claimDirectoryFactory)
    }

    func mover() throws -> RetentionRecordingTrash {
        let destination = base.directory.appendingPathComponent("fake-Trash")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        return RetentionRecordingTrash(destination: destination)
    }
}

private struct RetentionSeed: Sendable {
    let identity: CacheCompatibilityIdentity
    let directory: URL
    let observation: NotikaCacheDirectoryObservation
    var inode: UInt64 { observation.inode }
    var key: String { observation.cacheKey }
    var usage: URL { directory.appendingPathComponent(NotikaCacheCustody.metadataFilename) }
}

private final class RetentionRecordingTrash: ArtifactTrashOperator {
    let identifier = "temporary-fixture-trash"
    let destination: URL
    let sources = Mutex<[ArtifactTrashSource]>([])
    init(destination: URL) { self.destination = destination }
    func moveToTrash(_ source: ArtifactTrashSource) async throws {
        try source.revalidateBeforeMove()
        let descriptors = try source.inheritedDescriptors()
        #expect(descriptors.count >= 6)
        for descriptor in descriptors { #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0) }
        try FileManager.default.moveItem(atPath: source.path, toPath: destination.appendingPathComponent(URL(fileURLWithPath: source.originalPath).lastPathComponent).path)
        sources.withLock { $0.append(source) }
    }
}

private struct RetentionFailingTrash: ArtifactTrashOperator {
    let identifier = "failing-fixture-trash"
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

private struct RetentionMutatingTrash: ArtifactTrashOperator {
    let identifier = "mutating-fixture-trash"
    func moveToTrash(_ source: ArtifactTrashSource) async throws {
        try Data("changed during claimed operation".utf8).write(to: URL(fileURLWithPath: source.path).appendingPathComponent(NotikaCacheCustody.metadataFilename))
        try source.revalidateBeforeMove()
        Issue.record("changed claimed metadata was admitted")
    }
}

private func retentionDeepPayload(_ root: URL) throws {
    var path = root
    for _ in 0...NotikaCacheRetentionCollector.maximumCacheDepth {
        path.appendPathComponent("d")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
    }
}

private func retentionTestStatus(_ path: String) throws -> stat {
    var status = stat()
    guard lstat(path, &status) == 0 else { throw CompilationFixture.Failure.expected }
    return status
}
