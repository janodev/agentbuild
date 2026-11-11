@testable import AgentBuildCore
import AgentBuildTestSupport
import AgentLeaseCore
import Darwin
import Foundation
import Synchronization
import Testing

@Suite("Darwin session retirement")
struct DarwinSessionRetirementTests {
    @Test func helperProtocolPreservesScopeAndDefaultsOlderRequests() throws {
        let nonce = UUID().uuidString
        let command = try DarwinWorkloadCommand(executable: "/bin/sh", workingDirectory: "/", environment: [:], retirementScope: .session)
        let data = try NativeWorkerProtocol.encodeRequest(.init(command: command, nonce: nonce, locks: []))
        #expect(try NativeWorkerProtocol.decodeRequest(data, nonce: nonce).command().retirementScope == .session)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "retirementScope")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        #expect(try NativeWorkerProtocol.decodeRequest(legacyData, nonce: nonce).command().retirementScope == .processGroup)
        legacy["retirementScope"] = "allAccountProcesses"
        let invalidData = try JSONSerialization.data(withJSONObject: legacy)
        #expect(throws: (any Error).self) { try NativeWorkerProtocol.decodeRequest(invalidData, nonce: nonce) }
    }

    @Test(arguments: [SessionStop.leaderExit, .cancellation, .ownerEOF])
    func retiresSeparateGroupsBeforeReleasingOwnership(_ stop: SessionStop) async throws {
        let fixture = try SessionRetirementFixture()
        defer { fixture.remove() }
        let command = try fixture.command()
        let completed = Mutex(false)
        let task = Task {
            let result = await DarwinWorkloadSupervisor().run(
                command, retainedLockDescriptors: [fixture.lock.value],
                ownerLifelineDescriptor: fixture.ownerReader.value,
                standardOutputDescriptor: fixture.output.value,
                standardErrorDescriptor: fixture.output.value,
                onStart: { pid in fixture.started(pid) }
            )
            completed.withLock { $0 = true }
            return result
        }
        do {
            try await sessionWaitUntil { fixture.workerIdentity() != nil && fixture.leader.withLock { $0 } != nil }
            let identity = try #require(fixture.workerIdentity())
            let leader = try #require(fixture.leader.withLock { $0 })
            #expect(identity.pid != leader)
            #expect(identity.group == identity.pid)
            #expect(identity.session == leader)
            #expect(getsid(identity.pid) == leader)
            #expect(try !fixture.lockAvailable())

            switch stop {
            case .leaderExit:
                try Data().write(to: fixture.release)
            case .cancellation:
                task.cancel()
            case .ownerEOF:
                fixture.ownerWriter.close()
            }
            try await sessionWaitUntil { completed.withLock { $0 } || fixture.nativeExited(leader) }
            #expect(!completed.withLock { $0 })
            #expect(fixture.nativeExited(leader))
            #expect(getsid(identity.pid) == leader)
            #expect(try !fixture.lockAvailable())
            // The escaped worker closes itself. Session supervision retains
            // custody while waiting, without signalling an unpinned PID.
            try fixture.releaseWorker()
            let result = await task.value
            #expect(result.retirement == .reaped)
            #expect(result.failures.isEmpty, Comment(rawValue: String(describing: result.failures)))
            switch stop {
            case .leaderExit:
                #expect(result.termination == RunTermination(kind: .exit, value: 41))
                #expect(result.stopReason == nil)
            case .cancellation:
                #expect(result.termination == RunTermination(kind: .signal, value: SIGKILL))
                #expect(result.stopReason == .cancelled)
            case .ownerEOF:
                #expect(result.termination == RunTermination(kind: .signal, value: SIGKILL))
                #expect(result.stopReason == .ownerEOF)
            }
            try await sessionWaitUntil { kill(identity.pid, 0) == -1 && errno == ESRCH }
            #expect(try fixture.lockAvailable())
            var status: Int32 = 0
            #expect(waitpid(leader, &status, WNOHANG) == -1 && errno == ECHILD)
        } catch {
            fixture.ownerWriter.close()
            task.cancel()
            try? fixture.releaseWorker()
            _ = await task.value
            throw error
        }
    }

