import AgentBuildCore
import AgentLeaseCore
import CryptoKit
import Darwin
import Foundation
import Synchronization

public enum NotikaInteractiveError: Error, Equatable, Sendable {
    case hostLeaseRequired
    case hostLeaseInvalid
    case productInvalid
    case productChanged
    case processIdentityInvalid
    case lifecycleFailed
    case systemCall(String, Int32)
}

/// Kernel facts observed twice around proc_pidpath. A PID alone is never launch
/// evidence, and these facts do not authorize signalling a later process.
public struct NotikaInteractiveProcessIdentity: Equatable, Sendable {
    public let processID: Int32
    public let parentProcessID: Int32
    public let ownerUID: UInt32
    public let processGroupID: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64
    public let executable: String

    internal static func observe(_ processID: Int32) throws -> Self {
        guard processID > 0 else { throw NotikaInteractiveError.processIdentityInvalid }
        func bsdInfo() throws -> proc_bsdinfo {
            var info = proc_bsdinfo()
            let count = withUnsafeMutablePointer(to: &info) {
                proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, $0, Int32(MemoryLayout<proc_bsdinfo>.size))
            }
            guard count == MemoryLayout<proc_bsdinfo>.size else { throw NotikaInteractiveError.processIdentityInvalid }
            return info
        }
        let before = try bsdInfo()
        var path = [UInt8](repeating: 0, count: 4_096)
        let count = path.withUnsafeMutableBytes { proc_pidpath(processID, $0.baseAddress, UInt32($0.count)) }
        let after = try bsdInfo()
        guard count > 0, let end = path.firstIndex(of: 0),
              let executable = String(bytes: path.prefix(end), encoding: .utf8), executable.hasPrefix("/"),
              before.pbi_pid == after.pbi_pid, before.pbi_ppid == after.pbi_ppid,
              before.pbi_uid == after.pbi_uid, before.pbi_pgid == after.pbi_pgid,
              before.pbi_start_tvsec == after.pbi_start_tvsec, before.pbi_start_tvusec == after.pbi_start_tvusec,
              after.pbi_pid == UInt32(processID), after.pbi_ppid > 0, after.pbi_uid == geteuid(),
              after.pbi_start_tvsec > 0, after.pbi_start_tvusec < 1_000_000 else {
            throw NotikaInteractiveError.processIdentityInvalid
        }
        return Self(processID: processID, parentProcessID: Int32(after.pbi_ppid), ownerUID: after.pbi_uid,
                    processGroupID: Int32(after.pbi_pgid), startSeconds: after.pbi_start_tvsec,
                    startMicroseconds: after.pbi_start_tvusec, executable: executable)
    }

    internal var json: CanonicalJSONValue {
        .object(["processID": .integer(Int64(processID)), "parentProcessID": .integer(Int64(parentProcessID)),
            "ownerUID": .unsignedInteger(UInt64(ownerUID)), "processGroupID": .integer(Int64(processGroupID)),
            "startSeconds": .unsignedInteger(startSeconds), "startMicroseconds": .unsignedInteger(startMicroseconds),
            "executable": .string(executable)])
    }
}

public struct NotikaInteractiveRunningReport: Sendable {
    public let sessionID: String
    public let sessionPath: String
    public let helperPID: Int32
    public let process: NotikaInteractiveProcessIdentity
    public let bundlePath: String
    public let executableSHA256: String
    public let infoPlistSHA256: String
    public let startedAt: String
    public let rawLogDirectory: String

    public func jsonData() throws -> Data { try CanonicalJSONDigest.encode(json) }
    internal var json: CanonicalJSONValue {
        .object(["namespace": .string("agentbuild.notika-interactive-running"), "schemaVersion": .integer(1),
            "sessionID": .string(sessionID), "sessionPath": .string(sessionPath),
            "helperPID": .integer(Int64(helperPID)), "process": process.json,
            "bundleIdentifier": .string(NotikaInteractiveProduct.bundleIdentifier), "bundlePath": .string(bundlePath),
            "executableSHA256": .string(executableSHA256), "infoPlistSHA256": .string(infoPlistSHA256),
            "startedAt": .string(startedAt), "rawLogDirectory": .string(rawLogDirectory), "state": .string("running")])
    }
}

