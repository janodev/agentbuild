import AgentBuildCore
import AgentLeaseCore
import Darwin
import Foundation
import Synchronization
import Testing

@Suite("Account compilation admission")
struct CompilationAdmissionTests {
    @Test func accountSelectionIgnoresCheckoutRegistryAndHome() throws {
        let first = try HostCompilationAdmission.selectedRoot(environment: [
            "HOME": "/tmp/fake-account-one", "AGENTLEASE_HOME": "/tmp/checkout-one",
        ])
        let second = try HostCompilationAdmission.selectedRoot(environment: [
            "HOME": "/tmp/fake-account-two", "AGENTLEASE_HOME": "/tmp/checkout-two",
        ])
        #expect(first == second)
        #expect(first.hasSuffix("/.agentlease"))
        #expect(!first.contains("fake-account"))
    }

    @Test(arguments: ["", "relative/state", "/tmp/invalid\0state"])
    func explicitOverrideNeverFallsBack(_ override: String) {
        #expect(throws: CompilationAdmissionError.invalidOverride) {
            try HostCompilationAdmission.selectedRoot(environment: ["AGENTLEASE_COMPILE_HOME": override])
        }
    }

    @Test func sharedOverrideHasPriority() throws {
        #expect(try HostCompilationAdmission.selectedRoot(environment: [
            "AGENTLEASE_COMPILE_HOME": "/tmp/selected-compile-state",
            "AGENTLEASE_HOME": "/tmp/checkout", "HOME": "/tmp/false-home",
        ]) == "/tmp/selected-compile-state")
    }

    @Test func scopeRetainsOwnershipAndRejectsEscapedCapabilityAfterExit() async throws {
        let fixture = try CompilationFixture()
        defer { fixture.remove() }
        let escaped = try await HostCompilationAdmission().withLease(environment: fixture.environment) { lease in
            #expect(try !fixture.available())
            #expect(try lease.inheritedDescriptors().count == 1)
            let inherited = try lease.inheritedLeaseDescriptors()
            #expect(inherited.map(\.resource) == [HostCompilationAdmission.resource])
            #expect(inherited.map(\.mode) == [.exclusive])
            #expect(lease.registryRoot == fixture.registry.path)
            return lease
        }
        #expect(try fixture.available())
        #expect(throws: CompilationAdmissionError.expiredLease) { try escaped.inheritedDescriptors() }
        #expect(throws: CompilationAdmissionError.expiredLease) { try escaped.inheritedLeaseDescriptors() }
    }

    @Test func operationFailureClosesAdmission() async throws {
        let fixture = try CompilationFixture()
        defer { fixture.remove() }
        await #expect(throws: CompilationFixture.Failure.expected) {
            try await HostCompilationAdmission().withLease(environment: fixture.environment) { _ in
                #expect(try !fixture.available())
                throw CompilationFixture.Failure.expected
            }
        }
        #expect(try fixture.available())
    }

    @Test func cancelledWaitDoesNotEnterOperationOrUnlockCurrentOwner() async throws {
        let fixture = try CompilationFixture()
        defer { fixture.remove() }
        let owner = try fixture.lock()
        try #require(try owner.tryAcquire())
        defer { owner.release() }
        let contended = Mutex(false)
        let task = Task {
            try await HostCompilationAdmission().withLease(
                environment: fixture.environment,
                onContention: { _ in contended.withLock { $0 = true } }
            ) { _ in
                Issue.record("cancelled contender entered compilation")
            }
        }
        defer { task.cancel() }
        try await compilationWaitUntil { contended.withLock { $0 } }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try !fixture.available())
        owner.release()
        #expect(try fixture.available())
    }

    @Test func cancellingSpawnedCompilationReapsChildBeforeReleasingAdmission() async throws {
        let fixture = try CompilationFixture()
        defer { fixture.remove() }
        let startedPID = Mutex<Int32?>(nil)
        let task = Task {
            try await HostCompilationAdmission().withLease(environment: fixture.environment) { lease in
                try await SupervisedSubprocess.run(
                    executablePath: "/bin/sleep", arguments: ["/bin/sleep", "30"],
                    inheritedDescriptors: try lease.inheritedDescriptors(),
                    workingDirectory: fixture.directory.path,
                    teardownSequence: [.send(signal: .kill, toProcessGroup: true, allowedDurationToNextStep: .zero)],
                    onStart: { pid in startedPID.withLock { $0 = pid } }
                )
            }
        }
        defer { task.cancel() }
        try await compilationWaitUntil { startedPID.withLock { $0 != nil } }
        let childPID = try #require(startedPID.withLock { $0 })
        #expect(try !fixture.available())
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(kill(childPID, 0) == -1 && errno == ESRCH)
        #expect(try fixture.available())
    }
}

private func compilationWaitUntil(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw CompilationFixture.Failure.expected }
        try await Task.sleep(for: .milliseconds(5))
    }
}

struct CompilationFixture: Sendable {
    enum Failure: Error { case expected }
    let directory: URL
    let registry: URL
    let paths: AgentLeasePaths

    var environment: [String: String] { ["AGENTLEASE_COMPILE_HOME": registry.path] }

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentbuild-compile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(directory.path, &buffer) != nil else { throw Failure.expected }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        self.directory = URL(fileURLWithPath: path)
        registry = self.directory.appendingPathComponent("compile-registry")
        paths = try AgentLeasePaths.open(selectedRoot: registry.path)
    }

    func lock() throws -> FileLock {
        try FileLock(resource: ResourceName(HostCompilationAdmission.resource), paths: paths)
    }

    func available() throws -> Bool {
        let contender = try lock()
        defer { contender.release() }
        return try contender.tryAcquire()
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
