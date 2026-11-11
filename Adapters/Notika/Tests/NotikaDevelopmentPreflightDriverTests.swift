@testable import AgentBuildCore
import AgentBuildTestSupport
import AgentLeaseCore
import Darwin
import Foundation
@testable import NotikaAdapter
import Testing

@Suite("Standalone Notika development preflight")
struct NotikaDevelopmentPreflightDriverTests {
    @Test func realHelperFailureRetainsWriterGraphKeyAndCompileUntilRetirement() async throws {
        let fixture = try StandalonePreflightFixture()
        defer { fixture.remove() }
        let driver = fixture.driver(capture: { helper, command, descriptors, root, directory in
            #expect(descriptors.count == 4)
            #expect(descriptors.allSatisfy { fcntl($0, F_GETFD) >= 0 })
            #expect(try !fixture.available("notika:sessions:" + fixture.path))
            #expect(try !fixture.available(CacheCompatibilityIdentity.graphResourceName(canonicalWorktree: fixture.path)))
            #expect(try !fixture.compilationAvailable())
            #expect(command.executable == fixture.path + "/Scripts/semantic-operation-adoption")
            #expect(command.arguments == ["check"])
            return try await CapturedNativePhaseRunner().run(helperExecutable: helper, command: command,
                retainedLockDescriptors: descriptors, nativeWorkingDirectoryDescriptor: directory, artifactRoot: root)
        })
        let result = try await fixture.run(driver)
        #expect(result.status == "failed")
        #expect(result.exitCode == 29)
        #expect(result.nativeTermination == RunTermination(kind: .exit, value: 29))
        #expect(result.rawCaptures.count == 1)
        let raw = try #require(result.rawCaptures.first)
        #expect(try Data(contentsOf: URL(fileURLWithPath: raw.standardOutput.path)) == Data([0, 255, 128]))
        let report = try #require(result.report)
        #expect(report.status == "failed")
        #expect(report.nativeTermination == result.nativeTermination)
        let root = try StrictJSONDocument(data: report.originalData).root.requireObject()
        #expect(root.value(forKey: "request") == nil)
        #expect(root.value(forKey: "executionComplete") == .bool(false))
        #expect(try fixture.compilationAvailable())
        #expect(try fixture.available("notika:sessions:" + fixture.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "/reached-promotions"))
        try rejectStandalonePreflightForgery(report)
    }

    @Test func exactSourceReceiptReusesGateWithNoInventedNativePhases() async throws {
        let fixture = try StandalonePreflightFixture()
        defer { fixture.remove() }
        // Receipt ownership/material admission is exercised through the real
        // core exact-key scope. Checked fixture outcomes isolate session reuse.
        let plan = try NotikaProjectOwnershipPlan(rustTestFor: fixture.path)
        try await NotikaProjectAdmission().withOwnership(plan, registryRoot: fixture.registry, label: "standalone reuse fixture") { ownership in
            _ = try await NotikaDevelopmentPreflight().run(repository: fixture.path, ownership: ownership, environment: fixture.environment,
                identityOperation: { try fixture.identity() }, commandOperation: { _, _ in standalonePreflightSuccess },
                rustOperation: { _, _ in standalonePreflightSuccess })
        }
        let result = try await fixture.run(fixture.driver(capture: { _, _, _, _, _ in
            Issue.record("reused receipt started a native workload")
            throw StandalonePreflightFixture.Failure.expected
        }))
        #expect(result.exitCode == 0)
        #expect(result.status == "succeeded")
        #expect(result.nativeTermination == nil)
        #expect(result.rawCaptures.isEmpty)
        let report = try #require(result.report)
        let root = try StrictJSONDocument(data: report.originalData).root.requireObject()
        let evidence = try root.requiredValue(forKey: "evidence").requireObject()
        #expect(try controllerString(evidence.requiredValue(forKey: "report").requireObject(), "status") == "reused")
        var metadata = stat()
        #expect(lstat(result.sessionPath + "/manifest.json", &metadata) == 0)
        #expect(metadata.st_mode & 0o7777 == 0o400)
        #expect(metadata.st_nlink == 1)
    }