public struct NotikaInteractiveResult: Sendable {
    public let build: NotikaBuildCoordinatorResult
    public let running: NotikaInteractiveRunningReport?
    public let application: NativePhaseResult?
    public let failures: [String]
    public let cancellationSignal: Int32?
    public let rawCapture: NativeLogCaptureResult?
    public let nativeCommandBinding: CanonicalJSONValue?
    private let retainedRawCapture: NativeLogCapture?

    fileprivate init(
        build: NotikaBuildCoordinatorResult, running: NotikaInteractiveRunningReport?, application: NativePhaseResult?,
        failures: [String], cancellationSignal: Int32?, rawCapture: NativeLogCaptureResult?,
        nativeCommandBinding: CanonicalJSONValue?, retainedRawCapture: NativeLogCapture?
    ) {
        self.build = build; self.running = running; self.application = application; self.failures = failures
        self.cancellationSignal = cancellationSignal; self.rawCapture = rawCapture
        self.nativeCommandBinding = nativeCommandBinding; self.retainedRawCapture = retainedRawCapture
    }

    public var rawCaptureAdmitted: Bool {
        guard let rawCapture, rawCapture.captureComplete, let retainedRawCapture else { return false }
        return (try? retainedRawCapture.revalidateForPublication(rawCapture)) != nil
    }

    public var exitCode: Int32 {
        if let native = build.outcome?.nativeFailure { return native.kind == .exit ? native.value : 128 + native.value }
        if build.cancelled || application?.cancellationRequested == true { return cancellationSignal.map { 128 + $0 } ?? 130 }
        if build.exitCode != 0 { return build.exitCode }
        if let native = application?.workload?.termination {
            let code = native.kind == .exit ? native.value : 128 + native.value
            if code != 0 { return code }
        }
        if application?.cancellationRequested == true { return 130 }
        guard running != nil, let application, application.retirementProven,
              application.workload?.retirement == .reaped, application.workload?.termination != nil,
              application.failures.isEmpty, application.workload?.failures.isEmpty == true,
              rawCaptureAdmitted, failures.isEmpty else { return 70 }
        return 0
    }

    public func jsonData() throws -> Data {
        let native = application?.workload?.termination.map {
            CanonicalJSONValue.object(["kind": .string($0.kind.rawValue), "value": .integer(Int64($0.value))])
        } ?? .null
        return try CanonicalJSONDigest.encode(.object([
            "namespace": .string("agentbuild.notika-interactive"), "schemaVersion": .integer(1),
            "exitCode": .integer(Int64(exitCode)), "build": try interactiveJSON(build.jsonData()),
            "running": running?.json ?? .null, "applicationTermination": native,
            "retirement": application.map { .string($0.retirement.rawValue) } ?? .null,
            "cancellationSignal": cancellationSignal.map { .integer(Int64($0)) } ?? .null,
            "nativeCommandBinding": nativeCommandBinding ?? .null,
            "rawCapture": try rawCapture.map(interactiveEncoded) ?? .null,
            "rawCaptureAdmitted": .bool(rawCaptureAdmitted),
            "workingDirectoryIdentity": try application?.workingDirectoryIdentity.map(interactiveEncoded) ?? .null,
            "failures": .array(failures.map(CanonicalJSONValue.string)),
        ]))
    }
}

/// The continuation executes beneath the original build's writer/graph/policy/
/// cache ownership. Compilation admission has ended. The private native worker
/// owns the app until exact-child reaping; owner EOF retires it after parent death.
public struct NotikaInteractiveDriver: Sendable {
    private let coordinator: NotikaBuildCoordinator
    public init() { coordinator = NotikaBuildCoordinator() }
    internal init(coordinator: NotikaBuildCoordinator) { self.coordinator = coordinator }

