@testable import AgentBuildCore
import Darwin
import Foundation
import Synchronization
import Testing

@Suite("Native raw log capture custody")
struct NativeLogCaptureTests {
    @Test(arguments: [NativeLogStream.standardOutput, .standardError, .combined])
    func liveSameModeMetadataEventsDoNotInvalidateCapturedBytes(_ stream: NativeLogStream) async throws {
        let fixture = try LogCaptureFixture()
        defer { fixture.remove() }
        let capture = try fixture.capture()
        let name = stream == .standardOutput ? "stdout.log" : stream == .standardError ? "stderr.log" : "combined.log"
        let path = capture.directoryPath + "/" + name
        // chmod emits NOTE_ATTRIB even when the effective permissions stay
        // unchanged. A metadata notification alone cannot establish tampering.
        try #require(chmod(path, 0o600) == 0)
        let bytes = Data("unchanged custody".utf8)
        try logWrite(bytes, descriptor: capture.standardOutputDescriptor)
        let result = await capture.finishAfterWorkerRetirement()
        #expect(result.captureComplete)
        #expect(result.standardOutput.sha256 == CanonicalJSONDigest.digest(bytes))
        #expect(result.combined.sha256 == CanonicalJSONDigest.digest(bytes))
        try capture.revalidateForPublication(result)
    }

    @Test(arguments: [NativeLogStream.standardOutput, .standardError, .combined])
    func liveUnsafePermissionsStillInvalidateCapture(_ stream: NativeLogStream) async throws {
        let fixture = try LogCaptureFixture()
        defer { fixture.remove() }
        let capture = try fixture.capture()
        let name = stream == .standardOutput ? "stdout.log" : stream == .standardError ? "stderr.log" : "combined.log"
        let path = capture.directoryPath + "/" + name
        try #require(chmod(path, 0o640) == 0)
        try await logWaitUntil { capture.firstFailure != nil }
        try #require(chmod(path, 0o600) == 0)
        let result = await capture.finishAfterWorkerRetirement()
        #expect(!result.captureComplete)
        #expect(throws: NativeLogCaptureFailure.self) { try capture.revalidateForPublication(result) }
    }

    @Test(arguments: [NativeLogStream.standardOutput, .standardError, .combined])
    func finalizedCaptureRejectsRestoredPermissionChanges(_ stream: NativeLogStream) async throws {
        let fixture = try LogCaptureFixture()
        defer { fixture.remove() }
        let capture = try fixture.capture()
        let bytes = Data("finalized bytes".utf8)
        try logWrite(bytes, descriptor: capture.standardOutputDescriptor)
        let result = await capture.finishAfterWorkerRetirement()
        try #require(result.captureComplete)
        let name = stream == .standardOutput ? "stdout.log" : stream == .standardError ? "stderr.log" : "combined.log"
        let path = capture.directoryPath + "/" + name
        try #require(chmod(path, 0o640) == 0)
        try #require(chmod(path, 0o600) == 0)
        #expect(throws: NativeLogCaptureFailure.self) { try capture.revalidateForPublication(result) }
        #expect(capture.firstFailure?.operation == "capturePathMutation")
        #expect(throws: NativeLogCaptureFailure.self) { try capture.revalidateForPublication(result) }
    }

    @Test func siblingPhaseCapturesAndPublicationDoNotInvalidateEarlierLogs() async throws {
        let fixture = try LogCaptureFixture()
        defer { fixture.remove() }
        let first = try fixture.capture()
        try logWrite(Data("first phase".utf8), descriptor: first.standardOutputDescriptor)
        let firstResult = await first.finishAfterWorkerRetirement()
        #expect(firstResult.captureComplete)
        let second = try fixture.capture()
        try logWrite(Data("second phase".utf8), descriptor: second.standardOutputDescriptor)
        let secondResult = await second.finishAfterWorkerRetirement()
        #expect(secondResult.captureComplete)
        try fixture.write("captures/manifest.json", Data("published sibling".utf8))
        try first.revalidateForPublication(firstResult)
        try second.revalidateForPublication(secondResult)
        #expect(firstResult.standardOutput.sha256 == CanonicalJSONDigest.digest(Data("first phase".utf8)))
    }

