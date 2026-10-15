import CryptoKit
import Darwin
import Dispatch
import Foundation
import Synchronization

public enum NativeLogStream: String, Codable, Sendable {
    case standardOutput
    case standardError
    case combined
}

public struct NativeLogCaptureFailure: Codable, Equatable, Error, Sendable {
    public let operation: String
    public let code: Int32?
    public let stream: NativeLogStream?
    public let detail: String?

    public init(operation: String, code: Int32? = nil, stream: NativeLogStream? = nil, detail: String? = nil) {
        self.operation = operation
        self.code = code
        self.stream = stream
        self.detail = detail
    }
}

public struct NativeLogStreamResult: Codable, Equatable, Sendable {
    public let path: String
    public let observedBytes: Int64
    public let retainedBytes: Int64
    /// Commits only the retained prefix. It proves full output only when the
    /// enclosing captureComplete is true.
    public let sha256: String
    public let reachedEOF: Bool
}

public struct NativeLogCaptureResult: Codable, Equatable, Sendable {
    public let standardOutput: NativeLogStreamResult
    public let standardError: NativeLogStreamResult
    /// The order in which capture read the two source pipes, preserving every
    /// observed byte without inventing a cross-process write chronology.
    public let combined: NativeLogStreamResult
    public let maximumBytes: Int64
    public let captureComplete: Bool
    public let failures: [NativeLogCaptureFailure]
}

/// Owns pipe readers and pinned private raw logs. Helpers borrow only the write
/// ends; they never receive the log or directory descriptors. Queues drain even
/// after cancellation, overflow, or disk failure, so teardown cannot deadlock
/// behind a full pipe. Callbacks must be prompt and must stop the supervisor.
public final class NativeLogCapture: Sendable {
    public static let maximumRawBytes: Int64 = 64 * 1_024 * 1_024
    public let directoryPath: String
    public let standardOutputDescriptor: Int32
    public let standardErrorDescriptor: Int32

    private let files: CaptureFiles
    private let shared: CaptureSharedState
    private let readOrder: CaptureReadOrder
    private let outputWorker: CaptureStreamWorker
    private let errorWorker: CaptureStreamWorker
    private let mutationMonitor: CaptureMutationMonitor
    private let drainGroup = DispatchGroup()

    public convenience init(
        root: String, runID: String, maximumBytes: Int64 = NativeLogCapture.maximumRawBytes,
        onFailure: @escaping @Sendable (NativeLogCaptureFailure) -> Void = { _ in }
    ) throws {
        try self.init(root: root, runID: runID, maximumBytes: maximumBytes,
                      onFailure: onFailure, writeChunk: captureWriteChunk)
    }

    /// A narrow write fault seam used by piping fixtures. Production always uses
    /// the complete POSIX write loop, reporting its actual partial byte count.
    internal init(
        root: String, runID: String, maximumBytes: Int64,
        onFailure: @escaping @Sendable (NativeLogCaptureFailure) -> Void,
        writeChunk: @escaping @Sendable (Int32, Data) -> CaptureWriteObservation
    ) throws {
        guard (0...Self.maximumRawBytes).contains(maximumBytes) else {
            throw NativeLogCaptureFailure(operation: "validateCaptureLimit", code: EINVAL)
        }
        let files = try CaptureFiles(root: root, runID: runID)
        let outputPipe = try capturePipe()
        let errorPipe: (reader: Int32, writer: Int32)
        do { errorPipe = try capturePipe() }
        catch { close(outputPipe.reader); close(outputPipe.writer); throw error }
        self.files = files
        shared = CaptureSharedState(maximumBytes: maximumBytes, writers: [outputPipe.writer, errorPipe.writer], onFailure: onFailure)
        let readOrder = CaptureReadOrder()
        self.readOrder = readOrder
        outputWorker = CaptureStreamWorker(stream: .standardOutput, reader: outputPipe.reader,
                                           files: files, shared: shared, readOrder: readOrder, writeChunk: writeChunk)
        errorWorker = CaptureStreamWorker(stream: .standardError, reader: errorPipe.reader,
                                          files: files, shared: shared, readOrder: readOrder, writeChunk: writeChunk)
        mutationMonitor = CaptureMutationMonitor(files: files, shared: shared)
        directoryPath = files.artifacts.directoryPath
        standardOutputDescriptor = outputPipe.writer
        standardErrorDescriptor = errorPipe.writer
        for worker in [outputWorker, errorWorker] {
            drainGroup.enter()
            let group = drainGroup
            DispatchQueue(label: "agentbuild.raw-log.\(worker.stream.rawValue)", qos: .utility).async {
                worker.drain()
                group.leave()
            }
        }
    }