    public func run(
        repository: String, helperExecutable: String, registryRoot: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        waitSeconds: Double? = nil,
        receivedSignal: @escaping @Sendable () -> Int32? = { nil },
        onRunning: @escaping @Sendable (NotikaInteractiveRunningReport) throws -> Void = { _ in }
    ) async throws -> NotikaInteractiveResult {
        // Environment markers alone cannot adopt another process's UI ownership.
        _ = try NotikaLeaseBoundary.admit(
            request: NotikaActionRequest(platform: .macOS, interactiveMode: .run), environment: environment)
        let state = InteractiveLaunchState()
        let request = try NotikaActionRequest(makeRoute: .buildMacOS, platform: .macOS)
        let build = try await coordinator.runWithContinuation(repository: repository, request: request,
            helperExecutable: helperExecutable, registryRoot: registryRoot, environment: environment,
            waitSeconds: waitSeconds) { context in
                do {
                    guard let host = context.outerHostLease else { throw NotikaInteractiveError.hostLeaseRequired }
                    try await context.revalidateBeforeOperation()
                    try host.revalidate()
                    let product = try NotikaInteractiveProduct(cacheDirectory: context.cacheCustody.cacheDirectory)
                    let publisher = try InteractiveReceiptPublisher(session: context.session)
                    let inherited = try context.borrowedLockDescriptors()
                    let directory = try context.borrowedWorkingDirectoryDescriptor()
                    let childEnvironment = try NotikaChildEnvironmentPolicy.inheritedEnvironment(from: context.environment)
                    let command = try DarwinWorkloadCommand(executable: product.executable.path,
                        arguments: ["--notika-agent-session=\(context.session.runID)"],
                        workingDirectory: context.compatibilityIdentity.canonicalWorktree, environment: childEnvironment)
                    // No fresh source or tool identity can silently replace the
                    // built admission while an application is being prepared.
                    try await context.revalidateBeforeOperation()
                    try product.revalidate(); try host.revalidate()
                    let commandBinding = try interactiveCommandBinding(command)
                    // Nothing fallible intervenes before the supervisor owns
                    // retirement. Once piping starts, EOF must always be drained.
                    let capture = try NativeLogCapture(root: context.session.path, runID: UUID().uuidString)
                    let application = await NativePhaseSupervisor().run(helperExecutable: context.helperExecutable,
                        command: command, retainedLockDescriptors: inherited, nativeWorkingDirectoryDescriptor: directory,
                        standardOutputDescriptor: capture.standardOutputDescriptor,
                        standardErrorDescriptor: capture.standardErrorDescriptor,
                        onHelperStart: { pid in
                            state.helperStarted(pid)
                            try product.revalidate(); try host.revalidate()
                            _ = try context.borrowedLockDescriptors()
                        }, onNativeStart: { pid in
                            let identity = try NotikaInteractiveProcessIdentity.observe(pid)
                            guard let helper = state.helperPID, identity.parentProcessID == helper,
                                  identity.processGroupID == pid,
                                  identity.executable.utf8.elementsEqual(product.executable.path.utf8) else {
                                throw NotikaInteractiveError.processIdentityInvalid
                            }
                            try product.revalidate(); try host.revalidate()
                            let report = NotikaInteractiveRunningReport(sessionID: context.session.runID,
                                sessionPath: context.session.path, helperPID: helper, process: identity,
                                bundlePath: product.bundlePath, executableSHA256: product.executable.digest,
                                infoPlistSHA256: product.infoPlist.digest, startedAt: RunRecord.timestamp(),
                                rawLogDirectory: capture.directoryPath)
                            try publisher.publish(report.json, name: "interactive-running.json")
                            state.started(report)
                            try onRunning(report)
                        }, observeFailure: {
                            if let failure = capture.supervisorFailure() { return failure }
                            do { try product.revalidate(); try host.revalidate(); return nil }
                            catch { return DarwinWorkloadFailure(operation: "interactive product/host custody", detail: String(describing: error)) }
                        })
                    state.finished(application)
                    if let quarantine = application.quarantine { await quarantine.waitUntilProvenQuiescent() }
                    let raw = await capture.finishAfterWorkerRetirement()
                    state.captured(capture, result: raw, commandBinding: commandBinding)
                    var admitted = false
                    if raw.captureComplete {
                        do { try capture.revalidateForPublication(raw); admitted = true }
                        catch { state.failed(error) }
                    }
                    let admittedForPublication = admitted
                    try publisher.publish(state.terminalJSON(rawAdmitted: admitted), name: "interactive-terminal.json",
                        revalidate: {
                            if admittedForPublication { try capture.revalidateForPublication(raw) }
                        })
                    guard application.retirementProven, application.failures.isEmpty,
                          application.workload?.failures.isEmpty == true,
                          application.workload?.retirement == .reaped, state.running != nil, admitted else {
                        throw NotikaInteractiveError.lifecycleFailed
                    }
                } catch {
                    state.failed(error)
                    throw error
                }
            }
        return NotikaInteractiveResult(build: build, running: state.running, application: state.application,
            failures: state.failures, cancellationSignal: receivedSignal(), rawCapture: state.rawCapture,
            nativeCommandBinding: state.nativeCommandBinding, retainedRawCapture: state.retainedRawCapture)
    }
}

