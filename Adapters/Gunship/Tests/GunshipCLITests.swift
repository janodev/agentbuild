import AgentBuildCore
import AgentLeaseCore
import Darwin
import Foundation
@testable import GunshipAdapter
import Testing

@Suite("Gunship CLI cancellation and outcome contracts", .serialized)
struct GunshipCLITests {
    @Test(arguments: [SIGTERM, SIGHUP])
    func cancellationWhileWaitingPublishesTheReceivedSignal(_ signal: Int32) async throws {
        let fixture = try await GunshipFixture()
        defer { fixture.remove() }
        let owner = try gunshipCLICompilationLock(fixture)
        #expect(try owner.tryAcquire())
        defer { owner.release() }
        let process = gunshipCLIProcess(fixture, action: "build")
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        defer { gunshipCLIStop(process) }
        try await gunshipCLIWaitUntil { try gunshipCLIHasSession(fixture) }

        #expect(kill(process.processIdentifier, signal) == 0)
        try await gunshipCLIWaitUntil { !process.isRunning }
        let report = try gunshipCLIReport(output)
        try gunshipCLIExpectCancellation(process, report: report, signal: signal)
        #expect((report["phases"] as? [[String: Any]])?.isEmpty == true)
        #expect(report["nativeTermination"] == nil)
        try gunshipCLIExpectManifest(report)
    }

    @Test(arguments: [SIGTERM, SIGHUP])
    func activeCancellationKeepsNativeTerminationSeparateFromCLIStatus(_ signal: Int32) async throws {
        let fixture = try await GunshipFixture()
        defer { fixture.remove() }
        try Data("""
            mkdir -p Binaries
            trap '' TERM HUP INT
            printf '%s' "$$" > Binaries/child.pid.tmp
            mv Binaries/child.pid.tmp Binaries/child.pid
            exec /bin/sleep 30
            """.utf8).write(to: URL(fileURLWithPath: fixture.repository + "/Scripts/build_macos.sh"))
        let marker = URL(fileURLWithPath: fixture.repository + "/Binaries/child.pid")
        let process = gunshipCLIProcess(fixture, action: "build")
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        defer { gunshipCLIStop(process) }
        try await gunshipCLIWaitUntil { FileManager.default.fileExists(atPath: marker.path) }
        let child = try #require(Int32(try String(contentsOf: marker, encoding: .utf8)))
        #expect(kill(child, 0) == 0)

        #expect(kill(process.processIdentifier, signal) == 0)
        try await gunshipCLIWaitUntil { !process.isRunning }
        let report = try gunshipCLIReport(output)
        try gunshipCLIExpectCancellation(process, report: report, signal: signal)
        let native = try #require(report["nativeTermination"] as? [String: Any])
        #expect(native["kind"] as? String == "signal")
        #expect(native["value"] as? Int == Int(SIGKILL))
        #expect(kill(child, 0) == -1 && errno == ESRCH)
        try gunshipCLIExpectManifest(report)
    }

    @Test func humanCancellationStatusMatchesTheManifestAndProcessExit() async throws {
        let fixture = try await GunshipFixture()
        defer { fixture.remove() }
        let owner = try gunshipCLICompilationLock(fixture)
        #expect(try owner.tryAcquire())
        defer { owner.release() }
        let process = gunshipCLIProcess(fixture, action: "build", json: false)
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        defer { gunshipCLIStop(process) }
        try await gunshipCLIWaitUntil { try gunshipCLIHasSession(fixture) }
        #expect(kill(process.processIdentifier, SIGTERM) == 0)
        try await gunshipCLIWaitUntil { !process.isRunning }

        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 128 + SIGTERM)
        #expect(text.contains("Gunship build: cancelled (status \(128 + SIGTERM))"))
        let sessions = try FileManager.default.contentsOfDirectory(atPath: fixture.repository + "/Artifacts/AgentSessions")
        let session = try #require(sessions.first)
        let manifest = try gunshipCLIJSON(Data(contentsOf: URL(fileURLWithPath:
            fixture.repository + "/Artifacts/AgentSessions/" + session + "/manifest.json")))
        #expect(manifest["exitCode"] as? Int == Int(process.terminationStatus))
        #expect(manifest["cancellationSignal"] as? Int == Int(SIGTERM))
    }

    @Test func nativeFailureSurvivesReportParseFailureAndSourceDrift() async throws {
        let fixture = try await GunshipFixture()
        defer { fixture.remove() }
        try Data("printf '// changed during automation\\n' > Source/Gunship.cpp\nexit 27\n".utf8)
            .write(to: URL(fileURLWithPath: fixture.repository + "/Scripts/test_macos.sh"))
        let process = gunshipCLIProcess(fixture, action: "test")
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        defer { gunshipCLIStop(process) }
        try await gunshipCLIWaitUntil { !process.isRunning }

        let report = try gunshipCLIReport(output)
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 27)
        #expect(report["status"] as? String == "failed")
        #expect(report["exitCode"] as? Int == 27)
        #expect(report["sourceDrift"] as? Bool == true)
        #expect(report["cancellationSignal"] == nil)
        #expect((report["orchestrationFailures"] as? [String])?.isEmpty == false)
        let native = try #require(report["nativeTermination"] as? [String: Any])
        #expect(native["kind"] as? String == "exit")
        #expect(native["value"] as? Int == 27)
        try gunshipCLIExpectManifest(report)
    }
}