    deinit { mutationMonitor.stop(); shared.closeWriters() }

    public var firstFailure: NativeLogCaptureFailure? { shared.firstFailure }

    public func supervisorFailure() -> DarwinWorkloadFailure? {
        firstFailure.map {
            DarwinWorkloadFailure(operation: "nativeLogCapture.\($0.operation)", code: $0.code,
                                  detail: $0.detail ?? $0.stream?.rawValue)
        }
    }

    /// Call only after authenticated worker retirement (or a proven no-spawn
    /// outcome). The owner must await this before releasing its project leases.
    /// Cancelling the awaiting task does not close readers or fabricate EOF.
    /// Concurrent calls join the same final observation.
    public func finishAfterWorkerRetirement() async -> NativeLogCaptureResult {
        await withCheckedContinuation { continuation in
            switch shared.beginFinish(continuation) {
            case .completed(let result): continuation.resume(returning: result)
            case .joined: break
            case .started:
                shared.closeWriters()
                drainGroup.notify(queue: DispatchQueue(label: "agentbuild.raw-log.finalize", qos: .utility)) { [self] in
                    finalize()
                }
            }
        }
    }

    /// Retain this object through manifest sealing. A complete cached result is
    /// only publishable while its armed mutation watch and pinned logs still
    /// agree with that exact observation. A consumed event remains a failure.
    public func revalidateForPublication(_ expected: NativeLogCaptureResult) throws {
        try shared.validatePublicationResult(expected)
        do {
            try files.validate(expected.standardOutput, stream: .standardOutput)
            try files.validate(expected.standardError, stream: .standardError)
            try files.validate(expected.combined, stream: .combined)
            try files.checkWatch()
            try shared.validatePublicationResult(expected)
        } catch let failure as NativeLogCaptureFailure {
            shared.record(failure)
            throw failure
        } catch {
            let failure = NativeLogCaptureFailure(operation: "publicationValidation", detail: String(describing: error))
            shared.record(failure)
            throw failure
        }
    }

    private func finalize() {
        mutationMonitor.stop()
        let output = outputWorker.result
        let error = errorWorker.result
        let combined = readOrder.result(path: files.path(.combined), reachedEOF: output.reachedEOF && error.reachedEOF)
        do {
            try files.armFinalMutationWatch()
            try files.validate(output, stream: .standardOutput)
            try files.validate(error, stream: .standardError)
            try files.validate(combined, stream: .combined)
            try files.checkWatch()
        } catch let failure as NativeLogCaptureFailure {
            shared.record(failure)
        } catch {
            shared.record(NativeLogCaptureFailure(operation: "finalValidation", detail: String(describing: error)))
        }
        let failures = shared.failures
        let observedTotal = output.observedBytes.addingReportingOverflow(error.observedBytes)
        let retainedTotal = output.retainedBytes.addingReportingOverflow(error.retainedBytes)
        shared.complete(NativeLogCaptureResult(
            standardOutput: output, standardError: error, combined: combined, maximumBytes: shared.maximumBytes,
            captureComplete: failures.isEmpty && output.reachedEOF && error.reachedEOF && combined.reachedEOF
                && output.observedBytes == output.retainedBytes && error.observedBytes == error.retainedBytes
                && combined.observedBytes == combined.retainedBytes && !observedTotal.overflow && !retainedTotal.overflow
                && combined.observedBytes == observedTotal.partialValue && combined.retainedBytes == retainedTotal.partialValue,
            failures: failures
        ))
    }
}