private final class InteractiveLaunchState: Sendable {
    private struct State {
        var helperPID: Int32?
        var running: NotikaInteractiveRunningReport?
        var application: NativePhaseResult?
        var rawCapture: NativeLogCaptureResult?
        var retainedRawCapture: NativeLogCapture?
        var nativeCommandBinding: CanonicalJSONValue?
        var failures: [String] = []
    }
    private let state = Mutex(State())
    var helperPID: Int32? { state.withLock { $0.helperPID } }
    var running: NotikaInteractiveRunningReport? { state.withLock { $0.running } }
    var application: NativePhaseResult? { state.withLock { $0.application } }
    var failures: [String] { state.withLock { $0.failures } }
    var rawCapture: NativeLogCaptureResult? { state.withLock { $0.rawCapture } }
    var retainedRawCapture: NativeLogCapture? { state.withLock { $0.retainedRawCapture } }
    var nativeCommandBinding: CanonicalJSONValue? { state.withLock { $0.nativeCommandBinding } }
    func helperStarted(_ pid: Int32) { state.withLock { $0.helperPID = pid } }
    func started(_ report: NotikaInteractiveRunningReport) { state.withLock { $0.running = report } }
    func finished(_ result: NativePhaseResult) { state.withLock { $0.application = result } }
    func captured(_ capture: NativeLogCapture, result: NativeLogCaptureResult, commandBinding: CanonicalJSONValue) {
        state.withLock {
            $0.retainedRawCapture = capture; $0.rawCapture = result; $0.nativeCommandBinding = commandBinding
        }
    }
    func failed(_ error: any Error) { state.withLock { $0.failures.append(String(String(describing: error).prefix(512))) } }
    func terminalJSON(rawAdmitted: Bool) throws -> CanonicalJSONValue {
        try state.withLock { state in
            let native = state.application?.workload?.termination.map {
                CanonicalJSONValue.object(["kind": .string($0.kind.rawValue), "value": .integer(Int64($0.value))])
            } ?? .null
            return .object(["namespace": .string("agentbuild.notika-interactive-terminal"), "schemaVersion": .integer(1),
                "running": state.running?.json ?? .null, "nativeTermination": native,
                "completedAt": .string(RunRecord.timestamp()),
                "cancelled": .bool(state.application?.cancellationRequested ?? Task.isCancelled),
                "retirement": state.application.map { .string($0.retirement.rawValue) } ?? .null,
                "nativeCommandBinding": state.nativeCommandBinding ?? .null,
                "rawCapture": try state.rawCapture.map(interactiveEncoded) ?? .null,
                "rawCaptureAdmitted": .bool(rawAdmitted),
                "workingDirectoryIdentity": try state.application?.workingDirectoryIdentity.map(interactiveEncoded) ?? .null,
                "failures": .array((state.failures + (state.application?.failures.map { String(describing: $0) } ?? [])
                    + (state.application?.workload?.failures.map { String(describing: $0) } ?? [])
                    + (state.rawCapture?.failures.map { String(describing: $0) } ?? [])).map(CanonicalJSONValue.string))])
        }
    }
}

