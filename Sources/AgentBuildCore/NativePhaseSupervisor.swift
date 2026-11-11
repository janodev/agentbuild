import AgentLeaseCore
import Darwin
import Dispatch
import Foundation
import Synchronization

public enum NativePhaseRetirement: String, Codable, Sendable {
    case notStarted
    case proven
    case unproven
}

public struct NativePhaseResult: Sendable {
    public let helperPID: Int32?
    public let helperTermination: RunTermination?
    public let workload: DarwinWorkloadResult?
    public let retirement: NativePhaseRetirement
    public let cancellationRequested: Bool
    public let failures: [DarwinWorkloadFailure]
    public let quarantine: NativePhaseQuarantine?
    public let workingDirectoryIdentity: NativeWorkingDirectoryIdentity?

    public var retirementProven: Bool { retirement != .unproven }
}

/// An incomplete helper cannot authorize lock release or CLI exit. The registry
/// keeps the actual references even if this handle is dropped. No PID is signalled.
public final class NativePhaseQuarantine: Sendable {
    public let identifier: UUID
    public let nativePID: Int32?
    public let retirementScope: DarwinWorkloadRetirementScope
    private let releaseState = Mutex(false)

    fileprivate init(descriptors: [Int32], nativePID: Int32?, retirementScope: DarwinWorkloadRetirementScope) {
        identifier = UUID()
        self.nativePID = nativePID
        self.retirementScope = retirementScope
        NativeQuarantineRegistry.entries.withLock { $0[identifier] = descriptors }
    }

    public var quiescenceProven: Bool { releaseState.withLock { $0 } }

    /// Ignores cancellation. Without a start receipt there is no group identity
    /// to inspect: manual recovery is required and this wait conservatively stays.
    public func waitUntilProvenQuiescent() async {
        await withCheckedContinuation { continuation in
            DispatchQueue(label: "agentbuild.native-quarantine", qos: .utility).async {
                while !self.quiescenceProven {
                    if let pid = self.nativePID, self.scopeIsEmpty(pid) {
                        self.releaseState.withLock { state in
                            guard !state else { return }
                            let descriptors = NativeQuarantineRegistry.entries.withLock { $0.removeValue(forKey: self.identifier) }
                            for descriptor in descriptors ?? [] { _ = Darwin.close(descriptor) }
                            state = true
                        }
                    } else { nativePhasePause() }
                }
                continuation.resume()
            }
        }
    }

    private func scopeIsEmpty(_ pid: Int32) -> Bool {
        switch retirementScope {
        case .processGroup: nativePhaseGroupIsEmpty(pid)
        case .session: DarwinProcessSession.liveMembers(of: pid)?.isEmpty == true
        }
    }
}

private enum NativeQuarantineRegistry {
    static let entries = Mutex<[UUID: [Int32]]>([:])
}

/// Owns the private helper, not project admission. The caller supplies admitted
/// actual lock FDs and raw-capture writers; Make or environment claims add no authority.
public struct NativePhaseSupervisor: Sendable {
    public init() {}

