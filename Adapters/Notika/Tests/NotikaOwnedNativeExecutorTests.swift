@testable import AgentBuildCore
import AgentBuildTestSupport
import AgentLeaseCore
import Darwin
import Foundation
@testable import NotikaAdapter
import Synchronization
import Testing

@Suite("Owned native Notika execution")
struct NotikaOwnedNativeExecutorTests {
    @Test func testBuildAndRuntimeUseExactClaimsAndReleaseOnlyCompilationAdmission() async throws {
        let fixture = try OwnedExecutionFixture(route: .testUnitFile)
        defer { fixture.remove() }
        let observed = Mutex<[Int]>([])
        let result = try await fixture.owned { ownership in
            try await NotikaOwnedNativeExecutor().run(
                fixture.plan, identity: fixture.identity, ownership: ownership,
                environment: fixture.base.environment.merging([
                    "NOTIKA_DERIVED_DATA": "/wrong-cache", "NOTIKA_ROUTE_AUTHORITY_FD": "5",
                    "XCODEBUILD_FLAGS": "-scheme unadmitted", "AGENTBUILD_METAL_TOOLCHAIN": "/foreign/metal",
                ]) { _, supplied in supplied },
                metalToolchain: "/toolchain/usr/bin/metal"
            ) { command, claim, descriptors in
                #expect(command.executable == "/usr/bin/xcodebuild")
                #expect(command.arguments == claim.phase.arguments)
                #expect(command.workingDirectory == fixture.base.directory.path)
                #expect(command.environment["NOTIKA_DERIVED_DATA"] == fixture.ownershipPlan.cacheDirectory)
                #expect(command.environment["AGENTBUILD_METAL_TOOLCHAIN"] == "/toolchain/usr/bin/metal")
                #expect(command.environment["NOTIKA_ROUTE_AUTHORITY_FD"] == nil)
                #expect(command.environment["XCODEBUILD_FLAGS"] == nil)
                #expect(command.environment["PATH"]?.hasPrefix(fixture.base.directory.path + "/Scripts:") == true)
                #expect(descriptors.count == (claim.phase.requiresCompilation ? 4 : 3))
                do {
                    let compilationAvailable = try fixture.base.available()
                    #expect(compilationAvailable == !claim.phase.requiresCompilation)
                    for resource in fixture.ownershipPlan.orderedLeases {
                        let projectAvailable = try fixture.available(resource.resource)
                        #expect(!projectAvailable)
                    }
                } catch {
                    Issue.record(error)
                }
                observed.withLock { $0.append(claim.phase.physicalOrdinal) }
                return await fixture.workload("exit 0", descriptors: descriptors)
            }
        }
        #expect(result.complete)
        #expect(result.ledger.completedPhaseCount == 2)
        #expect(result.observations.map(\.workload.termination) == [
            RunTermination(kind: .exit, value: 0), RunTermination(kind: .exit, value: 0),
        ])
        #expect(observed.withLock { $0 } == [0, 1])
        #expect(try fixture.base.available())
        for resource in fixture.ownershipPlan.orderedLeases { #expect(try fixture.available(resource.resource)) }
    }

    @Test func nativeFailureStopsThePlanAndRemainsAuthoritative() async throws {
        let fixture = try OwnedExecutionFixture(route: .testUnitFile)
        defer { fixture.remove() }
        let result = try await fixture.owned { ownership in
            try await NotikaOwnedNativeExecutor().run(
                fixture.plan, identity: fixture.identity, ownership: ownership,
                environment: fixture.base.environment
            ) { _, claim, descriptors in
                #expect(claim.phase.physicalOrdinal == 0)
                return await fixture.workload("exit 27", descriptors: descriptors)
            }
        }
        #expect(!result.complete)
        #expect(result.nativeFailure == RunTermination(kind: .exit, value: 27))
        #expect(result.ledger.state == .stopped)
        #expect(result.observations.count == 1)
        #expect(result.orchestrationFailure == nil)
        #expect(try fixture.base.available())
    }

    @Test func failedLaunchDoesNotCreateANativeExitCode() async throws {
        let fixture = try OwnedExecutionFixture(route: .build)
        defer { fixture.remove() }
        let result = try await fixture.owned { ownership in
            try await NotikaOwnedNativeExecutor().run(
                fixture.plan, identity: fixture.identity, ownership: ownership,
                environment: fixture.base.environment
            ) { _, _, descriptors in
                let missing = try DarwinWorkloadCommand(
                    executable: fixture.base.directory.path + "/missing-executable",
                    workingDirectory: fixture.base.directory.path
                )
                return await fixture.workload(missing, descriptors: descriptors)
            }
        }
        #expect(!result.complete)
        #expect(result.nativeFailure == nil)
        #expect(result.observations.first?.workload.retirement == .notStarted)
        #expect(result.ledger.completions.first?.termination == nil)
        #expect(result.ledger.completions.first?.ancillaryFailure != nil)
        #expect(try fixture.base.available())
    }

    @Test func incompatibleCacheFailsBeforeEnteringTheExecutor() async throws {
        let fixture = try OwnedExecutionFixture(route: .build)
        defer { fixture.remove() }
        let changed = try NotikaXcodeInvocationPlan(
            request: fixture.plan.request, destination: "platform=macOS,arch=arm64",
            cacheDirectory: fixture.base.directory.path + "/wrong-cache",
            resultBundle: fixture.base.directory.path + "/unused.xcresult"
        )
        await #expect(throws: NotikaOwnedExecutionError.incompatibleOwnership) {
            try await fixture.owned { ownership in
                try await NotikaOwnedNativeExecutor().run(
                    changed, identity: fixture.identity, ownership: ownership,
                    environment: fixture.base.environment
                ) { _, _, _ in throw OwnedExecutionFixture.Failure.unexpectedExecution }
            }
        }
        #expect(try fixture.base.available())
    }

    @Test func setupErrorRemainsAnOrchestrationFailure() async throws {
        let fixture = try OwnedExecutionFixture(route: .build)
        defer { fixture.remove() }
        let result = try await fixture.owned { ownership in
            try await NotikaOwnedNativeExecutor().run(
                fixture.plan, identity: fixture.identity, ownership: ownership,
                environment: fixture.base.environment
            ) { _, _, _ in throw OwnedExecutionFixture.Failure.unexpectedExecution }
        }
        #expect(result.observations.isEmpty)
        #expect(result.nativeFailure == nil)
        #expect(result.ledger.completions.first?.termination == nil)
        #expect(result.orchestrationFailure != nil)
        #expect(try fixture.base.available())
    }

    @Test func compositeAcceptanceCacheCannotExecuteAnOrdinaryBuild() async throws {
        let fixture = try OwnedExecutionFixture(route: .build, purpose: "agent-loop-composite-acceptance")
        defer { fixture.remove() }
        await #expect(throws: NotikaOwnedExecutionError.incompatibleProfile) {
            try await fixture.owned { ownership in
                try await NotikaOwnedNativeExecutor().run(
                    fixture.plan, identity: fixture.identity, ownership: ownership,
                    environment: fixture.base.environment
                ) { _, _, _ in throw OwnedExecutionFixture.Failure.unexpectedExecution }
            }
        }
        #expect(try fixture.base.available())
    }

    @Test func cancellationAfterNativeRetirementKeepsZeroAndStopsSuccess() async throws {
        let fixture = try OwnedExecutionFixture(route: .build)
        defer { fixture.remove() }
        let task = Task {
            try await fixture.owned { ownership in
                try await NotikaOwnedNativeExecutor().run(
                    fixture.plan, identity: fixture.identity, ownership: ownership,
                    environment: fixture.base.environment
                ) { _, _, descriptors in
                    let observation = await fixture.workload("exit 0", descriptors: descriptors)
                    withUnsafeCurrentTask { $0?.cancel() }
                    return observation
                }
            }
        }
        let result = try await task.value
        #expect(result.cancelled)
        #expect(!result.complete)
        #expect(result.observations.first?.workload.termination == RunTermination(kind: .exit, value: 0))
        #expect(result.ledger.completions.first?.cancelled == true)
        #expect(result.nativeFailure == nil)
        #expect(try fixture.base.available())
    }
}

