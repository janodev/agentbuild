@testable import AgentBuildCore
import AgentBuildTestSupport
import AgentLeaseCore
import Darwin
import Foundation
@testable import NotikaAdapter
import Synchronization
import Testing

@Suite("Notika native Rust tests")
struct NotikaRustTestExecutorTests {
    @Test(arguments: NotikaRustTestFamily.allCases)
    func materialMatchesStaticPythonOracle(_ family: NotikaRustTestFamily) throws {
        let identity = try rustFixtureIdentity(repository: "/fixture/Notika", family: family)
        let expected = family == .liteparse ? "dd2eb231469ec481190f8bb7a704dc1a927a6cb8cffb4798774651724348f6b9" : "dce47c07bea05c4ed84f88006c5ea6868c0da557dfe2a3cb9329425eaba7b16b"
        // Reference rust_compatibility_material + canonical Python SHA-256.
        #expect(try identity.digest() == expected)
        #expect(try identity.cacheKey() == String(expected.prefix(24)))
        let worktree = "daeda70d9a1e23b0262341499b4c84cd22a1ce6118610cc0bed4a2b8d1960279"
        #expect(identity.policyResource == "notika:rust-test-cache-policy:" + worktree)
        #expect(try identity.cacheResource() == "notika:rust-test-cache:" + worktree + ":" + String(expected.prefix(24)))
        #expect(identity.pins == (family == .liteparse ? ["rust@1.88.0"] : []))
    }

