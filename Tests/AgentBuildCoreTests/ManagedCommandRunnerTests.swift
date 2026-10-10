import AgentBuildCore
import AgentLeaseCore
import Darwin
import Foundation
import Testing

@Suite("Managed execution")
struct ManagedCommandRunnerTests {
    @Test func rawBinaryLogsPreserveWorkingDirectoryArgumentsAndExit() async throws {
        let fixture = try ExecutionFixture()
        defer { fixture.remove() }
        let bytes = Data((0..<524_288).map { UInt8(truncatingIfNeeded: $0) })
        let input = fixture.directory.appendingPathComponent("input")
        try bytes.write(to: input)
        let literal = "$(false) space ' quote"
        let report = try await ManagedCommandRunner().run(fixture.command(arguments: [
            "-c", "/bin/cat \"$1\"; printf '%s\\n' \"$2\" >&2; /bin/pwd -P >&2; exit 23",
            "fixture", input.path, literal,
        ]))
        #expect(report.state == .completed)
        #expect(report.termination == RunTermination(kind: .exit, value: 23))
        #expect(report.exitCode == 23)
        #expect(report.standardOutputBytes == bytes.count)
        #expect(try Data(contentsOf: URL(fileURLWithPath: report.standardOutputPath)) == bytes)
        let errorText = try String(contentsOfFile: report.standardErrorPath, encoding: .utf8)
        let expectedError = "\(literal)\n\(fixture.directory.path)\n"
        #expect(errorText == expectedError)
        let manifest = URL(fileURLWithPath: report.standardOutputPath).deletingLastPathComponent().appendingPathComponent("manifest.json")
        #expect(try JSONDecoder().decode(ManagedExecutionReport.self, from: Data(contentsOf: manifest)) == report)
        let recordPath = fixture.leaseHome.appendingPathComponent("runs/\(report.runID).json")
        let record = try JSONDecoder().decode(RunRecord.self, from: Data(contentsOf: recordPath))
        #expect(record.state == .exited)
        #expect(record.arguments == nil)
        #expect(record.termination == report.termination)
        try await waitUntil { try fixture.available() }
    }

    @Test func signalAndLaunchFailureStayDistinct() async throws {
        let fixture = try ExecutionFixture()
        defer { fixture.remove() }
        let signaled = try await ManagedCommandRunner().run(fixture.command(arguments: ["-c", "kill -TERM $$"]))
        #expect(signaled.termination == RunTermination(kind: .signal, value: SIGTERM))
        #expect(signaled.exitCode == 143)
        let missing = try await ManagedCommandRunner().run(fixture.command(executable: fixture.directory.appendingPathComponent("missing").path))
        #expect(missing.state == .failed)
        #expect(missing.childPID == nil)
        #expect(missing.termination == nil)
        #expect(missing.failure?.kind == .executableNotFound)
        #expect(missing.exitCode == 127)
        try await waitUntil { try fixture.available() }
    }

    @Test func aMissingWorkingDirectoryIsADriverFailureRatherThanAMissingExecutable() async throws {
        let fixture = try ExecutionFixture()
        defer { fixture.remove() }
        let command = try ManagedCommand(
            executable: "/bin/pwd", workingDirectory: fixture.directory.appendingPathComponent("missing").path,
            artifactsRoot: fixture.artifacts.path, exclusiveResources: ["fixture:work"],
            leaseHome: fixture.leaseHome.path
        )
        let report = try await ManagedCommandRunner().run(command)
        #expect(report.state == .failed)
        #expect(report.childPID == nil)
        #expect(report.failure?.kind == .spawn)
        #expect(report.exitCode == 70)
        #expect(report.termination == nil)
        try await waitUntil { try fixture.available() }
    }

    @Test func cancellationDuringAcquisitionReleasesPartialOwnershipWithoutLaunching() async throws {
        let fixture = try ExecutionFixture()
        defer { fixture.remove() }
        let owner = try fixture.lock("fixture:zeta")
        #expect(try owner.tryAcquire())
        defer { owner.release() }
        let marker = fixture.directory.appendingPathComponent("launched")
        let command = try fixture.command(arguments: ["-c", "touch \"$1\"", "fixture", marker.path],
                                          resources: ["fixture:alpha", "fixture:zeta"])
        let task = Task { try await ManagedCommandRunner().run(command) }
        defer { task.cancel() }
        try await waitUntil { try !fixture.available("fixture:alpha") }
        task.cancel()
        let report = try await task.value
        #expect(report.state == .cancelled)
        #expect(report.childPID == nil)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        // Concurrent prefork diagnostic probes can briefly inherit a CLOEXEC
        // descriptor until exec; wait for those transient references to close.
        try await waitUntil { try fixture.available("fixture:alpha") }
        #expect(try !fixture.available("fixture:zeta"))
    }