private struct OwnedExecutionFixture: Sendable {
    enum Failure: Error { case unexpectedExecution; case systemCall(Int32) }
    let base: CompilationFixture
    let identity: CacheCompatibilityIdentity
    let ownershipPlan: NotikaProjectOwnershipPlan
    let plan: NotikaXcodeInvocationPlan
    let ownerRead: Int32
    let ownerWrite: Int32
    let output: Int32

    init(route: NotikaMakeRoute, purpose: String? = nil) throws {
        let base = try CompilationFixture()
        self.base = base
        let digest = String(repeating: "a", count: 64)
        identity = try CacheCompatibilityIdentity(
            canonicalWorktree: base.directory.path, toolchainHash: digest, gitlinks: [],
            submoduleStatusDigest: digest, submoduleWorktreeDigest: digest,
            projectGraphDigest: digest, generatedGraphDigest: digest, resolvedDependenciesDigest: digest,
            scheme: "Notika", configuration: "Debug", destinationFamily: "macos-arm64",
            buildFlags: ["-disableAutomaticPackageResolution"], purpose: purpose
        )
        ownershipPlan = try NotikaProjectOwnershipPlan(identity: identity)
        let request = try NotikaActionRequest(makeRoute: route, testFile: route.acceptsTestFile ? "FixtureTests" : "")
        plan = try NotikaXcodeInvocationPlan(
            request: request, destination: "platform=macOS,arch=arm64",
            cacheDirectory: ownershipPlan.cacheDirectory!, resultBundle: base.directory.path + "/result.xcresult"
        )
        var channel = [Int32](repeating: 0, count: 2)
        guard pipe(&channel) == 0 else { throw Failure.systemCall(errno) }
        ownerRead = channel[0]
        ownerWrite = channel[1]
        _ = fcntl(ownerRead, F_SETFD, FD_CLOEXEC)
        _ = fcntl(ownerWrite, F_SETFD, FD_CLOEXEC)
        output = Darwin.open("/dev/null", O_RDWR | O_CLOEXEC)
        guard output >= 0 else {
            _ = Darwin.close(ownerRead)
            _ = Darwin.close(ownerWrite)
            throw Failure.systemCall(errno)
        }
    }