    @Test func rustEnvironmentUsesItsExactNarrowReferenceAllowlist() throws {
        let expected = ["AGENTLEASE_HOME": "/local", "HOME": "/account", "LANG": "", "LC_ALL": "C", "LC_CTYPE": "C",
                        "LOGNAME": "user", "PATH": "/tools", "TERM": "dumb", "USER": "user", "__CF_USER_TEXT_ENCODING": "fixture"]
        #expect(try NotikaRustTestExecutor.environment(from: expected.merging([
            "AGENTLEASE_COMPILE_HOME": "/account/compile", "CARGO_HOME": "/foreign/cargo", "CARGO_TARGET_DIR": "/foreign/target",
            "TMPDIR": "/foreign/tmp", "RUSTFLAGS": "-foreign", "NOTIKA_ROUTE_AUTHORITY_FD": "99", "unknown": "bad\0value",
        ]) { _, new in new }) == expected)
    }

    @Test func usagePreservesExactMicrosecondOrderingAndNormalizesPriorOffsetTime() throws {
        let identity = try rustFixtureIdentity(repository: "/fixture/Notika", family: .liteparse)
        let observation = try NotikaRustCacheObservation(identity: identity, deviceID: 1, inode: 7, ownerUID: geteuid())
        let record = try NotikaRustCacheUsageRecord.make(identity: identity, observation: observation, sessionID: "fixture",
                                                       usedAt: Date(timeIntervalSince1970: 1_700_000_010), createdAt: "2023-11-15T00:13:20+02:00")
        #expect(record.createdAt == "2023-11-14T22:13:20Z")
        let text = try #require(String(data: record.document.originalData, encoding: .utf8))
        let inverted = text.replacingOccurrences(of: "2023-11-14T22:13:20Z", with: "2023-11-14T22:13:30.000002Z")
            .replacingOccurrences(of: "2023-11-14T22:13:30Z", with: "2023-11-14T22:13:30.000001Z")
        #expect(throws: NotikaRustTestError.unsafeMetadata) {
            try NotikaRustCacheUsageRecord(data: Data(inverted.utf8), identity: identity, observation: observation)
        }
    }

    @Test func usageFromAnEarlierBootIsAdmittedOnlyByItsInodeAfterRenumbering() throws {
        let identity = try rustFixtureIdentity(repository: "/fixture/Notika", family: .liteparse)
        let original = try NotikaRustCacheObservation(identity: identity, deviceID: 1, inode: 7, ownerUID: geteuid())
        let record = try NotikaRustCacheUsageRecord.make(identity: identity, observation: original, sessionID: "fixture",
                                                       usedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let renumbered = try NotikaRustCacheObservation(identity: identity, deviceID: 2, inode: 7, ownerUID: geteuid())
        let afterLastUse = DirectoryIdentityBoot(bootedAtMicrosecondsSince1970: 1_700_000_000_000_001)
        let atLastUse = DirectoryIdentityBoot(bootedAtMicrosecondsSince1970: 1_700_000_000_000_000)
        let admitted = try NotikaRustCacheUsageRecord(data: record.document.originalData, identity: identity,
                                                      observation: renumbered, boot: afterLastUse)
        #expect(admitted == record)
        #expect(throws: NotikaRustTestError.unsafeMetadata) {
            try NotikaRustCacheUsageRecord(data: record.document.originalData, identity: identity, observation: renumbered, boot: atLastUse)
        }
        #expect(throws: NotikaRustTestError.unsafeMetadata) {
            try NotikaRustCacheUsageRecord(data: record.document.originalData, identity: identity, observation: renumbered)
        }
        let moved = try NotikaRustCacheObservation(identity: identity, deviceID: 2, inode: 8, ownerUID: geteuid())
        #expect(throws: NotikaRustTestError.unsafeMetadata) {
            try NotikaRustCacheUsageRecord(data: record.document.originalData, identity: identity, observation: moved, boot: afterLastUse)
        }
    }

    @Test func usageRoundTripsJSONIntegersWithoutWeakeningSchemaAdmission() throws {
        let identity = try rustFixtureIdentity(repository: "/fixture/Notika", family: .liteparse)
        let observation = try NotikaRustCacheObservation(identity: identity, deviceID: 1, inode: 7, ownerUID: geteuid())
        let record = try NotikaRustCacheUsageRecord.make(identity: identity, observation: observation,
            sessionID: "fixture", usedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let admitted = try NotikaRustCacheUsageRecord(data: record.document.originalData, identity: identity, observation: observation)
        #expect(admitted == record)
        let object = try record.document.root.requireObject()
        #expect(object.members.count == 17)
        guard case .number(let schema) = try object.requiredValue(forKey: "schemaVersion") else {
            Issue.record("usage schema must retain an integer token")
            return
        }
        #expect(try schema.int64() == 1)
        let text = try #require(String(data: record.document.originalData, encoding: .utf8))
        for token in ["true", "1.0", "2"] {
            let altered = text.replacingOccurrences(of: #""schemaVersion":1"#, with: #""schemaVersion":"# + token)
            #expect(throws: (any Error).self) {
                _ = try NotikaRustCacheUsageRecord(data: Data(altered.utf8), identity: identity, observation: observation)
            }
        }
        let unknown = Data((#"{"unknown":true,"# + text.dropFirst()).utf8)
        #expect(throws: NotikaRustTestError.unsafeMetadata) {
            _ = try NotikaRustCacheUsageRecord(data: unknown, identity: identity, observation: observation)
        }
    }

    @Test(arguments: NotikaRustTestFamily.allCases)
    func observesFiveInputsCanonicalMiseBytesAndExactPinnedProbes(_ family: NotikaRustTestFamily) async throws {
        let fixture = try RustFixture(family: family)
        defer { fixture.remove() }
        let identity = try await NotikaRustTestExecutor.observeIdentity(repository: fixture.path, family: family,
                                                                        environment: fixture.environment, capture: RustProbeCapture(family: family))
        #expect(identity.misePath == fixture.path + "/tools/mise")
        #expect(identity.miseDigest == CanonicalJSONDigest.digest(Data("#!/bin/sh\nexit 0\n".utf8)))
        #expect(Set(identity.inputs.keys) == Set(NotikaRustCacheIdentity.inputPaths(family)))
        #expect(identity.inputs.values.allSatisfy { $0 == CanonicalJSONDigest.digest(Data("input".utf8)) })
        try FileManager.default.removeItem(atPath: fixture.path + "/Rust/" + identity.crate + "/Cargo.lock")
        try FileManager.default.createSymbolicLink(atPath: fixture.path + "/Rust/" + identity.crate + "/Cargo.lock", withDestinationPath: fixture.path + "/.mise.toml")
        await #expect(throws: NotikaRustTestError.unsafePath(fixture.path + "/Rust/" + identity.crate + "/Cargo.lock")) {
            try await NotikaRustTestExecutor.observeIdentity(repository: fixture.path, family: family, environment: fixture.environment,
                                                           capture: RustProbeCapture(family: family))
        }
    }

    @Test func invalidUTF8OrEmptyPinnedToolIdentityFailsRatherThanHashingReplacement() async throws {
        let fixture = try RustFixture()
        defer { fixture.remove() }
        await #expect(throws: NotikaRustTestError.invalidToolOutput) {
            try await NotikaRustTestExecutor.observeIdentity(repository: fixture.path, family: .liteparse, environment: fixture.environment,
                                                           capture: RustInvalidProbeCapture())
        }
    }

    @Test(arguments: NotikaRustTestFamily.allCases)
    func licenseThenLockedCargoUseIsolatedCacheUnderOrderedLiveLeases(_ family: NotikaRustTestFamily) async throws {
        let fixture = try RustFixture(family: family)
        defer { fixture.remove() }
        let calls = Mutex<[DarwinWorkloadCommand]>([])
        try await fixture.withContext { context in
            let report = try await NotikaRustTestExecutor().run(
                family: family, context: context, bindings: fixture.bindings,
                identityOperation: { fixture.identity }, sourceOperation: { String(repeating: "c", count: 64) },
                commandOperation: { command, descriptors in
                    #expect(descriptors.count == 6)
                    #expect(descriptors.allSatisfy { fcntl($0, F_GETFD) >= 0 })
                    do {
                        let compilationAvailable = try fixture.compilation.available()
                        let policyExclusiveAvailable = try fixture.available(fixture.identity.policyResource)
                        let policySharedAvailable = try fixture.available(fixture.identity.policyResource, mode: .shared)
                        let cacheAvailable = try fixture.available(fixture.identity.cacheResource())
                        #expect(!compilationAvailable)
                        #expect(!policyExclusiveAvailable)
                        #expect(policySharedAvailable)
                        #expect(!cacheAvailable)
                    } catch { Issue.record(error) }
                    #expect(command.environment["CARGO_HOME"] == fixture.cachePath + "/cargo-home")
                    #expect(command.environment["CARGO_TARGET_DIR"] == fixture.cachePath + "/target")
                    #expect(command.environment["TMPDIR"] == fixture.bindings.temporaryDirectory + "/")
                    #expect(command.environment["RUSTFLAGS"] == nil)
                    #expect(command.environment["AGENTLEASE_COMPILE_HOME"] == nil)
                    calls.withLock { $0.append(command) }
                    return rustSuccess
                }, usedAt: Date(timeIntervalSince1970: 1_700_000_000))
            #expect(report.outcome.succeeded)
            #expect(report.commands.count == 2)
            #expect(report.commands[0].executable == fixture.path + "/Scripts/bridges/" + fixture.identity.licenseScript)
            #expect(report.commands[0].arguments == ["check"])
            #expect(report.commands[1].executable == fixture.identity.misePath)
            #expect(report.commands[1].arguments == ["exec"] + fixture.identity.pins + ["--", "cargo", "test", "--locked", "--manifest-path", "Rust/" + fixture.identity.crate + "/Cargo.toml"])
            let usage = try #require(report.usage)
            #expect(usage.createdAt == "2023-11-14T22:13:20Z")
            #expect(usage.lastSessionID == fixture.bindings.sessionID)
            let object = try usage.document.root.requireObject()
            #expect(try object.requiredValue(forKey: "resourceID") == .string("notika.rust-test-cache-usage"))
            #expect(object.value(forKey: "storageIdentitySHA256") == nil)
            #expect(object.members.count == 17)
            #expect(try fixture.available(fixture.identity.policyResource))
            #expect(try fixture.available(fixture.identity.cacheResource()))
            #expect(try fixture.compilation.available())
            let again = try await NotikaRustTestExecutor().run(
                family: family, context: context, bindings: fixture.bindings, identityOperation: { fixture.identity },
                sourceOperation: { String(repeating: "c", count: 64) }, commandOperation: { _, _ in rustSuccess },
                usedAt: Date(timeIntervalSince1970: 1_700_000_010))
            #expect(again.usage?.createdAt == usage.createdAt)
            #expect(again.usage?.lastUsedAt == "2023-11-14T22:13:30Z")
        }
        #expect(calls.withLock { $0.count } == 2)
    }

    @Test func licenseNativeFailureStopsCargoAndPreservesCheckedNativeExit() async throws {
        let fixture = try RustFixture()
        defer { fixture.remove() }
        try await fixture.withContext { context in
            let result = try await NotikaRustTestExecutor().run(
                family: .liteparse, context: context, bindings: fixture.bindings, identityOperation: { fixture.identity },
                sourceOperation: { String(repeating: "c", count: 64) },
                commandOperation: { _, _ in .init(nativeTermination: RunTermination(kind: .exit, value: 7), retirementProven: true) })
            #expect(!result.outcome.succeeded)
            #expect(result.outcome.nativeTermination == RunTermination(kind: .exit, value: 7))
            #expect(result.commands.count == 1)
            #expect(result.usage != nil)
        }
    }

    @Test func unknownUsageBeforeExecutionAndDuringCargoIsPreserved() async throws {
        let fixture = try RustFixture()
        defer { fixture.remove() }
        let unknown = Data("{\"unknown\":true}".utf8)
        try fixture.writeUnknownMetadata(unknown)
        try await fixture.withContext { context in
            await #expect(throws: NotikaRustTestError.unsafeMetadata) {
                try await NotikaRustTestExecutor().run(
                    family: .liteparse, context: context, bindings: fixture.bindings, identityOperation: { fixture.identity },
                    sourceOperation: { String(repeating: "c", count: 64) },
                    commandOperation: { _, _ in Issue.record("unknown cache usage admitted native work"); return rustSuccess })
            }
            #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.metadataPath)) == unknown)
            try FileManager.default.removeItem(atPath: fixture.metadataPath)
            let result = try await NotikaRustTestExecutor().run(
                family: .liteparse, context: context, bindings: fixture.bindings, identityOperation: { fixture.identity },
                sourceOperation: { String(repeating: "c", count: 64) }, commandOperation: { command, _ in
                    if command.executable == fixture.identity.misePath { try fixture.writeUnknownMetadata(unknown) }
                    return rustSuccess
                })
            #expect(!result.outcome.succeeded)
            #expect(result.outcome.nativeTermination == RunTermination(kind: .exit, value: 0))
            #expect(result.outcome.failures.map(\.operation) == ["rustCacheUsage"])
            #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.metadataPath)) == unknown)
        }
    }

    @Test func cacheSymlinkEscapeNeverCreatesExternalTargetOrInvokesTools() async throws {
        let fixture = try RustFixture()
        let outside = try CompilationFixture()
        defer { fixture.remove(); outside.remove() }
        try FileManager.default.createDirectory(atPath: fixture.path + "/DerivedData/RustTestCaches", withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(atPath: fixture.cachePath, withDestinationPath: outside.directory.path)
        _ = try await fixture.withContext { context in
            await #expect(throws: NotikaRustTestError.unsafePath(fixture.cachePath)) {
                try await NotikaRustTestExecutor().run(
                    family: .liteparse, context: context, bindings: fixture.bindings, identityOperation: { fixture.identity },
                    sourceOperation: { String(repeating: "c", count: 64) },
                    commandOperation: { _, _ in Issue.record("escaped cache launched native work"); return rustSuccess })
            }
        }
        #expect(!FileManager.default.fileExists(atPath: outside.directory.path + "/target"))
        #expect(!FileManager.default.fileExists(atPath: outside.directory.path + "/cargo-home"))
    }

    @Test func sourceDriftAndUnprovenRetirementCannotBecomePassingRustOutcome() async throws {
        let fixture = try RustFixture()
        defer { fixture.remove() }
        let observations = Mutex(0)
        try await fixture.withContext { context in
            let report = try await NotikaRustTestExecutor().run(
                family: .liteparse, context: context, bindings: fixture.bindings, identityOperation: { fixture.identity },
                sourceOperation: { String(repeating: observations.withLock { $0 += 1; return $0 } == 1 ? "c" : "d", count: 64) },
                commandOperation: { _, _ in rustSuccess })
            #expect(!report.outcome.succeeded)
            #expect(report.outcome.nativeTermination == RunTermination(kind: .exit, value: 0))
            #expect(report.outcome.failures.map(\.operation) == ["rustSourceChanged"])
            let unproven = try await NotikaRustTestExecutor().run(
                family: .liteparse, context: context, bindings: fixture.bindings, identityOperation: { fixture.identity },
                sourceOperation: { String(repeating: "c", count: 64) },
                commandOperation: { _, _ in .init(nativeTermination: RunTermination(kind: .exit, value: 0), retirementProven: false) })
            #expect(!unproven.outcome.succeeded)
            #expect(unproven.commands.count == 1)
            #expect(unproven.usage == nil)
        }
    }

    @Test func busyRustCacheWaitDoesNotAcquireHostCompilationAndCancelsWithoutUnlockingOwner() async throws {
        let fixture = try RustFixture()
        defer { fixture.remove() }
        let paths = try AgentLeasePaths.open(selectedRoot: fixture.registry)
        let owner = try FileLock(resource: ResourceName(fixture.identity.cacheResource()), paths: paths)
        try #require(try owner.tryAcquire())
        defer { owner.release() }
        try await fixture.withContext { context in
            let waiter = Task {
                try await NotikaRustTestExecutor().run(
                    family: .liteparse, context: context, bindings: fixture.bindings, identityOperation: { fixture.identity },
                    sourceOperation: { String(repeating: "c", count: 64) },
                    commandOperation: { _, _ in Issue.record("busy cache reached compilation"); return rustSuccess })
            }
            defer { waiter.cancel() }
            let deadline = ContinuousClock.now + .seconds(3)
            while try fixture.available(fixture.identity.policyResource) {
                try #require(ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(try fixture.compilation.available())
            #expect(!FileManager.default.fileExists(atPath: fixture.cachePath))
            waiter.cancel()
            await #expect(throws: CancellationError.self) { try await waiter.value }
            #expect(try fixture.available(fixture.identity.policyResource))
            #expect(try !fixture.available(fixture.identity.cacheResource()))
        }
    }
}