    @Test func realChildPipesPreserveBinaryBytesAndIndependentDigests() async throws {
        let fixture = try LogCaptureFixture()
        defer { fixture.remove() }
        let output = Data((0..<262_144).map { UInt8(truncatingIfNeeded: $0) })
        let error = Data([255, 0, 10, 65, 195, 169]) + Data(repeating: 42, count: 131_072)
        try fixture.write("output", output)
        try fixture.write("error", error)
        let capture = try fixture.capture()
        let child = try fixture.child(capture, arguments: ["-c", "/bin/cat \"$1\"; /bin/cat \"$2\" >&2",
                                                         "fixture", fixture.path + "/output", fixture.path + "/error"])
        defer { fixture.stop(child) }
        try await logWaitUntil { !child.isRunning && kill(child.processIdentifier, 0) < 0 && errno == ESRCH }
        let result = await capture.finishAfterWorkerRetirement()
        #expect(child.terminationReason == .exit)
        #expect(child.terminationStatus == 0)
        #expect(result.captureComplete)
        #expect(result.failures.isEmpty)
        #expect(result.standardOutput.reachedEOF && result.standardError.reachedEOF && result.combined.reachedEOF)
        #expect(result.standardOutput.observedBytes == output.count)
        #expect(result.standardOutput.retainedBytes == output.count)
        #expect(result.standardError.observedBytes == error.count)
        #expect(result.standardError.retainedBytes == error.count)
        #expect(result.standardOutput.sha256 == CanonicalJSONDigest.digest(output))
        #expect(result.standardError.sha256 == CanonicalJSONDigest.digest(error))
        #expect(try Data(contentsOf: URL(fileURLWithPath: result.standardOutput.path)) == output)
        #expect(try Data(contentsOf: URL(fileURLWithPath: result.standardError.path)) == error)
        let combined = try Data(contentsOf: URL(fileURLWithPath: result.combined.path))
        #expect(result.combined.observedBytes == output.count + error.count)
        #expect(result.combined.retainedBytes == output.count + error.count)
        #expect(combined.count == output.count + error.count)
        #expect(result.combined.sha256 == CanonicalJSONDigest.digest(combined))
        var directory = stat()
        #expect(lstat(capture.directoryPath, &directory) == 0)
        #expect(directory.st_mode & 0o777 == 0o700)
        for path in [result.standardOutput.path, result.standardError.path, result.combined.path] {
            var file = stat()
            #expect(lstat(path, &file) == 0)
            #expect(file.st_mode & S_IFMT == S_IFREG)
            #expect(file.st_mode & 0o777 == 0o600)
            #expect(file.st_nlink == 1)
        }
        #expect(await capture.finishAfterWorkerRetirement() == result)
        try capture.revalidateForPublication(result)
    }

    @Test func combinedLogPreservesObservedBinarySequenceRatherThanConcatenatingStreams() async throws {
        let fixture = try LogCaptureFixture()
        defer { fixture.remove() }
        let capture = try fixture.capture()
        let first = Data([0, 255, 10, 65])
        let second = Data([195, 169, 0, 254])
        let third = Data([13, 66, 128, 10])
        let combinedPath = capture.directoryPath + "/combined.log"
        try logWrite(first, descriptor: capture.standardOutputDescriptor)
        // The next write follows an actual capture observation, rather than
        // assuming scheduler order or a chronology between two ready pipes.
        try await logWaitUntil { try Data(contentsOf: URL(fileURLWithPath: combinedPath)) == first }
        try logWrite(second, descriptor: capture.standardErrorDescriptor)
        try await logWaitUntil { try Data(contentsOf: URL(fileURLWithPath: combinedPath)) == first + second }
        try logWrite(third, descriptor: capture.standardOutputDescriptor)
        let result = await capture.finishAfterWorkerRetirement()
        #expect(result.captureComplete)
        #expect(try Data(contentsOf: URL(fileURLWithPath: result.standardOutput.path)) == first + third)
        #expect(try Data(contentsOf: URL(fileURLWithPath: result.standardError.path)) == second)
        #expect(try Data(contentsOf: URL(fileURLWithPath: result.combined.path)) == first + second + third)
        #expect(result.combined.sha256 == CanonicalJSONDigest.digest(first + second + third))
        #expect(result.combined.observedBytes == 12 && result.combined.retainedBytes == 12)
        #expect(result.combined.reachedEOF)
        try capture.revalidateForPublication(result)
    }

