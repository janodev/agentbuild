import AgentBuildTestSupport
import Darwin
import Foundation
import Testing

@Suite("External adapter process contracts")
struct AdapterDispatchTests {
    @Test func siblingReceivesLiteralArgumentsAndCallerIOEnvironmentAndDirectory() async throws {
        let fixture = try AdapterDispatchFixture()
        defer { fixture.remove() }
        try fixture.adapter(script: """
        printf '%s\\0' "$@"
        printf '%s\\0' "$ADAPTER_FIXTURE_TOKEN" "$PWD"
        /bin/cat
        printf 'adapter stderr\\n' >&2
        exit 37
        """)
        let arguments = ["--", "$(touch must-not-exist) `false` ; & | < >", "space ' quote \"", "", "--json"]
        let input = Data([0, 1, 2, 0xff, 10])
        let process = try fixture.process(arguments: ["example"] + arguments, input: input,
                                          environment: ["ADAPTER_FIXTURE_TOKEN": "caller value $()"])
        try process.run()
        defer { fixture.stop(process) }
        try await adapterWaitUntil { !process.isRunning }

        var expected = Data()
        for value in arguments + ["caller value $()", fixture.directory.path] {
            expected.append(contentsOf: value.utf8)
            expected.append(0)
        }
        expected.append(input)
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 37)
        let actual = try fixture.stdout()
        #expect(Array(actual) == Array(expected))
        #expect(try fixture.stderr() == "adapter stderr\n")
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("must-not-exist").path))
    }

    @Test func absoluteOverrideSelectsItsExactExecutable() async throws {
        let fixture = try AdapterDispatchFixture()
        defer { fixture.remove() }
        try fixture.adapter(script: "printf wrong-sibling; exit 99")
        let selected = try fixture.adapter(named: "reviewed adapter", script: "printf '%s|%s' \"$0\" \"$1\"")
        let process = try fixture.process(arguments: ["example", "literal argument"],
            environment: ["AGENTBUILD_ADAPTER_EXAMPLE_EXECUTABLE": selected.path])
        try process.run()
        defer { fixture.stop(process) }
        try await adapterWaitUntil { !process.isRunning }
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 0)
        #expect(try fixture.stdout() == Data("\(selected.path)|literal argument".utf8))
        #expect(try fixture.stderr().isEmpty)
    }

    @Test func execPreservesProcessIdentityAndNativeSignalTermination() async throws {
        let fixture = try AdapterDispatchFixture()
        defer { fixture.remove() }
        let marker = fixture.directory.appendingPathComponent("adapter.pid")
        try fixture.adapter(script: "printf '%s' \"$$\" > \"$1\"; exec /bin/sleep 30")
        let process = try fixture.process(arguments: ["example", marker.path])
        try process.run()
        defer { fixture.stop(process) }
        try await adapterWaitUntil { FileManager.default.fileExists(atPath: marker.path) }
        try await adapterWaitUntil { (try? Data(contentsOf: marker).isEmpty) == false }
        let adapterPID = try #require(Int32(try String(contentsOf: marker, encoding: .utf8)))
        #expect(adapterPID == process.processIdentifier)
        #expect(kill(process.processIdentifier, SIGTERM) == 0)
        try await adapterWaitUntil { !process.isRunning }
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGTERM)
        #expect(try fixture.stdout().isEmpty)
        #expect(try fixture.stderr().isEmpty)
    }

    @Test func execPreservesAnInheritedOpenDescriptor() async throws {
        let fixture = try AdapterDispatchFixture()
        defer { fixture.remove() }
        try fixture.adapter(script: "printf '%s' \"$1\" >&9")
        let receipt = fixture.directory.appendingPathComponent("inherited-descriptor")
        let process = try fixture.process(arguments: ["example", "descriptor survived $() --"])
        // Create the descriptor after Foundation's spawn boundary. The router
        // must preserve this caller-owned descriptor across its actual exec.
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exec 9>\"$1\"; shift; exec \"$@\"", "fixture", receipt.path,
                             fixture.router.path, "example", "descriptor survived $() --"]
        try process.run()
        defer { fixture.stop(process) }
        try await adapterWaitUntil { !process.isRunning }
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 0)
        #expect(try String(contentsOf: receipt, encoding: .utf8) == "descriptor survived $() --")
        #expect(try fixture.stderr().isEmpty)
    }

    @Test(arguments: AdapterDispatchFailure.allCases)
    func invalidAdapterTargetsFailWithoutStartingAnAdapter(_ failure: AdapterDispatchFailure) async throws {
        let fixture = try AdapterDispatchFixture()
        defer { fixture.remove() }
        let marker = fixture.directory.appendingPathComponent("started")
        let sibling = try fixture.adapter(script: "touch \"$1\"; exit 99")
        var environment: [String: String] = [:]
        var arguments = ["example", marker.path]
        switch failure {
        case .missing:
            try FileManager.default.removeItem(at: sibling)
        case .notExecutable:
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sibling.path)
        case .emptyOverride:
            environment["AGENTBUILD_ADAPTER_EXAMPLE_EXECUTABLE"] = ""
        case .relativeOverride:
            environment["AGENTBUILD_ADAPTER_EXAMPLE_EXECUTABLE"] = "agentbuild-example"
        case .directoryOverride:
            environment["AGENTBUILD_ADAPTER_EXAMPLE_EXECUTABLE"] = fixture.directory.path
        case .selfOverride:
            environment["AGENTBUILD_ADAPTER_EXAMPLE_EXECUTABLE"] = fixture.router.path
        case .hardLinkedSelf:
            try FileManager.default.removeItem(at: sibling)
            try FileManager.default.linkItem(at: fixture.router, to: sibling)
        case .invalidName:
            arguments[0] = "../example"
        }
        let process = try fixture.process(arguments: arguments, environment: environment)
        try process.run()
        defer { fixture.stop(process) }
        try await adapterWaitUntil { !process.isRunning }
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == failure.status)
        #expect(try fixture.stderr().contains(failure.diagnostic))
        #expect(try fixture.stdout().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}

