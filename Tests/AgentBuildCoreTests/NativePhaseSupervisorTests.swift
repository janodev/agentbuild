@testable import AgentBuildCore
import AgentLeaseCore
import Darwin
import Foundation
import Synchronization
import Testing

@Suite("Private native phase helper")
struct NativePhaseSupervisorTests {
    @Test func directoryChangedBeforeRequestProducesAuthenticatedNoSpawnAndReleasesLocks() async throws {
        let fixture = try PhaseFixture()
        defer { fixture.remove() }
        let directory = fixture.url("result.xcresult")
        let moved = fixture.url("retained-result.xcresult")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 3 else { throw PhaseTestError.systemCall(errno) }
        let owned = PhaseDescriptor(descriptor)
        defer { owned.close() }
        let started = PhaseValue(false)
        let command = try DarwinWorkloadCommand(executable: "/bin/sh", arguments: ["-c", #"touch "$1""#, "fixture", fixture.marker.path],
                                                workingDirectory: directory.path, environment: ["PATH": "/usr/bin:/bin"])
        let result = await NativePhaseSupervisor().run(
            helperExecutable: fixture.helper, command: command,
            retainedLockDescriptors: [fixture.lock.number], nativeWorkingDirectoryDescriptor: owned.number,
            standardOutputDescriptor: fixture.output.number, standardErrorDescriptor: fixture.error.number,
            onHelperStart: { _ in
                // Parent has not written the request yet, so the helper cannot
                // admit or spawn this command before the entry changes.
                try FileManager.default.moveItem(at: directory, to: moved)
                try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: moved)
                owned.close(); fixture.lock.close()
            },
            onNativeStart: { _ in started.set(true) })
        #expect(result.retirement == .proven)
        #expect(result.quarantine == nil)
        #expect(result.helperTermination == RunTermination(kind: .exit, value: 0))
        #expect(result.workload?.retirement == .notStarted)
        #expect(result.workload?.processIdentifier == nil)
        #expect(result.workload?.termination == nil)
        #expect(result.workload?.stopReason == .ancillaryFailure)
        #expect(result.workload?.failures.contains { $0.operation == "native worker protocol" } == true)
        #expect(!started.get())
        #expect(!FileManager.default.fileExists(atPath: fixture.marker.path))
        #expect(try fixture.available())
        try phaseExpectHelperReaped(result)
    }

    @Test func pinnedDirectorySurvivesCallerDescriptorCloseAndNeverBecomesLockAuthority() async throws {
        let fixture = try PhaseFixture()
        defer { fixture.remove() }
        let directory = fixture.url("result.xcresult")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        try Data("retained result bytes".utf8).write(to: directory.appendingPathComponent("evidence"))
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        #expect(descriptor >= 3)
        let owned = PhaseDescriptor(descriptor)
        defer { owned.close() }
        let command = try DarwinWorkloadCommand(executable: "/bin/sh", arguments: ["-c", "cat evidence; sleep 0.5"],
                                                workingDirectory: directory.path,
                                                environment: ["PATH": "/usr/bin:/bin"])
        let result = await NativePhaseSupervisor().run(
            helperExecutable: fixture.helper, command: command,
            retainedLockDescriptors: [fixture.lock.number], nativeWorkingDirectoryDescriptor: owned.number,
            standardOutputDescriptor: fixture.output.number, standardErrorDescriptor: fixture.error.number,
            onHelperStart: { _ in owned.close(); fixture.lock.close() },
            onNativeStart: { pid in
                do {
                    let hasDirectory = try phaseProcessHasDirectory(pid)
                    #expect(!hasDirectory)
                } catch { Issue.record(error) }
            })
        #expect(result.retirementProven)
        #expect(result.workload?.termination == RunTermination(kind: .exit, value: 0))
        #expect(result.failures.isEmpty)
        #expect(result.workload?.failures.isEmpty == true)
        var identity = stat()
        #expect(lstat(directory.path, &identity) == 0)
        #expect(result.workingDirectoryIdentity?.device == Int64(identity.st_dev))
        #expect(result.workingDirectoryIdentity?.inode == UInt64(identity.st_ino))
        #expect(try Data(contentsOf: fixture.outputURL) == Data("retained result bytes".utf8))
        #expect(try fixture.available())
    }

