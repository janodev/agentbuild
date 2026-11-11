@testable import AgentBuildCore
import AgentBuildTestSupport
import AgentLeaseCore
import Foundation
@testable import NotikaAdapter
import Testing

@Suite("Notika multi-domain maintenance")
struct NotikaArtifactMaintenanceTests {
    @Test func scopedSessionCleanupRespectsCachePolicyWithoutCreatingOtherNamespaces() async throws {
        let fixture = try CompilationFixture()
        defer { fixture.remove() }
        let policy = try FileLock(
            resource: ResourceName(CacheCompatibilityIdentity.cachePolicyResourceName(
                canonicalWorktree: fixture.directory.path)), paths: fixture.paths
        )
        try #require(try policy.tryAcquire())
        defer { policy.release() }
        let maintenance = try NotikaArtifactMaintenance(
            canonicalRepository: fixture.directory.path, registryRoot: fixture.registry.path
        )
        let report = try await maintenance.run(scope: .sessions, execute: true)
        #expect(!report.complete)
        #expect(report.scope == .sessions)
        #expect(report.sessions?.rootState == .busy)
        #expect(report.sessions?.rootReason == .cachePolicyBusy)
        #expect(report.sessions?.scanComplete == false)
        #expect(report.caches == nil)
        #expect(report.rustCaches == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path + "/DerivedData"))
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path + "/Artifacts"))
        policy.release()
        let released = try await maintenance.run(scope: .sessions, execute: true)
        #expect(released.complete)
        #expect(released.scope == .sessions)
        #expect(released.sessions?.rootState == .absent)
        #expect(released.caches == nil)
        #expect(released.rustCaches == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path + "/DerivedData"))
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path + "/Artifacts"))
    }

    @Test func emptyDomainsShareOneCalendarSnapshotWithoutCreatingCaches() async throws {
        let fixture = try CompilationFixture()
        defer { fixture.remove() }
        let evaluatedAt = Date(timeIntervalSince1970: 1_790_000_000)
        let zone = try #require(TimeZone(identifier: "Europe/Madrid"))
        let report = try await NotikaArtifactMaintenance(
            canonicalRepository: fixture.directory.path, registryRoot: fixture.registry.path,
            evaluatedAt: evaluatedAt, timeZone: zone
        ).run()
        #expect(report.complete)
        #expect(report.caches.rootState == .absent)
        #expect(report.sessions.rootState == .absent)
        #expect(report.rustCaches.rootState == .absent)
        #expect(report.caches.evaluatedAt == evaluatedAt)
        #expect(report.sessions.evaluatedAt == evaluatedAt)
        #expect(report.rustCaches.evaluatedAt == evaluatedAt)
        #expect(report.caches.localDayCutoff == report.sessions.localDayCutoff)
        #expect(report.caches.localDayCutoff == report.rustCaches.localDayCutoff)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path + "/DerivedData"))
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path + "/Artifacts"))
    }

    @Test func busySessionWriterIsProtectedWhileIndependentCacheDomainsAreAssessed() async throws {
        let fixture = try CompilationFixture()
        defer { fixture.remove() }
        let writer = try FileLock(
            resource: ResourceName("notika:sessions:" + fixture.directory.path), paths: fixture.paths
        )
        try #require(try writer.tryAcquire())
        defer { writer.release() }
        let report = try await NotikaArtifactMaintenance(
            canonicalRepository: fixture.directory.path, registryRoot: fixture.registry.path
        ).run(execute: true)
        #expect(!report.complete)
        #expect(report.sessions.rootState == .busy)
        #expect(report.sessions.rootReason == .namespaceBusy)
        #expect(report.caches.rootState == .absent)
        #expect(report.rustCaches.rootState == .absent)
        #expect(report.caches.movedToTrashAllocatedBytes == 0)
        #expect(report.rustCaches.movedToTrashAllocatedBytes == 0)
    }
}