    @Test func identitySetupFailureSealsDiagnosticWithoutFakeSourceOrNativeResult() async throws {
        let fixture = try StandalonePreflightFixture()
        defer { fixture.remove() }
        let driver = NotikaDevelopmentPreflightDriver(repositoryCapture: StandalonePreflightRepositoryCapture(),
            identityOperation: { throw StandalonePreflightFixture.Failure.expected },
            maintenanceOperation: fixture.maintenance)
        let result = try await fixture.run(driver)
        #expect(result.exitCode == 70)
        #expect(result.nativeTermination == nil)
        #expect(result.rawCaptures.isEmpty)
        let root = try StrictJSONDocument(data: #require(result.report).originalData).root.requireObject()
        #expect(root.value(forKey: "sourceBeforeSHA256") == .null)
        #expect(root.value(forKey: "executionComplete") == .bool(false))
        #expect(!result.publicationFailures.contains { $0.contains("invalidSchema") })
    }
}

private let standalonePreflightSuccess = NotikaPreflightCommandOutcome(nativeTermination: .init(kind: .exit, value: 0), retirementProven: true)
private func rejectStandalonePreflightForgery(_ report: NotikaPreflightSessionReport) throws {
    let object = try StrictJSONDocument(data: report.originalData).root.requireObject()
    for (key, value) in [("schemaVersion", CanonicalJSONValue.integer(2)), ("exitCode", .integer(0)),
                         ("sourceBeforeSHA256", .string(String(repeating: "c", count: 64))), ("executionComplete", .bool(true))] {
        let members = try object.members.map { member in
            let original = try controllerCanonical(member.value)
            return CanonicalJSONMember(key: member.key, value: member.key == key ? value : original)
        }
        #expect(throws: (any Error).self) { _ = try NotikaPreflightSessionReport(data: CanonicalJSONDigest.encode(.object(members))) }
    }
}
private struct StandalonePreflightRepositoryCapture: RepositoryCommandCapturing {
    func capture(arguments: [String], workingDirectory: String, environment: [String: String]) async throws -> Data {
        guard arguments == ["git", "rev-parse", "--show-toplevel"] else { throw StandalonePreflightFixture.Failure.expected }
        return Data((workingDirectory + "\n").utf8)
    }
}
private struct StandalonePreflightFixture: Sendable {
    enum Failure: Error { case expected }
    let path: String
    let helper: String
    var registry: String { path + "/registry" }
    var compilation: String { path + "/compile-registry" }
    var environment: [String: String] { ["PATH": path + "/tools:/usr/bin:/bin", "HOME": path, "AGENTLEASE_COMPILE_HOME": compilation] }
    var maintenance: NotikaRustTestDriver.MaintenanceOperation {
        { repository, registry, date, zone in
            try await NotikaArtifactMaintenance(canonicalRepository: repository, registryRoot: registry, evaluatedAt: date, timeZone: zone).run(execute: false)
        }
    }
    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentbuild-preflight-driver-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard let canonical = directory.path.withCString({ realpath($0, nil) }) else { throw Failure.expected }
        path = String(cString: canonical); free(canonical)
        let repository = AgentBuildTestPaths.packageRoot
        helper = repository.appendingPathComponent(".build/debug/agentbuild").path
        try script("Scripts/semantic-operation-adoption", #"printf '\000\377\200'; exit 29"#)
        try script("Scripts/agent-failure-diagnostics", "printf yes > reached-promotions")
        try script("tools/python3", "exit 0")
    }
    func identity() throws -> NotikaPreflightIdentity { try .init(sourceDigest: String(repeating: "a", count: 64), toolchainDigest: String(repeating: "b", count: 64)) }
    func driver(capture: NotikaDevelopmentPreflight.CapturedOperation? = nil) -> NotikaDevelopmentPreflightDriver {
        NotikaDevelopmentPreflightDriver(repositoryCapture: StandalonePreflightRepositoryCapture(), identityOperation: { try identity() },
            captureOperation: capture, maintenanceOperation: maintenance)
    }
    func run(_ driver: NotikaDevelopmentPreflightDriver) async throws -> NotikaPreflightDriverResult {
        try await driver.run(repository: path, helperExecutable: helper, registryRoot: registry, environment: environment)
    }
    func script(_ relative: String, _ body: String) throws {
        let file = URL(fileURLWithPath: path + "/" + relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(("#!/bin/sh\nset -eu\n" + body + "\n").utf8).write(to: file)
        guard chmod(file.path, 0o700) == 0 else { throw Failure.expected }
    }
    func available(_ resource: String) throws -> Bool {
        let lock = try FileLock(resource: ResourceName(resource), paths: AgentLeasePaths.open(selectedRoot: registry))
        defer { lock.release() }; return try lock.tryAcquire()
    }
    func compilationAvailable() throws -> Bool {
        let lock = try FileLock(resource: ResourceName(HostCompilationAdmission.resource), paths: AgentLeasePaths.open(selectedRoot: compilation))
        defer { lock.release() }; return try lock.tryAcquire()
    }
    func remove() { try? FileManager.default.removeItem(atPath: path) }
}