    @Test func combinedOverflowNotifiesThenDiscardsUntilBothPipesReachEOF() async throws {
        let fixture = try LogCaptureFixture()
        defer { fixture.remove() }
        let bytes = Data(repeating: 7, count: 262_144)
        try fixture.write("input", bytes)
        let failures = LogFailureObserver()
        let capture = try fixture.capture(maximumBytes: 1_024) { failures.add($0) }
        let child = try fixture.child(capture, arguments: ["-c", "/bin/cat \"$1\"; /bin/cat \"$1\" >&2",
                                                         "fixture", fixture.path + "/input"])
        defer { fixture.stop(child) }
        try await logWaitUntil { !child.isRunning && kill(child.processIdentifier, 0) < 0 && errno == ESRCH }
        let result = await capture.finishAfterWorkerRetirement()
        #expect(child.terminationReason == .exit)
        #expect(child.terminationStatus == 0)
        #expect(!result.captureComplete)
        #expect(result.standardOutput.reachedEOF && result.standardError.reachedEOF)
        #expect(result.standardOutput.observedBytes == bytes.count)
        #expect(result.standardError.observedBytes == bytes.count)
        #expect(result.standardOutput.retainedBytes + result.standardError.retainedBytes <= 1_024)
        #expect(result.combined.observedBytes == bytes.count * 2)
        #expect(result.combined.retainedBytes == result.standardOutput.retainedBytes + result.standardError.retainedBytes)
        #expect(result.combined.retainedBytes <= 1_024)
        #expect(result.combined.reachedEOF)
        #expect(result.failures.contains { $0.operation == "rawOutputLimit" })
        #expect(failures.values.contains { $0.operation == "rawOutputLimit" })
        #expect(capture.supervisorFailure()?.operation == "nativeLogCapture.rawOutputLimit")
    }

    @Test func exactInclusiveBoundStillAdmitsCompleteOutput() async throws {
        let fixture = try LogCaptureFixture()
        defer { fixture.remove() }
        let capture = try fixture.capture(maximumBytes: 8)
        try logWrite(Data("12345678".utf8), descriptor: capture.standardOutputDescriptor)
        let result = await capture.finishAfterWorkerRetirement()
        #expect(result.captureComplete)
        #expect(result.standardOutput.retainedBytes == 8)
        #expect(result.standardError.retainedBytes == 0)
        #expect(result.standardError.sha256 == CanonicalJSONDigest.digest(Data()))
        #expect(result.combined.observedBytes == 8 && result.combined.retainedBytes == 8)
        #expect(result.combined.sha256 == CanonicalJSONDigest.digest(Data("12345678".utf8)))
        #expect(result.combined.reachedEOF)
    }

    @Test func diskFailureDoesNotStrandAChildBehindItsFullOutputPipe() async throws {
        let fixture = try LogCaptureFixture()
        defer { fixture.remove() }
        let bytes = Data(repeating: 3, count: 262_144)
        try fixture.write("input", bytes)
        let failures = LogFailureObserver()
        let capture = try NativeLogCapture(root: fixture.path + "/captures", runID: UUID().uuidString,
                                           maximumBytes: NativeLogCapture.maximumRawBytes,
                                           onFailure: { failures.add($0) },
                                           writeChunk: { _, _ in CaptureWriteObservation(bytesWritten: 0, errorNumber: ENOSPC) })
        let child = try fixture.child(capture, arguments: ["-c", "/bin/cat \"$1\"; /bin/cat \"$1\" >&2",
                                                         "fixture", fixture.path + "/input"])
        defer { fixture.stop(child) }
        try await logWaitUntil { !child.isRunning && kill(child.processIdentifier, 0) < 0 && errno == ESRCH }
        let result = await capture.finishAfterWorkerRetirement()
        #expect(child.terminationReason == .exit)
        #expect(child.terminationStatus == 0)
        #expect(!result.captureComplete)
        #expect(result.standardOutput.reachedEOF && result.standardError.reachedEOF)
        #expect(result.standardOutput.observedBytes == bytes.count)
        #expect(result.standardError.observedBytes == bytes.count)
        #expect(result.standardOutput.retainedBytes == 0 && result.standardError.retainedBytes == 0)
        #expect(result.combined.observedBytes == bytes.count * 2 && result.combined.retainedBytes == 0)
        #expect(result.combined.reachedEOF)
        #expect(result.failures.contains { $0.operation == "writeLog" && $0.code == ENOSPC })
        #expect(!failures.values.isEmpty)
    }

