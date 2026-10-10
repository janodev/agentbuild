import AgentLeaseCore
import Darwin
import Dispatch
import Foundation
import Synchronization

public struct DarwinWorkloadCommand: Sendable {
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: String
    public let environment: [String: String]

    public init(
        executable: String, arguments: [String] = [], workingDirectory: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        guard [executable, workingDirectory].allSatisfy({ $0.hasPrefix("/") && !$0.utf8.contains(0) }),
              !arguments.contains(where: { $0.utf8.contains(0) }),
              environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") &&
                  !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) }) else {
            throw DarwinWorkloadFailure(operation: "validateCommand", code: EINVAL)
        }
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

public struct DarwinWorkloadFailure: Codable, Equatable, Error, Sendable {
    public let operation: String
    public let code: Int32?
    public let detail: String?

    public init(operation: String, code: Int32? = nil, detail: String? = nil) {
        self.operation = operation
        self.code = code
        self.detail = detail
    }
}

public enum DarwinWorkloadStopReason: String, Codable, Sendable {
    case ancillaryFailure
    case cancelled
    case ownerEOF
}

public enum DarwinWorkloadRetirement: String, Codable, Sendable {
    case notStarted
    case reaped
}

/// A returned result never represents an uncertain or still-running group.
/// Native termination is independent of capture, callback, and cleanup failures.
public struct DarwinWorkloadResult: Codable, Equatable, Sendable {
    public let processIdentifier: Int32?
    public let termination: RunTermination?
    public let stopReason: DarwinWorkloadStopReason?
    public let retirement: DarwinWorkloadRetirement
    public let failures: [DarwinWorkloadFailure]
}

/// The trusted worker for an owner-derived command, not project route authority.
/// Its calling process must survive the coordinator and watch only its own child.
public struct DarwinWorkloadSupervisor: Sendable {
    public init() {}

    /// Borrowed descriptors are duplicated before launch; caller flags are unchanged.
    /// Only admitted lock duplicates reach the native command as crash fallback;
    /// the owner channel never does. The sole writer of the empty owner pipe must
    /// remain in the coordinator. No other code may
    /// reap this child or alter SIGCHLD policy. Callbacks must return promptly.
    /// Capture owners await this operation before expecting EOF from its output FDs.
    public func run(
        _ command: DarwinWorkloadCommand,
        retainedLockDescriptors: [Int32],
        ownerLifelineDescriptor: Int32,
        nativeWorkingDirectoryDescriptor: Int32? = nil,
        standardOutputDescriptor: Int32 = STDOUT_FILENO,
        standardErrorDescriptor: Int32 = STDERR_FILENO,
        onStart: @escaping @Sendable (Int32) throws -> Void = { _ in },
        observeFailure: @escaping @Sendable () -> DarwinWorkloadFailure? = { nil }
    ) async -> DarwinWorkloadResult {
        let cancellation = WorkloadCancellation(Task.isCancelled)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue(label: "agentbuild.native-workload", qos: .utility).async {
                    let worker = WorkloadWorker(
                        command: command, lockDescriptors: retainedLockDescriptors,
                        ownerDescriptor: ownerLifelineDescriptor,
                        nativeWorkingDirectoryDescriptor: nativeWorkingDirectoryDescriptor,
                        outputDescriptor: standardOutputDescriptor, errorDescriptor: standardErrorDescriptor,
                        cancellation: cancellation, onStart: onStart, observeFailure: observeFailure
                    )
                    continuation.resume(returning: worker.run())
                }
            }
        } onCancel: {
            cancellation.state.withLock { $0 = true }
        }
    }
}

private final class WorkloadWorker {
    let command: DarwinWorkloadCommand
    let lockDescriptors: [Int32]
    let ownerDescriptor: Int32
    let nativeWorkingDirectoryDescriptor: Int32?
    let outputDescriptor: Int32
    let errorDescriptor: Int32
    let cancellation: WorkloadCancellation
    let onStart: @Sendable (Int32) throws -> Void
    let observeFailure: @Sendable () -> DarwinWorkloadFailure?
    var ownedDescriptors: [Int32] = []
    var inheritedLocks: [Int32] = []
    var owner: Int32 = -1
    var output: Int32 = -1
    var error: Int32 = -1
    var directory: Int32 = -1
    var pid: Int32?
    var nativeTermination: RunTermination?
    var stopReason: DarwinWorkloadStopReason?
    var failures: [DarwinWorkloadFailure] = []