private let rustSuccess = NotikaPreflightCommandOutcome(nativeTermination: RunTermination(kind: .exit, value: 0), retirementProven: true)

private func rustFixtureIdentity(repository: String, family: NotikaRustTestFamily) throws -> NotikaRustCacheIdentity {
    try .init(repository: repository, family: family,
              inputs: Dictionary(uniqueKeysWithValues: NotikaRustCacheIdentity.inputPaths(family).map { ($0, String(repeating: "a", count: 64)) }),
              misePath: "/fixture/tools/mise", miseDigest: String(repeating: "b", count: 64),
              rustc: "rustc 1.88.0 (fixture)", sysroot: "/fixture/toolchain", cargo: "cargo 1.88.0 (fixture)")
}

private struct RustProbeCapture: RepositoryCommandCapturing {
    let family: NotikaRustTestFamily
    func capture(arguments: [String], workingDirectory: String, environment: [String: String]) async throws -> Data {
        let prefix = ["mise", "exec"] + (family == .liteparse ? ["rust@1.88.0"] : []) + ["--"]
        #expect(Array(arguments.prefix(prefix.count)) == prefix)
        #expect(environment["RUSTFLAGS"] == nil)
        #expect(environment["AGENTLEASE_COMPILE_HOME"] == nil)
        switch Array(arguments.dropFirst(prefix.count)) {
        case ["rustc", "--version", "--verbose"]: return Data("rustc fixture\n".utf8)
        case ["rustc", "--print", "sysroot"]: return Data("/fixture/sysroot\n".utf8)
        case ["cargo", "--version"]: return Data("cargo fixture\n".utf8)
        default: throw CompilationFixture.Failure.expected
        }
    }
}