/// The Dispatch timer is initialized once; a mutex serializes its event handler
/// with cancellation, including the final failure callback. The source's own
/// resume/cancel operations are thread safe, and no source fields are mutated.
private final class CaptureMutationMonitor: @unchecked Sendable {
    private let source: DispatchSourceTimer
    private let enabled: Mutex<Bool> = Mutex(true)

    init(files: CaptureFiles, shared: CaptureSharedState) {
        source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "agentbuild.raw-log.watch", qos: .utility))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.enabled.withLock { enabled in
                guard enabled else { return }
                do { try files.checkWatch(); try files.validateBindings() }
                catch let failure as NativeLogCaptureFailure { shared.record(failure) }
                catch { shared.record(NativeLogCaptureFailure(operation: "captureWatch", detail: String(describing: error))) }
            }
        }
        source.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(5))
        source.resume()
    }

    deinit { stop() }

    func stop() {
        enabled.withLock { $0 = false }
        source.cancel()
    }
}

internal struct CaptureWriteObservation: Sendable {
    let bytesWritten: Int
    let errorNumber: Int32?
}

private func captureWriteChunk(_ descriptor: Int32, _ bytes: Data) -> CaptureWriteObservation {
    bytes.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            if count < 0 {
                if errno == EINTR { continue }
                return CaptureWriteObservation(bytesWritten: offset, errorNumber: errno)
            }
            if count == 0 { return CaptureWriteObservation(bytesWritten: offset, errorNumber: EIO) }
            offset += count
        }
        return CaptureWriteObservation(bytesWritten: offset, errorNumber: nil)
    }
}

private final class CaptureSharedState: Sendable {
    enum FinishAdmission {
        case completed(NativeLogCaptureResult)
        case joined
        case started
    }

    private struct State {
        var reservedBytes: Int64 = 0
        var observedBytes: Int64 = 0
        var writers: [Int32]
        var failures: [NativeLogCaptureFailure] = []
        var finishing = false
        var finalResult: NativeLogCaptureResult?
        var waiters: [CheckedContinuation<NativeLogCaptureResult, Never>] = []
    }

    let maximumBytes: Int64
    private let state: Mutex<State>
    private let onFailure: @Sendable (NativeLogCaptureFailure) -> Void

    init(maximumBytes: Int64, writers: [Int32], onFailure: @escaping @Sendable (NativeLogCaptureFailure) -> Void) {
        self.maximumBytes = maximumBytes
        state = Mutex(State(writers: writers))
        self.onFailure = onFailure
    }

    var firstFailure: NativeLogCaptureFailure? { state.withLock { $0.failures.first } }
    var failures: [NativeLogCaptureFailure] { state.withLock { $0.failures } }

    func validatePublicationResult(_ expected: NativeLogCaptureResult) throws {
        try state.withLock { state in
            guard let result = state.finalResult, result.captureComplete,
                  expected == result,
                  expected.standardOutput.path.utf8.elementsEqual(result.standardOutput.path.utf8),
                  expected.standardError.path.utf8.elementsEqual(result.standardError.path.utf8),
                  expected.combined.path.utf8.elementsEqual(result.combined.path.utf8) else {
                throw NativeLogCaptureFailure(operation: "publicationRequiresCompleteCachedResult", code: EINVAL)
            }
            if let failure = state.failures.first { throw failure }
        }
    }

    func reserve(_ count: Int) -> Int {
        var overflow: NativeLogCaptureFailure?
        let reserved = state.withLock { state in
            let observed = state.observedBytes.addingReportingOverflow(Int64(count))
            state.observedBytes = observed.overflow ? Int64.max : observed.partialValue
            if observed.overflow || state.observedBytes > maximumBytes {
                overflow = NativeLogCaptureFailure(operation: "rawOutputLimit", code: EOVERFLOW,
                                                    detail: "combined stdout/stderr exceeds \(maximumBytes) bytes")
            }
            guard state.failures.isEmpty else { return 0 }
            let permitted = min(Int64(count), maximumBytes - state.reservedBytes)
            state.reservedBytes += permitted
            return Int(permitted)
        }
        if let overflow { record(overflow) }
        return reserved
    }

