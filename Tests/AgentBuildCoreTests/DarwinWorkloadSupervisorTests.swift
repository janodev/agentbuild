import AgentBuildCore
import AgentLeaseCore
import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing

@Suite("Trusted Darwin native workload")
struct DarwinWorkloadSupervisorTests {
    @Test func preservesLiteralArgumentsBinaryOutputCwdAndNativeFailure() async throws {
        let fixture = try WorkloadFixture()
        defer { fixture.remove() }
        let literal = "spaces `backticks` $(not-executed)"
        let command = try fixture.command(
            script: #"printf '%s\n%s\n' "$PWD" "$1"; printf '\000\377\200'; printf 'stderr' >&2; if read value; then exit 88; fi; exit 23"#,
            arguments: [literal]
        )
        let result = await fixture.run(command)
        #expect(result.termination == RunTermination(kind: .exit, value: 23))
        #expect(result.retirement == .reaped)
        #expect(result.stopReason == nil)
        #expect(result.failures.isEmpty)
        var expected = Data("\(fixture.directory.path)\n\(literal)\n".utf8)
        expected.append(contentsOf: [0, 255, 128])
        #expect(try Data(contentsOf: fixture.outputURL) == expected)
        #expect(try Data(contentsOf: fixture.errorURL) == Data("stderr".utf8))
        try expectReaped(result)
    }

    @Test func signalRemainsNativeSignalEvidence() async throws {
        let fixture = try WorkloadFixture()
        defer { fixture.remove() }
        let result = await fixture.run(try fixture.command(script: "kill -TERM $$"))
        #expect(result.termination == RunTermination(kind: .signal, value: SIGTERM))
        #expect(result.failures.isEmpty)
        try expectReaped(result)
    }

    @Test(arguments: [false, true])
    func prelaunchFailureDoesNotInventNativeTermination(missingDirectory: Bool) async throws {
        let fixture = try WorkloadFixture()
        defer { fixture.remove() }
        let command = try DarwinWorkloadCommand(
            executable: missingDirectory ? "/bin/sh" : fixture.directory.appendingPathComponent("missing-command").path,
            arguments: ["-c", "exit 0"],
            workingDirectory: missingDirectory ? fixture.directory.appendingPathComponent("missing-directory").path : fixture.directory.path,
            environment: [:]
        )
        let result = await fixture.run(command)
        #expect(result.retirement == .notStarted)
        #expect(result.processIdentifier == nil)
        #expect(result.termination == nil)
        #expect(result.failures.contains { $0.operation == (missingDirectory ? "open(cwd)" : "posix_spawn") && $0.code == ENOENT })
    }

    @Test func ownerAlreadyGoneDoesNotLaunch() async throws {
        let fixture = try WorkloadFixture()
        defer { fixture.remove() }
        fixture.closeOwner()
        let started = WorkloadValue<Int32?>(nil)
        let result = await fixture.run(try fixture.command(script: "exit 0")) { started.set($0) }
        #expect(started.get() == nil)
        #expect(result.retirement == .notStarted)
        #expect(result.termination == nil)
        #expect(result.stopReason == .ownerEOF)
        #expect(result.failures.isEmpty)
    }

    @Test func ownerEOFReapsIgnoringGroupBeforeLastLockReferenceCloses() async throws {
        let fixture = try WorkloadFixture()
        defer { fixture.remove() }
        let started = WorkloadValue<Int32?>(nil)
        let command = try fixture.command(script: #"trap '' TERM INT; printf '%s' "$$" > "$1"; sleep 30 & wait"#,
                                          arguments: [fixture.markerURL.path])
        let task = Task {
            await fixture.run(command) { pid in
                fixture.closeOriginalLock()
                started.set(pid)
            }
        }
        defer { fixture.closeOwner(); task.cancel() }
        try await workloadWaitUntil { started.get() != nil && FileManager.default.fileExists(atPath: fixture.markerURL.path) }
        let pid = try #require(started.get())
        #expect(getpgid(pid) == pid)
        #expect(try !fixture.lockAvailable())
        #expect(try nativeHasLock(pid, fixture: fixture))
        fixture.closeOwner()
        let result = await task.value
        #expect(result.stopReason == .ownerEOF)
        #expect(result.termination == RunTermination(kind: .signal, value: SIGKILL))
        #expect(result.failures.isEmpty)
        try expectReaped(result)
        #expect(try fixture.lockAvailable())
    }