private struct RustInvalidProbeCapture: RepositoryCommandCapturing {
    func capture(arguments: [String], workingDirectory: String, environment: [String: String]) async throws -> Data { Data([0xff]) }
}

private struct RustFixture: Sendable {
    let compilation: CompilationFixture
    let identity: NotikaRustCacheIdentity
    let plan: NotikaProjectOwnershipPlan
    let registry: String
    let bindings: NotikaRustTestExecutionBindings
    var path: String { compilation.directory.path }
    var cachePath: String { path + "/DerivedData/RustTestCaches/" + (try! identity.cacheKey()) }
    var metadataPath: String { cachePath + "/.notika-cache-usage.json" }
    var environment: [String: String] { compilation.environment.merging(["PATH": path + "/tools:/usr/bin:/bin", "HOME": path, "RUSTFLAGS": "foreign"]) { _, new in new } }

    init(family: NotikaRustTestFamily = .liteparse) throws {
        compilation = try CompilationFixture()
        identity = try rustFixtureIdentity(repository: compilation.directory.path, family: family)
        registry = compilation.directory.path + "/project-registry"
        let digest = String(repeating: "a", count: 64)
        plan = try NotikaProjectOwnershipPlan(identity: CacheCompatibilityIdentity(
            canonicalWorktree: compilation.directory.path, toolchainHash: digest, gitlinks: [],
            submoduleStatusDigest: digest, submoduleWorktreeDigest: digest, projectGraphDigest: digest,
            generatedGraphDigest: digest, resolvedDependenciesDigest: digest, scheme: "Notika", configuration: "Debug",
            destinationFamily: "macos-arm64", buildFlags: ["-disableAutomaticPackageResolution"]))
        bindings = try .init(sessionID: "fixture-rust", temporaryDirectory: compilation.directory.path + "/Artifacts/AgentSessions/fixture-rust/tmp")
        try FileManager.default.createDirectory(atPath: bindings.temporaryDirectory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        for relative in NotikaRustCacheIdentity.inputPaths(family) {
            let destination = path + "/" + relative
            try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: destination).deletingLastPathComponent().path, withIntermediateDirectories: true)
            try Data("input".utf8).write(to: URL(fileURLWithPath: destination))
        }
        try FileManager.default.createDirectory(atPath: path + "/tools", withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: path + "/tools/mise"))
        guard chmod(path + "/tools/mise", 0o755) == 0 else { throw CompilationFixture.Failure.expected }
    }

    func available(_ resource: String, mode: LeaseMode = .exclusive) throws -> Bool {
        let lock = try FileLock(resource: ResourceName(resource), mode: mode, paths: AgentLeasePaths.open(selectedRoot: registry))
        defer { lock.release() }
        return try lock.tryAcquire()
    }

    func withContext<Result: Sendable>(operation: @Sendable (NotikaPreflightRustContext) async throws -> Result) async throws -> Result {
        try await NotikaProjectAdmission().withOwnership(plan, registryRoot: registry, label: "Rust fixture") { ownership in
            try await operation(.init(repository: path, environment: environment, ownership: ownership,
                                      retainedLockDescriptors: ownership.inheritedDescriptors()))
        }
    }

    func writeUnknownMetadata(_ data: Data) throws {
        try FileManager.default.createDirectory(atPath: cachePath, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard chmod(path + "/DerivedData/RustTestCaches", 0o700) == 0 else { throw CompilationFixture.Failure.expected }
        try data.write(to: URL(fileURLWithPath: metadataPath))
        guard chmod(metadataPath, 0o600) == 0 else { throw CompilationFixture.Failure.expected }
    }
    func remove() { compilation.remove() }
}
