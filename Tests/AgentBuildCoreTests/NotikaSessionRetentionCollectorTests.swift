@testable import AgentBuildCore
import AgentLeaseCore
import Darwin
import Foundation
import Synchronization
import Testing

@Suite("Notika today-only session collector")
struct NotikaSessionRetentionCollectorTests {
    @Test func historicalTwoStreamTerminalIsRetentionEligibleWithoutCurrentCombinedAuthority() async throws {
        let fixture = try SessionCollectorFixture()
        defer { fixture.remove() }
        let name = try await fixture.historicalGenerationWithTwoRawStreams()
        let bytes = try Data(contentsOf: fixture.manifest(name))
        #expect(throws: (any Error).self) { try NotikaGenerationSessionReport(data: bytes) }
        let historical = try NotikaGenerationSessionReport(data: bytes, expectedRepository: fixture.path,
            expectedSessionID: name, captureAdmissionPolicy: .historicalRetention)
        #expect(historical.nativeTermination == RunTermination(kind: .exit, value: 29))
        #expect(historical.exitCode == 29)
        #expect(historical.status == "failed")
        let root = try StrictJSONDocument(data: historical.originalData).root.requireObject()
        guard case .array(let phases) = try root.requiredValue(forKey: "phases"), let phase = phases.first else {
            Issue.record("Historical phase missing"); return
        }
        let raw = try phase.requireObject().requiredValue(forKey: "rawCapture")
        #expect(try admitNativeLogCaptureRecord(raw, sessionPath: fixture.session(name).path, policy: .historicalRetention).combined == nil)
        let preview = try await fixture.collector().run(execute: false)
        #expect(preview.entries.first { $0.name == name }?.action == .wouldTrash)
        let moved = try await fixture.collector().run(execute: true)
        #expect(moved.entries.first { $0.name == name }?.action == .trashed)
        #expect(try Data(contentsOf: fixture.trash.appendingPathComponent(name + "/manifest.json")) == bytes)
    }

    @Test(arguments: StandaloneSessionFamily.allCases)
    func priorDayInactiveStandaloneProgressMovesWithoutInventingNativeCompletion(family: StandaloneSessionFamily) async throws {
        let fixture = try SessionCollectorFixture()
        defer { fixture.remove() }
        let name = try await fixture.standaloneSession(family, completedAt: nil)
        let progress = fixture.session(name).appendingPathComponent("in-progress.json")
        let bytes = try Data(contentsOf: progress)
        let preview = try await fixture.collector().run(execute: false)
        let entry = try #require(preview.entries.first { $0.name == name })
        #expect(entry.action == .wouldTrash)
        #expect(entry.reason == .abandonedBeforeLocalDay)
        #expect(entry.manifestDigest == nil)
        #expect(entry.detail?.contains("Native outcome unknown") == true)
        #expect(!FileManager.default.fileExists(atPath: fixture.manifest(name).path))
        let moved = try await fixture.collector().run(execute: true)
        #expect(moved.entries.first { $0.name == name }?.action == .trashed)
        let retained = fixture.trash.appendingPathComponent(name)
        #expect(try Data(contentsOf: retained.appendingPathComponent("in-progress.json")) == bytes)
        #expect(!FileManager.default.fileExists(atPath: retained.appendingPathComponent("manifest.json").path))
    }

    @Test func buildProgressRequiresItsOriginalSealedPeerAndRetainsTodaysEvidence() async throws {
        let fixture = try SessionCollectorFixture()
        defer { fixture.remove() }
        let old = try await fixture.swiftProgress(startedAt: fixture.yesterday)
        let today = try await fixture.swiftProgress(startedAt: fixture.today)
        let linked = try await fixture.swiftProgress(startedAt: fixture.yesterday)
        try FileManager.default.linkItem(at: fixture.session(linked).appendingPathComponent("in-progress.json"),
            to: fixture.root.appendingPathComponent("outside-progress-link"))
        let preview = try await fixture.collector().run(execute: false)
        #expect(preview.entries.first { $0.name == old }?.action == .wouldTrash)
        #expect(preview.entries.first { $0.name == today }?.classification == .retained)
        #expect(preview.entries.first { $0.name == linked }?.reason == .manifestInvalid)
    }

    @Test func legacyInactiveAuthorityAndBoundAbandonmentReceiptUseTodayOnlyPolicy() async throws {
        let fixture = try SessionCollectorFixture()
        defer { fixture.remove() }
        try fixture.legacyAuthority("old-authority", createdAt: fixture.yesterday)
        try fixture.legacyAuthority("today-authority", createdAt: fixture.today)
        try fixture.legacyAuthority("future-authority", createdAt: fixture.now.addingTimeInterval(3_600))
        try fixture.legacyAuthority("bound-abandoned", createdAt: fixture.yesterday, finalized: true)
        let report = try await fixture.collector().run(execute: true)
        #expect(report.entries.first { $0.name == "old-authority" }?.action == .trashed)
        #expect(report.entries.first { $0.name == "bound-abandoned" }?.action == .trashed)
        #expect(report.entries.first { $0.name == "today-authority" }?.classification == .retained)
        #expect(report.entries.first { $0.name == "future-authority" }?.reason == .lifecycleInFuture)
        #expect(report.entries.first { $0.name == "old-authority" }?.detail?.contains("Native outcome unknown") == true)
        let retained = try StrictJSONDocument(data: Data(contentsOf: fixture.trash.appendingPathComponent("bound-abandoned/manifest.json")))
        #expect(try retained.root.requireObject().requiredValue(forKey: "status") == .string("inconclusive"))
        #expect(try retained.root.requireObject().value(forKey: "nativeTermination") == nil)
    }

    @Test func liveOwnerForeignDirectoryAndForgedAbandonmentCannotAuthorizeCleanup() async throws {
        let fixture = try SessionCollectorFixture()
        defer { fixture.remove() }
        try fixture.legacyAuthority("exact-live-owner", createdAt: fixture.yesterday, liveOwner: true)
        try fixture.legacyAuthority("foreign-directory", createdAt: fixture.yesterday, fault: "directory")
        try fixture.legacyAuthority("forged-digest", createdAt: fixture.yesterday, finalized: true, fault: "authority-digest")
        try fixture.legacyAuthority("unknown-fields", createdAt: fixture.yesterday, fault: "extra-field")
        let mover = SessionCollectorMover(destination: fixture.trash.path)
        let report = try await fixture.collector(trash: mover).run(execute: true)
        #expect(report.entries.first { $0.name == "exact-live-owner" }?.classification == .incomplete)
        for name in ["foreign-directory", "forged-digest", "unknown-fields"] {
            #expect(report.entries.first { $0.name == name }?.reason == .manifestInvalid)
            #expect(FileManager.default.fileExists(atPath: fixture.session(name).path))
        }
        #expect(mover.calls.withLock { $0 } == 0)
    }

    @Test func inactiveAuthorityReplacementAndLateTerminalPublicationBlockTheMove() async throws {
        let fixture = try SessionCollectorFixture()
        defer { fixture.remove() }
        try fixture.legacyAuthority("replaced-authority", createdAt: fixture.yesterday)
        try fixture.legacyAuthority("late-terminal", createdAt: fixture.yesterday)
        let mover = SessionCollectorMover(destination: fixture.trash.path)
        let report = try await fixture.collector(trash: mover, beforeRevalidation: { path in
            let directory = URL(fileURLWithPath: path)
            if directory.lastPathComponent == "replaced-authority" {
                let evidence = directory.appendingPathComponent("development-session.json")
                let bytes = try Data(contentsOf: evidence)
                try FileManager.default.removeItem(at: evidence)
                try bytes.write(to: evidence)
                #expect(chmod(evidence.path, 0o400) == 0)
            } else {
                let manifest = directory.appendingPathComponent("manifest.json")
                try Data("{}".utf8).write(to: manifest)
                #expect(chmod(manifest.path, 0o400) == 0)
            }
        }).run(execute: true)
        for name in ["replaced-authority", "late-terminal"] {
            #expect(report.entries.first { $0.name == name }?.action == .skippedRevalidation)
            #expect(FileManager.default.fileExists(atPath: fixture.session(name).path))
        }
        #expect(mover.calls.withLock { $0 } == 0)
    }