    @Test func combinedWriteFailureStillDrainsBothOriginalPipesAndReportsItsOwnFailure() async throws {
        let fixture = try LogCaptureFixture()
        defer { fixture.remove() }
        let bytes = Data(repeating: 17, count: 262_144)
        try fixture.write("input", bytes)
        let failures = LogFailureObserver()
        let writer = LogCombinedFailureWriter()
        let capture = try NativeLogCapture(root: fixture.path + "/captures", runID: UUID().uuidString,
                                           maximumBytes: NativeLogCapture.maximumRawBytes,
                                           onFailure: { failures.add($0) }, writeChunk: { writer.write($0, $1) })
        try writer.pinCombined(path: capture.directoryPath + "/combined.log")
        let child = try fixture.child(capture, arguments: ["-c", "/bin/cat \"$1\"; /bin/cat \"$1\" >&2",
                                                         "fixture", fixture.path + "/input"])
        defer { fixture.stop(child) }
        try await logWaitUntil { !child.isRunning && kill(child.processIdentifier, 0) < 0 && errno == ESRCH }
        let result = await capture.finishAfterWorkerRetirement()
        #expect(child.terminationReason == .exit && child.terminationStatus == 0)
        #expect(!result.captureComplete)
        #expect(result.standardOutput.reachedEOF && result.standardError.reachedEOF && result.combined.reachedEOF)
        #expect(result.standardOutput.observedBytes == bytes.count && result.standardError.observedBytes == bytes.count)
        #expect(result.standardOutput.retainedBytes + result.standardError.retainedBytes > 0)
        #expect(result.combined.observedBytes == bytes.count * 2 && result.combined.retainedBytes == 0)
        #expect(result.combined.sha256 == CanonicalJSONDigest.digest(Data()))
        #expect(result.failures.contains { $0.operation == "writeLog" && $0.code == ENOSPC && $0.stream == .combined })
        #expect(failures.values.contains { $0.stream == .combined })
        #expect(capture.supervisorFailure()?.operation == "nativeLogCapture.writeLog")
        #expect(throws: NativeLogCaptureFailure.self) { try capture.revalidateForPublication(result) }
    }

    @Test func cancelledFinisherStillWaitsForADelayedWriterAndRetainsItsBytes() async throws {
        let fixture = try LogCaptureFixture()
        defer { fixture.remove() }
        let capture = try fixture.capture()
        var writer = fcntl(capture.standardOutputDescriptor, F_DUPFD_CLOEXEC, 64)
        #expect(writer >= 64)
        defer { if writer >= 0 { close(writer) } }
        try logWrite(Data("first ".utf8), descriptor: writer)
        let done = LogCompletionObserver()
        let finish = Task {
            let result = await capture.finishAfterWorkerRetirement()
            done.mark()
            return result
        }
        try await Task.sleep(for: .milliseconds(30))
        finish.cancel()
        try await Task.sleep(for: .milliseconds(30))
        #expect(!done.completed)
        try logWrite(Data("last".utf8), descriptor: writer)
        #expect(close(writer) == 0)
        writer = -1
        let result = await finish.value
        #expect(result.captureComplete)
        #expect(result.standardOutput.observedBytes == 10)
        #expect(result.standardOutput.sha256 == CanonicalJSONDigest.digest(Data("first last".utf8)))
        #expect(try String(contentsOfFile: result.standardOutput.path, encoding: .utf8) == "first last")
        #expect(result.combined.observedBytes == 10 && result.combined.retainedBytes == 10 && result.combined.reachedEOF)
        #expect(result.combined.sha256 == result.standardOutput.sha256)
        #expect(try String(contentsOfFile: result.combined.path, encoding: .utf8) == "first last")
    }