    public func run(
        helperExecutable: String,
        command: DarwinWorkloadCommand,
        retainedLockDescriptors: [Int32],
        nativeWorkingDirectoryDescriptor: Int32? = nil,
        standardOutputDescriptor: Int32 = STDOUT_FILENO,
        standardErrorDescriptor: Int32 = STDERR_FILENO,
        onHelperStart: @escaping @Sendable (Int32) throws -> Void = { _ in },
        onNativeStart: @escaping @Sendable (Int32) throws -> Void = { _ in },
        observeFailure: @escaping @Sendable () -> DarwinWorkloadFailure? = { nil }
    ) async -> NativePhaseResult {
        let cancellation = NativePhaseCancellation(cancelled: Task.isCancelled)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue(label: "agentbuild.native-phase", qos: .utility).async {
                    let parent = NativePhaseParent(
                        executable: helperExecutable, command: command, locks: retainedLockDescriptors,
                        nativeWorkingDirectoryDescriptor: nativeWorkingDirectoryDescriptor,
                        output: standardOutputDescriptor, error: standardErrorDescriptor,
                        cancellation: cancellation, onHelperStart: onHelperStart,
                        onNativeStart: onNativeStart, observeFailure: observeFailure
                    )
                    continuation.resume(returning: parent.run())
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

private final class NativePhaseCancellation: Sendable {
    private struct State {
        var cancelled: Bool
        var stopped = false
        var ownerWriter: Int32?
        var failures: [DarwinWorkloadFailure] = []
    }
    private let state: Mutex<State>

    init(cancelled: Bool) { state = Mutex(State(cancelled: cancelled, stopped: cancelled)) }
    var cancelled: Bool { state.withLock { $0.cancelled } }
    var failures: [DarwinWorkloadFailure] { state.withLock { $0.failures } }

    func attach(_ descriptor: Int32) {
        state.withLock { state in
            state.ownerWriter = descriptor
            if state.stopped { closeOwner(&state) }
        }
    }

    func cancel() {
        state.withLock { state in
            state.cancelled = true
            state.stopped = true
            closeOwner(&state)
        }
    }

    func stop() {
        state.withLock { state in
            state.stopped = true
            closeOwner(&state)
        }
    }

    private func closeOwner(_ state: inout State) {
        guard let descriptor = state.ownerWriter else { return }
        state.ownerWriter = nil
        if Darwin.close(descriptor) != 0 {
            state.failures.append(DarwinWorkloadFailure(operation: "close owner lifeline", code: errno))
        }
    }
}

private final class NativePhaseParent {
    let executable: String
    let command: DarwinWorkloadCommand
    let locks: [Int32]
    let nativeWorkingDirectoryDescriptor: Int32?
    let output: Int32
    let error: Int32
    let cancellation: NativePhaseCancellation
    let onHelperStart: @Sendable (Int32) throws -> Void
    let onNativeStart: @Sendable (Int32) throws -> Void
    let observeFailure: @Sendable () -> DarwinWorkloadFailure?
    let nonce = UUID().uuidString
    var owned: [Int32] = []
    var ownedLocks: [Int32] = []
    var directoryBinding: NativeWorkerDirectoryBinding?
    var requestRead: Int32 = -1
    var requestWrite: Int32 = -1
    var reportRead: Int32 = -1
    var reportWrite: Int32 = -1
    var ownerRead: Int32 = -1
    var outputCopy: Int32 = -1
    var errorCopy: Int32 = -1
    var pid: Int32?
    var helperTermination: RunTermination?
    var helperPinUncertain = false
    var nativePID: Int32?
    var receipt: DarwinWorkloadResult?
    var failures: [DarwinWorkloadFailure] = []
    var reportValid = true
    var reportEOF = false
    var reportBuffer = Data()
    var reportBytes = 0
    var request = Data()
    var digest = ""

    init(
        executable: String, command: DarwinWorkloadCommand, locks: [Int32],
        nativeWorkingDirectoryDescriptor: Int32?, output: Int32, error: Int32,
        cancellation: NativePhaseCancellation, onHelperStart: @escaping @Sendable (Int32) throws -> Void,
        onNativeStart: @escaping @Sendable (Int32) throws -> Void,
        observeFailure: @escaping @Sendable () -> DarwinWorkloadFailure?
    ) {
        self.executable = executable
        self.command = command
        self.locks = locks
        self.nativeWorkingDirectoryDescriptor = nativeWorkingDirectoryDescriptor
        self.output = output
        self.error = error
        self.cancellation = cancellation
        self.onHelperStart = onHelperStart
        self.onNativeStart = onNativeStart
        self.observeFailure = observeFailure
    }

    func run() -> NativePhaseResult {
        do {
            guard executable.hasPrefix("/"), !executable.utf8.contains(0) else {
                throw DarwinWorkloadFailure(operation: "validate helper executable", code: EINVAL)
            }
            if !cancellation.cancelled {
                try prepare()
                if !cancellation.cancelled { try spawn() }
            }
        } catch { record(error, operation: "helper preparation") }
        if let pid {
            closeOwned(requestRead); requestRead = -1
            closeOwned(reportWrite); reportWrite = -1
            closeOwned(ownerRead); ownerRead = -1
            do { try onHelperStart(pid) }
            catch { record(error, operation: "helper start callback") }
            monitor(pid)
            if let termination = helperTermination, termination.kind == .signal || termination.value != 0 {
                record(DarwinWorkloadFailure(operation: "native helper termination", code: termination.value,
                                            detail: termination.kind.rawValue), operation: "helper termination")
            }
        }
        cancellation.stop()
        for failure in cancellation.failures { record(failure, operation: "owner lifeline") }
        let proven = pid == nil || (reportValid && reportEOF && receipt != nil)
        var quarantine: NativePhaseQuarantine?
        if !proven {
            quarantine = NativePhaseQuarantine(descriptors: ownedLocks, nativePID: nativePID,
                                               retirementScope: command.retirementScope)
            owned.removeAll { ownedLocks.contains($0) }
            ownedLocks.removeAll()
            record(NativeWorkerProtocol.protocolFailure("native retirement unproven; actual locks quarantined"), operation: "receipt")
        }
        while let descriptor = owned.popLast() {
            if Darwin.close(descriptor) != 0 { record(DarwinWorkloadFailure(operation: "close phase descriptor", code: errno), operation: "close") }
        }
        return NativePhaseResult(helperPID: pid, helperTermination: helperTermination,
                                 workload: receipt,
                                 retirement: pid == nil ? .notStarted : (proven ? .proven : .unproven),
                                 cancellationRequested: cancellation.cancelled, failures: failures, quarantine: quarantine,
                                 workingDirectoryIdentity: directoryBinding?.identity)
    }

    func prepare() throws {
        var childAction = sigaction()
        guard sigaction(SIGCHLD, nil, &childAction) == 0,
              childAction.__sigaction_u.__sa_handler == nil, childAction.sa_flags & SA_NOCLDWAIT == 0 else {
            throw DarwinWorkloadFailure(operation: "helper requires default SIGCHLD policy", code: EINVAL)
        }
        for descriptor in Set(locks).sorted() { ownedLocks.append(try duplicate(descriptor)) }
        if let nativeWorkingDirectoryDescriptor {
            guard !locks.contains(nativeWorkingDirectoryDescriptor),
                  ![output, error].contains(nativeWorkingDirectoryDescriptor) else {
                throw NativeWorkerProtocol.protocolFailure("working directory aliases another capability")
            }
            directoryBinding = try NativeWorkerDirectoryBinding(
                descriptor: duplicate(nativeWorkingDirectoryDescriptor), path: command.workingDirectory)
        }
        (requestRead, requestWrite) = try makePipe()
        (reportRead, reportWrite) = try makePipe()
        let owner = try makePipe()
        ownerRead = owner.0
        owned.removeAll { $0 == owner.1 }
        cancellation.attach(owner.1) // The coordinator is the sole owner of this writer.
        outputCopy = try duplicate(output)
        errorCopy = try duplicate(error)
        try check(fcntl(requestWrite, F_SETNOSIGPIPE, 1), operation: "request F_SETNOSIGPIPE", errnoCode: true)
        for descriptor in [requestWrite, reportRead] {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0 else { throw DarwinWorkloadFailure(operation: "get phase pipe flags", code: errno) }
            try check(fcntl(descriptor, F_SETFL, flags | O_NONBLOCK), operation: "nonblocking phase pipe", errnoCode: true)
        }
        let body = try NativeWorkerProtocol.encodeRequest(.init(command: command, nonce: nonce, locks: ownedLocks,
                                                                workingDirectoryBinding: directoryBinding))
        digest = CanonicalJSONDigest.digest(body)
        request = try NativeWorkerProtocol.frame(body, limit: NativeWorkerProtocol.maximumRequestBytes)
    }

    func duplicate(_ descriptor: Int32) throws -> Int32 {
        let copy = fcntl(descriptor, F_DUPFD_CLOEXEC, 64)
        guard copy >= 64 else { throw DarwinWorkloadFailure(operation: "phase F_DUPFD_CLOEXEC", code: errno) }
        owned.append(copy)
        return copy
    }

    func makePipe() throws -> (Int32, Int32) {
        var descriptors: [Int32] = [0, 0]
        try check(pipe(&descriptors), operation: "phase pipe", errnoCode: true)
        defer { _ = Darwin.close(descriptors[0]); _ = Darwin.close(descriptors[1]) }
        return (try duplicate(descriptors[0]), try duplicate(descriptors[1]))
    }

    func spawn() throws {
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        var initializedAttributes = false
        var initializedActions = false
        defer {
            if initializedActions {
                let code = posix_spawn_file_actions_destroy(&actions)
                if code != 0 { record(DarwinWorkloadFailure(operation: "helper actions destroy", code: code), operation: "spawn") }
            }
            if initializedAttributes {
                let code = posix_spawnattr_destroy(&attributes)
                if code != 0 { record(DarwinWorkloadFailure(operation: "helper attributes destroy", code: code), operation: "spawn") }
            }
        }
        try check(posix_spawnattr_init(&attributes), operation: "helper attributes init")
        initializedAttributes = true
        try check(posix_spawn_file_actions_init(&actions), operation: "helper actions init")
        initializedActions = true
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0), operation: "helper null stdin")
        try check(posix_spawn_file_actions_adddup2(&actions, outputCopy, STDOUT_FILENO), operation: "helper stdout")
        try check(posix_spawn_file_actions_adddup2(&actions, errorCopy, STDERR_FILENO), operation: "helper stderr")
        for descriptor in ownedLocks + [requestRead, reportWrite, ownerRead] + (directoryBinding.map({ [$0.descriptor] }) ?? []) {
            try check(posix_spawn_file_actions_addinherit_np(&actions, descriptor), operation: "helper descriptor whitelist")
        }
        var mask = sigset_t()
        var defaults = sigset_t()
        try check(sigemptyset(&mask), operation: "helper signal mask", errnoCode: true)
        try check(sigfillset(&defaults), operation: "helper signal defaults", errnoCode: true)
        try check(posix_spawnattr_setsigmask(&attributes, &mask), operation: "helper set mask")
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults), operation: "helper set defaults")
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT |
                                                           POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)), operation: "helper flags")
        let argv = try NativePhaseCStringVector([executable, "_native-worker", "--request-fd", String(requestRead),
                                                "--report-fd", String(reportWrite), "--owner-fd", String(ownerRead), "--nonce", nonce])
        let environment = try NativePhaseCStringVector(["PATH=/usr/bin:/bin"])
        var child: pid_t = 0
        let code = argv.pointers.withUnsafeMutableBufferPointer { arguments in
            environment.pointers.withUnsafeMutableBufferPointer { variables in
                posix_spawn(&child, executable, &actions, &attributes, arguments.baseAddress!, variables.baseAddress!)
            }
        }
        if code == 0 { pid = child } // No fallible cleanup before registering the successful PID.
        else { throw DarwinWorkloadFailure(operation: "spawn native helper", code: code) }
    }

    func monitor(_ pid: Int32) {
        var offset = 0
        var escalation: UInt64?
        let startupDeadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
        while true {
            if let failure = observeFailure() { record(failure, operation: "capture") }
            if requestWrite >= 0 {
                let count = request.withUnsafeBytes {
                    Darwin.write(requestWrite, $0.baseAddress!.advanced(by: offset), $0.count - offset)
                }
                if count > 0 { offset += count }
                else if count < 0 && errno != EINTR && errno != EAGAIN {
                    record(DarwinWorkloadFailure(operation: "write helper request", code: errno), operation: "request")
                    closeOwned(requestWrite); requestWrite = -1
                }
                if offset == request.count { closeOwned(requestWrite); requestWrite = -1 }
            }
            readReports()
            let exited = peekHelper(pid)
            if exited == true {
                if nativePhaseGroupContainsOnlyExitedLeader(pid) {
                    var status: Int32 = 0
                    var reaped: Int32
                    repeat { reaped = waitpid(pid, &status, 0) } while reaped < 0 && errno == EINTR
                    if reaped == pid {
                        // Never signal this numeric group after its leader has been reaped.
                        readReports()
                        if !reportEOF { invalidate("report pipe did not reach EOF after helper retirement") }
                        if !reportBuffer.isEmpty { invalidate("truncated report frame") }
                        return
                    }
                    record(DarwinWorkloadFailure(operation: "reap native helper", code: errno), operation: "wait")
                    helperPinUncertain = true
                } else {
                    let now = DispatchTime.now().uptimeNanoseconds
                    let signal: Int32 = escalation == nil || now < escalation! ? SIGTERM : SIGKILL
                    if escalation == nil { escalation = now + 1_000_000_000 }
                    if kill(-pid, signal) != 0, errno != ESRCH {
                        record(DarwinWorkloadFailure(operation: "retire helper group", code: errno), operation: "retirement")
                    }
                }
            }
            if nativePID == nil, receipt == nil, DispatchTime.now().uptimeNanoseconds >= startupDeadline {
                record(DarwinWorkloadFailure(operation: "native helper startup deadline", code: ETIMEDOUT), operation: "startup")
            }
            // Closing the sole owner writer requests native cleanup. Cancellation
            // must never kill the helper that owns native group retirement.
            nativePhasePause()
        }
    }

    func readReports() {
        guard !reportEOF else { return }
        var bytes = [UInt8](repeating: 0, count: 8_192)
        var drained = 0
        while drained < 2 * (NativeWorkerProtocol.maximumReportBytes + 4) {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(reportRead, $0.baseAddress, $0.count) }
            if count == 0 { reportEOF = true; return }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && errno == EAGAIN { return }
            guard count > 0 else {
                invalidate("report pipe read failed")
                reportEOF = true
                return
            }
            reportBytes += count
            drained += count
            guard reportBytes <= 2 * (NativeWorkerProtocol.maximumReportBytes + 4) else {
                invalidate("report stream byte limit")
                continue // Drain without retaining arbitrary extra bytes.
            }
            guard reportValid else { continue }
            reportBuffer.append(contentsOf: bytes.prefix(count))
            do {
                while let frame = try NativeWorkerProtocol.takeFrame(&reportBuffer, limit: NativeWorkerProtocol.maximumReportBytes) {
                    let report = try NativeWorkerProtocol.decodeReport(frame, nonce: nonce, digest: digest)
                    guard receipt == nil else { throw NativeWorkerProtocol.protocolFailure("extra report after terminal receipt") }
                    if let started = report.nativePID {
                        guard nativePID == nil else { throw NativeWorkerProtocol.protocolFailure("duplicate start receipt") }
                        nativePID = started
                        do { try onNativeStart(started) }
                        catch { record(error, operation: "native start callback") }
                    } else if let result = report.result {
                        guard result.processIdentifier == nativePID else { throw NativeWorkerProtocol.protocolFailure("terminal native identity mismatch") }
                        receipt = result
                    }
                }
            } catch { invalidate(String(describing: error)) }
        }
    }

    func peekHelper(_ pid: Int32) -> Bool? {
        guard !helperPinUncertain else { return nil }
        if helperTermination != nil { return true }
        var information = siginfo_t()
        var code: Int32
        repeat { code = waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT) } while code < 0 && errno == EINTR
        guard code == 0 else {
            record(DarwinWorkloadFailure(operation: "observe native helper", code: errno), operation: "wait")
            return nil
        }
        guard information.si_pid == pid else { return false }
        if information.si_code == CLD_EXITED { helperTermination = RunTermination(kind: .exit, value: information.si_status) }
        else if information.si_code == CLD_KILLED || information.si_code == CLD_DUMPED {
            helperTermination = RunTermination(kind: .signal, value: information.si_status)
        } else { record(NativeWorkerProtocol.protocolFailure("unexpected helper wait status"), operation: "wait"); return nil }
        return true
    }

    func closeOwned(_ descriptor: Int32) {
        guard let index = owned.firstIndex(of: descriptor) else { return }
        owned.remove(at: index)
        if Darwin.close(descriptor) != 0 { record(DarwinWorkloadFailure(operation: "close phase descriptor", code: errno), operation: "close") }
    }

    func invalidate(_ detail: String) {
        reportValid = false
        reportBuffer.removeAll()
        record(NativeWorkerProtocol.protocolFailure(detail), operation: "protocol")
    }

    func record(_ error: any Error, operation: String) {
        let failure = (error as? DarwinWorkloadFailure) ?? DarwinWorkloadFailure(operation: operation, detail: String(describing: error))
        if !failures.contains(failure), failures.count < 32 { failures.append(failure) }
        cancellation.stop()
    }

    func check(_ code: Int32, operation: String, errnoCode: Bool = false) throws {
        guard code == 0 else { throw DarwinWorkloadFailure(operation: operation, code: errnoCode ? errno : code) }
    }
}