    @Test func yesterdayStartWithTodaysNestedLogRetainsTheSession() async throws {
        let fixture = try SessionCollectorFixture()
        defer { fixture.remove() }
        let name = try await fixture.swiftProgress(startedAt: fixture.yesterday)
        let nested = fixture.session(name).appendingPathComponent("nested/logs")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let log = nested.appendingPathComponent("native.log")
        try Data("today's native output".utf8).write(to: log)
        try fixture.ageTree(name, modifiedAt: fixture.yesterday)
        try FileManager.default.setAttributes([.modificationDate: fixture.today], ofItemAtPath: log.path)
        let mover = SessionCollectorMover(destination: fixture.trash.path)
        let report = try await fixture.collector(trash: mover).run(execute: true)
        #expect(report.entries.first { $0.name == name }?.classification == .retained)
        #expect(FileManager.default.fileExists(atPath: log.path))
        #expect(mover.calls.withLock { $0 } == 0)
    }

    @Test func inactiveTraversalBoundsFutureDatesAndSymlinksProtectEvidence() async throws {
        let fixture = try SessionCollectorFixture()
        defer { fixture.remove() }
        let bounded = try await fixture.swiftProgress(startedAt: fixture.yesterday)
        for index in 0..<NotikaSessionRetentionCollector.maximumInactiveDirectories {
            try FileManager.default.createDirectory(at: fixture.session(bounded).appendingPathComponent("directory-\(index)"),
                withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try fixture.ageTree(bounded, modifiedAt: fixture.yesterday)
        let future = try await fixture.swiftProgress(startedAt: fixture.yesterday)
        try FileManager.default.setAttributes([.modificationDate: fixture.now.addingTimeInterval(1)],
            ofItemAtPath: fixture.session(future).appendingPathComponent("in-progress.json").path)
        let linked = try await fixture.swiftProgress(startedAt: fixture.yesterday)
        try FileManager.default.createSymbolicLink(at: fixture.session(linked).appendingPathComponent("foreign"),
            withDestinationURL: fixture.root)
        // Restore only the containing directory's age; the link stays unsafe.
        try FileManager.default.setAttributes([.modificationDate: fixture.yesterday], ofItemAtPath: fixture.session(linked).path)
        let mover = SessionCollectorMover(destination: fixture.trash.path)
        let report = try await fixture.collector(trash: mover).run(execute: true)
        for name in [bounded, future, linked] {
            #expect(report.entries.first { $0.name == name }?.reason == .activityUncertain)
            #expect(FileManager.default.fileExists(atPath: fixture.session(name).path))
        }
        #expect(mover.calls.withLock { $0 } == 0)
    }

    @Test(arguments: StandaloneSessionFamily.allCases)
    func finalizedStandaloneSessionsUseTheirStrictReaderAndSingleLinkCustody(family: StandaloneSessionFamily) async throws {
        let fixture = try SessionCollectorFixture()
        defer { fixture.remove() }
        let yesterday = try await fixture.standaloneSession(family, completedAt: fixture.yesterday)
        let today = try await fixture.standaloneSession(family, completedAt: fixture.today)
        let bytes = try Data(contentsOf: fixture.manifest(yesterday))
        #expect(try family.lifecycle(data: bytes, repository: fixture.path, sessionID: yesterday) == "terminal")
        var physical = stat()
        #expect(lstat(fixture.manifest(yesterday).path, &physical) == 0)
        #expect(physical.st_mode & 0o7777 == 0o400)
        #expect(physical.st_nlink == 1)
        let mover = SessionCollectorMover(destination: fixture.trash.path)
        let report = try await fixture.collector(trash: mover).run(execute: true)
        #expect(report.rootState == .ready)
        #expect(report.entries.first { $0.name == yesterday }?.action == .trashed)
        #expect(report.entries.first { $0.name == today }?.classification == .retained)
        #expect(try Data(contentsOf: fixture.trash.appendingPathComponent(yesterday + "/manifest.json")) == bytes)
        #expect(FileManager.default.fileExists(atPath: fixture.session(today).path))
    }

    @Test(arguments: StandaloneSessionFamily.allCases)
    func misplacedProgressFutureAndExplicitlyKeptStandaloneSessionsStayProtected(family: StandaloneSessionFamily) async throws {
        let fixture = try SessionCollectorFixture()
        defer { fixture.remove() }
        let misplacedProgress = try await fixture.standaloneSession(family, completedAt: nil)
        let future = try await fixture.standaloneSession(family, completedAt: fixture.now.addingTimeInterval(3_600))
        let kept = try await fixture.standaloneSession(family, completedAt: fixture.yesterday)
        try fixture.keep(kept, expiresAt: fixture.now.addingTimeInterval(86_400))
        // A progress record copied to the terminal name is malformed final
        // evidence. Historical raw admission is restricted to terminal records.
        let progress = fixture.session(misplacedProgress).appendingPathComponent("in-progress.json")
        try Data(contentsOf: progress).write(to: fixture.manifest(misplacedProgress))
        guard chmod(fixture.manifest(misplacedProgress).path, 0o400) == 0 else { throw SessionCollectorFixtureError.io }
        let mover = SessionCollectorMover(destination: fixture.trash.path)
        let report = try await fixture.collector(trash: mover).run(execute: true)
        #expect(report.entries.first { $0.name == misplacedProgress }?.classification == .invalid)
        #expect(report.entries.first { $0.name == misplacedProgress }?.reason == .manifestInvalid)
        #expect(report.entries.first { $0.name == misplacedProgress }?.action == NotikaSessionRetentionAction.none)
        #expect(report.entries.first { $0.name == future }?.reason == .lifecycleInFuture)
        #expect(report.entries.first { $0.name == kept }?.retentionSource == .keep)
        #expect(report.entries.first { $0.name == kept }?.classification == .retained)
        #expect(mover.calls.withLock { $0 } == 0)
    }

    @Test(arguments: StandaloneSessionFamily.allCases)
    func unsupportedStandaloneSchemaAndAdditionalManifestLinkRemainProtected(family: StandaloneSessionFamily) async throws {
        let fixture = try SessionCollectorFixture()
        defer { fixture.remove() }
        let malformed = try await fixture.standaloneSession(family, completedAt: fixture.yesterday)
        let linked = try await fixture.standaloneSession(family, completedAt: fixture.yesterday)
        let original = try StrictJSONDocument(data: Data(contentsOf: fixture.manifest(malformed)))
        guard case .object(let members) = try controllerCanonical(original.root) else { throw SessionCollectorFixtureError.io }
        let futureShape = CanonicalJSONValue.object(members.map { member in
            member.key == "schemaVersion" ? CanonicalJSONMember(key: member.key, value: .integer(2)) : member
        })
        guard chmod(fixture.manifest(malformed).path, 0o600) == 0 else { throw SessionCollectorFixtureError.io }
        try CanonicalJSONDigest.encode(futureShape).write(to: fixture.manifest(malformed))
        guard chmod(fixture.manifest(malformed).path, 0o400) == 0 else { throw SessionCollectorFixtureError.io }
        try FileManager.default.linkItem(at: fixture.manifest(linked), to: fixture.root.appendingPathComponent("outside-standalone-link"))
        let mover = SessionCollectorMover(destination: fixture.trash.path)
        let report = try await fixture.collector(trash: mover).run(execute: true)
        #expect(report.entries.first { $0.name == malformed }?.reason == .manifestInvalid)
        #expect(report.entries.first { $0.name == linked }?.reason == .manifestInvalid)
        #expect(mover.calls.withLock { $0 } == 0)
    }

    @Test(arguments: StandaloneSessionFamily.allCases)
    func copiedStandaloneDirectoryCannotBorrowTheFinalizedManifest(family: StandaloneSessionFamily) async throws {
        let fixture = try SessionCollectorFixture()
        defer { fixture.remove() }
        let original = try await fixture.standaloneSession(family, completedAt: fixture.yesterday)
        let retained = fixture.root.appendingPathComponent("retained-original")
        try FileManager.default.moveItem(at: fixture.session(original), to: retained)
        try FileManager.default.copyItem(at: retained, to: fixture.session(original))
        let mover = SessionCollectorMover(destination: fixture.trash.path)
        let report = try await fixture.collector(trash: mover).run(execute: true)
        #expect(report.rootState == .ready)
        #expect(report.entries.first { $0.name == original }?.reason == .manifestInvalid)
        #expect(FileManager.default.fileExists(atPath: fixture.manifest(original).path))
        #expect(FileManager.default.fileExists(atPath: retained.appendingPathComponent("manifest.json").path))
        #expect(mover.calls.withLock { $0 } == 0)
    }

    @Test func finalizedYesterdayMovesWhileTodayStaysAndNativeReportBytesSurvive() async throws {
        let fixture = try SessionCollectorFixture()
        defer { fixture.remove() }
        let yesterday = try await fixture.swiftSession(completedAt: fixture.yesterday)
        let today = try await fixture.swiftSession(completedAt: fixture.today)
        let original = try Data(contentsOf: fixture.manifest(yesterday))
        let mover = SessionCollectorMover(destination: fixture.trash.path)
        let report = try await fixture.collector(trash: mover).run(execute: true)
        #expect(report.rootState == .ready)
        #expect(report.scanComplete)
        #expect(report.policy == .todayOnlySessions)
        #expect(report.entries.first { $0.name == yesterday }?.action == .trashed)
        #expect(report.entries.first { $0.name == today }?.classification == .retained)
        #expect(!FileManager.default.fileExists(atPath: fixture.session(yesterday).path))
        #expect(FileManager.default.fileExists(atPath: fixture.session(today).path))
        #expect(try Data(contentsOf: fixture.trash.appendingPathComponent(yesterday + "/manifest.json")) == original)
        #expect(mover.borrowedDescriptorCount.withLock { $0 } >= 9)
        let resources = ["notika:sessions:" + fixture.path,
            try CacheCompatibilityIdentity.cachePolicyResourceName(canonicalWorktree: fixture.path),
            try NotikaRustCacheRetentionCollector.policyResource(canonicalRepository: fixture.path)]
        for resource in resources {
            let lockPath = fixture.registry + "/locks/" + (try ResourceName(resource)).lockFileName
            var physical = stat()
            #expect(lstat(lockPath, &physical) == 0)
            let identity = SessionCollectorDescriptorIdentity(physical)
            #expect(mover.borrowedIdentities.withLock { $0.contains(identity) })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.path + "/Artifacts/AgentSessionTrashClaims").isEmpty)
        let escaped = try #require(mover.source.withLock { $0 })
        #expect(throws: ArtifactTrashError.retiredSource) { try escaped.revalidateBeforeMove() }
    }

    @Test func sharedActiveWriterBlocksWholeCollectorWithoutScanningOrMoving() async throws {
        let fixture = try SessionCollectorFixture()
        defer { fixture.remove() }
        _ = try await fixture.swiftSession(completedAt: fixture.yesterday)
        let mover = SessionCollectorMover(destination: fixture.trash.path)
        try await NotikaBuildSession.withSession(canonicalRepository: fixture.path, registryRoot: fixture.registry,
                                                request: fixture.request, startedAt: fixture.today) { session in
            let report = try await fixture.collector(trash: mover).run(execute: true)
            #expect(report.rootState == .busy)
            #expect(report.rootReason == .namespaceBusy)
            #expect(!report.scanComplete)
            #expect(report.entries.isEmpty)
            #expect(mover.calls.withLock { $0 } == 0)
            try session.publishTerminal(.init(orchestrationFailures: ["fixture"]), completedAt: fixture.today)
        }
    }

    @Test(arguments: ["xcode", "rust"])
    func orphanCachePolicyWithoutSessionWriterProtectsAbandonedEvidence(namespace: String) async throws {
        let fixture = try SessionCollectorFixture()
        defer { fixture.remove() }
        try fixture.legacyAuthority("abandoned-parent", createdAt: fixture.yesterday)
        let evidence = fixture.session("abandoned-parent").appendingPathComponent("development-session.json")
        let original = try Data(contentsOf: evidence)
        let paths = try AgentLeasePaths.open(selectedRoot: fixture.registry)
        let resource: String
        if namespace == "xcode" {
            resource = try CacheCompatibilityIdentity.cachePolicyResourceName(canonicalWorktree: fixture.path)
        } else {
            resource = try NotikaRustCacheRetentionCollector.policyResource(canonicalRepository: fixture.path)
        }
        let orphanPolicy = try FileLock(resource: ResourceName(resource), mode: .shared, paths: paths)
        #expect(try orphanPolicy.tryAcquire())
        defer { orphanPolicy.release() }
        // The parent's session writer is genuinely free, while its child's
        // inherited shared cache policy still provides live kernel custody.
        let sessionProbe = try FileLock(resource: ResourceName("notika:sessions:" + fixture.path), paths: paths)
        #expect(try sessionProbe.tryAcquire())
        sessionProbe.release()
        let mover = SessionCollectorMover(destination: fixture.trash.path)
        let report = try await fixture.collector(trash: mover).run(execute: true)
        #expect(report.rootState == .busy)
        #expect(report.rootReason == .cachePolicyBusy)
        #expect(!report.scanComplete && report.entries.isEmpty)
        #expect(try Data(contentsOf: evidence) == original)
        #expect(mover.calls.withLock { $0 } == 0)
        // A failed second-policy acquisition also releases the first policy
        // and session writer, so the collector cannot strand namespace locks.
        let releasedSession = try FileLock(resource: ResourceName("notika:sessions:" + fixture.path), paths: paths)
        #expect(try releasedSession.tryAcquire())
        releasedSession.release()
        if namespace == "rust" {
            let releasedXcode = try FileLock(resource: ResourceName(
                CacheCompatibilityIdentity.cachePolicyResourceName(canonicalWorktree: fixture.path)), paths: paths)
            #expect(try releasedXcode.tryAcquire())
            releasedXcode.release()
        }
        orphanPolicy.release()
        let inactive = try await fixture.collector(trash: mover).run(execute: true)
        #expect(inactive.entries.first { $0.name == "abandoned-parent" }?.action == .trashed)
    }

    @Test func dryRunHasNoClaimsAndProtectsFutureMissingUnknownAndDuplicateEvidence() async throws {
        let fixture = try SessionCollectorFixture()
        defer { fixture.remove() }
        let old = try await fixture.swiftSession(completedAt: fixture.yesterday)
        let future = try await fixture.swiftSession(completedAt: fixture.now.addingTimeInterval(3_600))
        try fixture.rawSession("unfinished", bytes: nil)
        try fixture.rawSession("foreign-schema", bytes: Data(#"{"schemaVersion":1,"resourceID":"other","status":"succeeded"}"#.utf8))
        try fixture.rawSession("duplicate-fields", bytes: Data(#"{"schemaVersion":1,"schemaVersion":1}"#.utf8))
        let mover = SessionCollectorMover(destination: fixture.trash.path)
        let report = try await fixture.collector(trash: mover).run(execute: false)
        #expect(report.entries.first { $0.name == old }?.action == .wouldTrash)
        #expect(report.entries.first { $0.name == future }?.reason == .lifecycleInFuture)
        #expect(report.entries.first { $0.name == "unfinished" }?.classification == .incomplete)
        #expect(report.entries.first { $0.name == "foreign-schema" }?.reason == .unknownSchema)
        #expect(report.entries.first { $0.name == "duplicate-fields" }?.reason == .manifestInvalid)
        #expect(mover.calls.withLock { $0 } == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "/Artifacts/AgentSessionTrashClaims"))
    }

    @Test func boundKeepOverridesDailyExpiryAndExpiredKeepCanMove() async throws {
        let fixture = try SessionCollectorFixture()
        defer { fixture.remove() }
        let kept = try await fixture.swiftSession(completedAt: fixture.yesterday)
        let expired = try await fixture.swiftSession(completedAt: fixture.yesterday)
        try fixture.keep(kept, expiresAt: fixture.now.addingTimeInterval(86_400))
        try fixture.keep(expired, expiresAt: fixture.now.addingTimeInterval(-3_600))
        let report = try await fixture.collector().run(execute: false)
        let protected = try #require(report.entries.first { $0.name == kept })
        #expect(protected.classification == .retained)
        #expect(protected.retentionSource == .keep)
        #expect(protected.keepDigest != nil)
        let old = try #require(report.entries.first { $0.name == expired })
        #expect(old.action == .wouldTrash)
        #expect(old.reason == .keepExpiryReached)
    }

    @Test(arguments: ["digest", "owner", "future-issue", "future-microsecond", "invalid-day", "too-long", "extra-field"])
    func invalidKeepNeverFallsBackToDailyExpiry(_ fault: String) async throws {
        let fixture = try SessionCollectorFixture()
        defer { fixture.remove() }
        let session = try await fixture.swiftSession(completedAt: fixture.yesterday)
        try fixture.keep(session, expiresAt: fixture.now.addingTimeInterval(86_400), fault: fault)
        let mover = SessionCollectorMover(destination: fixture.trash.path)
        let report = try await fixture.collector(trash: mover).run(execute: true)
        #expect(report.entries.first?.classification == .invalid)
        #expect(report.entries.first?.reason == .keepInvalid)
        #expect(mover.calls.withLock { $0 } == 0)
        #expect(FileManager.default.fileExists(atPath: fixture.session(session).path))
    }

    @Test func exactLegacySchemaGetsDailyCutoffAndUnknownExtraFieldsStayProtected() async throws {
        let fixture = try SessionCollectorFixture()
        defer { fixture.remove() }
        try fixture.legacySession("legacy-finalized")
        try fixture.legacySession("legacy-extended", extraField: true)
        let report = try await fixture.collector().run(execute: false)
        let eligible = try #require(report.entries.first { $0.name == "legacy-finalized" })
        #expect(eligible.action == .wouldTrash)
        #expect(eligible.retentionSource == .todayOnly)
        #expect(eligible.effectiveExpiresAt == report.localDayCutoff)
        #expect(report.entries.first { $0.name == "legacy-extended" }?.classification == .invalid)
    }

    @Test(arguments: LegacyStageSessionFamily.allCases)
    func legacyPublicationStageLinksMoveWithOriginalEvidenceBytes(family: LegacyStageSessionFamily) async throws {
        let fixture = try SessionCollectorFixture()
        defer { fixture.remove() }
        let name = "legacy-staged-" + family.rawValue
        try fixture.legacyStageSession(name, family: family)
        var originalBytes: [String: Data] = [:]
        for evidenceName in family.evidenceNames {
            let evidence = fixture.session(name).appendingPathComponent(evidenceName)
            let stage = try fixture.legacyStageLink(name, evidenceName: evidenceName)
            originalBytes[evidenceName] = try Data(contentsOf: evidence)
            var publicStatus = stat(), privateStatus = stat()
            try #require(lstat(evidence.path, &publicStatus) == 0)
            try #require(lstat(stage.path, &privateStatus) == 0)
            #expect(publicStatus.st_nlink == 2)
            #expect(publicStatus.st_ino == privateStatus.st_ino)
            #expect(publicStatus.st_dev == privateStatus.st_dev)
        }
        try fixture.ageTree(name, modifiedAt: fixture.yesterday)
        let preview = try await fixture.collector().run(execute: false)
        let eligible = try #require(preview.entries.first { $0.name == name })
        #expect(eligible.action == .wouldTrash)
        #expect(eligible.retentionSource == .todayOnly)
        if family == .authority {
            #expect(eligible.reason == .abandonedBeforeLocalDay)
            #expect(eligible.manifestDigest == nil)
        }
        let mover = SessionCollectorMover(destination: fixture.trash.path)
        let moved = try await fixture.collector(trash: mover).run(execute: true)
        #expect(moved.entries.first { $0.name == name }?.action == .trashed)
        #expect(mover.calls.withLock { $0 } == 1)
        let retained = fixture.trash.appendingPathComponent(name)
        for evidenceName in family.evidenceNames {
            let evidence = retained.appendingPathComponent(evidenceName)
            let stage = retained.appendingPathComponent(fixture.legacyStageName(evidenceName))
            #expect(try Data(contentsOf: evidence) == originalBytes[evidenceName])
            #expect(try Data(contentsOf: stage) == originalBytes[evidenceName])
            var publicStatus = stat(), privateStatus = stat()
            try #require(lstat(evidence.path, &publicStatus) == 0)
            try #require(lstat(stage.path, &privateStatus) == 0)
            #expect(publicStatus.st_nlink == 2)
            #expect(publicStatus.st_ino == privateStatus.st_ino)
        }
        if family == .authority {
            #expect(!FileManager.default.fileExists(atPath: retained.appendingPathComponent("manifest.json").path))
        }
    }

    @Test(arguments: ["external", "unrecognized", "third-link"])
    func legacyEvidenceAliasesOutsideThePublicationContractRemainProtected(aliasKind: String) async throws {
        let fixture = try SessionCollectorFixture()
        defer { fixture.remove() }
        var names: [String] = []
        for family in LegacyStageSessionFamily.allCases {
            for evidenceName in family.evidenceNames {
                let name = family.rawValue + "-" + evidenceName
                names.append(name)
                try fixture.legacyStageSession(name, family: family)
                for peer in family.evidenceNames where peer != evidenceName || aliasKind == "third-link" {
                    _ = try fixture.legacyStageLink(name, evidenceName: peer)
                }
                let evidence = fixture.session(name).appendingPathComponent(evidenceName)
                let alias = aliasKind == "unrecognized"
                    ? fixture.session(name).appendingPathComponent("unrecognized-" + evidenceName)
                    : fixture.root.appendingPathComponent(name + "-outside")
                try FileManager.default.linkItem(at: evidence, to: alias)
                try fixture.ageTree(name, modifiedAt: fixture.yesterday)
            }
        }
        let mover = SessionCollectorMover(destination: fixture.trash.path)
        let report = try await fixture.collector(trash: mover).run(execute: true)
        for name in names {
            let entry = try #require(report.entries.first { $0.name == name })
            #expect(entry.reason == .manifestInvalid)
            #expect(entry.action == NotikaSessionRetentionAction.none)
            #expect(FileManager.default.fileExists(atPath: fixture.session(name).path))
        }
        #expect(mover.calls.withLock { $0 } == 0)
    }

    @Test(arguments: ["zero-pid", "leading-zero-pid", "overflow-pid", "negative-pid", "uppercase-token", "short-token"])
    func legacyStageNamesRequireTheExactProducerPIDAndTokenShape(fault: String) async throws {
        let fixture = try SessionCollectorFixture()
        defer { fixture.remove() }
        let name = "malformed-stage"
        try fixture.legacySession(name)
        let token = String(repeating: "a", count: 32)
        let suffix: String
        switch fault {
        case "zero-pid": suffix = "0." + token
        case "leading-zero-pid": suffix = "056835." + token
        case "overflow-pid": suffix = "2147483648." + token
        case "negative-pid": suffix = "-1." + token
        case "uppercase-token": suffix = "56835." + String(repeating: "A", count: 32)
        default: suffix = "56835." + String(repeating: "a", count: 31)
        }
        try FileManager.default.linkItem(at: fixture.manifest(name),
            to: fixture.session(name).appendingPathComponent(".manifest.json." + suffix + ".stage"))
        let mover = SessionCollectorMover(destination: fixture.trash.path)
        let report = try await fixture.collector(trash: mover).run(execute: true)
        #expect(report.entries.first { $0.name == name }?.reason == .manifestInvalid)
        #expect(FileManager.default.fileExists(atPath: fixture.manifest(name).path))
        #expect(mover.calls.withLock { $0 } == 0)
    }

    @Test(arguments: ["removed", "replaced"])
    func admittedLegacyStageAliasChangesBlockRevalidation(change: String) async throws {
        let fixture = try SessionCollectorFixture()
        defer { fixture.remove() }
        var targets: [String: String] = [:]
        for family in LegacyStageSessionFamily.allCases {
            for evidenceName in family.evidenceNames {
                let name = family.rawValue + "-" + evidenceName
                targets[name] = evidenceName
                try fixture.legacyStageSession(name, family: family)
                for peer in family.evidenceNames {
                    _ = try fixture.legacyStageLink(name, evidenceName: peer)
                }
                try fixture.ageTree(name, modifiedAt: fixture.yesterday)
            }
        }
        let stageTargets = targets
        let mover = SessionCollectorMover(destination: fixture.trash.path)
        let report = try await fixture.collector(trash: mover, beforeRevalidation: { path in
            let directory = URL(fileURLWithPath: path)
            let evidenceName = try #require(stageTargets[directory.lastPathComponent])
            let stage = directory.appendingPathComponent(fixture.legacyStageName(evidenceName))
            let bytes = try Data(contentsOf: stage)
            try FileManager.default.removeItem(at: stage)
            if change == "replaced" {
                // Identical bytes at the private name do not retain inode custody.
                try bytes.write(to: stage)
                try #require(chmod(stage.path, 0o400) == 0)
            }
        }).run(execute: true)
        for name in stageTargets.keys {
            let entry = try #require(report.entries.first { $0.name == name })
            #expect(entry.action == .skippedRevalidation)
            #expect(entry.reason == .evidenceChanged)
            #expect(FileManager.default.fileExists(atPath: fixture.session(name).path))
        }
        #expect(mover.calls.withLock { $0 } == 0)
    }

    @Test func malformedCalendarDateAndMicrosecondFutureCompletionRemainProtected() async throws {
        let fixture = try SessionCollectorFixture()
        defer { fixture.remove() }
        try fixture.legacySession("invalid-calendar", timestampFault: "invalid-day")
        try fixture.legacySession("future-microsecond", timestampFault: "future-microsecond")
        let report = try await fixture.collector().run(execute: false)
        #expect(report.entries.first { $0.name == "invalid-calendar" }?.classification == .invalid)
        #expect(report.entries.first { $0.name == "future-microsecond" }?.reason == .lifecycleInFuture)
        #expect(report.entries.allSatisfy { $0.action == .none })
    }

    @Test func originalAndResultAwareBuildFormsRemainEligibleButUnpairedResultCommitmentStaysProtected() async throws {
        let fixture = try SessionCollectorFixture()
        defer { fixture.remove() }
        let old = try await fixture.swiftSession(completedAt: fixture.yesterday)
        let current = try await fixture.swiftSession(completedAt: fixture.yesterday)
        let broken = try await fixture.swiftSession(completedAt: fixture.yesterday)
        try fixture.transformSealedManifest(old, resultEvidence: "original")
        try fixture.transformSealedManifest(broken, resultEvidence: "unpaired")
        let oldBytes = try Data(contentsOf: fixture.manifest(old))
        let currentBytes = try Data(contentsOf: fixture.manifest(current))
        let oldObject = try StrictJSONDocument(data: oldBytes).root.requireObject()
        #expect(oldObject.value(forKey: "resultEvidence") == nil)
        #expect(try NotikaBuildSessionReport(data: oldBytes).lifecycle == "terminal")
        #expect(try StrictJSONDocument(data: currentBytes).root.requireObject().value(forKey: "resultEvidence") == .null)
        let report = try await fixture.collector().run(execute: false)
        #expect(report.entries.first { $0.name == old }?.action == .wouldTrash)
        #expect(report.entries.first { $0.name == current }?.action == .wouldTrash)
        #expect(report.entries.first { $0.name == broken }?.reason == .manifestInvalid)
    }

    @Test func manifestMutationAndNewKeepBetweenAdmissionAndMoveAreProtected() async throws {
        let fixture = try SessionCollectorFixture()
        defer { fixture.remove() }
        let old = try await fixture.swiftSession(completedAt: fixture.yesterday)
        let mover = SessionCollectorMover(destination: fixture.trash.path)
        let report = try await fixture.collector(trash: mover, beforeRevalidation: { path in
            let manifest = path + "/manifest.json"
            guard chmod(manifest, 0o600) == 0 else { throw SessionCollectorFixtureError.io }
            try Data("replacement".utf8).write(to: URL(fileURLWithPath: manifest))
            guard chmod(manifest, 0o400) == 0 else { throw SessionCollectorFixtureError.io }
        }).run(execute: true)
        #expect(report.entries.first?.action == .skippedRevalidation)
        #expect(mover.calls.withLock { $0 } == 0)
        #expect(try Data(contentsOf: fixture.manifest(old)) == Data("replacement".utf8))
        let second = try SessionCollectorFixture()
        defer { second.remove() }
        let next = try await second.swiftSession(completedAt: second.yesterday)
        let changed = try await second.collector(beforeRevalidation: { _ in
            try second.keep(next, expiresAt: second.now.addingTimeInterval(86_400))
        }).run(execute: true)
        #expect(changed.entries.first?.action == .skippedRevalidation)
        #expect(FileManager.default.fileExists(atPath: second.session(next).path))
    }

    @Test func trashFailureRestoresOnlyExactAdmittedSourceAndRetiresCapability() async throws {
        let fixture = try SessionCollectorFixture()
        defer { fixture.remove() }
        let old = try await fixture.swiftSession(completedAt: fixture.yesterday)
        let bytes = try Data(contentsOf: fixture.manifest(old))
        let mover = SessionCollectorMover(destination: fixture.trash.path, fail: true)
        let report = try await fixture.collector(trash: mover).run(execute: true)
        #expect(report.entries.first?.action == .trashFailed)
        #expect(try Data(contentsOf: fixture.manifest(old)) == bytes)
        let escaped = try #require(mover.source.withLock { $0 })
        #expect(throws: ArtifactTrashError.retiredSource) { try escaped.inheritedDescriptors() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.path + "/Artifacts/AgentSessionTrashClaims").isEmpty)
    }

    @Test(arguments: [1, 2])
    func descriptorFailureAroundClaimConstructionLeavesSourceAndNoEmptyClaims(_ failureCall: Int) async throws {
        let fixture = try SessionCollectorFixture()
        defer { fixture.remove() }
        let session = try await fixture.swiftSession(completedAt: fixture.yesterday)
        let bytes = try Data(contentsOf: fixture.manifest(session))
        let calls = Mutex(0)
        let mover = SessionCollectorMover(destination: fixture.trash.path)
        let collector = try NotikaSessionRetentionCollector(canonicalRepository: fixture.path, registryRoot: fixture.registry,
            evaluatedAt: fixture.now, timeZone: fixture.zone, trashOperator: mover,
            claimDirectoryFactory: { path in
                let count = calls.withLock { $0 += 1; return $0 }
                if count == failureCall { throw RetainedArtifactError.systemCall("open injected claim", EMFILE) }
                return try RetainedArtifactDirectory(path: path, requiredPermissions: 0o700)
            })
        let report = try await collector.run(execute: true)
        #expect(report.entries.first?.action == .trashFailed)
        #expect(mover.calls.withLock { $0 } == 0)
        #expect(try Data(contentsOf: fixture.manifest(session)) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.path + "/Artifacts/AgentSessionTrashClaims").isEmpty)
        let next = try await fixture.collector().run(execute: false)
        #expect(next.rootState == .ready)
        #expect(next.entries.first?.action == .wouldTrash)
    }

    @Test func claimConstructionFailureCannotRemoveReplacementEmptyDirectory() async throws {
        let fixture = try SessionCollectorFixture()
        defer { fixture.remove() }
        let session = try await fixture.swiftSession(completedAt: fixture.yesterday)
        let foreignPath = Mutex<String?>(nil)
        let collector = try NotikaSessionRetentionCollector(canonicalRepository: fixture.path, registryRoot: fixture.registry,
            evaluatedAt: fixture.now, timeZone: fixture.zone,
            trashOperator: SessionCollectorMover(destination: fixture.trash.path),
            claimDirectoryFactory: { path in
                try FileManager.default.moveItem(atPath: path, toPath: fixture.path + "/retained-original-placeholder")
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false,
                                                       attributes: [.posixPermissions: 0o700])
                foreignPath.withLock { $0 = path }
                throw RetainedArtifactError.systemCall("open injected claim", EMFILE)
            })
        let report = try await collector.run(execute: true)
        #expect(report.entries.first?.action == .trashFailed)
        let replacement = try #require(foreignPath.withLock { $0 })
        #expect(FileManager.default.fileExists(atPath: replacement))
        #expect(try FileManager.default.contentsOfDirectory(atPath: replacement).isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.session(session).path))
        let next = try await fixture.collector().run(execute: false)
        #expect(next.rootState == .unsafe)
        #expect(next.rootReason == .pendingTrashClaims)
    }

    @Test func foreignReplacementAtOriginalNameIsPreservedAndClaimQuarantined() async throws {
        let fixture = try SessionCollectorFixture()
        defer { fixture.remove() }
        let old = try await fixture.swiftSession(completedAt: fixture.yesterday)
        let mover = SessionCollectorMover(destination: fixture.trash.path, fail: true, replaceOriginal: true)
        let report = try await fixture.collector(trash: mover).run(execute: true)
        #expect(report.entries.first?.action == .trashFailed)
        #expect(try Data(contentsOf: fixture.session(old).appendingPathComponent("preserve")) == Data("foreign".utf8))
        let next = try await fixture.collector(trash: mover).run(execute: true)
        #expect(next.rootState == .unsafe)
        #expect(next.rootReason == .pendingTrashClaims)
        #expect(mover.calls.withLock { $0 } == 1)
    }

    @Test func rootBoundAndSymlinkEntriesCannotReachMover() async throws {
        let fixture = try SessionCollectorFixture()
        defer { fixture.remove() }
        _ = try await fixture.swiftSession(completedAt: fixture.yesterday)
        for index in 0..<NotikaSessionRetentionCollector.maximumRootEntries {
            try fixture.rawSession("unknown-\(index)", bytes: nil)
        }
        let mover = SessionCollectorMover(destination: fixture.trash.path)
        let report = try await fixture.collector(trash: mover).run(execute: true)
        #expect(report.rootState == .entryBoundExceeded)
        #expect(!report.scanComplete)
        #expect(report.entries.isEmpty)
        #expect(mover.calls.withLock { $0 } == 0)
        let second = try SessionCollectorFixture()
        defer { second.remove() }
        _ = try await second.swiftSession(completedAt: second.today)
        try FileManager.default.createSymbolicLink(atPath: second.path + "/Artifacts/AgentSessions/linked", withDestinationPath: fixture.path)
        let linked = try await second.collector(trash: mover).run(execute: true)
        #expect(linked.entries.first { $0.name == "linked" }?.classification == .invalid)
        #expect(mover.calls.withLock { $0 } == 0)
    }

    @Test func forgedDirectoryBindingAndMissingPrivateSealedLinkAreProtected() async throws {
        let fixture = try SessionCollectorFixture()
        defer { fixture.remove() }
        let old = try await fixture.swiftSession(completedAt: fixture.yesterday)
        let peer = try #require(FileManager.default.contentsOfDirectory(atPath: fixture.session(old).path)
            .first { $0.hasPrefix(".agentbuild-manifest.json-") })
        try FileManager.default.removeItem(at: fixture.session(old).appendingPathComponent(peer))
        let report = try await fixture.collector().run(execute: true)
        #expect(report.entries.first?.classification == .invalid)
        #expect(report.entries.first?.reason == .manifestInvalid)
        let second = try SessionCollectorFixture()
        defer { second.remove() }
        let original = try await second.swiftSession(completedAt: second.yesterday)
        let copy = UUID().uuidString
        try FileManager.default.copyItem(at: second.session(original), to: second.session(copy))
        let forged = try await second.collector().run(execute: false)
        #expect(forged.entries.first { $0.name == copy }?.classification == .invalid)
    }
}

enum StandaloneSessionFamily: CaseIterable, Sendable {
    case generation, rust, preflight, documentation

    func lifecycle(data: Data, repository: String, sessionID: String) throws -> String {
        switch self {
        case .generation:
            try NotikaGenerationSessionReport(data: data, expectedRepository: repository, expectedSessionID: sessionID).lifecycle
        case .rust:
            try NotikaRustTestSessionReport(data: data, expectedRepository: repository, expectedSessionID: sessionID).lifecycle
        case .preflight:
            try NotikaPreflightSessionReport(data: data, expectedRepository: repository, expectedSessionID: sessionID).lifecycle
        case .documentation:
            try NotikaDocumentationSessionReport(data: data, expectedRepository: repository, expectedSessionID: sessionID).lifecycle
        }
    }
}

enum LegacyStageSessionFamily: String, CaseIterable, Sendable {
    case terminal, authority, abandoned

    var evidenceNames: [String] {
        switch self {
        case .terminal: ["manifest.json"]
        case .authority: ["development-session.json"]
        case .abandoned: ["manifest.json", "development-session.json"]
        }
    }
}

private enum SessionCollectorFixtureError: Error { case io }

private struct SessionCollectorFixture: Sendable {
    let root: URL
    let path: String
    var registry: String { path + "/registry" }
    var trash: URL { root.appendingPathComponent("fake-trash") }
    let zone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_791_633_600) // 2026-10-10 12:00 UTC
    var yesterday: Date { now.addingTimeInterval(-86_400) }
    var today: Date { now.addingTimeInterval(-3_600) }
    var request: NotikaActionRequest { get throws { try NotikaActionRequest(makeRoute: .buildMacOS) } }
    init() throws {
        let proposed = FileManager.default.temporaryDirectory.appendingPathComponent("session-retention-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: proposed, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let canonical = realpath(proposed.path, nil) else { throw SessionCollectorFixtureError.io }
        defer { free(canonical) }
        path = String(cString: canonical)
        root = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func session(_ name: String) -> URL { root.appendingPathComponent("Artifacts/AgentSessions/" + name) }
    func manifest(_ name: String) -> URL { session(name).appendingPathComponent("manifest.json") }
    func legacyStageSession(_ name: String, family: LegacyStageSessionFamily) throws {
        if family == .terminal { try legacySession(name) }
        else { try legacyAuthority(name, createdAt: yesterday, finalized: family == .abandoned) }
    }
    func legacyStageName(_ evidenceName: String) -> String {
        "." + evidenceName + ".56835.5422e094373afbc0899266aa7b758e5b.stage"
    }
    func legacyStageLink(_ name: String, evidenceName: String) throws -> URL {
        let stage = session(name).appendingPathComponent(legacyStageName(evidenceName))
        try FileManager.default.linkItem(at: session(name).appendingPathComponent(evidenceName), to: stage)
        return stage
    }
    func swiftSession(completedAt: Date) async throws -> String {
        let runID = UUID().uuidString
        _ = try await NotikaBuildSession.withSession(canonicalRepository: path, registryRoot: registry, request: request,
                                                runID: runID, startedAt: completedAt.addingTimeInterval(-1), timeZone: zone) { session in
            try session.publishTerminal(.init(orchestrationFailures: ["fixture native setup"]), completedAt: completedAt)
        }
        return runID
    }
    func swiftProgress(startedAt: Date) async throws -> String {
        // Keep genuine producer-created sealed progress, then model a crash
        // before the final publication by removing only the fixture terminal.
        let name = try await swiftSession(completedAt: startedAt.addingTimeInterval(1))
        try FileManager.default.removeItem(at: manifest(name))
        for child in try FileManager.default.contentsOfDirectory(at: session(name), includingPropertiesForKeys: nil)
            where child.lastPathComponent.hasPrefix(".agentbuild-manifest.json-") && child.lastPathComponent.hasSuffix(".sealed") {
            try FileManager.default.removeItem(at: child)
        }
        try ageTree(name, modifiedAt: startedAt)
        return name
    }
    func standaloneSession(_ family: StandaloneSessionFamily, completedAt: Date?) async throws -> String {
        let runID = UUID().uuidString
        switch family {
        case .generation:
            _ = try await NotikaGenerationSessionReport.publishDiagnosticFixture(repository: path,
                registryRoot: registry, sessionID: runID, startedAt: (completedAt ?? yesterday).addingTimeInterval(-1),
                completedAt: completedAt, timeZone: zone)
        case .rust:
            _ = try await NotikaRustTestSessionReport.publishDiagnosticFixture(repository: path,
                registryRoot: registry, sessionID: runID, startedAt: (completedAt ?? yesterday).addingTimeInterval(-1),
                completedAt: completedAt, timeZone: zone)
        case .preflight:
            _ = try await NotikaPreflightSessionReport.publishDiagnosticFixture(repository: path,
                registryRoot: registry, sessionID: runID, startedAt: (completedAt ?? yesterday).addingTimeInterval(-1),
                completedAt: completedAt, timeZone: zone)
        case .documentation:
            _ = try await NotikaDocumentationSessionReport.publishDiagnosticFixture(repository: path,
                registryRoot: registry, sessionID: runID, startedAt: (completedAt ?? yesterday).addingTimeInterval(-1),
                completedAt: completedAt, timeZone: zone)
        }
        if completedAt == nil { try ageTree(runID, modifiedAt: yesterday) }
        return runID
    }
    func historicalGenerationWithTwoRawStreams() async throws -> String {
        let name = try await standaloneSession(.generation, completedAt: yesterday)
        let capture = session(name).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        func stream(_ leaf: String, _ bytes: Data) throws -> CanonicalJSONValue {
            let path = capture.appendingPathComponent(leaf)
            try bytes.write(to: path); guard chmod(path.path, 0o600) == 0 else { throw SessionCollectorFixtureError.io }
            return .object(["path": .string(path.path), "observedBytes": .integer(Int64(bytes.count)),
                "retainedBytes": .integer(Int64(bytes.count)), "sha256": .string(CanonicalJSONDigest.digest(bytes)), "reachedEOF": .bool(true)])
        }
        let raw = CanonicalJSONValue.object(["standardOutput": try stream("stdout.log", Data("stdout".utf8)),
            "standardError": try stream("stderr.log", Data("stderr".utf8)), "maximumBytes": .integer(NativeLogCapture.maximumRawBytes),
            "captureComplete": .bool(true), "failures": .array([])])
        let termination = CanonicalJSONValue.object(["kind": .string("exit"), "value": .integer(29)])
        let phase = CanonicalJSONValue.object(["step": .string("prepare-htt-mini.sh"),
            "command": .object(["executable": .string(path + "/Scripts/bridges/prepare-htt-mini.sh"), "arguments": .array([]),
                "workingDirectory": .string(path), "environmentSHA256": .string(CanonicalJSONDigest.digest(Data()))]),
            "nativeTermination": termination, "retirement": .string("workerReaped"), "cancelled": .bool(false),
            "failures": .array([]), "rawCapture": raw, "publicationAdmitted": .bool(true)])
        guard case .object(let original) = try sessionCollectorCanonical(StrictJSONDocument(data: Data(contentsOf: manifest(name))).root) else {
            throw SessionCollectorFixtureError.io
        }
        let replacements: [String: CanonicalJSONValue] = ["phases": .array([phase]), "nativeTermination": termination,
            "status": .string("failed"), "exitCode": .integer(29)]
        let changed = CanonicalJSONValue.object(original.map { .init(key: $0.key, value: replacements[$0.key] ?? $0.value) })
        guard chmod(manifest(name).path, 0o600) == 0 else { throw SessionCollectorFixtureError.io }
        try CanonicalJSONDigest.encode(changed).write(to: manifest(name))
        guard chmod(manifest(name).path, 0o400) == 0 else { throw SessionCollectorFixtureError.io }
        try ageTree(name, modifiedAt: yesterday)
        return name
    }
    func collector(
        trash: (any ArtifactTrashOperator)? = nil,
        beforeRevalidation: @escaping @Sendable (String) async throws -> Void = { _ in }
    ) throws -> NotikaSessionRetentionCollector {
        try NotikaSessionRetentionCollector(canonicalRepository: path, registryRoot: registry, evaluatedAt: now,
            timeZone: zone, trashOperator: trash ?? SessionCollectorMover(destination: self.trash.path),
            beforeRevalidation: beforeRevalidation)
    }
    func rawSession(_ name: String, bytes: Data?) throws {
        try FileManager.default.createDirectory(at: session(name), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let bytes {
            try bytes.write(to: manifest(name))
            guard chmod(manifest(name).path, 0o400) == 0 else { throw SessionCollectorFixtureError.io }
        }
    }
    func ageTree(_ name: String, modifiedAt: Date) throws {
        let directory = session(name)
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            throw SessionCollectorFixtureError.io
        }
        for case let item as URL in enumerator {
            try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: item.path)
        }
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: directory.path)
    }
    func legacyAuthority(
        _ name: String, createdAt: Date, liveOwner: Bool = false, finalized: Bool = false, fault: String? = nil
    ) throws {
        try rawSession(name, bytes: nil)
        var directory = stat()
        guard lstat(session(name).path, &directory) == 0 else { throw SessionCollectorFixtureError.io }
        let process = try NotikaInteractiveProcessIdentity.observe(getpid())
        let owner = CanonicalJSONValue.object([
            "processID": .integer(Int64(process.processID)), "parentProcessID": .integer(Int64(process.parentProcessID)),
            "ownerUserID": .unsignedInteger(UInt64(process.ownerUID)), "executable": .string(process.executable),
            // A different recorded birth proves this PID has been reused; the
            // exact-live case uses all genuine stable process facts instead.
            "startTimeSeconds": .unsignedInteger(liveOwner ? process.startSeconds : process.startSeconds - 1),
            "startTimeMicroseconds": .unsignedInteger(process.startMicroseconds),
        ])
        let key = String(repeating: "a", count: 24), hash = String(repeating: "b", count: 64)
        let cache = CanonicalJSONValue.object(["key": .string(key), "path": .string(path + "/DerivedData/AgentCaches/" + key),
            "lockPath": .string(registry + "/locks/cache.lock"), "ownershipAuthority": .string("agentlease-kernel-lock")])
        let requestValue = try sessionCollectorCanonical(StrictJSONDocument(data: JSONEncoder().encode(request)).root)
        var authority: [String: CanonicalJSONValue] = [
            "schemaVersion": .integer(1), "resourceID": .string("notika.development-session-authority"),
            "sessionID": .string(name), "repository": .string(path), "createdAt": .string(timestamp(createdAt)),
            "sourceBeforeHash": .string(hash), "request": requestValue, "ownerProcess": owner,
            "artifacts": .object(["root": .string(session(name).path), "deviceID": .unsignedInteger(UInt64(directory.st_dev)),
                "inode": .unsignedInteger(fault == "directory" ? directory.st_ino + 1 : directory.st_ino)]),
            "lease": .object(["platform": .string("macos-ui"), "required": .bool(false), "cleanupAuthority": .string("simlease-supervisor")]),
            "cache": cache,
            "cleanupPolicy": .object(["artifacts": .string("retain-then-trash-after-final-expiry"), "cache": .string("never-delete-or-unlock"),
                "lease": .string("never-adopt-or-release"), "process": .string("observe-only-never-signal")]),
        ]
        if fault == "extra-field" { authority["extra"] = .bool(true) }
        let authorityBytes = try CanonicalJSONDigest.encode(.object(authority))
        let authorityPath = session(name).appendingPathComponent("development-session.json")
        try authorityBytes.write(to: authorityPath)
        guard chmod(authorityPath.path, 0o400) == 0 else { throw SessionCollectorFixtureError.io }
        if finalized {
            var physical = stat()
            guard lstat(authorityPath.path, &physical) == 0 else { throw SessionCollectorFixtureError.io }
            let digest = fault == "authority-digest" ? String(repeating: "0", count: 64) : CanonicalJSONDigest.digest(authorityBytes)
            let completed = createdAt.addingTimeInterval(1)
            let fields: [String: CanonicalJSONValue] = [
                "schemaVersion": .integer(1), "resourceID": .string("notika.abandoned-development-session"), "sessionID": .string(name),
                "createdAt": .string(timestamp(createdAt)), "completedAt": .string(timestamp(completed)),
                "expiresAt": .string(timestamp(now.addingTimeInterval(7 * 86_400))), "status": .string("inconclusive"),
                "repository": .string(path), "sourceBeforeHash": .string(hash), "request": requestValue, "cache": cache,
                "artifacts": .object(["root": .string(session(name).path), "retained": .bool(true),
                    "inventory": .object(["algorithm": .string("notika.session-entry-metadata.sha256.v1"),
                        "entries": .integer(1), "sha256": .string(hash)])]),
                "abandonment": .object(["adjudicatedAt": .string(timestamp(completed)), "ownerProcess": owner,
                    "observedLiveness": .string("owner-identity-replaced"),
                    "directory": .object(["deviceID": .unsignedInteger(UInt64(directory.st_dev)), "inode": .unsignedInteger(directory.st_ino)]),
                    "authority": .object(["path": .string(authorityPath.path), "deviceID": .unsignedInteger(UInt64(physical.st_dev)),
                        "inode": .unsignedInteger(physical.st_ino), "sha256": .string(digest)]),
                    "custody": .object(["process": .string("not-signaled"), "lease": .string("not-adopted-or-released"),
                        "cache": .string("not-deleted-or-unlocked"), "artifacts": .string("retained-in-place")])]),
            ]
            try CanonicalJSONDigest.encode(.object(fields)).write(to: manifest(name))
            guard chmod(manifest(name).path, 0o400) == 0 else { throw SessionCollectorFixtureError.io }
        }
        try ageTree(name, modifiedAt: createdAt)
    }
    func keep(_ name: String, expiresAt: Date, fault: String? = nil) throws {
        let document = try StrictJSONDocument(data: Data(contentsOf: manifest(name)))
        let root = try document.root.requireObject()
        let original = try #require(root.value(forKey: "expiresAt"))
        let originalString: String
        if case .string(let string) = original { originalString = string } else { throw SessionCollectorFixtureError.io }
        var fields: [String: CanonicalJSONValue] = [
            "schemaVersion": .integer(1), "resourceID": .string("notika.agent-session-keep"), "sessionID": .string(name),
            "repository": .string(path), "manifestDigest": .string("sha256:" + document.digest),
            "originalExpiresAt": .string(originalString), "expiresAt": .string(timestamp(expiresAt)),
            "issuedAt": .string(timestamp(yesterday.addingTimeInterval(60))),
            "owner": .object(["account": .string(NSUserName()), "kind": .string("local-user"), "uid": .unsignedInteger(UInt64(geteuid()))]),
            "reason": .string("Keep this diagnostic evidence"), "retentionClass": .string("extended-ephemeral"), "durablePromotion": .bool(false),
        ]
        switch fault {
        case "digest": fields["manifestDigest"] = .string("sha256:" + String(repeating: "0", count: 64))
        case "owner": fields["owner"] = .object(["account": .string("foreign"), "kind": .string("local-user"), "uid": .unsignedInteger(UInt64(geteuid()))])
        case "future-issue": fields["issuedAt"] = .string(timestamp(now.addingTimeInterval(3_600)))
        case "future-microsecond": fields["issuedAt"] = .string(timestamp(now).replacingOccurrences(of: ".000Z", with: ".000001Z"))
        case "invalid-day": fields["expiresAt"] = .string("2026-10-32T12:00:00Z")
        case "too-long": fields["expiresAt"] = .string(timestamp(now.addingTimeInterval(32 * 86_400)))
        case "extra-field": fields["extra"] = .bool(true)
        default: break
        }
        let file = session(name).appendingPathComponent("retention-keep.json")
        try CanonicalJSONDigest.encode(.object(fields)).write(to: file)
        guard chmod(file.path, 0o400) == 0 else { throw SessionCollectorFixtureError.io }
    }
    func legacySession(_ name: String, extraField: Bool = false, timestampFault: String? = nil) throws {
        let source = CanonicalJSONValue.object(["canonicalWorktree": .string(path)])
        let toolchain = CanonicalJSONValue.object(["versions": .object([:]), "binaries": .object([:])])
        let key = String(repeating: "a", count: 24)
        let cache = path + "/DerivedData/AgentCaches/" + key
        let sessionPath = session(name).path
        let requestValue = try StrictJSONDocument(data: JSONEncoder().encode(request)).root
        var fields: [String: CanonicalJSONValue] = [
            "schemaVersion": .integer(1), "sessionID": .string(name), "createdAt": .string(timestamp(yesterday.addingTimeInterval(-1))),
            "completedAt": .string(timestamp(yesterday)), "expiresAt": .string(timestamp(now.addingTimeInterval(7 * 86_400))),
            "status": .string("inconclusive"), "failureDiagnosis": .null,
            "request": try sessionCollectorCanonical(requestValue), "repository": .string(path), "sourceBefore": source,
            "sourceBeforeHash": .string(try CanonicalJSONDigest.sha256(source)), "sourceAfter": source,
            "sourceAfterHash": .string(try CanonicalJSONDigest.sha256(source)), "sourceChangedDuringExecution": .bool(false),
            "privateSourceDriftObserved": .bool(false), "sourceObservationError": .null, "evidenceValidated": .bool(false),
            "generatedGraphLock": .object(["sourceAdmission": .null, "leasedExecution": .null]), "toolchain": toolchain,
            "toolchainHash": .string(try CanonicalJSONDigest.sha256(toolchain)),
            "cache": .object(["key": .string(key), "path": .string(cache), "lock": .string(registry + "/locks/cache.lock")]),
            "environmentBindings": .object(["derivedData": .string(cache), "sessionDirectory": .string(sessionPath)]),
            "environmentPolicy": .object(["inheritedAllowlist": .array([]), "makeOverridesArePinned": .bool(true)]),
            "artifacts": .object(["root": .string(sessionPath), "workflowLog": .string(sessionPath + "/workflow.log"),
                "workflowLogEvidence": .null, "rawXcodeLog": .null, "processEvidence": .null, "reports": .null,
                "resultCustody": .null, "resultBundle": .string(sessionPath + "/result.xcresult"),
                "resultBundlePresent": .bool(false), "resultBundleValidated": .null]),
            "outerExecution": .object([:]), "leasedExecution": .null, "replayOf": .null,
            "replayCommand": .array([.string(path + "/Scripts/notika-dev"), .string("replay"), .string(sessionPath + "/manifest.json")]),
        ]
        if extraField { fields["futureField"] = .bool(true) }
        if timestampFault == "invalid-day" {
            fields["createdAt"] = .string("2026-02-28T12:00:00Z")
            fields["completedAt"] = .string("2026-02-30T12:00:00Z")
        } else if timestampFault == "future-microsecond" {
            fields["completedAt"] = .string(timestamp(now).replacingOccurrences(of: ".000Z", with: ".000001Z"))
        }
        try rawSession(name, bytes: CanonicalJSONDigest.encode(.object(fields)))
    }
    func transformSealedManifest(_ name: String, resultEvidence form: String) throws {
        let report = try NotikaBuildSessionReport(data: Data(contentsOf: manifest(name)))
        guard case .object(let original) = report.canonicalValue else { throw SessionCollectorFixtureError.io }
        let transformed = original.filter { !$0.key.utf8.elementsEqual("resultEvidence".utf8) }.map { member in
            guard form == "original", member.key.utf8.elementsEqual("commitments".utf8),
                  case .object(let commitments) = member.value else { return member }
            return CanonicalJSONMember(key: member.key, value: .object(commitments.filter {
                !$0.key.utf8.elementsEqual("resultEvidenceSHA256".utf8)
            }))
        }
        guard chmod(manifest(name).path, 0o600) == 0 else { throw SessionCollectorFixtureError.io }
        try CanonicalJSONDigest.encode(.object(transformed)).write(to: manifest(name))
        guard chmod(manifest(name).path, 0o400) == 0 else { throw SessionCollectorFixtureError.io }
    }
    func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class SessionCollectorMover: ArtifactTrashOperator, Sendable {
    let identifier = "fixture-exact-session-move"
    let destination: String
    let fail: Bool
    let replaceOriginal: Bool
    let calls = Mutex(0)
    let borrowedDescriptorCount = Mutex(0)
    let borrowedIdentities = Mutex<[SessionCollectorDescriptorIdentity]>([])
    let source = Mutex<ArtifactTrashSource?>(nil)
    init(destination: String, fail: Bool = false, replaceOriginal: Bool = false) {
        self.destination = destination; self.fail = fail; self.replaceOriginal = replaceOriginal
    }
    func moveToTrash(_ source: ArtifactTrashSource) async throws {
        try source.revalidateBeforeMove()
        calls.withLock { $0 += 1 }
        self.source.withLock { $0 = source }
        let inherited = try source.inheritedDescriptors()
        for descriptor in inherited { #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0) }
        borrowedDescriptorCount.withLock { $0 = inherited.count }
        let identities = try inherited.map { descriptor in
            var physical = stat()
            guard fstat(descriptor, &physical) == 0 else { throw SessionCollectorFixtureError.io }
            return SessionCollectorDescriptorIdentity(physical)
        }
        borrowedIdentities.withLock { $0 = identities }
        if replaceOriginal {
            try FileManager.default.createDirectory(atPath: source.originalPath, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            try Data("foreign".utf8).write(to: URL(fileURLWithPath: source.originalPath + "/preserve"))
        }
        if fail { throw ArtifactTrashError.failed }
        let name = URL(fileURLWithPath: source.originalPath).lastPathComponent
        try FileManager.default.moveItem(atPath: source.path, toPath: destination + "/" + name)
    }
}

private struct SessionCollectorDescriptorIdentity: Equatable, Sendable {
    let device: Int64, inode: UInt64
    init(_ value: stat) { device = Int64(value.st_dev); inode = value.st_ino }
}

private func sessionCollectorCanonical(_ value: StrictJSONValue) throws -> CanonicalJSONValue {
    switch value {
    case .array(let values): .array(try values.map(sessionCollectorCanonical))
    case .bool(let value): .bool(value)
    case .null: .null
    case .number(let number): .integer(try number.int64())
    case .object(let object): .object(try object.members.map { CanonicalJSONMember(key: $0.key, value: try sessionCollectorCanonical($0.value)) })
    case .string(let value): .string(value)
    }
}