/// The one borrowed SimLease description is duplicated, never reopened as its
/// owner. Independent exclusive/shared probes and a vnode unlock watch prevent
/// an unlocked duplicate from borrowing somebody else's temporary contention.
internal final class NotikaInteractiveHostLease: Sendable {
    let descriptor: Int32
    private let directory: RetainedArtifactDirectory
    private let path: String
    private let identity: InteractiveFileIdentity
    private let watch: Int32
    private let invalidated = Mutex(false)
    private init(descriptor: Int32, directory: RetainedArtifactDirectory, path: String,
                 identity: InteractiveFileIdentity, watch: Int32) {
        self.descriptor = descriptor; self.directory = directory; self.path = path; self.identity = identity; self.watch = watch
    }
    deinit { _ = Darwin.close(watch); _ = Darwin.close(descriptor) }

    static func admit(environment: [String: String]) throws -> NotikaInteractiveHostLease {
        guard environment["SIMLEASE_MACOS_UI"] == "1", environment["SIMLEASE_HOST_RESOURCE"] == "macos-ui",
              let session = environment["SIMLEASE_SESSION_ID"], UUID(uuidString: session) != nil else {
            throw NotikaInteractiveError.hostLeaseRequired
        }
        let root: String
        if let configured = environment["SIMLEASE_HOME"] { root = configured }
        else {
            root = try interactiveAccountHome() + "/.simlease"
        }
        let path = root + "/host-locks/macos-ui.lock"
        let directory = try RetainedArtifactDirectory(path: root + "/host-locks")
        var observed = stat()
        guard lstat(path, &observed) == 0, observed.st_mode & S_IFMT == S_IFREG,
              observed.st_mode & 0o7777 == 0o600, observed.st_uid == geteuid(), observed.st_nlink == 1 else {
            throw NotikaInteractiveError.hostLeaseInvalid
        }
        let identity = InteractiveFileIdentity(observed)
        let names = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd")
        let matches = names.compactMap(Int32.init).filter { fd in
            guard fd >= 3, let value = try? interactiveStat(fd) else { return false }
            return InteractiveFileIdentity(value) == identity
        }
        guard matches.count == 1, let inherited = matches.first,
              fcntl(inherited, F_GETFD) & FD_CLOEXEC == 0 else { throw NotikaInteractiveError.hostLeaseInvalid }
        let descriptor = fcntl(inherited, F_DUPFD_CLOEXEC, 64)
        guard descriptor >= 64 else { throw interactiveIO("duplicate UI custody") }
        var transfer = false, watch: Int32 = -1
        defer { if !transfer { if watch >= 0 { _ = Darwin.close(watch) }; _ = Darwin.close(descriptor) } }
        watch = kqueue()
        guard watch >= 0, fcntl(watch, F_SETFD, FD_CLOEXEC) == 0 else { throw interactiveIO("create UI lock watch") }
        var event = kevent()
        event.ident = UInt(descriptor); event.filter = Int16(EVFILT_VNODE)
        event.flags = UInt16(EV_ADD | EV_CLEAR); event.fflags = UInt32(NOTE_FUNLOCK)
        guard interactiveKevent(watch, &event, 1, nil, 0, nil) == 0 else { throw interactiveIO("arm UI lock watch") }
        let lease = NotikaInteractiveHostLease(descriptor: descriptor, directory: directory, path: path, identity: identity, watch: watch)
        // Ownership now belongs to lease even if admission subsequently throws.
        transfer = true
        for mode in [LOCK_EX, LOCK_SH] {
            let contender = open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard contender >= 0 else { throw interactiveIO("open UI contention probe") }
            defer { _ = Darwin.close(contender) }
            guard try InteractiveFileIdentity(interactiveStat(contender)) == identity else { throw NotikaInteractiveError.hostLeaseInvalid }
            try lease.revalidate()
            if flock(contender, mode | LOCK_NB) == 0 {
                _ = flock(contender, LOCK_UN)
                throw NotikaInteractiveError.hostLeaseInvalid
            }
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw interactiveIO("probe UI ownership") }
        }
        try lease.revalidate()
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw NotikaInteractiveError.hostLeaseInvalid }
        try lease.revalidate()
        return lease
    }

    func revalidate() throws {
        try invalidated.withLock { invalidated in
            guard !invalidated else { throw NotikaInteractiveError.hostLeaseInvalid }
            do {
                try directory.revalidate()
                var current = stat()
                guard lstat(path, &current) == 0, InteractiveFileIdentity(current) == identity,
                      try InteractiveFileIdentity(interactiveStat(descriptor)) == identity else {
                    throw NotikaInteractiveError.hostLeaseInvalid
                }
                var event = kevent(), timeout = timespec(tv_sec: 0, tv_nsec: 0)
                var count: Int32
                repeat { count = interactiveKevent(watch, nil, 0, &event, 1, &timeout) } while count < 0 && errno == EINTR
                guard count == 0 else { throw NotikaInteractiveError.hostLeaseInvalid }
            } catch {
                // Consuming a vnode event cannot restore continuity on a later
                // check. Every subsequent use remains refused.
                invalidated = true
                throw error
            }
        }
    }
}