enum AdapterDispatchFailure: CaseIterable, Sendable {
    case missing, notExecutable, emptyOverride, relativeOverride, directoryOverride, selfOverride, hardLinkedSelf, invalidName

    var status: Int32 {
        switch self {
        case .missing: 127
        case .notExecutable, .directoryOverride: 126
        case .emptyOverride, .relativeOverride, .selfOverride, .hardLinkedSelf, .invalidName: 64
        }
    }

    var diagnostic: String {
        switch self {
        case .missing: "is not installed"
        case .notExecutable, .directoryOverride: "must be an executable regular file"
        case .emptyOverride, .relativeOverride: "must be a nonempty absolute executable path"
        case .selfOverride, .hardLinkedSelf: "cannot refer to the agentbuild router itself"
        case .invalidName: "Invalid adapter name"
        }
    }
}

private struct AdapterDispatchFixture {
    let directory: URL
    var router: URL { directory.appendingPathComponent("agentbuild") }

    init() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        // Resolve only after creation: resolving a nonexistent leaf can retain
        // /var while the child shell reports its physical /private/var cwd.
        var canonical = [CChar](repeating: 0, count: Int(PATH_MAX))
        try #require(realpath(temporary.path, &canonical) != nil)
        let path = String(decoding: canonical.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        directory = URL(fileURLWithPath: path)
        do {
            try FileManager.default.copyItem(at: AgentBuildTestPaths.packageRoot.appendingPathComponent(".build/debug/agentbuild"),
                                             to: router)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    @discardableResult
    func adapter(named name: String = "agentbuild-example", script: String) throws -> URL {
        let executable = directory.appendingPathComponent(name)
        try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    func process(arguments: [String], input: Data = Data(), environment: [String: String] = [:]) throws -> Process {
        let inputURL = directory.appendingPathComponent("stdin")
        try input.write(to: inputURL)
        for name in ["stdout", "stderr"] {
            try Data().write(to: directory.appendingPathComponent(name))
        }
        let process = Process()
        process.executableURL = router
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var inherited = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("AGENTBUILD_ADAPTER_") }
        inherited.merge(environment) { _, value in value }
        process.environment = inherited
        process.standardInput = try FileHandle(forReadingFrom: inputURL)
        process.standardOutput = try FileHandle(forWritingTo: directory.appendingPathComponent("stdout"))
        process.standardError = try FileHandle(forWritingTo: directory.appendingPathComponent("stderr"))
        return process
    }

    func stdout() throws -> Data { try Data(contentsOf: directory.appendingPathComponent("stdout")) }
    func stderr() throws -> String { try String(contentsOf: directory.appendingPathComponent("stderr"), encoding: .utf8) }

    func stop(_ process: Process) {
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
            let deadline = ContinuousClock().now.advanced(by: .seconds(5))
            while process.isRunning, ContinuousClock().now < deadline { usleep(10_000) }
            #expect(!process.isRunning, "Adapter fixture must retire within five seconds.")
        }
        for handle in [process.standardInput, process.standardOutput, process.standardError] {
            try? (handle as? FileHandle)?.close()
        }
    }
}

private enum AdapterDispatchFixtureError: Error { case deadline }

private func adapterWaitUntil(_ condition: () throws -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while clock.now < deadline {
        if try condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw AdapterDispatchFixtureError.deadline
}
