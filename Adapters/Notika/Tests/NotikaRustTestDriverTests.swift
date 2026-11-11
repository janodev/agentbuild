@testable import AgentBuildCore
import AgentBuildTestSupport
import AgentLeaseCore
import Darwin
import Foundation
@testable import NotikaAdapter
import Synchronization
import Testing

@Suite("Notika supervised Rust controller")
struct NotikaRustTestDriverTests {
    @Test(arguments: NotikaRustTestFamily.allCases)
    func realLicenseAndCargoCaptureRetainFiveOwnershipLayers(_ family: NotikaRustTestFamily) async throws {
        let fixture = try RustDriverFixture(family: family)
        defer { fixture.remove() }
        let seen = Mutex(0)
        let driver = fixture.driver(capture: { helper, command, descriptors, root, directory in
            #expect(descriptors.count == 5)
            #expect(descriptors.allSatisfy { fcntl($0, F_GETFD) >= 0 })
            #expect(try !fixture.available("notika:sessions:" + fixture.path))
            #expect(try !fixture.available(CacheCompatibilityIdentity.graphResourceName(canonicalWorktree: fixture.path)))
            #expect(try !fixture.available(fixture.identity.policyResource))
            #expect(try !fixture.available(fixture.identity.cacheResource()))
            #expect(try !fixture.compilationAvailable())
            #expect(command.workingDirectory == fixture.path)
            #expect(command.environment["RUSTFLAGS"] == nil)
            #expect(command.environment["NOTIKA_ROUTE_AUTHORITY_FD"] == nil)
            #expect(command.environment["CARGO_TARGET_DIR"] == fixture.cachePath + "/target")
            #expect(command.environment["CARGO_HOME"] == fixture.cachePath + "/cargo-home")
            #expect(command.environment["TMPDIR"] == root + "/tmp/")
            seen.withLock { $0 += 1 }
            return try await CapturedNativePhaseRunner().run(helperExecutable: helper, command: command,
                retainedLockDescriptors: descriptors, nativeWorkingDirectoryDescriptor: directory, artifactRoot: root)
        })
        let result = try await fixture.run(driver)
        #expect(result.exitCode == 0)
        #expect(result.status == "succeeded")
        #expect(result.nativeTermination == RunTermination(kind: .exit, value: 0))
        #expect(seen.withLock { $0 } == 2)
        let complete = result.rawCaptures.allSatisfy { $0.captureComplete }
        #expect(complete)
        let report = try #require(result.report)
        #expect(report.lifecycle == "terminal")
        #expect(report.nativeTermination == result.nativeTermination)
        let root = try StrictJSONDocument(data: report.originalData).root.requireObject()
        #expect(root.value(forKey: "request") == nil)
        let execution = try root.requiredValue(forKey: "execution").requireObject()
        let usage = try execution.requiredValue(forKey: "usage").requireObject()
        #expect(try controllerString(usage, "lastSessionID") == result.runID)
        #expect(try controllerString(usage, "cachePath") == fixture.cachePath)
        for name in ["in-progress.json", "manifest.json"] {
            var metadata = stat()
            #expect(lstat(result.sessionPath + "/" + name, &metadata) == 0)
            #expect(metadata.st_mode & 0o7777 == 0o400)
            #expect(metadata.st_nlink == 1)
        }
        #expect(try fixture.available("notika:sessions:" + fixture.path))
        #expect(try fixture.compilationAvailable())
        try rejectRustDriverForgery(report)
    }

    @Test func licenseFailurePreservesRawBytesAndCannotReachCargo() async throws {
        let fixture = try RustDriverFixture(family: .svg)
        defer { fixture.remove() }
        try fixture.script("Scripts/bridges/" + fixture.identity.licenseScript, #"printf '\000\377\200'; printf 'license failed' >&2; exit 31"#)
        let result = try await fixture.run(fixture.driver())
        #expect(result.exitCode == 31)
        #expect(result.status == "failed")
        #expect(result.nativeTermination == RunTermination(kind: .exit, value: 31))
        #expect(result.rawCaptures.count == 1)
        let capture = try #require(result.rawCaptures.first)
        #expect(try Data(contentsOf: URL(fileURLWithPath: capture.standardOutput.path)) == Data([0, 255, 128]))
        #expect(result.report?.nativeTermination == result.nativeTermination)
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "/cargo-ran"))
    }

    @Test func sourceDriftAndMaintenanceDiagnosticKeepNativeZeroIndependent() async throws {
        let fixture = try RustDriverFixture(family: .liteparse)
        defer { fixture.remove() }
        let observations = Mutex(0)
        let driver = fixture.driver(source: {
            let first = observations.withLock { let first = $0 == 0; $0 += 1; return first }
            return String(repeating: first ? "a" : "c", count: 64)
        }, maintenance: { repository, _, _, _ in
            #expect(repository == fixture.path)
            #expect(try fixture.available("notika:sessions:" + fixture.path))
            throw RustDriverFixture.Failure.expected
        })
        let result = try await fixture.run(driver)
        #expect(result.nativeTermination == RunTermination(kind: .exit, value: 0))
        #expect(result.exitCode == 70)
        #expect(result.status == "inconclusive")
        #expect(result.maintenanceFailures.count == 1)
        #expect(result.report?.nativeTermination == result.nativeTermination)
        #expect(result.report?.status == "inconclusive")
        let root = try #require(result.report).canonicalValue
        let parsed = try StrictJSONDocument(data: CanonicalJSONDigest.encode(root)).root.requireObject()
        #expect(parsed.value(forKey: "executionComplete") == .bool(false))
    }

    @Test func publicationMutationCannotAdvertisePassedRustExecution() async throws {
        let fixture = try RustDriverFixture(family: .svg)
        defer { fixture.remove() }
        let first = Mutex(true)
        let driver = fixture.driver(capture: { helper, command, descriptors, root, directory in
            let phase = try await CapturedNativePhaseRunner().run(helperExecutable: helper, command: command,
                retainedLockDescriptors: descriptors, nativeWorkingDirectoryDescriptor: directory, artifactRoot: root)
            if first.withLock({ let value = $0; $0 = false; return value }) {
                try Data("substituted".utf8).write(to: URL(fileURLWithPath: phase.rawCapture.standardOutput.path))
            }
            return phase
        })
        let result = try await fixture.run(driver)
        #expect(result.nativeTermination == RunTermination(kind: .exit, value: 0))
        #expect(result.exitCode == 70)
        #expect(!result.publicationFailures.isEmpty)
    }
}