internal final class NotikaInteractiveProduct: Sendable {
    static let bundleIdentifier = "dev.jano.apple.notes"
    let bundlePath: String
    let executable: InteractiveProductFile
    let infoPlist: InteractiveProductFile
    init(cacheDirectory: String) throws {
        bundlePath = cacheDirectory + "/Build/Products/Debug/Notika.app"
        executable = try InteractiveProductFile(path: bundlePath + "/Contents/MacOS/Notika", maximum: 512 * 1_024 * 1_024, executable: true)
        infoPlist = try InteractiveProductFile(path: bundlePath + "/Contents/Info.plist", maximum: 1_024 * 1_024, executable: false)
        let plist = try PropertyListSerialization.propertyList(from: infoPlist.read(), options: [], format: nil)
        guard let values = plist as? [String: Any], values["CFBundleIdentifier"] as? String == Self.bundleIdentifier,
              values["CFBundleExecutable"] as? String == "Notika" else { throw NotikaInteractiveError.productInvalid }
        try revalidate()
    }
    func revalidate() throws { try executable.revalidate(); try infoPlist.revalidate() }
}

internal final class InteractiveProductFile: Sendable {
    let path: String
    let digest: String
    private let ownedDescriptor: InteractiveOwnedDescriptor
    private var descriptor: Int32 { ownedDescriptor.value }
    private let directory: RetainedArtifactDirectory
    private let fingerprint: InteractiveProductFingerprint
    init(path: String, maximum: Int, executable: Bool) throws {
        guard let slash = path.lastIndex(of: "/") else { throw NotikaInteractiveError.productInvalid }
        let directory = try RetainedArtifactDirectory(path: String(path[..<slash]))
        var observed = stat()
        guard lstat(path, &observed) == 0, observed.st_mode & S_IFMT == S_IFREG, observed.st_uid == geteuid(),
              observed.st_mode & 0o7022 == 0, observed.st_nlink == 1, observed.st_size > 0,
              observed.st_size <= maximum, !executable || observed.st_mode & 0o111 != 0 else { throw NotikaInteractiveError.productInvalid }
        let opened = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard opened >= 0 else { throw interactiveIO("open built product") }
        let owned = InteractiveOwnedDescriptor(opened)
        let fingerprint = InteractiveProductFingerprint(observed)
        guard try InteractiveProductFingerprint(interactiveStat(opened)) == fingerprint else { throw NotikaInteractiveError.productChanged }
        var hash = SHA256(), offset = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while offset < observed.st_size {
            let count = buffer.withUnsafeMutableBytes { pread(opened, $0.baseAddress, min($0.count, Int(observed.st_size) - offset), off_t(offset)) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw NotikaInteractiveError.productChanged }
            hash.update(data: Data(buffer.prefix(count))); offset += count
        }
        self.path = path; self.directory = directory; self.ownedDescriptor = owned; self.fingerprint = fingerprint
        digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        try revalidate()
    }
    func revalidate() throws {
        try directory.revalidate()
        var current = stat()
        guard lstat(path, &current) == 0, InteractiveProductFingerprint(current) == fingerprint,
              try InteractiveProductFingerprint(interactiveStat(descriptor)) == fingerprint else { throw NotikaInteractiveError.productChanged }
    }
    func read() throws -> Data {
        try revalidate()
        var bytes = Data(count: Int(fingerprint.size))
        try bytes.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = pread(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, off_t(offset))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw NotikaInteractiveError.productChanged }
                offset += count
            }
        }
        try revalidate()
        return bytes
    }
}