    init(
        command: DarwinWorkloadCommand, lockDescriptors: [Int32], ownerDescriptor: Int32,
        nativeWorkingDirectoryDescriptor: Int32?,
        outputDescriptor: Int32, errorDescriptor: Int32, cancellation: WorkloadCancellation,
        onStart: @escaping @Sendable (Int32) throws -> Void,
        observeFailure: @escaping @Sendable () -> DarwinWorkloadFailure?
    ) {
        self.command = command
        self.lockDescriptors = lockDescriptors
        self.ownerDescriptor = ownerDescriptor
        self.nativeWorkingDirectoryDescriptor = nativeWorkingDirectoryDescriptor
        self.outputDescriptor = outputDescriptor
        self.errorDescriptor = errorDescriptor
        self.cancellation = cancellation
        self.onStart = onStart
        self.observeFailure = observeFailure
    }

    func run() -> DarwinWorkloadResult {
        do {
            try prepareDescriptors()
            observeStop()
            if stopReason == nil { spawn() }
        } catch let failure as DarwinWorkloadFailure {
            record(failure)
        } catch {
            record(DarwinWorkloadFailure(operation: "prepare", detail: String(describing: error)))
        }
        if let pid {
            do { try onStart(pid) }
            catch { record(DarwinWorkloadFailure(operation: "onStart", detail: String(describing: error))) }
            retire(pid)
        }
        // A successful spawn is registered before any fallible operation. Only
        // proven group quiescence and exact-child reaping can reach this release.
        while let descriptor = ownedDescriptors.popLast() {
            if Darwin.close(descriptor) != 0 {
                record(DarwinWorkloadFailure(operation: "close", code: errno))
            }
        }
        return DarwinWorkloadResult(
            processIdentifier: pid, termination: nativeTermination, stopReason: stopReason,
            retirement: pid == nil ? .notStarted : .reaped, failures: failures
        )
    }