    func record(_ failure: NativeLogCaptureFailure) {
        let added = state.withLock { state in
            guard !state.failures.contains(failure), state.failures.count < 32 else { return false }
            state.failures.append(failure)
            return true
        }
        if added { onFailure(failure) }
    }

    func closeWriters() {
        let descriptors = state.withLock { state in
            let descriptors = state.writers
            state.writers = []
            return descriptors
        }
        for descriptor in descriptors {
            if Darwin.close(descriptor) != 0 {
                record(NativeLogCaptureFailure(operation: "closePipeWriter", code: errno))
            }
        }
    }

    func beginFinish(_ continuation: CheckedContinuation<NativeLogCaptureResult, Never>) -> FinishAdmission {
        state.withLock { state in
            if let result = state.finalResult { return .completed(result) }
            state.waiters.append(continuation)
            guard !state.finishing else { return .joined }
            state.finishing = true
            return .started
        }
    }

    func complete(_ result: NativeLogCaptureResult) {
        let waiters = state.withLock { state in
            state.finalResult = result
            let waiters = state.waiters
            state.waiters = []
            return waiters
        }
        for waiter in waiters { waiter.resume(returning: result) }
    }
}

private enum CaptureReadStep: Sendable {
    case chunk, retry, eof
    case failure(Int32)
}

private struct CaptureCombinedObservation {
    var observedBytes: Int64 = 0
    var retainedBytes: Int64 = 0
    var hasher = SHA256()

    mutating func observe(_ count: Int) {
        let addition = observedBytes.addingReportingOverflow(Int64(count))
        observedBytes = addition.overflow ? Int64.max : addition.partialValue
    }

    mutating func append(_ bytes: Data, files: CaptureFiles, shared: CaptureSharedState,
                         writeChunk: (Int32, Data) -> CaptureWriteObservation) {
        let write = writeChunk(files.writeDescriptor(.combined), bytes)
        guard (0...bytes.count).contains(write.bytesWritten) else {
            shared.record(NativeLogCaptureFailure(operation: "invalidWriteObservation", code: EIO, stream: .combined))
            return
        }
        if write.bytesWritten > 0 {
            hasher.update(data: bytes.prefix(write.bytesWritten))
            retainedBytes += Int64(write.bytesWritten)
        }
        if let code = write.errorNumber {
            shared.record(NativeLogCaptureFailure(operation: "writeLog", code: code, stream: .combined))
        } else if write.bytesWritten != bytes.count {
            shared.record(NativeLogCaptureFailure(operation: "partialWrite", code: EIO, stream: .combined))
        }
    }
}

/// Readiness waits happen outside this mutex. The actual nonblocking read,
/// original write, and combined append are one ordered observation; neither
/// worker can read its next chunk while the other observation is being stored.
private final class CaptureReadOrder: Sendable {
    private let observation: Mutex<CaptureCombinedObservation> = Mutex(CaptureCombinedObservation())

    func withRead(_ operation: (inout CaptureCombinedObservation) -> CaptureReadStep) -> CaptureReadStep {
        observation.withLock { observation in operation(&observation) }
    }

    func result(path: String, reachedEOF: Bool) -> NativeLogStreamResult {
        observation.withLock { observation in
            let hasher = observation.hasher
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return NativeLogStreamResult(path: path, observedBytes: observation.observedBytes,
                                         retainedBytes: observation.retainedBytes, sha256: digest, reachedEOF: reachedEOF)
        }
    }
}

private final class CaptureStreamWorker: Sendable {
    let stream: NativeLogStream
    private let reader: Int32
    private let files: CaptureFiles
    private let shared: CaptureSharedState
    private let readOrder: CaptureReadOrder
    private let writeChunk: @Sendable (Int32, Data) -> CaptureWriteObservation
    private let completed: Mutex<NativeLogStreamResult?> = Mutex(nil)

    init(stream: NativeLogStream, reader: Int32, files: CaptureFiles, shared: CaptureSharedState,
         readOrder: CaptureReadOrder,
         writeChunk: @escaping @Sendable (Int32, Data) -> CaptureWriteObservation) {
        self.stream = stream
        self.reader = reader
        self.files = files
        self.shared = shared
        self.readOrder = readOrder
        self.writeChunk = writeChunk
    }