private struct InteractiveFileIdentity: Equatable, Sendable {
    let device: Int64, inode: UInt64, mode: UInt16, owner: UInt32, group: UInt32, links: UInt64
    init(_ value: stat) {
        device = Int64(value.st_dev); inode = UInt64(value.st_ino); mode = UInt16(value.st_mode)
        owner = value.st_uid; group = value.st_gid; links = UInt64(value.st_nlink)
    }
}
private struct InteractiveProductFingerprint: Equatable, Sendable {
    let identity: InteractiveFileIdentity
    let size: Int64, modifiedSeconds: Int64, modifiedNanoseconds: Int64, changedSeconds: Int64, changedNanoseconds: Int64
    init(_ value: stat) {
        identity = InteractiveFileIdentity(value); size = Int64(value.st_size)
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }
}

private final class InteractiveReceiptPublisher: Sendable {
    private let session: NotikaBuildSession
    private let directory: RetainedArtifactDirectory
    private let ownedDescriptor: InteractiveOwnedDescriptor
    private var descriptor: Int32 { ownedDescriptor.value }
    init(session: NotikaBuildSession) throws {
        _ = try session.inheritedDescriptors()
        self.session = session
        directory = try RetainedArtifactDirectory(path: session.path, requiredPermissions: 0o700)
        let opened = open(session.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard opened >= 0 else { throw interactiveIO("open interactive receipt directory") }
        let owned = InteractiveOwnedDescriptor(opened)
        var current = stat()
        guard fstat(opened, &current) == 0, Int64(current.st_dev) == directory.fingerprint.device,
              UInt64(current.st_ino) == directory.fingerprint.inode else {
            throw NotikaInteractiveError.lifecycleFailed
        }
        ownedDescriptor = owned
    }
    func publish(_ value: CanonicalJSONValue, name: String,
                 revalidate: @Sendable () throws -> Void = {}) throws {
        guard name == "interactive-running.json" || name == "interactive-terminal.json" else { throw NotikaInteractiveError.lifecycleFailed }
        _ = try session.inheritedDescriptors(); try directory.revalidate(); try revalidate()
        let temporary = "." + name + "." + UUID().uuidString + ".tmp"
        let file = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard file >= 0 else { throw interactiveIO("create interactive receipt") }
        var owned = true
        defer {
            if owned { _ = Darwin.close(file) }
            _ = unlinkat(descriptor, temporary, 0)
        }
        let bytes = try CanonicalJSONDigest.encode(value)
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw interactiveIO("write interactive receipt") }
                offset += count
            }
        }
        guard fsync(file) == 0, fchmod(file, 0o400) == 0 else { throw interactiveIO("seal interactive receipt") }
        owned = false
        guard Darwin.close(file) == 0 else { throw interactiveIO("retire interactive receipt writer") }
        _ = try session.inheritedDescriptors(); try directory.revalidate(); try revalidate()
        guard linkat(descriptor, temporary, descriptor, name, 0) == 0 else { throw interactiveIO("publish interactive receipt") }
        guard unlinkat(descriptor, temporary, 0) == 0, fsync(descriptor) == 0 else { throw interactiveIO("finish interactive receipt publication") }
        let retained = try RetainedArtifactFile(directory: directory, name: name,
            policy: ArtifactFilePolicy(minimumBytes: 1, requiredPermissions: 0o400))
        guard try retained.readBounded() == bytes else { throw NotikaInteractiveError.lifecycleFailed }
        try revalidate()
    }
}

