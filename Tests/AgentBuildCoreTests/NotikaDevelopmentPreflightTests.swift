@testable import AgentBuildCore
import AgentLeaseCore
import Darwin
import Foundation
import Synchronization
import Testing

@Suite("Notika development preflight")
struct NotikaDevelopmentPreflightTests {
    @Test func closedCatalogMatchesStaticMakeOracleAndUsesSeparateNativeKey() throws {
        let steps = NotikaDevelopmentPreflight.steps
        #expect(steps.count == 19)
        #expect(steps.prefix(3).map(\.name) == ["check-agent-adoption", "check-agent-promotions", "test-agent-adoption"])
        #expect(steps.suffix(2).map(\.operation) == [.rust(.liteparse), .rust(.svg)])
        let digest = try CanonicalJSONDigest.sha256(.array(steps.map(\.commandMaterial)))
        // Static json.dumps(sort_keys=True, ensure_ascii=False, separators=(',', ':'))
        // oracle from Makefile's 17 helper commands and two native Rust entries.
        #expect(digest == "1469617f7c99c2324c33234d6af87c1a544652a04356128fdf96aef75112d74a")
        let key = try CanonicalJSONDigest.sha256(.object([
            "schemaVersion": .integer(1), "sourceIdentitySHA256": .string(String(repeating: "a", count: 64)),
            "toolchainIdentitySHA256": .string(String(repeating: "b", count: 64)), "commandSHA256": .string(digest),
        ]))
        #expect(key == "266e2db7b6abb713bbf6032fb5c507fe0f684a4218d3a0fd794eb6afa0501884")
        #expect(digest != (try CanonicalJSONDigest.sha256(.array(["make", "--no-print-directory", "_test-development-preflight"].map { .string($0) }))))
        for step in steps {
            if case .helper(let arguments, _) = step.operation {
                #expect(!arguments.contains("Scripts/notika-dev"))
                #expect(!arguments.contains("Scripts/development-preflight"))
            }
        }
    }

    @Test func broadRouteClassifierMatchesMakePrerequisites() throws {
        for route in [NotikaMakeRoute.test, .testXcode, .testMacOS, .testIOS, .testUnit, .unitTest, .unitTestXcode, .testUnitIOS, .testUnitMacOS, .buildAndTest] {
            #expect(NotikaDevelopmentPreflight.requiresPreflight(for: try NotikaActionRequest(makeRoute: route)))
        }
        for route in [NotikaMakeRoute.build, .buildMacOS, .testShowOnlyErrors, .testCoverage, .replayFixedSemantic] {
            #expect(!NotikaDevelopmentPreflight.requiresPreflight(for: try NotikaActionRequest(makeRoute: route)))
        }
    }