    @Test func helperWaitsForSeparateGroupBeforeReleasingOwnership() async throws {
        let fixture = try SessionRetirementFixture()
        defer { fixture.remove() }
        let command = try fixture.command()
        let completed = Mutex(false)
        let helper = AgentBuildTestPaths.packageRoot.appendingPathComponent(".build/debug/agentbuild").path
        let task = Task {
            let result = await NativePhaseSupervisor().run(
                helperExecutable: helper, command: command, retainedLockDescriptors: [fixture.lock.value],
                standardOutputDescriptor: fixture.output.value, standardErrorDescriptor: fixture.output.value,
                onNativeStart: { pid in fixture.started(pid) }
            )
            completed.withLock { $0 = true }
            return result
        }
        do {
            try await sessionWaitUntil { fixture.workerIdentity() != nil && fixture.leader.withLock { $0 } != nil }
            let identity = try #require(fixture.workerIdentity())
            let leader = try #require(fixture.leader.withLock { $0 })
            try Data().write(to: fixture.release)
            try await sessionWaitUntil { completed.withLock { $0 } || fixture.nativeIsZombie(leader) }
            #expect(!completed.withLock { $0 })
            #expect(fixture.nativeIsZombie(leader))
            #expect(try !fixture.lockAvailable())
            try fixture.releaseWorker()
            let result = await task.value
            #expect(result.retirementProven)
            #expect(result.workload?.termination == RunTermination(kind: .exit, value: 41))
            #expect(result.workload?.failures.isEmpty == true)
            #expect(result.failures.isEmpty)
            try await sessionWaitUntil { kill(identity.pid, 0) == -1 && errno == ESRCH }
            #expect(try fixture.lockAvailable())
        } catch {
            task.cancel()
            try? fixture.releaseWorker()
            _ = await task.value
            throw error
        }
    }

    @Test func helperDeathQuarantinesLocksUntilSeparateSessionGroupsFinish() async throws {
        let fixture = try SessionRetirementFixture()
        defer { fixture.remove() }
        let command = try fixture.command()
        let helper = AgentBuildTestPaths.packageRoot.appendingPathComponent(".build/debug/agentbuild").path
        let helperPID = Mutex<Int32?>(nil)
        let task = Task {
            await NativePhaseSupervisor().run(
                helperExecutable: helper, command: command, retainedLockDescriptors: [fixture.lock.value],
                standardOutputDescriptor: fixture.output.value, standardErrorDescriptor: fixture.output.value,
                onHelperStart: { pid in helperPID.withLock { $0 = pid } },
                onNativeStart: { pid in fixture.started(pid) }
            )
        }
        var quarantineWait: Task<Void, Never>?
        do {
            try await sessionWaitUntil {
                fixture.workerIdentity() != nil && fixture.leader.withLock { $0 } != nil && helperPID.withLock { $0 } != nil
            }
            let identity = try #require(fixture.workerIdentity())
            let leader = try #require(fixture.leader.withLock { $0 })
            let ownedHelper = try #require(helperPID.withLock { $0 })
            #expect(identity.group == identity.pid && identity.session == leader)
            // The supervisor owns and pins this helper; escaped worker PIDs
            // are never used as signal targets by the fixture.
            #expect(kill(ownedHelper, SIGKILL) == 0)
            let result = await task.value
            #expect(result.helperTermination == RunTermination(kind: .signal, value: SIGKILL))
            #expect(!result.retirementProven)
            #expect(result.workload == nil)
            let quarantine = try #require(result.quarantine)
            #expect(quarantine.retirementScope == .session)
            #expect(quarantine.nativePID == leader)
            try Data().write(to: fixture.release)
            try await sessionWaitUntil { kill(leader, 0) == -1 && errno == ESRCH }
            #expect(getsid(identity.pid) == leader)
            #expect(try !fixture.lockAvailable())

            let completed = Mutex(false)
            quarantineWait = Task {
                await quarantine.waitUntilProvenQuiescent()
                completed.withLock { $0 = true }
            }
            // This negative liveness check spans several census attempts;
            // the native process and its original group are already gone.
            try await Task.sleep(for: .milliseconds(100))
            #expect(!completed.withLock { $0 })
            #expect(!quarantine.quiescenceProven)
            #expect(try !fixture.lockAvailable())
            try fixture.releaseWorker()
            await quarantineWait?.value
            #expect(quarantine.quiescenceProven)
            #expect(try fixture.lockAvailable())
        } catch {
            task.cancel()
            try? Data().write(to: fixture.release)
            try? fixture.releaseWorker()
            _ = await task.value
            await quarantineWait?.value
            throw error
        }
    }
}

enum SessionStop: Sendable { case leaderExit, cancellation, ownerEOF }

private final class SessionRetirementFixture: Sendable {
    struct WorkerIdentity { let pid: Int32; let group: Int32; let session: Int32 }
    let directory: URL
    let release: URL
    let workerRelease: URL
    let marker: URL
    let lockPath: String
    let lock: SessionDescriptor
    let ownerReader: SessionDescriptor
    let ownerWriter: SessionDescriptor
    let output: SessionDescriptor
    let leader = Mutex<Int32?>(nil)