    func prepareDescriptors() throws {
        var childAction = sigaction()
        try check(sigaction(SIGCHLD, nil, &childAction), operation: "sigaction(SIGCHLD)", useErrno: true)
        guard childAction.__sigaction_u.__sa_handler == nil,
              childAction.sa_flags & SA_NOCLDWAIT == 0 else {
            throw DarwinWorkloadFailure(operation: "SIGCHLD requires default reaping policy", code: EINVAL)
        }
        for descriptor in Set(lockDescriptors).sorted() { inheritedLocks.append(try duplicate(descriptor)) }
        owner = try duplicate(ownerDescriptor)
        var status = stat()
        try check(fstat(owner, &status), operation: "fstat(owner)", useErrno: true)
        let ownerFlags = fcntl(owner, F_GETFL)
        guard status.st_mode & S_IFMT == S_IFIFO, ownerFlags >= 0,
              ownerFlags & O_ACCMODE == O_RDONLY else {
            throw DarwinWorkloadFailure(operation: "owner lifeline must be a read-only pipe", code: EINVAL)
        }
        output = try duplicate(outputDescriptor)
        error = try duplicate(errorDescriptor)
        if let nativeWorkingDirectoryDescriptor {
            guard !lockDescriptors.contains(nativeWorkingDirectoryDescriptor),
                  ![ownerDescriptor, outputDescriptor, errorDescriptor].contains(nativeWorkingDirectoryDescriptor) else {
                throw NativeWorkerProtocol.protocolFailure("working directory aliases another capability")
            }
            directory = try duplicate(nativeWorkingDirectoryDescriptor)
            _ = try NativeWorkerDirectoryBinding(descriptor: directory, path: command.workingDirectory)
        } else {
            directory = Darwin.open(command.workingDirectory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard directory >= 0 else { throw DarwinWorkloadFailure(operation: "open(cwd)", code: errno) }
            ownedDescriptors.append(directory)
        }
    }

    func duplicate(_ descriptor: Int32) throws -> Int32 {
        let copy = fcntl(descriptor, F_DUPFD_CLOEXEC, 64)
        guard copy >= 64 else { throw DarwinWorkloadFailure(operation: "F_DUPFD_CLOEXEC", code: errno) }
        ownedDescriptors.append(copy)
        return copy
    }

    func spawn() {
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        var attributesInitialized = false
        var actionsInitialized = false
        defer {
            if actionsInitialized {
                let code = posix_spawn_file_actions_destroy(&actions)
                if code != 0 { record(DarwinWorkloadFailure(operation: "spawn actions destroy", code: code)) }
            }
            if attributesInitialized {
                let code = posix_spawnattr_destroy(&attributes)
                if code != 0 { record(DarwinWorkloadFailure(operation: "spawn attributes destroy", code: code)) }
            }
        }
        do {
            try check(posix_spawnattr_init(&attributes), operation: "spawn attributes init")
            attributesInitialized = true
            try check(posix_spawn_file_actions_init(&actions), operation: "spawn actions init")
            actionsInitialized = true
            try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
                      operation: "spawn null stdin")
            try check(posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO), operation: "spawn stdout")
            try check(posix_spawn_file_actions_adddup2(&actions, error, STDERR_FILENO), operation: "spawn stderr")
            try check(posix_spawn_file_actions_addfchdir(&actions, directory), operation: "spawn cwd")
            for descriptor in inheritedLocks {
                try check(posix_spawn_file_actions_addinherit_np(&actions, descriptor), operation: "spawn lock inheritance")
            }
            var mask = sigset_t()
            var defaults = sigset_t()
            try check(sigemptyset(&mask), operation: "sigemptyset", useErrno: true)
            try check(sigfillset(&defaults), operation: "sigfillset", useErrno: true)
            try check(posix_spawnattr_setsigmask(&attributes, &mask), operation: "spawn signal mask")
            try check(posix_spawnattr_setsigdefault(&attributes, &defaults), operation: "spawn signal defaults")
            let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
            try check(posix_spawnattr_setflags(&attributes, Int16(flags)), operation: "spawn flags")
            let argv = try CStringVector([command.executable] + command.arguments)
            let environment = try CStringVector(command.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
            var child: pid_t = 0
            let code = argv.pointers.withUnsafeMutableBufferPointer { arguments in
                environment.pointers.withUnsafeMutableBufferPointer { variables in
                    posix_spawn(&child, command.executable, &actions, &attributes,
                                arguments.baseAddress!, variables.baseAddress!)
                }
            }
            if code == 0 {
                pid = child // Register immediately: nothing fallible may precede this assignment.
            } else {
                record(DarwinWorkloadFailure(operation: "posix_spawn", code: code))
            }
        } catch let failure as DarwinWorkloadFailure {
            record(failure)
        } catch {
            record(DarwinWorkloadFailure(operation: "spawn preparation", detail: String(describing: error)))
        }
    }

    func observeStop() {
        if cancellation.state.withLock({ $0 }) && stopReason == nil { stopReason = .cancelled }
        if let failure = observeFailure() { record(failure) }
        guard owner >= 0 else { return }
        var descriptor = pollfd(fd: owner, events: Int16(POLLIN | POLLHUP), revents: 0)
        var result: Int32
        repeat { result = poll(&descriptor, 1, 0) } while result < 0 && errno == EINTR
        if result < 0 {
            record(DarwinWorkloadFailure(operation: "poll(owner)", code: errno))
        } else if descriptor.revents & Int16(POLLNVAL | POLLERR) != 0 {
            record(DarwinWorkloadFailure(operation: "owner pipe invalid", code: EIO))
        } else if descriptor.revents & Int16(POLLIN | POLLHUP) != 0 {
            var byte: UInt8 = 0
            var count: Int
            repeat { count = Darwin.read(owner, &byte, 1) } while count < 0 && errno == EINTR
            if count == 0 {
                if stopReason == nil { stopReason = .ownerEOF }
            } else {
                record(DarwinWorkloadFailure(operation: "owner pipe expected EOF", code: count < 0 ? errno : EPROTO))
            }
        }
    }