    @Test func acquisitionTimeoutDoesNotPretendTheCommandFailed() async throws {
        let fixture = try ExecutionFixture()
        defer { fixture.remove() }
        let owner = try fixture.lock()
        #expect(try owner.tryAcquire())
        defer { owner.release() }
        let report = try await ManagedCommandRunner().run(fixture.command(waitSeconds: 0.05))
        #expect(report.state == .failed)
        #expect(report.childPID == nil)
        #expect(report.termination == nil)
        #expect(report.failure?.kind == .acquisitionTimeout)
        #expect(report.exitCode == 75)
    }

    @Test func anExpiredPositiveDeadlineCannotBecomeImmediateAdmission() async throws {
        let fixture = try ExecutionFixture()
        defer { fixture.remove() }
        let marker = fixture.directory.appendingPathComponent("launched")
        let report = try await ManagedCommandRunner().run(fixture.command(
            arguments: ["-c", "touch \"$1\"", "fixture", marker.path], waitSeconds: Double.leastNonzeroMagnitude
        ))
        #expect(report.failure?.kind == .acquisitionTimeout)
        #expect(report.childPID == nil)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        try await waitUntil { try fixture.available() }
    }

    @Test func cancellationReapsTheChildAndStopsAnIgnoringDescendantBeforeRelease() async throws {
        let fixture = try ExecutionFixture()
        defer { fixture.remove() }
        let marker = fixture.directory.appendingPathComponent("descendant.pid")
        let command = try fixture.command(arguments: [
            "-c", "trap '' INT TERM; (trap '' INT TERM; exec /bin/sleep 30) & printf '%s' \"$!\" > \"$1\"; wait",
            "fixture", marker.path,
        ])
        let task = Task { try await ManagedCommandRunner().run(command) }
        defer { task.cancel() }
        try await waitUntil { FileManager.default.fileExists(atPath: marker.path) }
        let descendant = try processID(in: marker)
        defer { _ = kill(descendant, SIGKILL) }
        #expect(try !fixture.available())
        task.cancel()
        let report = try await task.value
        let child = try #require(report.childPID)
        #expect(report.state == .cancelled)
        #expect(report.termination == nil)
        #expect(kill(child, 0) == -1 && errno == ESRCH)
        try await waitUntil { kill(descendant, 0) == -1 && errno == ESRCH }
        try await waitUntil { try fixture.available() }
    }

    @Test func callbackFailureDoesNotReleaseBeforeChildReaping() async throws {
        let fixture = try ExecutionFixture()
        defer { fixture.remove() }
        let report = try await ManagedCommandRunner().run(
            fixture.command(executable: "/bin/sleep", arguments: ["30"]),
            onStart: { _ in throw FixtureError.injected }
        )
        let child = try #require(report.childPID)
        #expect(report.state == .failed)
        #expect(report.failure?.kind == .internal)
        #expect(kill(child, 0) == -1 && errno == ESRCH)
        try await waitUntil { try fixture.available() }
    }

    @Test func failedFinalPublicationRetainsTheObservedNativeStatus() async throws {
        let fixture = try ExecutionFixture()
        defer { fixture.remove() }
        do {
            _ = try await ManagedCommandRunner().run(fixture.command(arguments: ["-c", "sleep 0.05; exit 19"]), onStart: { _ in
                let session = try #require(FileManager.default.contentsOfDirectory(at: fixture.artifacts, includingPropertiesForKeys: nil).first)
                let manifest = session.appendingPathComponent("manifest.json")
                try FileManager.default.removeItem(at: manifest)
                try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
            })
            Issue.record("Publication should fail when its destination becomes a directory")
        } catch ManagedExecutionError.evidencePublication(let report, _) {
            #expect(report.termination == RunTermination(kind: .exit, value: 19))
            #expect(report.exitCode == 19)
            #expect(report.state == .completed)
        }
        try await waitUntil { try fixture.available() }
    }

    @Test func callbackPublicationErrorsFinalizeThisRunRatherThanTrustingAnotherReport() async throws {
        let fixture = try ExecutionFixture()
        defer { fixture.remove() }
        let previous = try await ManagedCommandRunner().run(fixture.command(arguments: ["-c", "exit 17"]))
        let report = try await ManagedCommandRunner().run(
            fixture.command(executable: "/bin/sleep", arguments: ["30"]),
            onStart: { _ in throw ManagedExecutionError.evidencePublication(report: previous, detail: "callback fixture") }
        )
        #expect(report.runID != previous.runID)
        #expect(report.state == .failed)
        #expect(report.termination == nil)
        #expect(report.failure?.kind == .recordPublication)
        let child = try #require(report.childPID)
        #expect(kill(child, 0) == -1 && errno == ESRCH)
        let record = try JSONDecoder().decode(RunRecord.self, from: Data(contentsOf: fixture.leaseHome.appendingPathComponent("runs/\(report.runID).json")))
        #expect(record.state == .failed)
        try await waitUntil { try fixture.available() }
    }