    init() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("agentbuild-session-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        guard let path = temporary.path.withCString({ realpath($0, nil) }) else { throw SessionTestFailure.systemCall(errno) }
        defer { free(path) }
        directory = URL(fileURLWithPath: String(cString: path))
        release = directory.appendingPathComponent("release")
        workerRelease = directory.appendingPathComponent("worker-release")
        marker = directory.appendingPathComponent("worker")
        lockPath = directory.appendingPathComponent("ownership.lock").path
        lock = try SessionDescriptor.open(lockPath)
        guard flock(lock.value, LOCK_EX | LOCK_NB) == 0 else { throw SessionTestFailure.systemCall(errno) }
        output = try SessionDescriptor.open(directory.appendingPathComponent("output").path)
        var pipeDescriptors: [Int32] = [0, 0]
        guard pipe(&pipeDescriptors) == 0 else { throw SessionTestFailure.systemCall(errno) }
        defer { _ = Darwin.close(pipeDescriptors[0]); _ = Darwin.close(pipeDescriptors[1]) }
        ownerReader = try SessionDescriptor.duplicate(pipeDescriptors[0])
        ownerWriter = try SessionDescriptor.duplicate(pipeDescriptors[1])
    }

    func command() throws -> DarwinWorkloadCommand {
        // Unreal's Mac CreateProc follows this pattern: a new process group,
        // closed inherited descriptors, and the original session retained.
        let program = #"""
        import os, pathlib, signal, sys, time
        marker, release, worker_release = map(pathlib.Path, sys.argv[1:])
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.alarm(20)
        child = os.fork()
        if child == 0:
            os.setpgid(0, 0)
            os.closerange(3, 1024)
            null = os.open('/dev/null', os.O_RDWR)
            for fd in range(3):
                os.dup2(null, fd)
            os.close(null)
            marker.write_text(f'{os.getpid()} {os.getpgrp()} {os.getsid(0)}')
            while not worker_release.exists():
                time.sleep(0.01)
            os._exit(0)
        while not release.exists():
            time.sleep(0.01)
        os._exit(41)
        """#
        return try DarwinWorkloadCommand(
            executable: "/usr/bin/python3", arguments: ["-c", program, marker.path, release.path, workerRelease.path],
            workingDirectory: directory.path, environment: ["PATH": "/usr/bin:/bin"], retirementScope: .session
        )
    }

    func started(_ pid: Int32) {
        leader.withLock { $0 = pid }
        lock.close()
    }

    func workerIdentity() -> WorkerIdentity? {
        guard let text = try? String(contentsOf: marker, encoding: .utf8) else { return nil }
        let values = text.split(separator: " ").compactMap { Int32($0) }
        guard values.count == 3 else { return nil }
        return WorkerIdentity(pid: values[0], group: values[1], session: values[2])
    }

    func lockAvailable() throws -> Bool {
        let descriptor = Darwin.open(lockPath, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw SessionTestFailure.systemCall(errno) }
        defer { _ = Darwin.close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
        guard errno == EWOULDBLOCK || errno == EAGAIN else { throw SessionTestFailure.systemCall(errno) }
        return false
    }

    func nativeExited(_ pid: Int32) -> Bool {
        var information = siginfo_t()
        return waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT) == 0 && information.si_pid == pid
    }

    func nativeIsZombie(_ pid: Int32) -> Bool {
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var information = kinfo_proc()
        var bytes = MemoryLayout<kinfo_proc>.stride
        return sysctl(&query, UInt32(query.count), &information, &bytes, nil, 0) == 0
            && bytes == MemoryLayout<kinfo_proc>.stride && information.kp_proc.p_pid == pid
            && information.kp_proc.p_stat == Int8(SZOMB)
    }

    func releaseWorker() throws { try Data().write(to: workerRelease) }

    func remove() {
        ownerWriter.close(); ownerReader.close(); lock.close(); output.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class SessionDescriptor: Sendable {
    private let descriptor: Mutex<Int32?>
    var value: Int32 { descriptor.withLock { $0 ?? -1 } }
    private init(_ value: Int32) { descriptor = Mutex(value) }
    deinit { close() }

    static func open(_ path: String) throws -> SessionDescriptor {
        let descriptor = Darwin.open(path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SessionTestFailure.systemCall(errno) }
        defer { _ = Darwin.close(descriptor) }
        return try duplicate(descriptor)
    }

    static func duplicate(_ value: Int32) throws -> SessionDescriptor {
        let copy = fcntl(value, F_DUPFD_CLOEXEC, 64)
        guard copy >= 64 else { throw SessionTestFailure.systemCall(errno) }
        return SessionDescriptor(copy)
    }

    func close() {
        let retiring = descriptor.withLock { value -> Int32? in
            let retiring = value
            value = nil
            return retiring
        }
        if let retiring { _ = Darwin.close(retiring) }
    }
}

private enum SessionTestFailure: Error { case systemCall(Int32), timedOut }

private func sessionWaitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw SessionTestFailure.timedOut }
        try await Task.sleep(for: .milliseconds(5))
    }
}