    @Test func normalLeaderExitRetiresLingeringWriterAndPreservesItsExitCode() async throws {
        let fixture = try WorkloadFixture()
        defer { fixture.remove() }
        let descendantMarker = fixture.directory.appendingPathComponent("descendant.pid")
        let script = #"/bin/sh -c 'trap "" TERM INT; printf "descendant\n"; printf "%s" "$$" > "$1"; sleep 30 & wait' descendant "$1" & while [ ! -s "$1" ]; do sleep 0.01; done; exit 41"#
        let command = try fixture.command(script: script, arguments: [descendantMarker.path])
        let result = await fixture.run(command) { _ in fixture.closeOriginalLock() }
        #expect(result.termination == RunTermination(kind: .exit, value: 41))
        #expect(result.stopReason == nil)
        #expect(result.failures.isEmpty)
        #expect(try Data(contentsOf: fixture.outputURL) == Data("descendant\n".utf8))
        let descendant = try markerPID(descendantMarker)
        #expect(kill(descendant, 0) == -1 && errno == ESRCH)
        try expectReaped(result)
        #expect(try fixture.lockAvailable())
    }

    @Test func taskCancellationAwaitsRetirementInsteadOfAbandoningWorker() async throws {
        let fixture = try WorkloadFixture()
        defer { fixture.remove() }
        let command = try fixture.command(script: #"trap '' TERM INT; printf '%s' "$$" > "$1"; sleep 30 & wait"#,
                                          arguments: [fixture.markerURL.path])
        let task = Task { await fixture.run(command) { _ in fixture.closeOriginalLock() } }
        defer { fixture.closeOwner(); task.cancel() }
        try await workloadWaitUntil { FileManager.default.fileExists(atPath: fixture.markerURL.path) }
        #expect(try !fixture.lockAvailable())
        task.cancel()
        let result = await task.value
        #expect(result.stopReason == .cancelled)
        #expect(result.termination == RunTermination(kind: .signal, value: SIGKILL))
        #expect(result.failures.isEmpty)
        try expectReaped(result)
        #expect(try fixture.lockAvailable())
    }

    @Test func captureFailureStopsWorkAndKeepsFailureSeparateFromNativeSignal() async throws {
        let fixture = try WorkloadFixture()
        defer { fixture.remove() }
        let failure = WorkloadValue<DarwinWorkloadFailure?>(nil)
        let expected = DarwinWorkloadFailure(operation: "rawCapture", code: ENOSPC)
        let command = try fixture.command(script: #"trap '' TERM INT; printf '%s' "$$" > "$1"; sleep 30 & wait"#,
                                          arguments: [fixture.markerURL.path])
        let task = Task {
            await fixture.run(command, onStart: { _ in fixture.closeOriginalLock() }, observeFailure: { failure.get() })
        }
        defer { fixture.closeOwner(); task.cancel() }
        try await workloadWaitUntil { FileManager.default.fileExists(atPath: fixture.markerURL.path) }
        failure.set(expected)
        let result = await task.value
        #expect(result.stopReason == .ancillaryFailure)
        #expect(result.failures == [expected])
        #expect(result.termination == RunTermination(kind: .signal, value: SIGKILL))
        try expectReaped(result)
        #expect(try fixture.lockAvailable())
    }