private final class NativePhaseCStringVector {
    var pointers: [UnsafeMutablePointer<CChar>?] = []

    init(_ values: [String]) throws {
        for value in values {
            guard let pointer = strdup(value) else {
                for pointer in pointers { free(pointer) }
                pointers.removeAll()
                throw DarwinWorkloadFailure(operation: "helper strdup", code: ENOMEM)
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
    }

    deinit { for pointer in pointers { free(pointer) } }
}

private func nativePhaseGroupMembers(_ pid: Int32) -> [Int32]? {
    errno = 0
    let required = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pid), nil, 0)
    guard required >= 0, errno == 0 else { return nil }
    let capacity = max(Int(required) + 1_024, 4_096)
    guard capacity <= 16 * 1_024 * 1_024 else { return nil }
    var members = [Int32](repeating: 0, count: capacity / MemoryLayout<Int32>.stride)
    errno = 0
    let bytes = members.withUnsafeMutableBytes {
        proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pid), $0.baseAddress, Int32($0.count))
    }
    guard bytes >= 0, bytes < capacity, errno == 0, Int(bytes) % MemoryLayout<Int32>.stride == 0 else { return nil }
    return members.prefix(Int(bytes) / MemoryLayout<Int32>.stride).filter { $0 > 0 }
}

private func nativePhaseGroupContainsOnlyExitedLeader(_ pid: Int32) -> Bool { nativePhaseGroupMembers(pid) == [pid] }
private func nativePhaseGroupIsEmpty(_ pid: Int32) -> Bool { nativePhaseGroupMembers(pid)?.isEmpty == true }

private func nativePhasePause() {
    var interval = timespec(tv_sec: 0, tv_nsec: 20_000_000)
    var remainder = timespec()
    while nanosleep(&interval, &remainder) != 0 && errno == EINTR { interval = remainder }
}