    @Test func reusedEvidenceBindsClosedDigestSourceAndReceiptPath() throws {
        let repository = "/fixture/Notika", runID = UUID().uuidString
        let identity = try preflightIdentity()
        let command = try CanonicalJSONDigest.sha256(.array(NotikaDevelopmentPreflight.steps.map(\.commandMaterial)))
        let key = try CanonicalJSONDigest.sha256(.object(["schemaVersion": .integer(1), "sourceIdentitySHA256": .string(identity.sourceDigest),
            "toolchainIdentitySHA256": .string(identity.toolchainDigest), "commandSHA256": .string(command)]))
        let report = NotikaDevelopmentPreflightReport(status: .reused, identity: identity, commandDigest: command, key: key,
            receiptPath: repository + "/Untracked/DevelopmentPreflight/" + key + ".json", executions: [])
        let evidence = NotikaDevelopmentPreflightEvidence(report: report, capturedPhases: [], rustReports: [], orchestrationFailures: [], cancelled: false)
        let request = try NotikaActionRequest(makeRoute: .testUnit)
        let value = try evidence.canonicalValue
        let result = try NotikaDevelopmentPreflightEvidence.validateCanonicalValue(value, request: request,
            sourceBeforeSHA256: identity.sourceDigest, sessionPath: repository + "/Artifacts/AgentSessions/" + runID)
        #expect(result.succeeded)
        #expect(result.nativeFailure == nil)
        #expect(!result.cancelled)
        for source in [String(repeating: "c", count: 64), "malformed"] {
            #expect(throws: (any Error).self) {
                _ = try NotikaDevelopmentPreflightEvidence.validateCanonicalValue(value, request: request,
                    sourceBeforeSHA256: source, sessionPath: repository + "/Artifacts/AgentSessions/" + runID)
            }
        }
        #expect(throws: (any Error).self) {
            _ = try NotikaDevelopmentPreflightEvidence.validateCanonicalValue(value, request: NotikaActionRequest(makeRoute: .testCoverage),
                sourceBeforeSHA256: identity.sourceDigest, sessionPath: repository + "/Artifacts/AgentSessions/" + runID)
        }
        var members: [CanonicalJSONMember]
        guard case .object(let original) = value else { Issue.record("missing evidence object"); return }
        members = original + [CanonicalJSONMember(key: "foreignAuthority", value: .bool(true))]
        #expect(throws: (any Error).self) {
            _ = try NotikaDevelopmentPreflightEvidence.validateCanonicalValue(.object(members), request: request,
                sourceBeforeSHA256: identity.sourceDigest, sessionPath: repository + "/Artifacts/AgentSessions/" + runID)
        }
    }

    @Test func environmentMatchesReferenceScrubWithoutBroadeningOuterAdmission() throws {
        let input = ["PATH": "/tools", "HOME": "/account", "SRCROOT": "/repo", "LANG": "",
                     "MISE_ENV": "fixture", "PYTHONPATH": "/fixture/python", "CI": "1",
                     "NOTIKA_AGENTLEASE_INTEGRATION_BINARY": "/trusted/integration", "NOTIKA_DERIVED_DATA": "/cache",
                     "NOTIKA_ROUTE_AUTHORITY_FD": "900", "NOTIKA_AGENT_SOURCE_BEFORE_HASH": "untrusted",
                     "SIMLEASE_SESSION_ID": "sim-session", "SIMULATOR_ID": "device", "FILE": "ForeignTests",
                     "MAKEFLAGS": "-j8", "XCODEBUILD_FLAGS": "-foreign", "PWD": "/wrong", "_": "/command"]
        #expect(try NotikaDevelopmentPreflight.environment(from: input) == [
            "PATH": "/tools", "HOME": "/account", "SRCROOT": "/repo", "MISE_ENV": "fixture",
            "PYTHONPATH": "/fixture/python", "CI": "1", "NOTIKA_AGENTLEASE_INTEGRATION_BINARY": "/trusted/integration",
        ])
        #expect(try NotikaDevelopmentPreflight.environment(from: ["SIMLEASE_UNKNOWN": "bad\0value"]).isEmpty)
        #expect(throws: NotikaDevelopmentPreflightError.invalidEnvironment("PATH")) {
            try NotikaDevelopmentPreflight.environment(from: ["PATH": "/tools\0suffix"])
        }
    }

    @Test func combinedVersionTransportKeepsArgumentsLiteralAndRestoresToolEnvironment() async throws {
        let capture = PreflightVersionCapture()
        let result = try await NotikaDevelopmentPreflight.captureVersion(
            .rustc, repository: "/repo with spaces", environment: ["PATH": "/tools", "BASH_ENV": "literal $(no-shell) startup", "ENV": "fixture"],
            capture: capture)
        #expect(result == "combined-version-�")
        await #expect(throws: RepositoryCaptureError.outputLimitExceeded) {
            try await NotikaDevelopmentPreflight.captureVersion(.cargo, repository: "/repo", environment: [:], capture: PreflightOverflowCapture())
        }
    }

    @Test func completeGatePublishesReadOnlyReceiptAndSecondConsumerReusesIt() async throws {
        let fixture = try PreflightFixture()
        defer { fixture.remove() }
        let observations = Mutex(0)
        let helpers = Mutex<[String]>([])
        let rust = Mutex<[NotikaRustTestFamily]>([])
        try await fixture.withOwnership { ownership in
            let command: NotikaDevelopmentPreflight.CommandOperation = { command, descriptors in
                #expect(command.workingDirectory == fixture.path)
                #expect(command.environment["SIMULATOR_ID"] == nil)
                #expect(command.environment["NOTIKA_AGENT_SOURCE_BEFORE_HASH"] == nil)
                #expect(descriptors.allSatisfy { fcntl($0, F_GETFD) >= 0 })
                let compiling = command.executable == fixture.path + "/Scripts/semantic-operation-adoption"
                #expect(descriptors.count == (compiling ? 5 : 4))
                let available = try fixture.compilation.available()
                #expect(available == !compiling)
                helpers.withLock { $0.append(command.arguments.last ?? "") }
                return preflightSuccess
            }
            let rustCommand: NotikaDevelopmentPreflight.RustOperation = { family, context in
                #expect(context.repository == fixture.path)
                #expect(context.ownership.runID == ownership.runID)
                #expect(context.retainedLockDescriptors.count == 4)
                rust.withLock { $0.append(family) }
                return preflightSuccess
            }
            let observe: NotikaDevelopmentPreflight.IdentityOperation = {
                observations.withLock { $0 += 1 }
                return try preflightIdentity()
            }
            let first = try await NotikaDevelopmentPreflight().run(
                repository: fixture.path, ownership: ownership, environment: fixture.environment,
                admittedSourceDigest: String(repeating: "a", count: 64), identityOperation: observe,
                commandOperation: command, rustOperation: rustCommand)
            #expect(first.status == .passed)
            #expect(first.executions.count == 19)
            #expect(first.executions.allSatisfy { $0.outcome.succeeded })
            var status = stat()
            #expect(lstat(first.receiptPath, &status) == 0)
            #expect(status.st_mode & 0o7777 == 0o400)
            #expect(status.st_nlink == 1)
            let payload = try StrictJSONDocument(data: Data(contentsOf: URL(fileURLWithPath: first.receiptPath)))
            #expect(try payload.root.requireObject().members.count == 6)
            let second = try await NotikaDevelopmentPreflight().run(
                repository: fixture.path, ownership: ownership, environment: fixture.environment,
                identityOperation: observe, commandOperation: command, rustOperation: rustCommand)
            #expect(second.status == .reused)
            #expect(second.key == first.key)
            #expect(second.executions.isEmpty)
            #expect(helpers.withLock { $0.count } == 17)
            #expect(rust.withLock { $0 } == [.liteparse, .svg])
            #expect(observations.withLock { $0 } == 5)
        }
    }

    @Test(arguments: [PreflightFailure.native, .unproven, .capture, .cancelled, .missing])
    fileprivate func incompleteNativeOutcomeCannotPublishReceipt(_ vector: PreflightFailure) async throws {
        let fixture = try PreflightFixture()
        defer { fixture.remove() }
        try await fixture.withOwnership { ownership in
            let result = try await NotikaDevelopmentPreflight().run(
                repository: fixture.path, ownership: ownership, environment: fixture.environment,
                identityOperation: { try preflightIdentity() }, commandOperation: { _, _ in vector.outcome },
                rustOperation: { _, _ in Issue.record("failed helper reached Rust"); return preflightSuccess })
            #expect(result.status == .failed)
            #expect(result.executions.count == 1)
            #expect(result.executions[0].outcome == vector.outcome)
            #expect(!FileManager.default.fileExists(atPath: result.receiptPath))
            #expect(try fixture.compilation.available())
        }
    }

    @Test func missingManagedRustExecutorFailsBeforeReceiptReuseOrHelperExecution() async throws {
        let fixture = try PreflightFixture()
        defer { fixture.remove() }
        try await fixture.withOwnership { ownership in
            await #expect(throws: NotikaDevelopmentPreflightError.rustExecutorUnavailable) {
                try await NotikaDevelopmentPreflight().run(
                    repository: fixture.path, ownership: ownership, environment: fixture.environment,
                    identityOperation: { Issue.record("missing Rust executor observed identities"); return try preflightIdentity() },
                    commandOperation: { _, _ in Issue.record("missing Rust executor ran helper"); return preflightSuccess })
            }
            #expect(!FileManager.default.fileExists(atPath: fixture.path + "/Untracked/DevelopmentPreflight"))
        }
    }

    @Test(arguments: ["source", "toolchain", "admitted"])
    func identityChangeDuringGateCannotPublish(_ changed: String) async throws {
        let fixture = try PreflightFixture()
        defer { fixture.remove() }
        let count = Mutex(0)
        try await fixture.withOwnership { ownership in
            let failure: NotikaDevelopmentPreflightError = changed == "admitted" ? .admittedSourceChanged : .identityChanged("execution")
            await #expect(throws: failure) {
                try await NotikaDevelopmentPreflight().run(
                    repository: fixture.path, ownership: ownership, environment: fixture.environment,
                    admittedSourceDigest: changed == "admitted" ? String(repeating: "a", count: 64) : nil,
                    identityOperation: {
                        let position = count.withLock { $0 += 1; return $0 }
                        if position < 3 { return try preflightIdentity() }
                        return try preflightIdentity(source: changed == "toolchain" ? "a" : "c", tools: changed == "toolchain" ? "c" : "b")
                    }, commandOperation: { _, _ in preflightSuccess }, rustOperation: { _, _ in preflightSuccess })
            }
            let files = try FileManager.default.contentsOfDirectory(atPath: fixture.path + "/Untracked/DevelopmentPreflight")
            #expect(files.filter { $0.hasSuffix(".json") }.isEmpty)
        }
    }

    @Test func malformedReceiptAndOutsideSymlinkRequireFreshPassWithoutFollowingTarget() async throws {
        let fixture = try PreflightFixture()
        defer { fixture.remove() }
        let calls = Mutex(0)
        try await fixture.withOwnership { ownership in
            let run: @Sendable () async throws -> NotikaDevelopmentPreflightReport = {
                try await NotikaDevelopmentPreflight().run(
                    repository: fixture.path, ownership: ownership, environment: fixture.environment,
                    identityOperation: { try preflightIdentity() },
                    commandOperation: { _, _ in calls.withLock { $0 += 1 }; return preflightSuccess },
                    rustOperation: { _, _ in preflightSuccess })
            }
            let first = try await run()
            try FileManager.default.removeItem(atPath: first.receiptPath)
            let outside = fixture.path + "/outside-receipt"
            try Data("untouched".utf8).write(to: URL(fileURLWithPath: outside))
            try FileManager.default.createSymbolicLink(atPath: first.receiptPath, withDestinationPath: outside)
            let second = try await run()
            #expect(second.status == .passed)
            #expect(try Data(contentsOf: URL(fileURLWithPath: outside)) == Data("untouched".utf8))
            #expect(calls.withLock { $0 } == 34)
            try FileManager.default.removeItem(atPath: second.receiptPath)
            try Data("{\"passed\":true,\"passed\":true}".utf8).write(to: URL(fileURLWithPath: second.receiptPath))
            #expect(chmod(second.receiptPath, 0o400) == 0)
            #expect(try await run().status == .passed)
            #expect(calls.withLock { $0 } == 51)
        }
    }

    @Test func linkedStateDirectoryIsRejectedBeforeHelpers() async throws {
        let fixture = try PreflightFixture()
        let outside = try CompilationFixture()
        defer { fixture.remove(); outside.remove() }
        try FileManager.default.createSymbolicLink(atPath: fixture.path + "/Untracked", withDestinationPath: outside.directory.path)
        _ = try await fixture.withOwnership { ownership in
            await #expect(throws: NotikaDevelopmentPreflightError.unsafePath(fixture.path + "/Untracked")) {
                try await NotikaDevelopmentPreflight().run(
                    repository: fixture.path, ownership: ownership, environment: fixture.environment,
                    identityOperation: { try preflightIdentity() },
                    commandOperation: { _, _ in Issue.record("linked state ran helper"); return preflightSuccess },
                    rustOperation: { _, _ in preflightSuccess })
            }
        }
        #expect(!FileManager.default.fileExists(atPath: outside.directory.path + "/DevelopmentPreflight"))
    }

    @Test func receiptLockWaitCancellationRetainsExternalOwnerAndReleasesProjectScope() async throws {
        let fixture = try PreflightFixture()
        defer { fixture.remove() }
        let opening = Mutex(false)
        try await fixture.withOwnership { ownership in
            let first = try await NotikaDevelopmentPreflight().run(
                repository: fixture.path, ownership: ownership, environment: fixture.environment,
                identityOperation: { try preflightIdentity() }, commandOperation: { _, _ in preflightSuccess },
                rustOperation: { _, _ in preflightSuccess })
            let lockPath = fixture.path + "/Untracked/DevelopmentPreflight/" + first.key + ".lock"
            let external = Darwin.open(lockPath, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            try #require(external >= 0)
            defer { Darwin.close(external) }
            try #require(flock(external, LOCK_EX | LOCK_NB) == 0)
            let waiter = Task {
                try await NotikaDevelopmentPreflight().run(
                    repository: fixture.path, ownership: ownership, environment: fixture.environment,
                    identityOperation: { opening.withLock { $0 = true }; return try preflightIdentity() },
                    commandOperation: { _, _ in Issue.record("cancelled waiter ran helper"); return preflightSuccess },
                    rustOperation: { _, _ in preflightSuccess })
            }
            defer { waiter.cancel() }
            let deadline = ContinuousClock.now + .seconds(3)
            while !opening.withLock({ $0 }) {
                try #require(ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(5))
            }
            waiter.cancel()
            await #expect(throws: CancellationError.self) { try await waiter.value }
            let contender = Darwin.open(lockPath, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            try #require(contender >= 0)
            defer { Darwin.close(contender) }
            #expect(flock(contender, LOCK_EX | LOCK_NB) != 0)
        }
        #expect(try fixture.compilation.available())
    }
}

private let preflightSuccess = NotikaPreflightCommandOutcome(nativeTermination: RunTermination(kind: .exit, value: 0), retirementProven: true)

private struct PreflightVersionCapture: RepositoryCommandCapturing {
    func capture(arguments: [String], workingDirectory: String, environment: [String: String]) async throws -> Data {
        #expect(workingDirectory == "/repo with spaces")
        #expect(environment == ["PATH": "/tools"])
        #expect(arguments == ["/bin/bash", "--noprofile", "--norc", "-c", "if [[ -n \"$1\" ]]; then export \"$1\"; fi; if [[ -n \"$2\" ]]; then export \"$2\"; fi; shift 2; exec \"$@\" 2>&1", "--",
                              "BASH_ENV=literal $(no-shell) startup", "ENV=fixture", "mise", "exec", "--", "rustc", "--version", "--verbose"])
        return Data(Array(" \ncombined-version-".utf8) + [0xff, 0x0a])
    }
}