private func rejectRustDriverForgery(_ report: NotikaRustTestSessionReport) throws {
    let object = try StrictJSONDocument(data: report.originalData).root.requireObject()
    for (key, value) in [("schemaVersion", CanonicalJSONValue.integer(2)), ("exitCode", .integer(99)),
                         ("family", .string("foreign")), ("cancelled", .bool(true)), ("executionComplete", .bool(false))] {
        let members = try object.members.map { member in
            let original = try controllerCanonical(member.value)
            return CanonicalJSONMember(key: member.key, value: member.key == key ? value : original)
        }
        #expect(throws: (any Error).self) {
            _ = try NotikaRustTestSessionReport(data: CanonicalJSONDigest.encode(.object(members)))
        }
    }
    let members = try object.members.map { CanonicalJSONMember(key: $0.key, value: try controllerCanonical($0.value)) } + [.init(key: "routeAuthority", value: .bool(true))]
    #expect(throws: (any Error).self) { _ = try NotikaRustTestSessionReport(data: CanonicalJSONDigest.encode(.object(members))) }
}

private struct RustDriverRepositoryCapture: RepositoryCommandCapturing {
    func capture(arguments: [String], workingDirectory: String, environment: [String: String]) async throws -> Data {
        guard arguments == ["git", "rev-parse", "--show-toplevel"] else { throw RustDriverFixture.Failure.expected }
        return Data((workingDirectory + "\n").utf8)
    }
}
private struct RustDriverFixture: Sendable {
    enum Failure: Error { case expected }
    let path: String
    let helper: String
    let identity: NotikaRustCacheIdentity
    var registry: String { path + "/registry" }
    var compilation: String { path + "/compile-registry" }
    var cachePath: String { path + "/DerivedData/RustTestCaches/" + (try! identity.cacheKey()) }
    var environment: [String: String] {
        ["PATH": path + "/tools:/usr/bin:/bin", "HOME": path, "AGENTLEASE_COMPILE_HOME": compilation,
         "RUSTFLAGS": "foreign", "NOTIKA_ROUTE_AUTHORITY_FD": "1234"]
    }
    init(family: NotikaRustTestFamily) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentbuild-rust-driver-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard let canonical = directory.path.withCString({ realpath($0, nil) }) else { throw Failure.expected }
        path = String(cString: canonical); free(canonical)
        let repository = AgentBuildTestPaths.packageRoot
        helper = repository.appendingPathComponent(".build/debug/agentbuild").path
        identity = try NotikaRustCacheIdentity(repository: path, family: family,
            inputs: Dictionary(uniqueKeysWithValues: NotikaRustCacheIdentity.inputPaths(family).map { ($0, String(repeating: "a", count: 64)) }),
            misePath: path + "/tools/mise", miseDigest: String(repeating: "b", count: 64),
            rustc: "rustc fixture", sysroot: "/fixture/sysroot", cargo: "cargo fixture")
        try script("Scripts/bridges/" + identity.licenseScript, "printf 'license ready'")
        try script("tools/mise", "printf 'cargo ready'; printf 'yes' > cargo-ran")
    }
    func driver(source: NotikaRustTestExecutor.SourceOperation? = nil, capture: NotikaRustTestDriver.CaptureOperation? = nil,
                maintenance: NotikaRustTestDriver.MaintenanceOperation? = nil) -> NotikaRustTestDriver {
        let identity = identity
        return NotikaRustTestDriver(repositoryCapture: RustDriverRepositoryCapture(), identityOperation: { identity },
            sourceOperation: source ?? { String(repeating: "a", count: 64) }, captureOperation: capture,
            maintenanceOperation: maintenance ?? { repository, registry, date, zone in
                try await NotikaArtifactMaintenance(canonicalRepository: repository, registryRoot: registry, evaluatedAt: date, timeZone: zone).run(execute: false)
            })
    }
    func run(_ driver: NotikaRustTestDriver) async throws -> NotikaRustTestDriverResult {
        try await driver.run(family: identity.family, repository: path, helperExecutable: helper, registryRoot: registry, environment: environment)
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