    func retire(_ pid: Int32) {
        var escalationAt: UInt64?
        while true {
            observeStop()
            let exited = peekTermination(pid)
            if exited == true, groupContainsOnlyExitedLeader(pid) {
                if reap(pid) { return }
            }
            // An unsuccessful wait observation cannot prove that the PID is
            // still pinned. Retain ownership and retry without signalling it.
            if exited != nil && (stopReason != nil || exited == true) {
                let now = DispatchTime.now().uptimeNanoseconds
                if escalationAt == nil {
                    signalGroup(pid, SIGTERM)
                    escalationAt = now + 1_000_000_000
                } else if now >= escalationAt! {
                    signalGroup(pid, SIGKILL)
                }
            }
            // Uncertain kernel observations retain the descriptors and the PID;
            // they never become a successful retirement or an unsafe release.
            var interval = timespec(tv_sec: 0, tv_nsec: 20_000_000)
            var remainder = timespec()
            while nanosleep(&interval, &remainder) != 0 && errno == EINTR { interval = remainder }
        }
    }

    func peekTermination(_ pid: Int32) -> Bool? {
        if nativeTermination != nil { return true }
        var information = siginfo_t()
        var code: Int32
        repeat { code = waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT) }
        while code < 0 && errno == EINTR
        guard code == 0 else {
            record(DarwinWorkloadFailure(operation: "waitid(WNOWAIT)", code: errno))
            return nil
        }
        guard information.si_pid == pid else { return false }
        switch information.si_code {
        case CLD_EXITED:
            nativeTermination = RunTermination(kind: .exit, value: information.si_status)
        case CLD_KILLED, CLD_DUMPED:
            nativeTermination = RunTermination(kind: .signal, value: information.si_status)
        default:
            record(DarwinWorkloadFailure(operation: "unexpected waitid status", code: EPROTO))
            return nil
        }
        return nativeTermination != nil
    }

    func groupContainsOnlyExitedLeader(_ pid: Int32) -> Bool {
        let required = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pid), nil, 0)
        guard required > 0 else {
            record(DarwinWorkloadFailure(operation: "proc_listpids size", code: errno))
            return false
        }
        let capacity = max(Int(required) + 1_024, 4_096)
        guard capacity <= 16 * 1_024 * 1_024 else {
            record(DarwinWorkloadFailure(operation: "process group census limit", code: EOVERFLOW))
            return false
        }
        var members = [Int32](repeating: 0, count: capacity / MemoryLayout<Int32>.stride)
        let bytes = members.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pid), $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0, bytes < capacity, Int(bytes) % MemoryLayout<Int32>.stride == 0 else {
            record(DarwinWorkloadFailure(operation: "proc_listpids census", code: errno))
            return false
        }
        return members.prefix(Int(bytes) / MemoryLayout<Int32>.stride).filter { $0 > 0 } == [pid]
    }

    func signalGroup(_ pid: Int32, _ signal: Int32) {
        if kill(-pid, signal) != 0, errno != ESRCH {
            record(DarwinWorkloadFailure(operation: "kill process group", code: errno))
        }
    }

    func reap(_ pid: Int32) -> Bool {
        var status: Int32 = 0
        var result: Int32
        repeat { result = waitpid(pid, &status, 0) } while result < 0 && errno == EINTR
        guard result == pid else {
            record(DarwinWorkloadFailure(operation: "waitpid", code: errno))
            return false
        }
        // The census was performed while the zombie pinned its PGID. Never
        // signal or probe that numeric group after reaping permits PID reuse.
        return true
    }

    func record(_ failure: DarwinWorkloadFailure) {
        if !failures.contains(failure), failures.count < 32 { failures.append(failure) }
        if stopReason == nil { stopReason = .ancillaryFailure }
    }

    func check(_ result: Int32, operation: String, useErrno: Bool = false) throws {
        guard result == 0 else { throw DarwinWorkloadFailure(operation: operation, code: useErrno ? errno : result) }
    }
}

private final class CStringVector {
    var pointers: [UnsafeMutablePointer<CChar>?] = []

    init(_ values: [String]) throws {
        for value in values {
            guard let pointer = strdup(value) else {
                for pointer in pointers { free(pointer) }
                pointers.removeAll()
                throw DarwinWorkloadFailure(operation: "strdup", code: ENOMEM)
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
    }

    deinit { for pointer in pointers { free(pointer) } }
}

private final class WorkloadCancellation: Sendable {
    let state: Mutex<Bool>

    init(_ cancelled: Bool) { state = Mutex(cancelled) }
}