    @Test func helperReceiptPreservesBinaryOutputLiteralArgumentsAndNativeFailure() async throws {
        let fixture = try PhaseFixture()
        defer { fixture.remove() }
        let helper = PhaseValue<Int32?>(nil)
        let native = PhaseValue<Int32?>(nil)
        let literal = "$(false) `literal` space"
        let command = try fixture.command(#"printf '%s\n%s\n%s\n' "$PWD" "$1" "$VALUE"; printf '\000\377\200'; printf stderr >&2; if read line; then exit 99; fi; exit 29"#,
                                          arguments: [literal], environment: ["PATH": "/usr/bin:/bin", "VALUE": "inherited literally"])
        let result = await fixture.run(command, onHelperStart: { helper.set($0); fixture.lock.close() },
                                       onNativeStart: { native.set($0) })
        #expect(result.retirement == .proven)
        #expect(result.retirementProven)
        #expect(result.quarantine == nil)
        #expect(result.helperTermination == RunTermination(kind: .exit, value: 0))
        #expect(result.workload?.termination == RunTermination(kind: .exit, value: 29))
        #expect(result.workload?.retirement == .reaped)
        #expect(result.failures.isEmpty)
        #expect(result.workload?.failures.isEmpty == true)
        #expect(helper.get() == result.helperPID)
        #expect(native.get() == result.workload?.processIdentifier)
        #expect(helper.get() != native.get())
        var expected = Data("\(fixture.path)\n\(literal)\ninherited literally\n".utf8)
        expected.append(contentsOf: [0, 255, 128])
        let actual = try Data(contentsOf: fixture.outputURL)
        #expect(actual == expected,
                "Native stdout differs: expected \(Array(expected)), observed \(Array(actual))")
        #expect(try Data(contentsOf: fixture.errorURL) == Data("stderr".utf8))
        #expect(try fixture.available())
        try phaseExpectHelperReaped(result)
    }

    @Test func cancellationClosesLifelineAndWaitsForIgnoringNativeGroup() async throws {
        let fixture = try PhaseFixture()
        defer { fixture.remove() }
        let helper = PhaseValue<Int32?>(nil)
        let native = PhaseValue<Int32?>(nil)
        let task = Task {
            await fixture.run(try fixture.command(#"trap '' TERM INT; printf '%s' "$$" > "$1"; sleep 30 & wait"#,
                                                  arguments: [fixture.marker.path]),
                              onHelperStart: { helper.set($0); fixture.lock.close() }, onNativeStart: { native.set($0) })
        }
        defer { task.cancel() }
        try await phaseWaitUntil { FileManager.default.fileExists(atPath: fixture.marker.path) && native.get() != nil }
        let nativePID = try #require(native.get())
        let helperPID = try #require(helper.get())
        #expect(getpgid(helperPID) == helperPID)
        #expect(getpgid(nativePID) == nativePID)
        #expect(try !fixture.available())
        task.cancel()
        let result = try await task.value
        #expect(result.cancellationRequested)
        #expect(result.retirementProven)
        #expect(result.workload?.stopReason == .ownerEOF)
        #expect(result.workload?.termination == RunTermination(kind: .signal, value: SIGKILL))
        #expect(result.helperTermination == RunTermination(kind: .exit, value: 0))
        #expect(result.failures.isEmpty)
        #expect(kill(nativePID, 0) == -1 && errno == ESRCH)
        #expect(try fixture.available())
        try phaseExpectHelperReaped(result)
    }

    @Test func requestLargerThanPipeCapacityKeepsLiteralEnvironmentAndCompletes() async throws {
        let fixture = try PhaseFixture()
        defer { fixture.remove() }
        let value = String(repeating: "x", count: 8_192)
        let environment = Dictionary(uniqueKeysWithValues: (0..<20).map { ("PART\($0)", value) })
        let result = await fixture.run(try fixture.command(#"printf '%s' "$PART19""#, environment: environment),
                                       onHelperStart: { _ in fixture.lock.close() })
        #expect(result.retirementProven)
        #expect(result.workload?.termination == RunTermination(kind: .exit, value: 0))
        #expect(result.failures.isEmpty)
        #expect(try Data(contentsOf: fixture.outputURL) == Data(value.utf8))
        #expect(try fixture.available())
    }

    @Test func startupCallbackFailureProducesAuthenticatedNotStartedReceipt() async throws {
        let fixture = try PhaseFixture()
        defer { fixture.remove() }
        let result = await fixture.run(try fixture.command(#"touch "$1""#, arguments: [fixture.marker.path]),
                                       onHelperStart: { _ in
                                           fixture.lock.close()
                                           throw DarwinWorkloadFailure(operation: "fixture startup", code: EIO)
                                       })
        #expect(result.retirementProven)
        #expect(result.workload?.retirement == .notStarted)
        #expect(result.workload?.termination == nil)
        #expect(result.failures.contains { $0.operation == "fixture startup" })
        #expect(!FileManager.default.fileExists(atPath: fixture.marker.path))
        #expect(try fixture.available())
        try phaseExpectHelperReaped(result)
    }

    @Test func nativeCallbackFailureCannotEraseCompletedNativeFailure() async throws {
        let fixture = try PhaseFixture()
        defer { fixture.remove() }
        let result = await fixture.run(try fixture.command("exit 43"), onHelperStart: { _ in fixture.lock.close() },
                                       onNativeStart: { pid in
                                           let deadline = Date().addingTimeInterval(5)
                                           while kill(pid, 0) == 0 {
                                               guard Date() < deadline else { throw PhaseTestError.deadline }
                                               usleep(1_000)
                                           }
                                           throw DarwinWorkloadFailure(operation: "fixture native callback", code: EIO)
                                       })
        #expect(result.retirementProven)
        #expect(result.workload?.termination == RunTermination(kind: .exit, value: 43))
        #expect(result.failures.contains { $0.operation == "fixture native callback" })
        #expect(try fixture.available())
        try phaseExpectHelperReaped(result)
    }

    @Test func captureFailureRetiresGroupAndPreservesItsSeparateDiagnostic() async throws {
        let fixture = try PhaseFixture()
        defer { fixture.remove() }
        let capture = PhaseValue<DarwinWorkloadFailure?>(nil)
        let expected = DarwinWorkloadFailure(operation: "capture fixture", code: ENOSPC)
        let task = Task {
            await fixture.run(try fixture.command(#"trap '' TERM INT; printf '%s' "$$" > "$1"; sleep 30 & wait"#,
                                                  arguments: [fixture.marker.path]),
                              onHelperStart: { _ in fixture.lock.close() }, observeFailure: { capture.get() })
        }
        defer { task.cancel() }
        try await phaseWaitUntil { FileManager.default.fileExists(atPath: fixture.marker.path) }
        capture.set(expected)
        let result = try await task.value
        #expect(result.retirementProven)
        #expect(result.failures.contains(expected))
        #expect(result.workload?.termination == RunTermination(kind: .signal, value: SIGKILL))
        #expect(result.workload?.stopReason == .ownerEOF)
        #expect(try fixture.available())
    }

    @Test func missingHelperDoesNotInventNativeEvidence() async throws {
        let fixture = try PhaseFixture()
        defer { fixture.remove() }
        let result = await fixture.run(try fixture.command("exit 0"), helper: fixture.path + "/missing")
        #expect(result.helperPID == nil)
        #expect(result.helperTermination == nil)
        #expect(result.workload == nil)
        #expect(result.retirement == .notStarted)
        #expect(result.quarantine == nil)
        #expect(result.failures.contains { $0.operation == "spawn native helper" && $0.code == ENOENT })
    }

    @Test func missingReceiptKeepsLocksEvenWhenReturnedHandleIsDropped() async throws {
        let fixture = try PhaseFixture()
        defer { fixture.remove() }
        do {
            let result = await fixture.run(try fixture.command("exit 0"), helper: "/usr/bin/true",
                                           onHelperStart: { _ in fixture.lock.close() })
            #expect(!result.retirementProven)
            #expect(result.workload == nil)
            #expect(result.quarantine?.nativePID == nil)
            #expect(result.quarantine?.quiescenceProven == false)
            #expect(try !fixture.available())
        }
        // An ignored incomplete result cannot close the last actual reference.
        #expect(try !fixture.available())
    }

    @Test func helperDeathQuarantinesLocksUntilAllGroupMembersFinish() async throws {
        let fixture = try PhaseFixture()
        defer { fixture.remove() }
        let helper = PhaseValue<Int32?>(nil)
        let native = PhaseValue<Int32?>(nil)
        let leaderFinish = fixture.url("leader-finish")
        let childFinish = fixture.url("child-finish")
        let childPIDFile = fixture.url("child.pid")
        let source = #"""
        import os, subprocess, sys, time
        child = subprocess.Popen([sys.executable, '-c', 'import os,sys,time;open(sys.argv[1],"w").write(str(os.getpid()));\nwhile not os.path.exists(sys.argv[2]): time.sleep(.01)', sys.argv[2], sys.argv[4]], close_fds=True)
        open(sys.argv[1], 'w').write(str(os.getpid()))
        while not os.path.exists(sys.argv[3]): time.sleep(.01)
        """#
        let command = try DarwinWorkloadCommand(executable: fixture.python, arguments: ["-c", source, fixture.marker.path,
                                                                                     childPIDFile.path, leaderFinish.path, childFinish.path],
                                               workingDirectory: fixture.path, environment: ["PATH": "/usr/bin:/bin"])
        let task = Task { await fixture.run(command, onHelperStart: { helper.set($0); fixture.lock.close() }, onNativeStart: { native.set($0) }) }
        defer {
            try? Data().write(to: leaderFinish)
            try? Data().write(to: childFinish)
            task.cancel()
        }
        try await phaseWaitUntil { helper.get() != nil && native.get() != nil && phaseFileHasBytes(childPIDFile) }
        let helperPID = try #require(helper.get())
        let nativePID = try #require(native.get())
        let childPID = try fixture.pid(childPIDFile)
        #expect(getpgid(childPID) == nativePID)
        #expect(try phaseProcessHasLock(nativePID, fixture: fixture))
        #expect(try !phaseProcessHasLock(childPID, fixture: fixture)) // Real subprocess close-on-exec behavior.
        #expect(kill(helperPID, SIGKILL) == 0)
        let result = await task.value
        #expect(result.helperTermination == RunTermination(kind: .signal, value: SIGKILL))
        #expect(!result.retirementProven)
        #expect(result.workload == nil)
        let quarantine = try #require(result.quarantine)
        #expect(quarantine.nativePID == nativePID)
        #expect(try !fixture.available())
        try phaseExpectHelperReaped(result)
        try Data().write(to: leaderFinish)
        try await phaseWaitUntil { kill(nativePID, 0) < 0 && errno == ESRCH }
        #expect(kill(childPID, 0) == 0)
        #expect(try !fixture.available()) // Native fallback is gone; parent quarantine remains.
        let finished = PhaseValue(false)
        let wait = Task { await quarantine.waitUntilProvenQuiescent(); finished.set(true) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!finished.get())
        try Data().write(to: childFinish)
        await wait.value
        #expect(quarantine.quiescenceProven)
        #expect(try fixture.available())
    }

    @Test func coordinatorSIGKILLLeavesHelperToRetireNativeAndChildBeforeUnlocking() async throws {
        let fixture = try PhaseFixture(locked: false)
        defer { fixture.remove() }
        let childMarker = fixture.url("child.pid")
        let script = #"trap '' TERM INT; /bin/sh -c 'trap "" TERM INT; printf "%s" "$$" > "$1"; sleep 30 & wait' child "$2" & printf '%s' "$$" > "$1"; wait"#
        let process = try fixture.externalCoordinator(script: script, arguments: [fixture.marker.path, childMarker.path])
        defer { fixture.stop(process) }
        try await phaseWaitUntil { FileManager.default.fileExists(atPath: fixture.url("started.json").path) && phaseFileHasBytes(childMarker) }
        let identities = try fixture.identities()
        let childPID = try fixture.pid(childMarker)
        var retired = false
        defer { if !retired { _ = kill(-identities.native, SIGKILL) } }
        #expect(getpgid(identities.helper) == identities.helper)
        #expect(getpgid(identities.native) == identities.native)
        #expect(try !fixture.available())
        #expect(kill(process.processIdentifier, SIGKILL) == 0)
        try await phaseWaitUntil { !process.isRunning && kill(process.processIdentifier, 0) < 0 && errno == ESRCH }
        #expect(process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try !fixture.available()) // TERM-ignoring native remains inside the escalation interval.
        try await phaseWaitUntil {
            guard kill(identities.native, 0) < 0, kill(childPID, 0) < 0 else { return false }
            return try fixture.available()
        }
        #expect(kill(identities.native, 0) == -1 && errno == ESRCH)
        #expect(kill(childPID, 0) == -1 && errno == ESRCH)
        retired = true
        try await phaseWaitUntil { kill(identities.helper, 0) < 0 && errno == ESRCH }
    }

    @Test func simultaneousHelperAndCoordinatorDeathLeavesNativeActualLockFallback() async throws {
        let fixture = try PhaseFixture(locked: false)
        defer { fixture.remove() }
        let finish = fixture.url("finish")
        let process = try fixture.externalCoordinator(script: #"trap '' TERM INT; printf '%s' "$$" > "$1"; while [ ! -e "$2" ]; do sleep .01; done"#,
                                                      arguments: [fixture.marker.path, finish.path])
        defer { fixture.stop(process); try? Data().write(to: finish) }
        try await phaseWaitUntil { FileManager.default.fileExists(atPath: fixture.url("started.json").path) && FileManager.default.fileExists(atPath: fixture.marker.path) }
        let identities = try fixture.identities()
        var retired = false
        defer { if !retired { _ = kill(-identities.native, SIGKILL) } }
        #expect(try phaseProcessHasLock(identities.native, fixture: fixture))
        #expect(kill(identities.helper, SIGKILL) == 0)
        #expect(kill(process.processIdentifier, SIGKILL) == 0)
        try await phaseWaitUntil { !process.isRunning && kill(process.processIdentifier, 0) < 0 && errno == ESRCH }
        #expect(process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL)
        try await phaseWaitUntil { kill(identities.helper, 0) < 0 && errno == ESRCH }
        #expect(kill(identities.native, 0) == 0)
        #expect(try !fixture.available())
        try Data().write(to: finish)
        try await phaseWaitUntil {
            guard kill(identities.native, 0) < 0 else { return false }
            return try fixture.available()
        }
        retired = true
        #expect(try fixture.available())
    }

    @Test func requestAndReportSchemasRejectDuplicatesUnknownFieldsIdentityMismatchAndOversize() throws {
        let nonce = UUID().uuidString
        let command = try DarwinWorkloadCommand(executable: "/bin/sh", workingDirectory: "/", environment: [:])
        let valid = try NativeWorkerProtocol.encodeRequest(.init(command: command, nonce: nonce, locks: []))
        #expect(try NativeWorkerProtocol.decodeRequest(valid, nonce: nonce).executable == "/bin/sh")
        for data in [Data(valid.dropLast()) + Data(",\"extra\":true}".utf8),
                     Data(valid.dropLast()) + Data(",\"nonce\":\"\(nonce)\"}".utf8)] {
            #expect(throws: (any Error).self) { try NativeWorkerProtocol.decodeRequest(data, nonce: nonce) }
        }
        #expect(throws: (any Error).self) { try NativeWorkerProtocol.decodeRequest(valid, nonce: UUID().uuidString) }
        let started = NativeWorkerProtocol.Report.started(nonce: nonce, digest: "digest", pid: 123)
        let report = try JSONEncoder().encode(started)
        #expect(throws: (any Error).self) { try NativeWorkerProtocol.decodeReport(report, nonce: nonce, digest: "other") }
        var oversized = Data([0, 4, 0, 1])
        #expect(throws: (any Error).self) { try NativeWorkerProtocol.takeFrame(&oversized, limit: 256 * 1_024) }
        var partial = try NativeWorkerProtocol.frame(report, limit: NativeWorkerProtocol.maximumReportBytes)
        partial.removeLast()
        #expect(try NativeWorkerProtocol.takeFrame(&partial, limit: NativeWorkerProtocol.maximumReportBytes) == nil)
    }
}

private final class PhaseFixture: Sendable {
    let path: String
    let lock: PhaseDescriptor
    let output: PhaseDescriptor
    let error: PhaseDescriptor
    let device: UInt32
    let inode: UInt64
    let python: String

    var marker: URL { url("native.pid") }
    var outputURL: URL { url("stdout") }
    var errorURL: URL { url("stderr") }
    var lockURL: URL { url("owned.lock") }
    var helper: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug/agentbuild").path
    }

    init(locked: Bool = true) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-phase-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        guard let physicalDirectory = realpath(directory.path, nil) else { throw PhaseTestError.systemCall(errno) }
        defer { free(physicalDirectory) }
        path = String(cString: physicalDirectory)
        lock = try PhaseDescriptor.open(path + "/owned.lock")
        if locked, flock(lock.number, LOCK_EX | LOCK_NB) != 0 { throw PhaseTestError.systemCall(errno) }
        var status = stat()
        guard fstat(lock.number, &status) == 0 else { throw PhaseTestError.systemCall(errno) }
        device = UInt32(bitPattern: status.st_dev)
        inode = UInt64(status.st_ino)
        output = try PhaseDescriptor.open(path + "/stdout")
        error = try PhaseDescriptor.open(path + "/stderr")
        guard let python = ["/opt/homebrew/bin/python3", "/usr/bin/python3"].first(where: {
            $0.withCString { access($0, X_OK) == 0 }
        }) else {
            throw PhaseTestError.noPython
        }
        self.python = python
    }

    func url(_ component: String) -> URL { URL(fileURLWithPath: path + "/" + component) }
    func remove() { lock.close(); output.close(); error.close(); try? FileManager.default.removeItem(atPath: path) }

    func command(_ script: String, arguments: [String] = [], environment: [String: String] = ["PATH": "/usr/bin:/bin"]) throws -> DarwinWorkloadCommand {
        try DarwinWorkloadCommand(executable: "/bin/sh", arguments: ["-c", script, "phase-fixture"] + arguments,
                                  workingDirectory: path, environment: environment)
    }

    func run(
        _ command: DarwinWorkloadCommand, helper: String? = nil,
        onHelperStart: @escaping @Sendable (Int32) throws -> Void = { _ in },
        onNativeStart: @escaping @Sendable (Int32) throws -> Void = { _ in },
        observeFailure: @escaping @Sendable () -> DarwinWorkloadFailure? = { nil }
    ) async -> NativePhaseResult {
        await NativePhaseSupervisor().run(helperExecutable: helper ?? self.helper, command: command,
                                           retainedLockDescriptors: [lock.number], standardOutputDescriptor: output.number,
                                           standardErrorDescriptor: error.number, onHelperStart: onHelperStart,
                                           onNativeStart: onNativeStart, observeFailure: observeFailure)
    }

    func available() throws -> Bool {
        let probe = try PhaseDescriptor.open(lockURL.path)
        defer { probe.close() }
        if flock(probe.number, LOCK_EX | LOCK_NB) == 0 { return true }
        guard errno == EWOULDBLOCK else { throw PhaseTestError.systemCall(errno) }
        return false
    }

    func pid(_ url: URL) throws -> Int32 {
        try #require(Int32(try String(contentsOf: url, encoding: .utf8)))
    }

    func identities() throws -> (helper: Int32, native: Int32) {
        let dictionary = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url("started.json"))) as? [String: Any])
        return (try #require((dictionary["helper"] as? NSNumber)?.int32Value),
                try #require((dictionary["native"] as? NSNumber)?.int32Value))
    }

    func externalCoordinator(script: String, arguments: [String]) throws -> Process {
        let source = #"""
        import fcntl, hashlib, json, os, struct, subprocess, sys, time, uuid
        root, executable, script = sys.argv[1:4]
        lock = os.open(root + '/owned.lock', os.O_RDWR)
        fcntl.flock(lock, fcntl.LOCK_EX)
        request_r, request_w = os.pipe()
        report_r, report_w = os.pipe()
        owner_r, owner_w = os.pipe()
        nonce = str(uuid.uuid4())
        request = dict(schemaVersion=1, nonce=nonce, executable='/bin/sh', arguments=['-c', script, 'external-fixture'] + sys.argv[4:], workingDirectory=root, environment={'PATH':'/usr/bin:/bin'}, lockDescriptors=[lock])
        body = json.dumps(request, separators=(',',':')).encode()
        child = subprocess.Popen([executable, '_native-worker', '--request-fd',str(request_r),'--report-fd',str(report_w),'--owner-fd',str(owner_r),'--nonce',nonce], pass_fds=(lock,request_r,report_w,owner_r), start_new_session=True, stdin=subprocess.DEVNULL, stdout=open(root+'/stdout','wb'), stderr=open(root+'/stderr','wb'))
        for fd in (request_r,report_w,owner_r): os.close(fd)
        framed = struct.pack('>I',len(body)) + body
        while framed:
            count = os.write(request_w,framed)
            framed = framed[count:]
        os.close(request_w)
        def read_exact(n):
            value=b''
            while len(value)<n:
                block=os.read(report_r,n-len(value))
                if not block: raise RuntimeError('report EOF')
                value+=block
            return value
        report=json.loads(read_exact(struct.unpack('>I',read_exact(4))[0]))
        assert report['nonce']==nonce and report['requestDigest']==hashlib.sha256(body).hexdigest() and report['kind']=='started'
        with open(root+'/started.tmp','w') as file: json.dump({'helper':child.pid,'native':report['nativePID']},file)
        os.replace(root+'/started.tmp',root+'/started.json')
        # This process is the only owner writer; SIGKILL must expose EOF to the worker.
        while os.read(report_r,8192): pass
        while True: time.sleep(30)
        """#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-c", source, path, helper, script] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.environment = ["PATH": "/usr/bin:/bin"]
        try process.run()
        return process
    }

    func stop(_ process: Process) {
        guard process.isRunning else { return }
        _ = kill(process.processIdentifier, SIGKILL)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            if !process.isRunning && kill(process.processIdentifier, 0) < 0 && errno == ESRCH { return }
            _ = usleep(10_000)
        }
        Issue.record("Fixture coordinator retirement was not observed before the deadline")
    }
}

private final class PhaseDescriptor: Sendable {
    private let stored: Mutex<Int32?>
    var number: Int32 { stored.withLock { $0 ?? -1 } }
    init(_ descriptor: Int32) { stored = Mutex(descriptor) }
    deinit { close() }

    static func open(_ path: String) throws -> PhaseDescriptor {
        let descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw PhaseTestError.systemCall(errno) }
        return PhaseDescriptor(descriptor)
    }

    func close() {
        stored.withLock { value in
            guard let descriptor = value else { return }
            value = nil
            _ = Darwin.close(descriptor)
        }
    }
}

private final class PhaseValue<Value: Sendable>: Sendable {
    let value: Mutex<Value>
    init(_ value: Value) { self.value = Mutex(value) }
    func get() -> Value { value.withLock { $0 } }
    func set(_ newValue: Value) { value.withLock { $0 = newValue } }
}

private enum PhaseTestError: Error { case deadline, noPython, systemCall(Int32) }

private func phaseFileHasBytes(_ url: URL) -> Bool { ((try? Data(contentsOf: url).count) ?? 0) > 0 }

private func phaseWaitUntil(_ condition: () throws -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    while clock.now < deadline {
        if try condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw PhaseTestError.deadline
}

private func phaseExpectHelperReaped(_ result: NativePhaseResult) throws {
    let pid = try #require(result.helperPID)
    var status: Int32 = 0
    #expect(waitpid(pid, &status, WNOHANG) == -1 && errno == ECHILD)
}

private func phaseProcessHasLock(_ pid: Int32, fixture: PhaseFixture) throws -> Bool {
    let required = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard required > 0 else { throw PhaseTestError.systemCall(errno) }
    var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(required) / MemoryLayout<proc_fdinfo>.stride + 16)
    let count = descriptors.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
    guard count > 0 else { throw PhaseTestError.systemCall(errno) }
    for descriptor in descriptors.prefix(Int(count) / MemoryLayout<proc_fdinfo>.stride) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
        var info = vnode_fdinfo()
        let size = proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEINFO, &info, Int32(MemoryLayout<vnode_fdinfo>.size))
        if size == MemoryLayout<vnode_fdinfo>.size,
           info.pvi.vi_stat.vst_dev == fixture.device,
           info.pvi.vi_stat.vst_ino == fixture.inode { return true }
    }
    return false
}

private func phaseProcessHasDirectory(_ pid: Int32) throws -> Bool {
    let required = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard required > 0 else { throw PhaseTestError.systemCall(errno) }
    var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(required) / MemoryLayout<proc_fdinfo>.stride + 16)
    let count = descriptors.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
    guard count > 0 else { throw PhaseTestError.systemCall(errno) }
    for descriptor in descriptors.prefix(Int(count) / MemoryLayout<proc_fdinfo>.stride)
    where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
        var info = vnode_fdinfo()
        let size = proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEINFO, &info, Int32(MemoryLayout<vnode_fdinfo>.size))
        if size == MemoryLayout<vnode_fdinfo>.size, info.pvi.vi_stat.vst_mode & UInt16(S_IFMT) == UInt16(S_IFDIR) { return true }
    }
    return false
}
