import AgentBuildCore
import Darwin
import Foundation
import Testing

@Suite("Notika read-only planning CLI")
struct NotikaPlanningCLITests {
    @Test(arguments: [NotikaPlatform.macOS, .iPadSimulator])
    func observesInputsWithoutCreatingOwnershipOrExecutionArtifacts(_ platform: NotikaPlatform) async throws {
        let fixture = try PlanningCLIFixture()
        defer { fixture.remove() }
        try await fixture.initialize()
        var arguments = ["--repository", fixture.path, "--route", platform == .macOS ? "test-unit" : "test-unit-ios", "--json"]
        if platform == .iPadSimulator { arguments += ["--simulator-id", "PLAN-ONLY-123"] }
        let result = try await fixture.run(arguments)
        #expect(result.exitCode == 0)
        let report = try #require(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
        #expect(report["schemaVersion"] as? Int == 1)
        #expect(report["stage"] as? String == "unowned-planning")
        #expect(report["admissionEstablished"] as? Bool == false)
        #expect(report["observationsAreAtomic"] as? Bool == false)
        let source = try #require(report["sourceObservation"] as? [String: Any])
        #expect(source["canonicalWorktree"] as? String == fixture.path)
        #expect((source["digest"] as? String)?.count == 64)
        #expect((report["toolchainObservationDigest"] as? String)?.count == 64)
        let key = try #require(report["cacheStorageKey"] as? String)
        #expect(key.count == 24)
        #expect(report["cachePath"] as? String == fixture.path + "/DerivedData/AgentCaches/" + key)
        let phases = try #require(report["physicalPhases"] as? [[String: Any]])
        #expect(phases.count == 2)
        #expect(phases[0]["requiresCompilation"] as? Bool == true)
        #expect(phases[1]["requiresCompilation"] as? Bool == false)
        let runtime = try #require(phases[1]["arguments"] as? [String])
        #expect(runtime.contains(fixture.path + "/Artifacts/AgentSessions/plan-only/result.xcresult"))
        #expect(runtime.contains(platform == .macOS ? "platform=macOS,arch=arm64" : "platform=iOS Simulator,id=PLAN-ONLY-123"))
        let resources = try #require(report["requestedResources"] as? [[String: String]])
        #expect(resources.map { $0["mode"] } == ["shared", "shared", "exclusive"])
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "/Artifacts"))
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "/DerivedData"))
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "/.agentlease"))
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "/device-command-ran"))
    }

    @Test func invalidClosedRequestsFailBeforeRepositoryObservation() async throws {
        let fixture = try PlanningCLIFixture()
        defer { fixture.remove() }
        let missing = fixture.path + "/missing-worktree"
        let missingSimulator = try await fixture.run(["--repository", missing, "--route", "build-ios"])
        #expect(missingSimulator.exitCode != 0)
        #expect(String(decoding: missingSimulator.error, as: UTF8.self).contains("require --simulator-id"))
        let unknownRoute = try await fixture.run(["--repository", missing, "--route", "arbitrary-target"])
        #expect(unknownRoute.exitCode != 0)
        #expect(String(decoding: unknownRoute.error, as: UTF8.self).contains("Unknown Notika route"))
        let incompatible = try await fixture.run(["--repository", missing, "--route", "build-macos", "--platform", "ipad-simulator"])
        #expect(incompatible.exitCode != 0)
        #expect(String(decoding: incompatible.error, as: UTF8.self).contains("expectedPlatform"))
        #expect(!FileManager.default.fileExists(atPath: missing))
    }
}

private struct PlanningCLIResult {
    let exitCode: Int32
    let output: Data
    let error: Data
}

private struct PlanningCLIFixture {
    let path: String

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notika-plan-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        guard let resolved = root.path.withCString({ realpath($0, nil) }) else { throw PlanningCLIError.deadline }
        defer { free(resolved) }
        path = String(cString: resolved)
    }

    func remove() { try? FileManager.default.removeItem(atPath: path) }

    var environment: [String: String] {
        ["PATH": path + "/bin:/usr/bin:/bin", "HOME": path,
         "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
    }

    func initialize() async throws {
        for arguments in [["init", "-q"], ["config", "user.email", "plan-fixture@example.invalid"],
                          ["config", "user.name", "Plan Fixture"]] {
            _ = try await RepositoryCommandCapture().capture(arguments: ["/usr/bin/git"] + arguments,
                                                              workingDirectory: path, environment: environment)
        }
        try write("Project.swift", "fixture project graph\n")
        for (name, value) in [("xcodebuild", "Xcode fixture"), ("swift", "Swift fixture"), ("xcrun", "27.0")] {
            try write("bin/" + name, "#!/bin/sh\nprintf '%s\\n' '\(value)'\n", executable: true)
        }
        try write("Scripts/tuist", "#!/bin/sh\nprintf '%s\\n' '4.210.0'\n", executable: true)
        // Planning may hash these executables but must never operate a device.
        for name in ["simlease", "simslim", "sim-use"] {
            try write("bin/" + name, "#!/bin/sh\ntouch '\(path)/device-command-ran'\nexit 99\n", executable: true)
        }
        _ = try await RepositoryCommandCapture().capture(arguments: ["/usr/bin/git", "add", "."],
                                                          workingDirectory: path, environment: environment)
        _ = try await RepositoryCommandCapture().capture(arguments: ["/usr/bin/git", "commit", "-qm", "planning fixture"],
                                                          workingDirectory: path, environment: environment)
    }

    private func write(_ relative: String, _ contents: String, executable: Bool = false) throws {
        let url = URL(fileURLWithPath: path + "/" + relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }

    func run(_ arguments: [String]) async throws -> PlanningCLIResult {
        let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/agentbuild")
        let process = Process()
        process.executableURL = executable
        process.arguments = ["notika", "plan"] + arguments
        process.environment = environment
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        defer {
            if process.isRunning {
                let result = kill(process.processIdentifier, SIGKILL), error = errno
                #expect(result == 0 || error == ESRCH)
                let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(5))
                var retired = false
                while clock.now < deadline {
                    if !process.isRunning && kill(process.processIdentifier, 0) < 0 && errno == ESRCH { retired = true; break }
                    usleep(10_000)
                }
                #expect(retired, "Planning CLI fixture retirement must be observed within five seconds.")
            }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        var retired = false
        while clock.now < deadline {
            if !process.isRunning && kill(process.processIdentifier, 0) < 0 && errno == ESRCH { retired = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard retired else { throw PlanningCLIError.deadline }
        try #require(process.terminationReason == .exit)
        return PlanningCLIResult(exitCode: process.terminationStatus,
                                 output: output.fileHandleForReading.readDataToEndOfFile(),
                                 error: error.fileHandleForReading.readDataToEndOfFile())
    }
}

private enum PlanningCLIError: Error { case deadline }