private final class InteractiveOwnedDescriptor: Sendable {
    let value: Int32
    init(_ value: Int32) { self.value = value }
    deinit { _ = Darwin.close(value) }
}

private func interactiveStat(_ descriptor: Int32) throws -> stat {
    var result = stat()
    guard fstat(descriptor, &result) == 0 else { throw interactiveIO("fstat interactive custody") }
    return result
}
private func interactiveIO(_ operation: String) -> NotikaInteractiveError { .systemCall(operation, errno) }
private func interactiveCommandBinding(_ command: DarwinWorkloadCommand) throws -> CanonicalJSONValue {
    let value: CanonicalJSONValue = .object([
        "executable": .string(command.executable),
        "arguments": .array(command.arguments.map(CanonicalJSONValue.string)),
        "workingDirectory": .string(command.workingDirectory),
    ])
    return .object(["command": value, "commandSHA256": .string(try CanonicalJSONDigest.sha256(value))])
}
private func interactiveEncoded(_ value: some Encodable) throws -> CanonicalJSONValue {
    try interactiveJSON(JSONEncoder().encode(value))
}
private func interactiveAccountHome() throws -> String {
    var entry = passwd(), result: UnsafeMutablePointer<passwd>?
    var storage = [CChar](repeating: 0, count: 64 * 1_024)
    return try storage.withUnsafeMutableBufferPointer { bytes in
        guard getpwuid_r(geteuid(), &entry, bytes.baseAddress!, bytes.count, &result) == 0,
              result != nil, let home = String(validatingCString: entry.pw_dir), home.hasPrefix("/") else {
            throw NotikaInteractiveError.hostLeaseInvalid
        }
        return home
    }
}
private func interactiveJSON(_ data: Data) throws -> CanonicalJSONValue {
    func convert(_ value: StrictJSONValue) throws -> CanonicalJSONValue {
        switch value {
        case .array(let values): .array(try values.map(convert))
        case .bool(let value): .bool(value)
        case .null: .null
        case .number(let value):
            value.lexicalValue.hasPrefix("-") ? .integer(try value.int64()) : .unsignedInteger(try value.uint64())
        case .object(let value): .object(try value.members.map { .init(key: $0.key, value: try convert($0.value)) })
        case .string(let value): .string(value)
        }
    }
    return try convert(StrictJSONDocument(data: data).root)
}
@_silgen_name("kevent")
private func interactiveKevent(
    _ queue: Int32, _ changes: UnsafePointer<kevent>?, _ changeCount: Int32,
    _ events: UnsafeMutablePointer<kevent>?, _ eventCount: Int32, _ timeout: UnsafePointer<timespec>?
) -> Int32