    @Test(arguments: ["directory", "file", "combined-file"])
    func pathSubstitutionIsDetectedEvenWhileOutputIsQuiet(_ mutation: String) async throws {
        let fixture = try LogCaptureFixture()
        defer { fixture.remove() }
        let capture = try fixture.capture()
        if mutation == "directory" {
            #expect(rename(capture.directoryPath, capture.directoryPath + ".moved") == 0)
            #expect(mkdir(capture.directoryPath, 0o700) == 0)
        } else {
            let path = capture.directoryPath + (mutation == "combined-file" ? "/combined.log" : "/stdout.log")
            #expect(rename(path, path + ".moved") == 0)
            let replacement = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            #expect(replacement >= 0)
            if replacement >= 0 { close(replacement) }
        }
        try await logWaitUntil { capture.firstFailure != nil }
        let result = await capture.finishAfterWorkerRetirement()
        #expect(!result.captureComplete)
        #expect(result.standardOutput.reachedEOF && result.standardError.reachedEOF)
        #expect(!result.failures.isEmpty)
    }

    @Test func symlinkedAncestorRejectsCaptureCreationWithoutCreatingLogsAtItsTarget() throws {
        let fixture = try LogCaptureFixture()
        defer { fixture.remove() }
        let target = fixture.path + "/real-parent"
        let alias = fixture.path + "/parent-alias"
        #expect(mkdir(target, 0o700) == 0)
        #expect(symlink(target, alias) == 0)
        #expect(throws: (any Error).self) {
            try NativeLogCapture(root: alias + "/captures", runID: UUID().uuidString)
        }
        #expect(!FileManager.default.fileExists(atPath: target + "/captures"))
    }

    @Test func publicationRequiresItsExactCompleteCachedResult() async throws {
        let fixture = try LogCaptureFixture()
        defer { fixture.remove() }
        let capture = try fixture.capture()
        let empty = NativeLogStreamResult(path: "", observedBytes: 0, retainedBytes: 0,
                                           sha256: CanonicalJSONDigest.digest(Data()), reachedEOF: true)
        let premature = NativeLogCaptureResult(standardOutput: empty, standardError: empty, combined: empty,
                                               maximumBytes: NativeLogCapture.maximumRawBytes,
                                               captureComplete: true, failures: [])
        #expect(throws: NativeLogCaptureFailure.self) { try capture.revalidateForPublication(premature) }
        try logWrite(Data("captured".utf8), descriptor: capture.standardOutputDescriptor)
        let result = await capture.finishAfterWorkerRetirement()
        #expect(result.captureComplete)
        let substituted = NativeLogCaptureResult(standardOutput: result.standardOutput,
                                                  standardError: result.standardError,
                                                  combined: result.combined,
                                                  maximumBytes: result.maximumBytes - 1,
                                                  captureComplete: true, failures: [])
        #expect(throws: NativeLogCaptureFailure.self) { try capture.revalidateForPublication(substituted) }
        #expect(capture.firstFailure == nil)
        try capture.revalidateForPublication(result)
    }

    @Test(arguments: [NativeLogStream.standardOutput, .combined], ["write-and-restore", "rename-and-restore", "replace-and-restore"])
    func publicationRejectsRestoredMutationAndNeverClearsItsConsumedEvent(_ stream: NativeLogStream, _ mutation: String) async throws {
        let fixture = try LogCaptureFixture()
        defer { fixture.remove() }
        let capture = try fixture.capture()
        let bytes = Data("captured".utf8)
        try logWrite(bytes, descriptor: capture.standardOutputDescriptor)
        let result = await capture.finishAfterWorkerRetirement()
        #expect(result.captureComplete)
        try capture.revalidateForPublication(result)
        let path = stream == .combined ? result.combined.path : result.standardOutput.path
        if mutation == "write-and-restore" {
            let descriptor = open(path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw LogFixtureError.setup }
            defer { close(descriptor) }
            try logWrite(Data("replaced".utf8), descriptor: descriptor)
            #expect(lseek(descriptor, 0, SEEK_SET) == 0)
            try logWrite(bytes, descriptor: descriptor)
        } else {
            #expect(rename(path, path + ".moved") == 0)
            if mutation == "replace-and-restore" {
                let replacement = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard replacement >= 0 else { throw LogFixtureError.setup }
                do { try logWrite(bytes, descriptor: replacement) }
                catch { close(replacement); throw error }
                #expect(close(replacement) == 0)
                try FileManager.default.removeItem(atPath: path)
            }
            #expect(rename(path + ".moved", path) == 0)
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
        #expect(throws: NativeLogCaptureFailure.self) { try capture.revalidateForPublication(result) }
        #expect(capture.firstFailure?.operation == "capturePathMutation")
        #expect(throws: NativeLogCaptureFailure.self) { try capture.revalidateForPublication(result) }
    }
}