    @Test func callbackFailureCannotEraseAlreadyObservedNativeFailure() async throws {
        let fixture = try WorkloadFixture()
        defer { fixture.remove() }
        let command = try fixture.command(script: "exit 44")
        let result = await fixture.run(command) { pid in
            fixture.closeOriginalLock()
            try waitForExitedWithoutReaping(pid)
            throw DarwinWorkloadFailure(operation: "fixture callback", code: EIO)
        }
        #expect(result.termination == RunTermination(kind: .exit, value: 44))
        #expect(result.stopReason == .ancillaryFailure)
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.operation == "onStart")
        try expectReaped(result)
        #expect(try fixture.lockAvailable())
    }

    @Test func activeStartupCallbackFailureRetiresGroupBeforeReturning() async throws {
        let fixture = try WorkloadFixture()
        defer { fixture.remove() }
        let command = try fixture.command(script: #"trap '' TERM INT; printf '%s' "$$" > "$1"; sleep 30 & wait"#,
                                          arguments: [fixture.markerURL.path])
        let result = await fixture.run(command) { _ in
            fixture.closeOriginalLock()
            let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
            while !FileManager.default.fileExists(atPath: fixture.markerURL.path) {
                guard DispatchTime.now().uptimeNanoseconds < deadline else { throw WorkloadTestFailure.timedOut }
                usleep(1_000)
            }
            throw DarwinWorkloadFailure(operation: "fixture startup failure", code: EIO)
        }
        #expect(result.stopReason == .ancillaryFailure)
        #expect(result.termination == RunTermination(kind: .signal, value: SIGKILL))
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.operation == "onStart")
        try expectReaped(result)
        #expect(try fixture.lockAvailable())
    }

    @Test func nativeNeverInheritsOwnerPipeOrUnrelatedDescriptors() async throws {
        let fixture = try WorkloadFixture()
        defer { fixture.remove() }
        let foreign = try WorkloadDescriptor.open(fixture.directory.appendingPathComponent("unrelated").path)
        defer { foreign.close() }
        let number = foreign.value()
        let flags = fcntl(number, F_GETFD)
        try #require(fcntl(number, F_SETFD, flags & ~FD_CLOEXEC) == 0)
        let command = try fixture.command(
            script: #"for number in "$@"; do if [ -e "/dev/fd/$number" ]; then exit 77; fi; done; exit 0"#,
            arguments: [String(fixture.ownerReader.value()), String(fixture.ownerWriter.value()), String(number)]
        )
        let result = await fixture.run(command)
        #expect(result.termination == RunTermination(kind: .exit, value: 0))
        #expect(result.failures.isEmpty)
        #expect(fcntl(number, F_GETFD) == flags & ~FD_CLOEXEC)
        #expect(fcntl(fixture.ownerReader.value(), F_GETFD) & FD_CLOEXEC != 0)
        #expect(fcntl(fixture.lock.value(), F_GETFD) & FD_CLOEXEC != 0)
    }
}

