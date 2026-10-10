import AgentBuildCore
import Darwin
import Foundation
import Testing

@Suite("Strict raw repository command capture")
struct RepositoryCommandCaptureTests {
    @Test func bytesAndLiteralArgumentsArePreservedWithoutTextDecoding() async throws {
        let capture = try RepositoryCommandCapture(outputLimit: 64)
        let output = try await capture.capture(
            arguments: ["/bin/sh", "-c", "printf '\\000\\377'; printf '%s' \"$1\"; printf diagnostic >&2",
                        "fixture", "$(false) space ' quote"], workingDirectory: "/private/tmp", environment: [:])
        #expect(output == Data([0, 255]) + Data("$(false) space ' quote".utf8))
    }

    @Test func inclusiveLimitAndNonzeroDiagnosticsMatchTheReference() async throws {
        let capture = try RepositoryCommandCapture(outputLimit: 10)
        #expect(try await capture.capture(arguments: ["/usr/bin/printf", "%s", "0123456789"],
                                          workingDirectory: "/private/tmp", environment: [:]) == Data("0123456789".utf8))
        await #expect(throws: RepositoryCaptureError.outputLimitExceeded) {
            _ = try await capture.capture(arguments: ["/usr/bin/printf", "%s", "01234567890"],
                                          workingDirectory: "/private/tmp", environment: [:])
        }
        await #expect(throws: RepositoryCaptureError.commandFailed(executable: "/bin/sh", exitCode: 7,
                                                                   diagnostic: "broken")) {
            _ = try await capture.capture(arguments: ["/bin/sh", "-c", "printf ' \\034broken\\035\\n' >&2; exit 7"],
                                          workingDirectory: "/private/tmp", environment: [:])
        }
    }

    @Test func eitherStreamOverflowTearsDownTheGroupAndReapsTheChild() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.remove() }
        let capture = try RepositoryCommandCapture(outputLimit: 8, diagnosticLimit: 8)
        for stream in ["stdout", "stderr"] {
            let pidFile = fixture.path + "/pid-" + stream
            let marker = fixture.path + "/marker-" + stream
            let script = "printf '%s' \"$$\" > \"$1\"; (/bin/sleep 0.2; printf leaked > \"$2\") & " +
                (stream == "stdout" ? "printf '012345678'" : "printf '012345678' >&2") + "; wait"
            await #expect(throws: RepositoryCaptureError.outputLimitExceeded) {
                _ = try await capture.capture(arguments: ["/bin/sh", "-c", script, "fixture", pidFile, marker],
                                              workingDirectory: fixture.path, environment: [:])
            }
            let pid = try #require(Int32(String(contentsOfFile: pidFile, encoding: .utf8)))
            #expect(kill(pid, 0) == -1 && errno == ESRCH)
            try await Task.sleep(for: .milliseconds(250))
            #expect(!FileManager.default.fileExists(atPath: marker))
        }
    }

    @Test func timeoutAndParentCancellationAwaitTeardown() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.remove() }
        let pidFile = fixture.path + "/pid"
        let marker = fixture.path + "/marker"
        let script = "printf '%s' \"$$\" > \"$1\"; (/bin/sleep 0.25; printf leaked > \"$2\") & wait"
        let arguments = ["/bin/sh", "-c", script, "fixture", pidFile, marker]
        await #expect(throws: RepositoryCaptureError.timedOut) {
            _ = try await RepositoryCommandCapture(timeout: .milliseconds(100)).capture(
                arguments: arguments, workingDirectory: fixture.path, environment: [:])
        }
        let firstPID = try #require(Int32(String(contentsOfFile: pidFile, encoding: .utf8)))
        #expect(kill(firstPID, 0) == -1 && errno == ESRCH)
        try FileManager.default.removeItem(atPath: pidFile)
        let capture = try RepositoryCommandCapture()
        let task = Task { try await capture.capture(arguments: arguments, workingDirectory: fixture.path, environment: [:]) }
        defer { task.cancel() }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: pidFile) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let secondPID = try #require(Int32(String(contentsOfFile: pidFile, encoding: .utf8)))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(kill(secondPID, 0) == -1 && errno == ESRCH)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test func relativePathEntriesUseTheRequestedChildDirectoryAndEnvironment() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.remove() }
        let tool = fixture.path + "/fixture-tool"
        try Data("#!/bin/sh\nprintf '%s' \"$FIXTURE_VALUE\"\n".utf8).write(to: URL(fileURLWithPath: tool))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool)
        let data = try await RepositoryCommandCapture().capture(arguments: ["fixture-tool"], workingDirectory: fixture.path,
                                                                environment: ["PATH": "", "FIXTURE_VALUE": "selected"])
        #expect(data == Data("selected".utf8))
    }

    @Test func malformedInputsFailBeforeSpawn() async throws {
        #expect(throws: RepositoryCaptureError.invalidInput) { try RepositoryCommandCapture(outputLimit: -1) }
        #expect(throws: RepositoryCaptureError.invalidInput) { try RepositoryCommandCapture(timeout: .zero) }
        let capture = try RepositoryCommandCapture()
        await #expect(throws: RepositoryCaptureError.invalidInput) {
            _ = try await capture.capture(arguments: ["/bin/echo", "nul\0tail"], workingDirectory: "/tmp", environment: [:])
        }
        await #expect(throws: RepositoryCaptureError.invalidInput) {
            _ = try await capture.capture(arguments: ["/bin/echo"], workingDirectory: "/tmp", environment: ["A=B": "value"])
        }
    }
}

private struct CaptureFixture {
    let path: String
    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("repository-capture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        path = url.resolvingSymlinksInPath().path
    }
    func remove() { try? FileManager.default.removeItem(atPath: path) }
}