private struct LogCaptureFixture {
    let path: String

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("raw-log-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        guard let pointer = root.path.withCString({ realpath($0, nil) }) else { throw LogFixtureError.setup }
        defer { free(pointer) }
        path = String(cString: pointer)
    }

    func remove() { try? FileManager.default.removeItem(atPath: path) }

    func write(_ name: String, _ bytes: Data) throws { try bytes.write(to: URL(fileURLWithPath: path + "/" + name)) }

    func capture(maximumBytes: Int64 = NativeLogCapture.maximumRawBytes,
                 onFailure: @escaping @Sendable (NativeLogCaptureFailure) -> Void = { _ in }) throws -> NativeLogCapture {
        try NativeLogCapture(root: path + "/captures", runID: UUID().uuidString,
                              maximumBytes: maximumBytes, onFailure: onFailure)
    }

    func child(_ capture: NativeLogCapture, arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments
        process.standardOutput = FileHandle(fileDescriptor: capture.standardOutputDescriptor, closeOnDealloc: false)
        process.standardError = FileHandle(fileDescriptor: capture.standardErrorDescriptor, closeOnDealloc: false)
        try process.run()
        return process
    }

    func stop(_ process: Process) {
        guard process.isRunning else { return }
        let result = kill(process.processIdentifier, SIGKILL), error = errno
        #expect(result == 0 || error == ESRCH)
        let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(5))
        var retired = false
        while clock.now < deadline {
            if !process.isRunning && kill(process.processIdentifier, 0) < 0 && errno == ESRCH { retired = true; break }
            usleep(10_000)
        }
        #expect(retired, "Log fixture process retirement must be observed within five seconds.")
    }
}

private final class LogFailureObserver: Sendable {
    private let state: Mutex<[NativeLogCaptureFailure]> = Mutex([])
    var values: [NativeLogCaptureFailure] { state.withLock { $0 } }
    func add(_ failure: NativeLogCaptureFailure) { state.withLock { $0.append(failure) } }
}

private final class LogCompletionObserver: Sendable {
    private let state: Mutex<Bool> = Mutex(false)
    var completed: Bool { state.withLock { $0 } }
    func mark() { state.withLock { $0 = true } }
}

private enum LogFixtureError: Error { case setup, deadline, write }

private func logWaitUntil(_ condition: () throws -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while clock.now < deadline {
        if try condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw LogFixtureError.deadline
}

private func logWrite(_ data: Data, descriptor: Int32) throws {
    try data.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw LogFixtureError.write }
            offset += count
        }
    }
}

private final class LogCombinedFailureWriter: Sendable {
    private let identity: Mutex<(device: dev_t, inode: ino_t)?> = Mutex(nil)

    func pinCombined(path: String) throws {
        var file = stat()
        guard lstat(path, &file) == 0, file.st_mode & S_IFMT == S_IFREG else { throw LogFixtureError.setup }
        identity.withLock { $0 = (file.st_dev, file.st_ino) }
    }

    func write(_ descriptor: Int32, _ data: Data) -> CaptureWriteObservation {
        // Compare actual descriptor identity; no variadic F_GETPATH bridge or
        // dependency on the order in which the source pipes become readable.
        guard let expected = identity.withLock({ $0 }) else {
            return CaptureWriteObservation(bytesWritten: 0, errorNumber: EINVAL)
        }
        var file = stat()
        guard fstat(descriptor, &file) == 0 else { return CaptureWriteObservation(bytesWritten: 0, errorNumber: errno) }
        if file.st_dev == expected.device && file.st_ino == expected.inode {
            return CaptureWriteObservation(bytesWritten: 0, errorNumber: ENOSPC)
        }
        return logObservedWrite(descriptor, data)
    }
}

private func logObservedWrite(_ descriptor: Int32, _ data: Data) -> CaptureWriteObservation {
    return data.withUnsafeBytes { buffer in
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
