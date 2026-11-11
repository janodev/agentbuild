import AgentBuildCore
import AgentBuildTestSupport
import Darwin
import Foundation
@testable import NotikaAdapter
import Testing

@Suite("Standalone preflight CLI boundary")
struct NotikaPreflightCommandTests {
    @Test func helpDescribesClosedPreflightWithoutXcodeRequestOptions() throws {
        let result = try preflightCLI(["notika", "run-preflight", "--help"])
        #expect(result.status == 0)
        let normalizedHelp = result.output.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(normalizedHelp.contains("exact-source"))
        #expect(result.output.contains("--repository"))
        #expect(!result.output.contains("--route"))
        #expect(!result.output.contains("--platform"))
    }

    @Test func invalidWaitFailsBeforeCreatingArtifactsOrExecutingTools() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentbuild-preflight-cli-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try preflightCLI(["notika", "run-preflight", "--repository", root.path, "--wait-seconds=-1", "--json"])
        #expect(result.status != 0)
        #expect(result.error.contains("finite and nonnegative"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Artifacts").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".agentlease").path))
    }
}

private func preflightCLI(_ arguments: [String]) throws -> (status: Int32, output: String, error: String) {
    let root = AgentBuildTestPaths.packageRoot
    let process = Process(), output = Pipe(), error = Pipe()
    process.executableURL = root.appendingPathComponent(".build/debug/agentbuild")
    process.arguments = arguments
    process.standardOutput = output; process.standardError = error
    try process.run()
    let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(5))
    var retired = false
    while clock.now < deadline {
        if !process.isRunning && kill(process.processIdentifier, 0) < 0 && errno == ESRCH { retired = true; break }
        usleep(5_000)
    }
    if !retired {
        let result = kill(process.processIdentifier, SIGKILL), error = errno
        #expect(result == 0 || error == ESRCH)
        let retirementDeadline = clock.now.advanced(by: .seconds(5))
        while clock.now < retirementDeadline {
            if !process.isRunning && kill(process.processIdentifier, 0) < 0 && errno == ESRCH { retired = true; break }
            usleep(5_000)
        }
        #expect(retired, "Preflight CLI fixture retirement must be observed within five seconds.")
        throw NotikaPreflightDriverError.invalidArgument("CLI fixture deadline")
    }
    try #require(process.terminationReason == .exit)
    return (process.terminationStatus,
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}