private final class WorkloadFixture: Sendable {
    let directory: URL
    let outputURL: URL
    let errorURL: URL
    let markerURL: URL
    let lockURL: URL
    let lock: WorkloadDescriptor
    let ownerReader: WorkloadDescriptor
    let ownerWriter: WorkloadDescriptor
    let output: WorkloadDescriptor
    let error: WorkloadDescriptor
    let lockDevice: UInt32
    let lockInode: UInt64

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentbuild-workload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var canonical = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(directory.path, &canonical) != nil else { throw WorkloadTestFailure.systemCall(errno) }
        guard let canonicalPath = canonical.withUnsafeBufferPointer({ String(validatingCString: $0.baseAddress!) }) else {
            throw WorkloadTestFailure.systemCall(EILSEQ)
        }
        self.directory = URL(fileURLWithPath: canonicalPath)
        outputURL = self.directory.appendingPathComponent("stdout")
        errorURL = self.directory.appendingPathComponent("stderr")
        markerURL = self.directory.appendingPathComponent("ready.pid")
        lockURL = self.directory.appendingPathComponent("owned.lock")
        lock = try WorkloadDescriptor.open(lockURL.path)
        guard flock(lock.value(), LOCK_EX | LOCK_NB) == 0 else { throw WorkloadTestFailure.systemCall(errno) }
        var lockStatus = stat()
        guard fstat(lock.value(), &lockStatus) == 0 else { throw WorkloadTestFailure.systemCall(errno) }
        lockDevice = UInt32(bitPattern: lockStatus.st_dev)
        lockInode = UInt64(lockStatus.st_ino)
        var pipeDescriptors: [Int32] = [0, 0]
        guard pipe(&pipeDescriptors) == 0 else { throw WorkloadTestFailure.systemCall(errno) }
        defer { _ = Darwin.close(pipeDescriptors[0]); _ = Darwin.close(pipeDescriptors[1]) }
        ownerReader = try WorkloadDescriptor.duplicate(pipeDescriptors[0])
        ownerWriter = try WorkloadDescriptor.duplicate(pipeDescriptors[1])
        output = try WorkloadDescriptor.open(outputURL.path)
        error = try WorkloadDescriptor.open(errorURL.path)
    }

    func command(script: String, arguments: [String] = []) throws -> DarwinWorkloadCommand {
        try DarwinWorkloadCommand(executable: "/bin/sh", arguments: ["-c", script, "workload-fixture"] + arguments,
                                  workingDirectory: directory.path, environment: ["PATH": "/usr/bin:/bin"])
    }

    func run(
        _ command: DarwinWorkloadCommand,
        onStart: @escaping @Sendable (Int32) throws -> Void = { _ in },
        observeFailure: @escaping @Sendable () -> DarwinWorkloadFailure? = { nil }
    ) async -> DarwinWorkloadResult {
        await DarwinWorkloadSupervisor().run(
            command, retainedLockDescriptors: [lock.value()], ownerLifelineDescriptor: ownerReader.value(),
            standardOutputDescriptor: output.value(), standardErrorDescriptor: error.value(),
            onStart: onStart, observeFailure: observeFailure
        )
    }

    func closeOwner() { ownerWriter.close() }
    func closeOriginalLock() { lock.close() }

    func lockAvailable() throws -> Bool {
        let probe = Darwin.open(lockURL.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard probe >= 0 else { throw WorkloadTestFailure.systemCall(errno) }
        defer { _ = Darwin.close(probe) }
        let result = flock(probe, LOCK_EX | LOCK_NB)
        if result == 0 { return true }
        guard errno == EWOULDBLOCK || errno == EAGAIN else { throw WorkloadTestFailure.systemCall(errno) }
        return false
    }

    func remove() {
        ownerWriter.close(); ownerReader.close(); lock.close(); output.close(); error.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class WorkloadDescriptor: Sendable {
    private let state: Mutex<Int32?>

    private init(_ descriptor: Int32) { state = Mutex(descriptor) }
    deinit { close() }

    static func open(_ path: String) throws -> WorkloadDescriptor {
        let original = Darwin.open(path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard original >= 0 else { throw WorkloadTestFailure.systemCall(errno) }
        defer { _ = Darwin.close(original) }
        return try duplicate(original)
    }

    static func duplicate(_ descriptor: Int32) throws -> WorkloadDescriptor {
        let copy = fcntl(descriptor, F_DUPFD_CLOEXEC, 64)
        guard copy >= 64 else { throw WorkloadTestFailure.systemCall(errno) }
        return WorkloadDescriptor(copy)
    }

    func value() -> Int32 { state.withLock { $0 ?? -1 } }

    func close() {
        let descriptor = state.withLock { state -> Int32? in
            let value = state
            state = nil
            return value
        }
        if let descriptor { _ = Darwin.close(descriptor) }
    }
}

private final class WorkloadValue<Value: Sendable>: Sendable {
    let state: Mutex<Value>
    init(_ value: Value) { state = Mutex(value) }
    func get() -> Value { state.withLock { $0 } }
    func set(_ value: Value) { state.withLock { $0 = value } }
}

private enum WorkloadTestFailure: Error {
    case systemCall(Int32)
    case timedOut
}

private func workloadWaitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw WorkloadTestFailure.timedOut }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private func markerPID(_ marker: URL) throws -> Int32 {
    try #require(Int32(String(contentsOf: marker, encoding: .utf8)))
}

private func expectReaped(_ result: DarwinWorkloadResult) throws {
    #expect(result.retirement == .reaped)
    let pid = try #require(result.processIdentifier)
    var status: Int32 = 0
    #expect(waitpid(pid, &status, WNOHANG) == -1 && errno == ECHILD)
}

private func waitForExitedWithoutReaping(_ pid: Int32) throws {
    let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
    while DispatchTime.now().uptimeNanoseconds < deadline {
        var information = siginfo_t()
        guard waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT) == 0 else {
            throw WorkloadTestFailure.systemCall(errno)
        }
        if information.si_pid == pid { return }
        usleep(1_000)
    }
    throw WorkloadTestFailure.timedOut
}

private func nativeHasLock(_ pid: Int32, fixture: WorkloadFixture) throws -> Bool {
    var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: 1_024)
    let count = descriptors.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
    guard count > 0, Int(count) < descriptors.count * MemoryLayout<proc_fdinfo>.stride else {
        throw WorkloadTestFailure.systemCall(errno)
    }
    for descriptor in descriptors.prefix(Int(count) / MemoryLayout<proc_fdinfo>.stride)
    where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
        var information = vnode_fdinfo()
        let bytes = proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEINFO, &information, Int32(MemoryLayout<vnode_fdinfo>.size))
        if bytes == MemoryLayout<vnode_fdinfo>.size,
           information.pvi.vi_stat.vst_dev == fixture.lockDevice,
           information.pvi.vi_stat.vst_ino == fixture.lockInode { return true }
    }
    return false
}
