import AgentBuildCore
import AgentLeaseCore
import Darwin
import Foundation
import Synchronization
import Testing

@Suite("Captured native phase lifecycle")
struct CapturedNativePhaseRunnerTests {
    @Test func nativeFailureAndBinaryLogsSurviveUntilPublication() async throws {
        let fixture = try CapturedPhaseFixture()
        defer { fixture.remove() }
        let captured = try await CapturedNativePhaseRunner().run(
            helperExecutable: fixture.helper,
            command: fixture.command(#"printf '\000\377\200'; printf 'diagnostic' >&2; exit 31"#),
            retainedLockDescriptors: [], artifactRoot: fixture.root
        )
        #expect(captured.observation.termination == RunTermination(kind: .exit, value: 31))
        #expect(captured.observation.retirement == .workerReaped)
        #expect(captured.observation.failures.isEmpty)
        #expect(captured.rawCapture.captureComplete)
        #expect(try Data(contentsOf: URL(fileURLWithPath: captured.rawCapture.standardOutput.path)) == Data([0, 255, 128]))
        #expect(try Data(contentsOf: URL(fileURLWithPath: captured.rawCapture.standardError.path)) == Data("diagnostic".utf8))
        try captured.revalidateForPublication()
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: captured.rawCapture.standardOutput.path))
        #expect(throws: (any Error).self) { try captured.revalidateForPublication() }
        // Consuming a mutation watch cannot make a second publication valid.
        #expect(throws: (any Error).self) { try captured.revalidateForPublication() }
        #expect(captured.observation.termination == RunTermination(kind: .exit, value: 31))
    }

    @Test func cancellationStillAwaitsHelperAndRawPipeEOF() async throws {
        let fixture = try CapturedPhaseFixture()
        defer { fixture.remove() }
        let started = Mutex<Int32?>(nil)
        let marker = fixture.root + "/started"
        let task = Task {
            try await CapturedNativePhaseRunner().run(
                helperExecutable: fixture.helper,
                command: fixture.command(#"trap '' TERM INT; printf 'before cancellation'; printf '%s' "$$" > "$1"; sleep 30 & wait"#,
                                         arguments: [marker]),
                retainedLockDescriptors: [], artifactRoot: fixture.root + "/logs",
                onNativeStart: { pid in started.withLock { $0 = pid } }
            )
        }
        defer { task.cancel() }
        let deadline = ContinuousClock.now + .seconds(5)
        while started.withLock({ $0 == nil }) || !FileManager.default.fileExists(atPath: marker) {
            guard ContinuousClock.now < deadline else { throw CapturedPhaseFixture.Failure.deadline }
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        let captured = try await task.value
        #expect(captured.observation.cancelled)
        #expect(captured.observation.termination == RunTermination(kind: .signal, value: SIGKILL))
        #expect(captured.rawCapture.captureComplete)
        #expect(captured.rawCapture.standardOutput.reachedEOF)
        #expect(captured.rawCapture.standardError.reachedEOF)
        let pid = try #require(started.withLock { $0 })
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        try captured.revalidateForPublication()
    }
}

private struct CapturedPhaseFixture: Sendable {
    enum Failure: Error { case deadline; case systemCall(Int32) }
    let root: String
    let helper: String

    init() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("agentbuild-captured-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var canonical = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(temporary.path, &canonical) != nil else { throw Failure.systemCall(errno) }
        root = String(decoding: canonical.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        helper = repository.appendingPathComponent(".build/debug/agentbuild").path
    }

    func command(_ script: String, arguments: [String] = []) throws -> DarwinWorkloadCommand {
        try DarwinWorkloadCommand(executable: "/bin/sh", arguments: ["-c", script, "capture-fixture"] + arguments,
                                  workingDirectory: root, environment: ["PATH": "/usr/bin:/bin"])
    }

    func remove() { try? FileManager.default.removeItem(atPath: root) }
}