private struct PreflightOverflowCapture: RepositoryCommandCapturing {
    func capture(arguments: [String], workingDirectory: String, environment: [String: String]) async throws -> Data {
        throw RepositoryCaptureError.outputLimitExceeded
    }
}

private enum PreflightFailure: Sendable {
    case native, unproven, capture, cancelled, missing
    var outcome: NotikaPreflightCommandOutcome {
        switch self {
        case .native: .init(nativeTermination: RunTermination(kind: .exit, value: 7), retirementProven: true)
        case .unproven: .init(nativeTermination: RunTermination(kind: .exit, value: 0), retirementProven: false)
        case .capture: .init(nativeTermination: RunTermination(kind: .exit, value: 0), retirementProven: true, failures: [.init(operation: "capture", code: EIO)])
        case .cancelled: .init(nativeTermination: RunTermination(kind: .exit, value: 0), retirementProven: true, cancelled: true)
        case .missing: .init(nativeTermination: nil, retirementProven: true)
        }
    }
}

private func preflightIdentity(source: String = "a", tools: String = "b") throws -> NotikaPreflightIdentity {
    try NotikaPreflightIdentity(sourceDigest: String(repeating: source, count: 64), toolchainDigest: String(repeating: tools, count: 64))
}

private struct PreflightFixture: Sendable {
    let compilation: CompilationFixture
    let plan: NotikaProjectOwnershipPlan
    let registry: String
    var path: String { compilation.directory.path }
    var environment: [String: String] {
        compilation.environment.merging(["PATH": "/usr/bin:/bin", "HOME": path,
                                         "SIMULATOR_ID": "foreign-device", "NOTIKA_AGENT_SOURCE_BEFORE_HASH": "foreign"])
        { _, new in new }
    }