    @Test func descendantOwnershipOutlivesACompletedCoordinator() async throws {
        let fixture = try ExecutionFixture()
        defer { fixture.remove() }
        let marker = fixture.directory.appendingPathComponent("descendant.pid")
        let report = try await ManagedCommandRunner().run(fixture.command(arguments: [
            "-c", "/bin/sleep 30 & printf '%s' \"$!\" > \"$1\"; exit 0", "fixture", marker.path,
        ]))
        let descendant = try processID(in: marker)
        defer { _ = kill(descendant, SIGKILL) }
        #expect(report.exitCode == 0)
        #expect(try !fixture.available())
        #expect(kill(descendant, SIGKILL) == 0)
        try await waitUntil { try fixture.available() }
    }

    @Test func killingTheCLILeavesTheChildHoldingItsLease() async throws {
        let fixture = try ExecutionFixture()
        defer { fixture.remove() }
        let marker = fixture.directory.appendingPathComponent("child.pid")
        let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/agentbuild")
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "run", "--resource", "fixture:work", "--lease-home", fixture.leaseHome.path,
            "--artifacts-root", fixture.artifacts.path, "--working-directory", fixture.directory.path,
            "--", "/bin/sh", "-c", "printf '%s' \"$$\" > \"$1\"; exec /bin/sleep 30", "fixture", marker.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: ChildEnvironment.heldResourcesKey)
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { fixture.stop(process) }
        try await waitUntil { FileManager.default.fileExists(atPath: marker.path) }
        let child = try processID(in: marker)
        defer { _ = kill(child, SIGKILL) }
        #expect(kill(process.processIdentifier, SIGKILL) == 0)
        try await waitUntil { !process.isRunning && kill(process.processIdentifier, 0) < 0 && errno == ESRCH }
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGKILL)
        #expect(kill(child, 0) == 0)
        #expect(try !fixture.available())
        #expect(kill(child, SIGKILL) == 0)
        try await waitUntil { try fixture.available() }
    }

    @Test func inheritedLeaseMarkersCannotCauseAnAccidentalNestedAcquisition() async throws {
        let fixture = try ExecutionFixture()
        defer { fixture.remove() }
        let command = try fixture.command()
        await #expect(throws: ManagedExecutionError.self) {
            try await ManagedCommandRunner().run(command, environment: [ChildEnvironment.heldResourcesKey: "fixture:work"])
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.artifacts.path))
    }
}

private enum FixtureError: Error { case injected; case deadline; case invalidPID; case invalidPath }

private struct ExecutionFixture: Sendable {
    let directory: URL
    var leaseHome: URL { directory.appendingPathComponent("leases") }
    var artifacts: URL { directory.appendingPathComponent("artifacts") }

    init() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        guard let physicalPath = realpath(temporary.path, nil) else { throw FixtureError.invalidPath }
        defer { free(physicalPath) }
        directory = URL(fileURLWithPath: String(cString: physicalPath))
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

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
        #expect(retired, "Managed CLI fixture retirement must be observed within five seconds.")
    }

    func command(
        executable: String = "/bin/sh", arguments: [String] = ["-c", "exit 0"],
        resources: [String] = ["fixture:work"], waitSeconds: Double? = nil
    ) throws -> ManagedCommand {
        try ManagedCommand(executable: executable, arguments: arguments, workingDirectory: directory.path,
                           artifactsRoot: artifacts.path, exclusiveResources: resources,
                           leaseHome: leaseHome.path, waitSeconds: waitSeconds)
    }

    func lock(_ resource: String = "fixture:work") throws -> FileLock {
        try FileLock(resource: ResourceName(resource), paths: AgentLeasePaths.open(selectedRoot: leaseHome.path))
    }

    func available(_ resource: String = "fixture:work") throws -> Bool {
        let probe = try lock(resource)
        defer { probe.release() }
        return try probe.tryAcquire()
    }
}

private func processID(in url: URL) throws -> Int32 {
    guard let value = Int32(try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)), value > 1 else {
        throw FixtureError.invalidPID
    }
    return value
}

private func waitUntil(_ condition: () throws -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while clock.now < deadline {
        if try condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw FixtureError.deadline
}
