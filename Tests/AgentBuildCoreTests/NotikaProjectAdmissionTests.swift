import AgentBuildCore
import AgentLeaseCore
import Foundation
import Synchronization
import Testing

@Suite("Notika project admission")
struct NotikaProjectAdmissionTests {
    @Test func nativeScopeOwnsGraphPolicyAndCacheBeforeCompilation() async throws {
        let fixture = try ProjectFixture()
        defer { fixture.base.remove() }
        let escaped = try await NotikaProjectAdmission().withOwnership(
            fixture.plan, registryRoot: fixture.base.registry.path, label: "native admission fixture"
        ) { ownership in
            #expect(try ownership.inheritedDescriptors().count == 3)
            #expect(try ownership.inheritedLeaseDescriptors().map(\.resource) == fixture.plan.orderedLeases.map { $0.resource.value })
            #expect(try ownership.inheritedLeaseDescriptors().map(\.mode) == [.shared, .shared, .exclusive])
            for lease in fixture.plan.orderedLeases { #expect(try !fixture.available(lease.resource)) }
            #expect(try fixture.available(fixture.plan.orderedLeases[0].resource, mode: .shared))
            #expect(try fixture.available(fixture.plan.orderedLeases[1].resource, mode: .shared))
            #expect(try fixture.base.available())
            try await HostCompilationAdmission().withLease(environment: fixture.base.environment) { _ async throws in
                #expect(try !fixture.base.available())
                for lease in fixture.plan.orderedLeases { #expect(try !fixture.available(lease.resource)) }
            }
            #expect(try fixture.base.available())
            for lease in fixture.plan.orderedLeases { #expect(try !fixture.available(lease.resource)) }
            return ownership
        }
        for lease in fixture.plan.orderedLeases { #expect(try fixture.available(lease.resource)) }
        #expect(throws: ProjectAdmissionError.expiredOwnership) { try escaped.inheritedDescriptors() }
        #expect(throws: ProjectAdmissionError.expiredOwnership) { try escaped.inheritedLeaseDescriptors() }
    }

    @Test func generationRequiresExclusiveGraphWithoutCacheOrPolicy() async throws {
        let fixture = try ProjectFixture()
        defer { fixture.base.remove() }
        let generation = try NotikaProjectOwnershipPlan(generationFor: fixture.base.directory.path)
        #expect(generation.cacheDirectory == nil)
        #expect(generation.orderedLeases.map(\.mode) == [.exclusive])
        try await NotikaProjectAdmission().withOwnership(
            generation, registryRoot: fixture.base.registry.path, label: "generation fixture"
        ) { ownership async throws in
            #expect(try ownership.inheritedDescriptors().count == 1)
            #expect(try !fixture.available(generation.orderedLeases[0].resource, mode: .shared))
            for lease in fixture.plan.orderedLeases.dropFirst() { #expect(try fixture.available(lease.resource)) }
        }
        #expect(try fixture.available(generation.orderedLeases[0].resource))
    }

    @Test func cancelledCacheWaitClosesEarlierLayersAndLeavesCacheOwnerAlone() async throws {
        let fixture = try ProjectFixture()
        defer { fixture.base.remove() }
        let cache = try fixture.lock(fixture.plan.orderedLeases[2].resource)
        try #require(try cache.tryAcquire())
        defer { cache.release() }
        let reachedCache = Mutex(false)
        let task = Task {
            try await NotikaProjectAdmission().withOwnership(
                fixture.plan, registryRoot: fixture.base.registry.path, label: "cancelled cache waiter",
                onContention: { lease, _ in
                    if lease.resource == fixture.plan.orderedLeases[2].resource {
                        reachedCache.withLock { $0 = true }
                    }
                }
            ) { _ in Issue.record("cancelled cache waiter entered native work") }
        }
        defer { task.cancel() }
        try await projectWaitUntil { reachedCache.withLock { $0 } }
        // The waiter has acquired both earlier layers while the cache is busy.
        #expect(try !fixture.available(fixture.plan.orderedLeases[0].resource))
        #expect(try !fixture.available(fixture.plan.orderedLeases[1].resource))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try fixture.available(fixture.plan.orderedLeases[0].resource))
        #expect(try fixture.available(fixture.plan.orderedLeases[1].resource))
        #expect(try !fixture.available(fixture.plan.orderedLeases[2].resource))
        cache.release()
        #expect(try fixture.available(fixture.plan.orderedLeases[2].resource))
    }

    @Test func immediateContentionDoesNotEnterOperationOrLeakEarlierLayers() async throws {
        let fixture = try ProjectFixture()
        defer { fixture.base.remove() }
        let policy = try fixture.lock(fixture.plan.orderedLeases[1].resource)
        try #require(try policy.tryAcquire())
        defer { policy.release() }
        await #expect(throws: LeaseSetError.timedOut(fixture.plan.orderedLeases[1].resource.value)) {
            try await NotikaProjectAdmission().withOwnership(
                fixture.plan, registryRoot: fixture.base.registry.path, label: "immediate contention", waitSeconds: 0
            ) { _ in Issue.record("busy policy allowed native operation") }
        }
        #expect(try fixture.available(fixture.plan.orderedLeases[0].resource))
        #expect(try fixture.available(fixture.plan.orderedLeases[2].resource))
        #expect(try !fixture.available(fixture.plan.orderedLeases[1].resource))
    }

    @Test func graphWaitDoesNotAcquirePolicyOrCache() async throws {
        let fixture = try ProjectFixture()
        defer { fixture.base.remove() }
        let graph = try fixture.lock(fixture.plan.orderedLeases[0].resource)
        try #require(try graph.tryAcquire())
        defer { graph.release() }
        let reachedGraph = Mutex(false)
        let task = Task {
            try await NotikaProjectAdmission().withOwnership(
                fixture.plan, registryRoot: fixture.base.registry.path, label: "graph waiter",
                onContention: { _, _ in reachedGraph.withLock { $0 = true } }
            ) { _ in Issue.record("busy graph allowed native operation") }
        }
        defer { task.cancel() }
        try await projectWaitUntil { reachedGraph.withLock { $0 } }
        for lease in fixture.plan.orderedLeases.dropFirst() { #expect(try fixture.available(lease.resource)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try !fixture.available(fixture.plan.orderedLeases[0].resource))
    }

    @Test func positiveWaitBudgetIsSharedAcrossContendedLayers() async throws {
        let fixture = try ProjectFixture()
        defer { fixture.base.remove() }
        let graph = try fixture.lock(fixture.plan.orderedLeases[0].resource)
        let policy = try fixture.lock(fixture.plan.orderedLeases[1].resource)
        try #require(try graph.tryAcquire())
        try #require(try policy.tryAcquire())
        defer { graph.release(); policy.release() }
        let contended = Mutex<Set<ResourceName>>([])
        let task = Task {
            try await NotikaProjectAdmission().withOwnership(
                fixture.plan, registryRoot: fixture.base.registry.path, label: "total budget fixture", waitSeconds: 2,
                onContention: { lease, _ in _ = contended.withLock { $0.insert(lease.resource) } }
            ) { _ in Issue.record("each acquisition received a fresh budget") }
        }
        defer { task.cancel() }
        try await projectWaitUntil { contended.withLock { $0.contains(fixture.plan.orderedLeases[0].resource) } }
        try await Task.sleep(for: .milliseconds(1_200))
        graph.release()
        try await projectWaitUntil { contended.withLock { $0.contains(fixture.plan.orderedLeases[1].resource) } }
        try await Task.sleep(for: .milliseconds(1_200))
        policy.release()
        await #expect(throws: LeaseSetError.timedOut(fixture.plan.orderedLeases[1].resource.value)) {
            try await task.value
        }
        for lease in fixture.plan.orderedLeases { #expect(try fixture.available(lease.resource)) }
    }

    @Test func operationFailureReleasesAllLayers() async throws {
        let fixture = try ProjectFixture()
        defer { fixture.base.remove() }
        await #expect(throws: CompilationFixture.Failure.expected) {
            try await NotikaProjectAdmission().withOwnership(
                fixture.plan, registryRoot: fixture.base.registry.path, label: "failing operation"
            ) { _ in throw CompilationFixture.Failure.expected }
        }
        for lease in fixture.plan.orderedLeases { #expect(try fixture.available(lease.resource)) }
    }

    @Test func sharedAppAndUISchemesUseTheSameOwnedCache() throws {
        let fixture = try ProjectFixture()
        defer { fixture.base.remove() }
        let ui = try NotikaProjectOwnershipPlan(identity: fixture.identity(scheme: "NotikaUITestsOnly"))
        #expect(ui == fixture.plan)
        let historical = try fixture.identity().cacheKey(metadataSchemaVersion: 1)
        let old = try NotikaProjectOwnershipPlan(identity: fixture.identity(), admittedCacheKey: historical)
        #expect(old.cacheDirectory?.hasSuffix(historical) == true)
        #expect(old.orderedLeases[2] != fixture.plan.orderedLeases[2])
        #expect(throws: CacheCompatibilityError.incompatibleAdmission) {
            try NotikaProjectOwnershipPlan(identity: fixture.identity(), admittedCacheKey: String(repeating: "f", count: 24))
        }
    }

    @Test(arguments: ["", "new\nline", "invalid\0label", "delete\u{7f}label"])
    func invalidLabelsDoNotStartOwnership(_ label: String) async throws {
        let fixture = try ProjectFixture()
        defer { fixture.base.remove() }
        await #expect(throws: ProjectAdmissionError.invalidLabel) {
            try await NotikaProjectAdmission().withOwnership(
                fixture.plan, registryRoot: fixture.base.registry.path, label: label
            ) { _ in Issue.record("invalid label entered ownership") }
        }
        for lease in fixture.plan.orderedLeases { #expect(try fixture.available(lease.resource)) }
    }
}

private struct ProjectFixture: Sendable {
    let base: CompilationFixture
    let plan: NotikaProjectOwnershipPlan

    init() throws {
        base = try CompilationFixture()
        plan = try NotikaProjectOwnershipPlan(identity: Self.identity(worktree: base.directory.path))
    }

    func identity(scheme: String = "Notika") throws -> CacheCompatibilityIdentity {
        try Self.identity(worktree: base.directory.path, scheme: scheme)
    }

    private static func identity(worktree: String, scheme: String = "Notika") throws -> CacheCompatibilityIdentity {
        let digest = String(repeating: "a", count: 64)
        return try CacheCompatibilityIdentity(
            canonicalWorktree: worktree, toolchainHash: digest, gitlinks: [],
            submoduleStatusDigest: digest, submoduleWorktreeDigest: digest,
            projectGraphDigest: digest, generatedGraphDigest: digest, resolvedDependenciesDigest: digest,
            scheme: scheme, configuration: "Debug", destinationFamily: "macos-arm64",
            buildFlags: ["-disableAutomaticPackageResolution"]
        )
    }

    func lock(_ resource: ResourceName, mode: LeaseMode = .exclusive) throws -> FileLock {
        try FileLock(resource: resource, mode: mode, paths: base.paths)
    }

    func available(_ resource: ResourceName, mode: LeaseMode = .exclusive) throws -> Bool {
        let contender = try lock(resource, mode: mode)
        defer { contender.release() }
        return try contender.tryAcquire()
    }
}

private func projectWaitUntil(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw CompilationFixture.Failure.expected }
        try await Task.sleep(for: .milliseconds(5))
    }
}