    init() throws {
        compilation = try CompilationFixture()
        registry = compilation.directory.path + "/project-registry"
        let digest = String(repeating: "a", count: 64)
        let identity = try CacheCompatibilityIdentity(
            canonicalWorktree: compilation.directory.path, toolchainHash: digest, gitlinks: [],
            submoduleStatusDigest: digest, submoduleWorktreeDigest: digest, projectGraphDigest: digest,
            generatedGraphDigest: digest, resolvedDependenciesDigest: digest, scheme: "Notika", configuration: "Debug",
            destinationFamily: "macos-arm64", buildFlags: ["-disableAutomaticPackageResolution"])
        plan = try NotikaProjectOwnershipPlan(identity: identity)
        try FileManager.default.createDirectory(atPath: path + "/Scripts", withIntermediateDirectories: true)
        for name in ["semantic-operation-adoption", "agent-failure-diagnostics"] {
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: path + "/Scripts/" + name))
            guard chmod(path + "/Scripts/" + name, 0o755) == 0 else { throw CompilationFixture.Failure.expected }
        }
    }

    func withOwnership<Result: Sendable>(operation: @Sendable (ProjectOwnership) async throws -> Result) async throws -> Result {
        try await NotikaProjectAdmission().withOwnership(plan, registryRoot: registry, label: "preflight fixture", operation: operation)
    }

    func remove() { compilation.remove() }
}
