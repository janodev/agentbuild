import AgentBuildCore
import AgentLeaseCore
import Darwin
import Foundation
import Testing

@Suite("Managed CLI signal and argument contracts")
struct ManagedCLITests {
    @Test func unsafeArtifactSetupIsADriverFailureWithoutLaunching() async throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.artifacts, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o777])
        let marker = fixture.directory.appendingPathComponent("launched")
        let process = fixture.process(arguments: ["-c", "touch \"$1\"", "fixture", marker.path])
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        defer { fixture.stop(process) }
        try await cliWaitUntil { !process.isRunning }
        process.waitUntilExit()
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 70)
        #expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
        let diagnostic = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(diagnostic.contains("Execution failed"))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func terminationSignalPublishesMatchingStatusAfterReaping() async throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let marker = fixture.directory.appendingPathComponent("child.pid")
        let process = fixture.process(arguments: [
            "-c", "printf '%s' \"$$\" > \"$1\"; exec /bin/sleep 30", "fixture", marker.path,
        ])
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        defer { fixture.stop(process) }
        try await cliWaitUntil { FileManager.default.fileExists(atPath: marker.path) }
        let child = try #require(Int32(try String(contentsOf: marker, encoding: .utf8)))
        defer { _ = kill(child, SIGKILL) }
        #expect(try !fixture.available())

        #expect(kill(process.processIdentifier, SIGTERM) == 0)
        try await cliWaitUntil { !process.isRunning }
        process.waitUntilExit()
        let report = try fixture.report(output)
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 128 + SIGTERM)
        #expect(report.receivedSignal == SIGTERM)
        #expect(report.exitCode == process.terminationStatus)
        #expect(report.state == .cancelled)
        #expect(report.childPID == child)
        #expect(report.termination == nil)
        #expect(kill(child, 0) == -1 && errno == ESRCH)
        #expect(try fixture.available())
        let record = try fixture.record(report)
        #expect(record.receivedSignal == SIGTERM)
    }

    @Test func interruptDuringAdmissionPublishesCancellationWithoutAChild() async throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let owner = try fixture.lock()
        #expect(try owner.tryAcquire())
        defer { owner.release() }
        let marker = fixture.directory.appendingPathComponent("launched")
        let process = fixture.process(arguments: ["-c", "touch \"$1\"", "fixture", marker.path])
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        defer { fixture.stop(process) }
        try await cliWaitUntil { try fixture.hasAcquiringManifest() }

        #expect(kill(process.processIdentifier, SIGINT) == 0)
        try await cliWaitUntil { !process.isRunning }
        process.waitUntilExit()
        let report = try fixture.report(output)
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 128 + SIGINT)
        #expect(report.receivedSignal == SIGINT)
        #expect(report.exitCode == process.terminationStatus)
        #expect(report.state == .cancelled)
        #expect(report.childPID == nil)
        #expect(report.termination == nil)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(try !fixture.available())
        owner.release()
        #expect(try fixture.available())
        #expect(try fixture.record(report).receivedSignal == SIGINT)
    }

    @Test func passthroughKeepsLaterTerminatorsAndShellCharactersLiteral() async throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let literal = "$(false) space ' quote"
        let process = fixture.process(arguments: [
            "-c", "printf '%s|%s' \"$1\" \"$2\"", "fixture", "--", literal,
        ])
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        defer { fixture.stop(process) }
        try await cliWaitUntil { !process.isRunning }
        process.waitUntilExit()
        let report = try fixture.report(output)
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 0)
        #expect(report.exitCode == 0)
        #expect(report.state == .completed)
        #expect(report.receivedSignal == nil)
        #expect(try String(contentsOfFile: report.standardOutputPath, encoding: .utf8) == "--|\(literal)")
        #expect(try fixture.available())
    }

    @Test func sharedOptionJoinsAnExistingReaderWithoutAdmittingAnExclusiveOwner() async throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let owner = try fixture.lock(mode: .shared)
        #expect(try owner.tryAcquire())
        defer { owner.release() }
        #expect(try !fixture.available())

        let process = fixture.process(arguments: ["-c", "printf shared"], resourceOption: "--shared-resource")
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        defer { fixture.stop(process) }
        try await cliWaitUntil { !process.isRunning }
        process.waitUntilExit()
        let report = try fixture.report(output)
        let expectedLeases = [ResourceLease(resource: try ResourceName("fixture:work"), mode: .shared)]
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 0)
        #expect(report.exitCode == 0)
        #expect(report.state == .completed)
        #expect(report.resources == expectedLeases)
        #expect(try fixture.record(report).resourceLeases == expectedLeases)
        #expect(try String(contentsOfFile: report.standardOutputPath, encoding: .utf8) == "shared")
        #expect(try !fixture.available())
        owner.release()
        #expect(try fixture.available())
    }
}

private struct CLIFixture {
    let directory: URL
    var leaseHome: URL { directory.appendingPathComponent("leases") }
    var artifacts: URL { directory.appendingPathComponent("artifacts") }

    init() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        directory = temporary.resolvingSymlinksInPath()
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func process(arguments: [String], resourceOption: String = "--resource") -> Process {
        let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/agentbuild")
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "run", "--json", resourceOption, "fixture:work", "--lease-home", leaseHome.path,
            "--artifacts-root", artifacts.path, "--working-directory", directory.path,
            "--", "/bin/sh",
        ] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: ChildEnvironment.heldResourcesKey)
        process.environment = environment
        process.standardError = FileHandle.nullDevice
        return process
    }

    func stop(_ process: Process) {
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }

    func report(_ output: Pipe) throws -> ManagedExecutionReport {
        try JSONDecoder().decode(ManagedExecutionReport.self, from: output.fileHandleForReading.readDataToEndOfFile())
    }

    func record(_ report: ManagedExecutionReport) throws -> RunRecord {
        try JSONDecoder().decode(RunRecord.self, from: Data(contentsOf: leaseHome.appendingPathComponent("runs/\(report.runID).json")))
    }

    func hasAcquiringManifest() throws -> Bool {
        guard FileManager.default.fileExists(atPath: artifacts.path) else { return false }
        for session in try FileManager.default.contentsOfDirectory(at: artifacts, includingPropertiesForKeys: nil) {
            let manifest = session.appendingPathComponent("manifest.json")
            guard FileManager.default.fileExists(atPath: manifest.path) else { continue }
            let report = try JSONDecoder().decode(ManagedExecutionReport.self, from: Data(contentsOf: manifest))
            if report.state == .acquiring { return true }
        }
        return false
    }

    func lock(mode: LeaseMode = .exclusive) throws -> FileLock {
        try FileLock(resource: ResourceName("fixture:work"), mode: mode,
                     paths: AgentLeasePaths.open(selectedRoot: leaseHome.path))
    }

    func available() throws -> Bool {
        let probe = try lock()
        defer { probe.release() }
        return try probe.tryAcquire()
    }
}

private enum CLIFixtureError: Error { case deadline }

private func cliWaitUntil(_ condition: () throws -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while clock.now < deadline {
        if try condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw CLIFixtureError.deadline
}