    func owned<Result: Sendable>(
        _ operation: @Sendable (ProjectOwnership) async throws -> Result
    ) async throws -> Result {
        try await NotikaProjectAdmission().withOwnership(
            ownershipPlan, registryRoot: base.registry.path, label: "owned executor fixture", operation: operation
        )
    }

    func available(_ resource: ResourceName) throws -> Bool {
        let lock = try FileLock(resource: resource, paths: base.paths)
        defer { lock.release() }
        return try lock.tryAcquire()
    }

    func workload(_ script: String, descriptors: [Int32]) async -> NativeObservation {
        do {
            return await workload(try DarwinWorkloadCommand(
                executable: "/bin/sh", arguments: ["-c", script], workingDirectory: base.directory.path
            ), descriptors: descriptors)
        } catch {
            Issue.record(error)
            return NativeObservation(worker: DarwinWorkloadResult(
                processIdentifier: nil, termination: nil, stopReason: .ancillaryFailure,
                retirement: .notStarted, failures: [.init(operation: "fixture setup")]
            ))
        }
    }

    func workload(_ command: DarwinWorkloadCommand, descriptors: [Int32]) async -> NativeObservation {
        NativeObservation(worker: await DarwinWorkloadSupervisor().run(
            command, retainedLockDescriptors: descriptors, ownerLifelineDescriptor: ownerRead,
            standardOutputDescriptor: output, standardErrorDescriptor: output
        ))
    }

    func remove() {
        _ = Darwin.close(ownerRead)
        _ = Darwin.close(ownerWrite)
        _ = Darwin.close(output)
        base.remove()
    }
}