    var result: NativeLogStreamResult {
        completed.withLock { $0! } // Published before this worker leaves the drain group.
    }

    func drain() {
        var observed: Int64 = 0
        var retained: Int64 = 0
        var hasher = SHA256()
        var eof = false
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        draining: while true {
            if let code = captureWaitReadable(reader) {
                shared.record(NativeLogCaptureFailure(operation: "waitReadablePipe", code: code, stream: stream))
                break
            }
            let step = readOrder.withRead { combined in
                let count = buffer.withUnsafeMutableBytes { Darwin.read(reader, $0.baseAddress, $0.count) }
                if count < 0 {
                    let code = errno
                    if code == EINTR || code == EAGAIN || code == EWOULDBLOCK { return .retry }
                    return .failure(code)
                }
                if count == 0 { return .eof }
                let addition = observed.addingReportingOverflow(Int64(count))
                observed = addition.overflow ? Int64.max : addition.partialValue
                combined.observe(count)
                do { try files.checkWatch(); try files.validateBindings() }
                catch let failure as NativeLogCaptureFailure { shared.record(failure) }
                catch { shared.record(NativeLogCaptureFailure(operation: "captureBinding", detail: String(describing: error))) }
                // Mirror the admitted prefix without reserving the same input
                // again. Failures stop retention, while both pipes keep draining.
                let allowed = shared.reserve(count)
                guard allowed > 0 else { return .chunk }
                let bytes = Data(buffer.prefix(allowed))
                let write = writeChunk(files.writeDescriptor(stream), bytes)
                if (0...bytes.count).contains(write.bytesWritten) {
                    if write.bytesWritten > 0 {
                        hasher.update(data: bytes.prefix(write.bytesWritten))
                        retained += Int64(write.bytesWritten)
                    }
                    if let code = write.errorNumber {
                        shared.record(NativeLogCaptureFailure(operation: "writeLog", code: code, stream: stream))
                    } else if write.bytesWritten != bytes.count {
                        shared.record(NativeLogCaptureFailure(operation: "partialWrite", code: EIO, stream: stream))
                    }
                } else {
                    shared.record(NativeLogCaptureFailure(operation: "invalidWriteObservation", code: EIO, stream: stream))
                }
                combined.append(bytes, files: files, shared: shared, writeChunk: writeChunk)
                return .chunk
            }
            switch step {
            case .chunk, .retry: continue
            case .eof: eof = true; break draining
            case .failure(let code):
                shared.record(NativeLogCaptureFailure(operation: "readPipe", code: code, stream: stream))
                break draining
            }
        }
        if Darwin.close(reader) != 0 { shared.record(NativeLogCaptureFailure(operation: "closePipeReader", code: errno, stream: stream)) }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        completed.withLock {
            $0 = NativeLogStreamResult(path: files.path(stream), observedBytes: observed,
                                      retainedBytes: retained, sha256: digest, reachedEOF: eof)
        }
    }
}

private final class CaptureFiles: Sendable {
    let artifacts: SessionArtifacts
    private let rootPath: String
    private let root: Int32
    private let directory: Int32
    private let outputReader: Int32
    private let errorReader: Int32
    private let combinedReader: Int32
    private let combinedWriter: Int32
    private let watch: Int32
    private struct WatchState {
        var failure: NativeLogCaptureFailure?
        var finalized = false
    }

    private let eventAccess: Mutex<WatchState> = Mutex(WatchState())