private func gunshipCLIProcess(_ fixture: GunshipFixture, action: String, json: Bool = true) -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: fixture.helper)
    process.arguments = ["gunship", action, "--repository", fixture.repository, "--engine", fixture.engine,
                         "--wait-seconds", "30"] + (json ? ["--json"] : [])
    process.environment = fixture.environment
    process.standardError = FileHandle.nullDevice
    return process
}

private func gunshipCLICompilationLock(_ fixture: GunshipFixture) throws -> FileLock {
    try FileLock(resource: ResourceName("host:compile"), mode: .exclusive,
                 paths: AgentLeasePaths.open(selectedRoot: fixture.environment["AGENTLEASE_COMPILE_HOME"]!))
}

private func gunshipCLIHasSession(_ fixture: GunshipFixture) throws -> Bool {
    let root = fixture.repository + "/Artifacts/AgentSessions"
    guard FileManager.default.fileExists(atPath: root) else { return false }
    return try FileManager.default.contentsOfDirectory(atPath: root).contains {
        FileManager.default.fileExists(atPath: root + "/" + $0 + "/in-progress.json")
    }
}

private func gunshipCLIReport(_ output: Pipe) throws -> [String: Any] {
    try gunshipCLIJSON(output.fileHandleForReading.readDataToEndOfFile())
}

private func gunshipCLIJSON(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func gunshipCLIExpectCancellation(_ process: Process, report: [String: Any], signal: Int32) throws {
    #expect(process.terminationReason == .exit)
    #expect(process.terminationStatus == 128 + signal)
    #expect(report["exitCode"] as? Int == Int(process.terminationStatus))
    #expect(report["status"] as? String == "cancelled")
    #expect(report["cancelled"] as? Bool == true)
    #expect(report["cancellationSignal"] as? Int == Int(signal))
}

private func gunshipCLIExpectManifest(_ report: [String: Any]) throws {
    let session = try #require(report["sessionPath"] as? String)
    let manifest = try gunshipCLIJSON(Data(contentsOf: URL(fileURLWithPath: session + "/manifest.json")))
    #expect(manifest["status"] as? String == report["status"] as? String)
    #expect(manifest["exitCode"] as? Int == report["exitCode"] as? Int)
    #expect(manifest["cancellationSignal"] as? Int == report["cancellationSignal"] as? Int)
}

private func gunshipCLIStop(_ process: Process) {
    guard process.isRunning else { return }
    // Let the CLI retire its supervised workload before tearing down a failed
    // fixture. Killing only the coordinator would leave teardown to owner EOF.
    _ = kill(process.processIdentifier, SIGTERM)
    var deadline = ContinuousClock().now.advanced(by: .seconds(5))
    while process.isRunning, ContinuousClock().now < deadline { usleep(10_000) }
    if process.isRunning {
        _ = kill(process.processIdentifier, SIGKILL)
        deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while process.isRunning, ContinuousClock().now < deadline { usleep(10_000) }
    }
    #expect(!process.isRunning, "Gunship fixture CLI must retire within five seconds")
}

private enum GunshipCLIFixtureError: Error { case deadline }

private func gunshipCLIWaitUntil(_ condition: () throws -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    while clock.now < deadline {
        if try condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw GunshipCLIFixtureError.deadline
}
