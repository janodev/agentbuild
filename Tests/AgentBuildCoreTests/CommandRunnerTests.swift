import AgentBuildCore
import Foundation
import Testing

@Test func argumentsRemainLiteralAndStreamsRemainSeparate() async throws {
    let result = try await CommandRunner().run(
        executable: "/bin/sh",
        arguments: ["-c", "printf '%s' \"$1\"; printf 'diagnostic' >&2; exit 7", "fixture", "$(false) space ' quote"]
    )
    #expect(result.standardOutput == "$(false) space ' quote")
    #expect(result.standardError == "diagnostic")
    #expect(result.termination == .exited(7))
}

@Test func commandUsesRequestedWorkingDirectory() async throws {
    let result = try await CommandRunner().run(
        executable: "/bin/pwd", workingDirectory: "/private/tmp"
    )
    #expect(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "/private/tmp")
}

@Test func capturedOutputHasAByteBound() async {
    await #expect(throws: (any Error).self) {
        _ = try await CommandRunner(outputLimit: 8).run(
            executable: "/usr/bin/printf", arguments: ["%s", String(repeating: "x", count: 64)]
        )
    }
}

@Test func timeoutStopsTheCommandAndItsDescendants() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("descendant-ran")
    let ready = directory.appendingPathComponent("ready")
    await #expect(throws: CommandRunnerError.timedOut) {
        _ = try await CommandRunner().run(
            executable: "/bin/sh",
            arguments: [
                "-c", "(sleep 0.2; printf leaked > \"$1\") & printf ready > \"$2\"; wait",
                "fixture", marker.path, ready.path,
            ],
            timeout: .milliseconds(100)
        )
    }
    #expect(FileManager.default.fileExists(atPath: ready.path))
    try await Task.sleep(for: .milliseconds(300))
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}

@Test func emptyPathComponentFindsToolsInTheCurrentDirectory() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for name in ["swift", "xcodebuild", "agentlease"] {
        let path = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\nprintf 'fixture-version'\n".utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }
    let report = await ToolchainDoctor(searchPath: "", currentDirectory: directory.path).inspect()
    #expect(report.ready)
    #expect(report.tools.filter(\.required).allSatisfy { $0.version == "fixture-version" })
}

@Test func missingRequiredToolsAreReportedAndJSONRoundTrips() async throws {
    let report = await ToolchainDoctor(searchPath: "").inspect()
    #expect(!report.ready)
    #expect(report.tools.filter(\.required).count == 3)
    #expect(report.tools.allSatisfy { $0.status == .missing })
    let bytes = try JSONEncoder().encode(report)
    #expect(try JSONDecoder().decode(DoctorReport.self, from: bytes) == report)
}