    init(root: String, runID: String) throws {
        artifacts = try SessionArtifacts(root: root, runID: runID)
        rootPath = (artifacts.directoryPath as NSString).deletingLastPathComponent
        var opened: [Int32] = []
        do {
            let rootFD = Darwin.open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard rootFD >= 0 else { throw captureFailure("openCaptureRoot") }
            opened.append(rootFD)
            let directoryFD = Darwin.open(artifacts.directoryPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directoryFD >= 0 else { throw captureFailure("openCaptureDirectory") }
            opened.append(directoryFD)
            let output = Darwin.openat(directoryFD, "stdout.log", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard output >= 0 else { throw captureFailure("openOutputReader") }
            opened.append(output)
            let error = Darwin.openat(directoryFD, "stderr.log", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard error >= 0 else { throw captureFailure("openErrorReader") }
            opened.append(error)
            let combinedWriter = Darwin.openat(directoryFD, "combined.log", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard combinedWriter >= 0 else { throw captureFailure("createCombinedLog", stream: .combined) }
            opened.append(combinedWriter)
            guard fchmod(combinedWriter, 0o600) == 0 else { throw captureFailure("setCombinedLogPermissions", stream: .combined) }
            let combined = Darwin.openat(directoryFD, "combined.log", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard combined >= 0 else { throw captureFailure("openCombinedReader", stream: .combined) }
            opened.append(combined)
            while fsync(directoryFD) != 0 { if errno != EINTR { throw captureFailure("syncCaptureDirectory") } }
            let queue = Darwin.kqueue()
            guard queue >= 0 else { throw captureFailure("createCaptureWatch") }
            opened.append(queue)
            guard fcntl(queue, F_SETFD, FD_CLOEXEC) == 0 else { throw captureFailure("setCaptureWatchCloseOnExec") }
            try Self.validateBindings(artifacts: artifacts, root: rootFD, rootPath: rootPath,
                                      directory: directoryFD, outputReader: output, errorReader: error,
                                      combinedReader: combined, combinedWriter: combinedWriter)
            try Self.armWatch(watch: queue, root: rootFD, directory: directoryFD,
                              outputReader: output, errorReader: error, combinedReader: combined, includeWrites: false)
            self.root = rootFD
            directory = directoryFD
            outputReader = output
            errorReader = error
            combinedReader = combined
            self.combinedWriter = combinedWriter
            watch = queue
        } catch {
            for descriptor in opened { Darwin.close(descriptor) }
            throw error
        }
    }

    deinit { for descriptor in [watch, outputReader, errorReader, combinedReader, combinedWriter, directory, root] { Darwin.close(descriptor) } }

    func path(_ stream: NativeLogStream) -> String {
        switch stream {
        case .standardOutput: artifacts.standardOutputPath
        case .standardError: artifacts.standardErrorPath
        case .combined: artifacts.directoryPath + "/combined.log"
        }
    }

    func writeDescriptor(_ stream: NativeLogStream) -> Int32 {
        switch stream {
        case .standardOutput: artifacts.stdoutDescriptor
        case .standardError: artifacts.stderrDescriptor
        case .combined: combinedWriter
        }
    }

    private func readDescriptor(_ stream: NativeLogStream) -> Int32 {
        switch stream {
        case .standardOutput: outputReader
        case .standardError: errorReader
        case .combined: combinedReader
        }
    }

    func validateBindings() throws {
        try Self.validateBindings(artifacts: artifacts, root: root, rootPath: rootPath,
                                  directory: directory, outputReader: outputReader, errorReader: errorReader,
                                  combinedReader: combinedReader, combinedWriter: combinedWriter)
    }

    private static func validateBindings(artifacts: SessionArtifacts, root: Int32, rootPath: String,
                                         directory: Int32, outputReader: Int32, errorReader: Int32,
                                         combinedReader: Int32, combinedWriter: Int32) throws {
        try artifacts.revalidateRootCustody()
        try captureDirectoryBinding(descriptor: root, path: rootPath, privateMode: false)
        try captureDirectoryBinding(descriptor: directory, path: artifacts.directoryPath, privateMode: true)
        for (name, writer, reader) in [("stdout.log", artifacts.stdoutDescriptor, outputReader),
                                       ("stderr.log", artifacts.stderrDescriptor, errorReader),
                                       ("combined.log", combinedWriter, combinedReader)] {
            let file = try captureStat(writer, operation: "statLogWriter")
            let read = try captureStat(reader, operation: "statLogReader")
            var entry = stat()
            guard fstatat(directory, name, &entry, AT_SYMLINK_NOFOLLOW) == 0 else { throw captureFailure("statLogEntry") }
            guard captureValidLog(file), captureValidLog(read), captureValidLog(entry),
                  captureSameInode(file, read), captureSameInode(file, entry) else {
                throw NativeLogCaptureFailure(operation: "validateLogBinding", code: ESTALE, detail: name)
            }
        }
    }

    func armFinalMutationWatch(includeWrites: Bool = true) throws {
        try eventAccess.withLock { state in
            try checkWatchLocked(&state)
            do {
                try Self.armWatch(watch: watch, root: root, directory: directory,
                                  outputReader: outputReader, errorReader: errorReader,
                                  combinedReader: combinedReader, includeWrites: includeWrites)
                state.finalized = true
            } catch let error as NativeLogCaptureFailure {
                state.failure = error
                throw error
            }
        }
    }

    private static func armWatch(watch: Int32, root: Int32, directory: Int32,
                                 outputReader: Int32, errorReader: Int32, combinedReader: Int32, includeWrites: Bool) throws {
        var changes: [kevent] = []
        for descriptor in [root, directory, outputReader, errorReader, combinedReader] {
            var event = kevent()
            event.ident = UInt(descriptor)
            event.filter = Int16(EVFILT_VNODE)
            event.flags = UInt16(EV_ADD | EV_ENABLE | EV_CLEAR)
            event.fflags = UInt32(NOTE_DELETE | NOTE_RENAME | NOTE_ATTRIB | NOTE_REVOKE)
            // The shared session root legitimately gains sibling phase
            // captures and publication files. Watch its binding, not its
            // changing link count. Private capture entries remain sealed.
            if descriptor != root { event.fflags |= UInt32(NOTE_LINK) }
            if includeWrites && [outputReader, errorReader, combinedReader].contains(descriptor) {
                event.fflags |= UInt32(NOTE_WRITE | NOTE_EXTEND)
            }
            changes.append(event)
        }
        let code = changes.withUnsafeBufferPointer { captureKevent(watch, $0.baseAddress, Int32($0.count), nil, 0, nil) }
        guard code >= 0 else { throw captureFailure("armCaptureWatch") }
    }

    func checkWatch() throws {
        try eventAccess.withLock { state in try checkWatchLocked(&state) }
    }

    private func checkWatchLocked(_ state: inout WatchState) throws {
        if let failure = state.failure { throw failure }
        while true {
            var event = kevent()
            var timeout = timespec(tv_sec: 0, tv_nsec: 0)
            var count: Int32
            repeat { count = captureKevent(watch, nil, 0, &event, 1, &timeout) } while count < 0 && errno == EINTR
            if count < 0 {
                let error = captureFailure("readCaptureWatch")
                state.failure = error
                throw error
            }
            guard count > 0 else { return }
            let descriptor = Int32(event.ident)
            if !state.finalized, event.flags & UInt16(EV_ERROR) == 0,
               event.fflags == UInt32(NOTE_ATTRIB),
               [outputReader, errorReader, combinedReader].contains(descriptor) {
                // Live logs receive metadata notifications even when their
                // custody is unchanged. Validate every pinned binding before
                // admitting one. Finalized logs reject even restored changes.
                do { try validateBindings() }
                catch {
                    let failure = (error as? NativeLogCaptureFailure)
                        ?? NativeLogCaptureFailure(operation: "captureBinding", detail: String(describing: error))
                    state.failure = failure
                    throw failure
                }
                continue
            }
            let labels = [root: "capture root", directory: "capture directory",
                          outputReader: "stdout.log", errorReader: "stderr.log", combinedReader: "combined.log"]
            let error = NativeLogCaptureFailure(operation: "capturePathMutation", code: ESTALE,
                                                detail: "vnode event \(event.fflags) on \(labels[descriptor] ?? "unknown descriptor")")
            state.failure = error
            throw error
        }
    }

    func validate(_ result: NativeLogStreamResult, stream: NativeLogStream) throws {
        try checkWatch()
        try validateBindings()
        let descriptor = readDescriptor(stream)
        let writer = writeDescriptor(stream)
        while fsync(writer) != 0 { if errno != EINTR { throw captureFailure("syncLog", stream: stream) } }
        let before = try captureStat(descriptor, operation: "statFinalLog")
        guard before.st_size == result.retainedBytes, before.st_size <= NativeLogCapture.maximumRawBytes else {
            throw NativeLogCaptureFailure(operation: "finalLogSize", code: ESTALE, stream: stream)
        }
        var hasher = SHA256()
        var offset: Int64 = 0
        var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
        while offset < before.st_size {
            let requested = min(bytes.count, Int(before.st_size - offset))
            let count = bytes.withUnsafeMutableBytes { Darwin.pread(descriptor, $0.baseAddress, requested, off_t(offset)) }
            if count < 0 { if errno == EINTR { continue }; throw captureFailure("readFinalLog", stream: stream) }
            guard count > 0 else { throw NativeLogCaptureFailure(operation: "shortFinalLog", code: EIO, stream: stream) }
            hasher.update(data: Data(bytes.prefix(count)))
            offset += Int64(count)
        }
        let after = try captureStat(descriptor, operation: "statFinalLog")
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard captureSameInode(before, after), before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              digest == result.sha256 else {
            throw NativeLogCaptureFailure(operation: "finalLogMutation", code: ESTALE, stream: stream)
        }
        try validateBindings()
        try checkWatch()
    }
}

// Darwin imports the kevent structure under the same spelling as its C entry
// point. Bind that entry point with the SDK's exact pointer/integer signature.
@_silgen_name("kevent")
private func captureKevent(
    _ queue: Int32, _ changes: UnsafePointer<kevent>?, _ changeCount: Int32,
    _ events: UnsafeMutablePointer<kevent>?, _ eventCount: Int32,
    _ timeout: UnsafePointer<timespec>?
) -> Int32

private func capturePipe() throws -> (reader: Int32, writer: Int32) {
    var descriptors: [Int32] = [-1, -1]
    guard Darwin.pipe(&descriptors) == 0 else { throw captureFailure("createCapturePipe") }
    for descriptor in descriptors {
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            let failure = captureFailure("setCapturePipeCloseOnExec")
            for descriptor in descriptors { Darwin.close(descriptor) }
            throw failure
        }
    }
    let flags = fcntl(descriptors[0], F_GETFL)
    guard flags >= 0, fcntl(descriptors[0], F_SETFL, flags | O_NONBLOCK) == 0 else {
        let failure = captureFailure("setCaptureReaderNonblocking")
        for descriptor in descriptors { Darwin.close(descriptor) }
        throw failure
    }
    return (descriptors[0], descriptors[1])
}

private func captureWaitReadable(_ descriptor: Int32) -> Int32? {
    var event = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
    while true {
        let count = Darwin.poll(&event, 1, -1)
        if count < 0 { if errno == EINTR { continue }; return errno }
        if count == 0 { continue }
        if event.revents & Int16(POLLNVAL) != 0 { return EBADF }
        return nil
    }
}

private func captureFailure(_ operation: String, stream: NativeLogStream? = nil) -> NativeLogCaptureFailure {
    NativeLogCaptureFailure(operation: operation, code: errno, stream: stream)
}

private func captureStat(_ descriptor: Int32, operation: String) throws -> stat {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else { throw captureFailure(operation) }
    return metadata
}

private func captureSameInode(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
}

private func captureValidLog(_ metadata: stat) -> Bool {
    metadata.st_mode & S_IFMT == S_IFREG && metadata.st_uid == geteuid()
        && metadata.st_mode & 0o777 == 0o600 && metadata.st_nlink == 1
}

private func captureDirectoryBinding(descriptor: Int32, path: String, privateMode: Bool) throws {
    let retained = try captureStat(descriptor, operation: "statCaptureDirectory")
    var entry = stat()
    guard lstat(path, &entry) == 0 else { throw captureFailure("statCaptureDirectoryEntry") }
    guard retained.st_mode & S_IFMT == S_IFDIR, entry.st_mode & S_IFMT == S_IFDIR,
          retained.st_uid == geteuid(), retained.st_mode & 0o022 == 0,
          !privateMode || retained.st_mode & 0o777 == 0o700,
          captureSameInode(retained, entry) else {
        throw NativeLogCaptureFailure(operation: "validateCaptureDirectoryBinding", code: ESTALE)
    }
}
