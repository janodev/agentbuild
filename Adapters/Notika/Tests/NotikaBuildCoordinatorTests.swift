@testable import AgentBuildCore
import AgentBuildTestSupport
import AgentLeaseCore
import Darwin
import Foundation
@testable import NotikaAdapter
import Synchronization
import Testing

@Suite("Production Notika native build coordinator")
struct NotikaBuildCoordinatorTests {
    @Test func exactBuildRunsUnderEveryOwnerAndPublishesCoherentRawEvidence() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let executed = Mutex(false)
        let coordinator = fixture.coordinator { helper, command, claim, descriptors, root, directory in
            #expect(command.executable == "/usr/bin/xcodebuild")
            #expect(command.workingDirectory == fixture.repository)
            #expect(command.arguments == claim.phase.arguments)
            let cache = try #require(command.environment["NOTIKA_DERIVED_DATA"])
            #expect(command.arguments == [
                "-derivedDataPath", cache, "-disableAutomaticPackageResolution", "build",
                "-workspace", "Notika.xcworkspace", "-scheme", "Notika", "-configuration", "Debug",
                "-destination", "platform=macOS,arch=arm64",
            ])
            #expect(command.environment["XCODEBUILD_FLAGS"] == nil)
            #expect(command.environment["NOTIKA_ROUTE_AUTHORITY_FD"] == nil)
            #expect(descriptors.count == 5)
            for descriptor in descriptors { #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0) }
            try fixture.expectAllOwnersHeld(cache: cache)
            #expect(FileManager.default.fileExists(atPath: root + "/in-progress.json"))
            #expect(FileManager.default.fileExists(atPath: cache + "/.notika-cache-usage.json"))
            executed.withLock { $0 = true }
            return try await fixture.worker(helper, descriptors: descriptors, root: root,
                                            directory: directory,
                                            script: #"printf '\000\377raw'; printf diagnostic >&2"#)
        }
        let result = try await fixture.run(coordinator, environment: fixture.environment.merging([
            "XCODEBUILD_FLAGS": "-scheme foreign", "NOTIKA_ROUTE_AUTHORITY_FD": "17",
        ]) { _, new in new })
        #expect(executed.withLock { $0 })
        #expect(result.exitCode == 0 && result.status == "succeeded")
        #expect(result.nativeTermination == RunTermination(kind: .exit, value: 0))
        #expect(result.publicationFailures.isEmpty && result.orchestrationFailures.isEmpty)
        let report = try #require(result.report)
        #expect(report.sessionID == fixture.runID)
        #expect(report.nativeTermination == result.nativeTermination)
        let saved = try NotikaBuildSessionReport(data: Data(contentsOf: fixture.manifestURL),
            expectedRepository: fixture.repository, expectedSessionID: fixture.runID)
        #expect(saved.originalData == report.originalData)
        let raw = try #require(result.rawCaptures.first)
        #expect(raw.captureComplete)
        #expect(try Data(contentsOf: URL(fileURLWithPath: raw.standardOutput.path)) == Data([0, 255, 114, 97, 119]))
        #expect(try String(contentsOfFile: raw.standardError.path, encoding: .utf8) == "diagnostic")
        let envelope = try StrictJSONDocument(data: result.jsonData()).root.requireObject()
        guard case .number(let exitNumber) = try envelope.requiredValue(forKey: "exitCode") else {
            throw CoordinatorFixtureError.setup
        }
        #expect(try exitNumber.int64() == 0)
        #expect(envelope.value(forKey: "status") == .string("succeeded"))
        try await fixture.expectOwnersReleased(cache: rawCacheDirectory(report))
    }

    @Test func compatibilityIsReobservedUnderGraphAndMismatchStartsNoNativeChild() async throws {
        let fixture = try CoordinatorFixture(mode: .changeCompatibilityOnSecondSource)
        defer { fixture.remove() }
        let coordinator = fixture.coordinator { _, _, _, _, _, _ in
            Issue.record("A changed compatibility observation must not reach native execution")
            throw CoordinatorFixtureError.unexpectedExecution
        }
        let result = try await fixture.run(coordinator)
        #expect(result.nativeTermination == nil)
        #expect(result.outcome == nil)
        #expect(result.exitCode == 70)
        #expect(result.orchestrationFailures.contains { $0.contains("compatibilityChangedBeforeExecution") })
        #expect(fixture.capture.sourceCount == 3)
        #expect(!FileManager.default.fileExists(atPath: fixture.repository + "/DerivedData"))
        #expect(try NotikaBuildSessionReport(data: Data(contentsOf: fixture.manifestURL)).nativeTermination == nil)
        #expect(try fixture.available("notika:sessions:" + fixture.repository))
    }

    @Test func cancellingWhileGraphIsBusyKeepsWriterUntilFinalUncancelledObservations() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let graph = try CacheCompatibilityIdentity.graphResourceName(canonicalWorktree: fixture.repository)
        let held = try fixture.acquire(graph)
        defer { held.release() }
        let coordinator = fixture.coordinator { _, _, _, _, _, _ in
            Issue.record("A waiting cancelled build must never start a native child")
            throw CoordinatorFixtureError.unexpectedExecution
        }
        let task = Task { try await fixture.run(coordinator, waitSeconds: nil) }
        try await coordinatorWaitUntil { fixture.capture.sourceCount >= 1 }
        #expect(try !fixture.available("notika:sessions:" + fixture.repository))
        #expect(FileManager.default.fileExists(atPath: fixture.sessionPath + "/in-progress.json"))
        task.cancel()
        let result = try await task.value
        #expect(result.cancelled)
        #expect(result.exitCode == 130)
        #expect(result.nativeTermination == nil && result.rawCaptures.isEmpty)
        #expect(fixture.capture.sourceCount == 2)
        #expect(fixture.capture.cancelledCaptureCalls == 0)
        let report = try #require(result.report)
        let root = try StrictJSONDocument(data: report.originalData).root.requireObject()
        #expect(root.value(forKey: "sourceAfter") != .null)
        #expect(root.value(forKey: "toolchainAfter") != .null)
        #expect(try fixture.available("notika:sessions:" + fixture.repository))
        #expect(try !fixture.available(graph)) // The fixture's independent owner remains held.
    }

    @Test(arguments: [false, true])
    func ordinarySourceDriftDoesNotRewriteNativeSuccess(_ reverted: Bool) async throws {
        let fixture = try CoordinatorFixture(mode: reverted ? .transientOrdinarySource : .ordinary)
        defer { fixture.remove() }
        let coordinator = fixture.coordinator { helper, _, _, descriptors, root, directory in
            let capsule = try await fixture.worker(helper, descriptors: descriptors, root: root,
                                                  directory: directory, script: "exit 0")
            if !reverted { fixture.capture.changeOrdinarySource() }
            return capsule
        }
        let result = try await fixture.run(coordinator)
        #expect(result.nativeTermination == RunTermination(kind: .exit, value: 0))
        #expect(result.exitCode == 3 && result.status == "inconclusive")
        #expect(result.orchestrationFailures.isEmpty && result.publicationFailures.isEmpty)
        let root = try StrictJSONDocument(data: #require(result.report).originalData).root.requireObject()
        let drift = try root.requiredValue(forKey: "sourceDrift").requireObject()
        #expect(drift.value(forKey: "sourceChanged") == .bool(!reverted))
        #expect(drift.value(forKey: "sourceObservedReverted") == .bool(reverted))
    }

    @Test(arguments: [Int32(0), 29])
    func finalObservationFailureKeepsNativeExitAndMakesSuccessInconclusive(_ code: Int32) async throws {
        let fixture = try CoordinatorFixture(mode: .failFinalSource)
        defer { fixture.remove() }
        let coordinator = fixture.coordinator { helper, _, _, descriptors, root, directory in
            try await fixture.worker(helper, descriptors: descriptors, root: root,
                                     directory: directory, script: "exit \(code)")
        }
        let result = try await fixture.run(coordinator)
        #expect(result.nativeTermination == RunTermination(kind: .exit, value: code))
        #expect(result.exitCode == (code == 0 ? 70 : code))
        #expect(result.orchestrationFailures.contains { $0.contains("final source observation") })
        #expect(result.report?.nativeTermination == result.nativeTermination)
        #expect(result.report?.exitCode == result.exitCode)
    }

    @Test(arguments: [Int32(0), 29])
    func failedRawAdmissionPublishesDiagnosticWithoutErasingNativeOutcome(_ code: Int32) async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator { helper, _, _, descriptors, root, directory in
            let capsule = try await fixture.worker(helper, descriptors: descriptors, root: root,
                directory: directory,
                script: "printf original; exit \(code)")
            let descriptor = open(capsule.rawCapture.standardOutput.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw CoordinatorFixtureError.setup }
            defer { close(descriptor) }
            #expect("corrupt!".withCString { pwrite(descriptor, $0, 8, 0) } == 8)
            #expect(fsync(descriptor) == 0)
            return capsule
        }
        let result = try await fixture.run(coordinator)
        #expect(result.nativeTermination == RunTermination(kind: .exit, value: code))
        #expect(result.exitCode == (code == 0 ? 70 : code))
        #expect(!result.publicationFailures.isEmpty)
        let report = try #require(result.report)
        #expect(report.exitCode == result.exitCode)
        let root = try StrictJSONDocument(data: report.originalData).root.requireObject()
        guard case .array(let logs) = try root.requiredValue(forKey: "rawLogReports") else {
            throw CoordinatorFixtureError.setup
        }
        #expect(logs.count == 1)
        #expect(try logs[0].requireObject().value(forKey: "publicationAdmitted") == .bool(false))
    }

    @Test func invalidGeneratedWorkspaceDoesNotReachTheNativeExecutor() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(atPath: fixture.repository + "/Notika.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        let result = try await fixture.run(fixture.coordinator { _, _, _, _, _, _ in
            Issue.record("Invalid generated workspace must not execute")
            throw CoordinatorFixtureError.unexpectedExecution
        })
        #expect(result.nativeTermination == nil && result.rawCaptures.isEmpty)
        #expect(result.exitCode == 70)
        #expect(!result.orchestrationFailures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.repository + "/DerivedData"))
    }

    @Test func unsupportedRoutesFailBeforeCreatingAnySessionOrCache() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        for request in try [
            NotikaActionRequest(platform: .macOS, documentationMode: .archive),
            NotikaActionRequest(platform: .macOS, interactiveMode: .run),
            NotikaActionRequest(platform: .macOS, testFile: "UITests", testMethod: "testExample"),
        ] {
            await #expect(throws: NotikaBuildCoordinatorError.unsupportedRequest) {
                try await fixture.coordinator { _, _, _, _, _, _ in
                    throw CoordinatorFixtureError.unexpectedExecution
                }.run(repository: fixture.repository, request: request, helperExecutable: fixture.helper,
                      registryRoot: fixture.registry, environment: fixture.environment)
            }
        }
        #expect(fixture.capture.sourceCount == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.repository + "/Artifacts"))
        #expect(!FileManager.default.fileExists(atPath: fixture.repository + "/DerivedData"))
    }

    @Test(arguments: [NotikaMakeRoute.testUnitFile, .testXcodeFile, .testUnitFocused])
    func focusedUnitRuntimeAndSummaryRetainOwnersAfterCompileLeaseRelease(_ route: NotikaMakeRoute) async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let request = try NotikaActionRequest(makeRoute: route, testFile: route == .testUnitFocused ? "" : "PaperTests",
            unitSelectors: route == .testUnitFocused ? ["PaperTests/spacing()"] : [])
        let phases = Mutex<[NativeInvocationPhase]>([])
        let probes = Mutex(0)
        let coordinator = fixture.coordinator({ helper, command, claim, descriptors, root, directory in
            phases.withLock { $0.append(claim.phase) }
            #expect(command.arguments == claim.phase.arguments)
            #expect(command.arguments.contains("-only-testing:NotikaTests/" + (route == .testUnitFocused ? "PaperTests/spacing()" : "PaperTests")))
            let cache = try #require(command.environment["NOTIKA_DERIVED_DATA"])
            try fixture.expectAllOwnersHeld(cache: cache, compilationHeld: claim.phase.requiresCompilation)
            #expect(descriptors.count == (claim.phase.requiresCompilation ? 5 : 4))
            if claim.phase.requiresCompilation {
                #expect(command.arguments.contains("build-for-testing"))
                #expect(!command.arguments.contains("-resultBundlePath"))
                #expect(!FileManager.default.fileExists(atPath: root + "/result.xcresult"))
            } else {
                #expect(command.arguments.contains("test-without-building"))
                #expect(command.arguments.contains(root + "/result.xcresult"))
            }
            return try await fixture.worker(helper, descriptors: descriptors, root: root, directory: directory,
                script: claim.phase.requiresCompilation ? "printf compiled" : fixture.createResultScript())
        }, summary: { helper, command, descriptors, root, directory in
            probes.withLock { $0 += 1 }
            #expect(command.executable == "/usr/bin/xcrun")
            #expect(command.arguments == ["xcresulttool", "get", "test-results", "summary", "--path", ".", "--compact"])
            #expect(command.workingDirectory == root + "/result.xcresult")
            #expect(descriptors.count == 4)
            let cache = try #require(command.environment["NOTIKA_DERIVED_DATA"])
            try fixture.expectAllOwnersHeld(cache: cache, compilationHeld: false)
            #expect(FileManager.default.fileExists(atPath: root + "/result-custody.json"))
            return try await fixture.summaryWorker(helper, command: command, descriptors: descriptors,
                root: root, directory: directory, passed: 3)
        })
        let result = try await fixture.run(coordinator, request: request)
        #expect(result.exitCode == 0 && result.status == "succeeded")
        #expect(result.nativeTermination == RunTermination(kind: .exit, value: 0))
        #expect(phases.withLock { $0.map(\.phaseOrdinal) } == [0, 1])
        #expect(probes.withLock { $0 } == 1)
        #expect(result.rawCaptures.count == 3)
        let summary = try #require(result.resultSummary)
        #expect(summary.provesPassingRun)
        #expect(summary.tests?.executed == 3)
        #expect(!summary.focusedMethod) // Swift Testing methods may contain parameterized cases.
        try summary.revalidateForPublication()
        let report = try #require(result.report)
        let saved = try NotikaBuildSessionReport(data: Data(contentsOf: fixture.manifestURL),
            expectedRepository: fixture.repository, expectedSessionID: fixture.runID)
        #expect(saved.originalData == report.originalData)
        try await fixture.expectOwnersReleased(cache: rawCacheDirectory(report))
    }

    @Test func focusedUnitCompilationFailureSkipsRuntimeAndResultProbe() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let calls = Mutex(0)
        let coordinator = fixture.coordinator({ helper, _, claim, descriptors, root, directory in
            calls.withLock { $0 += 1 }
            #expect(claim.phase.requiresCompilation)
            return try await fixture.worker(helper, descriptors: descriptors, root: root,
                directory: directory, script: "exit 42")
        }, summary: { _, _, _, _, _ in
            Issue.record("A failed compilation must not probe a result")
            throw CoordinatorFixtureError.unexpectedExecution
        })
        let result = try await fixture.run(coordinator, request: NotikaActionRequest(makeRoute: .testUnitFile, testFile: "PaperTests"))
        #expect(result.exitCode == 42 && result.nativeTermination == RunTermination(kind: .exit, value: 42))
        #expect(calls.withLock { $0 } == 1)
        #expect(result.outcome?.observations.count == 1)
        #expect(result.resultSummary == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.sessionPath + "/result.xcresult"))
        #expect(!FileManager.default.fileExists(atPath: fixture.sessionPath + "/result-custody.json"))
        #expect(result.report?.exitCode == 42)
    }

    @Test(arguments: [Int32(0), 65])
    func missingUnitResultNeverProvesSuccessOrErasesNativeFailure(_ code: Int32) async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator({ helper, _, claim, descriptors, root, directory in
            try await fixture.worker(helper, descriptors: descriptors, root: root, directory: directory,
                script: "exit \(claim.phase.requiresCompilation ? 0 : code)")
        }, summary: { _, _, _, _, _ in
            Issue.record("A missing result cannot be probed")
            throw CoordinatorFixtureError.unexpectedExecution
        })
        let result = try await fixture.run(coordinator, request: NotikaActionRequest(makeRoute: .testUnitFile, testFile: "PaperTests"))
        #expect(result.nativeTermination == RunTermination(kind: .exit, value: code))
        #expect(result.exitCode == (code == 0 ? 70 : code))
        #expect(result.resultSummary == nil)
        #expect(!result.orchestrationFailures.isEmpty)
        #expect(result.report?.exitCode == result.exitCode)
    }

    @Test(arguments: [false, true])
    func emptyOrFailedSummaryCannotConvertNativeZeroIntoPassingUnitTests(_ probeFails: Bool) async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator({ helper, _, claim, descriptors, root, directory in
            try await fixture.worker(helper, descriptors: descriptors, root: root, directory: directory,
                script: claim.phase.requiresCompilation ? "exit 0" : fixture.createResultScript())
        }, summary: { helper, command, descriptors, root, directory in
            try await fixture.summaryWorker(helper, command: command, descriptors: descriptors,
                root: root, directory: directory, passed: 0, exitCode: probeFails ? 19 : 0)
        })
        let result = try await fixture.run(coordinator, request: NotikaActionRequest(makeRoute: .testUnitFile, testFile: "PaperTests"))
        #expect(result.nativeTermination == RunTermination(kind: .exit, value: 0))
        #expect(result.exitCode == 3 && result.status == "inconclusive")
        let summary = try #require(result.resultSummary)
        #expect(!summary.provesPassingRun)
        if probeFails { #expect(summary.probe?.observation.termination == RunTermination(kind: .exit, value: 19)) }
        else { #expect(summary.tests?.executed == 0) }
        #expect(result.report?.exitCode == 3)
    }

    @Test(arguments: [Int32(0), 65])
    func resultMutationDuringProbeIsUnadmittedAndKeepsXcodeOutcome(_ code: Int32) async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator({ helper, _, claim, descriptors, root, directory in
            try await fixture.worker(helper, descriptors: descriptors, root: root, directory: directory,
                script: claim.phase.requiresCompilation ? "exit 0" : fixture.createResultScript(exitCode: code))
        }, summary: { helper, command, descriptors, root, directory in
            let probe = try await fixture.summaryWorker(helper, command: command, descriptors: descriptors,
                root: root, directory: directory, passed: 1)
            try Data("changed".utf8).write(to: URL(fileURLWithPath: command.workingDirectory + "/evidence"))
            return probe
        })
        let result = try await fixture.run(coordinator, request: NotikaActionRequest(makeRoute: .testUnitFile, testFile: "PaperTests"))
        #expect(result.nativeTermination == RunTermination(kind: .exit, value: code))
        #expect(result.exitCode == (code == 0 ? 70 : code))
        #expect(!result.publicationFailures.isEmpty)
        #expect(result.resultSummary?.provesPassingRun == false)
        #expect(result.report?.exitCode == result.exitCode)
    }

    @Test func maintenanceSetupFailureIsSeparateFromSuccessfulNativeBuild() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let maintenanceObserved = Mutex(false)
        let coordinator = fixture.coordinator({ helper, _, _, descriptors, root, directory in
            #expect(maintenanceObserved.withLock { $0 })
            return try await fixture.worker(helper, descriptors: descriptors, root: root,
                directory: directory, script: "exit 0")
        }, maintenance: { repository, registry, _, _ in
            #expect(repository == fixture.repository && registry == fixture.registry)
            #expect(!FileManager.default.fileExists(atPath: fixture.sessionPath))
            #expect(try fixture.available("notika:sessions:" + fixture.repository))
            maintenanceObserved.withLock { $0 = true }
            throw CoordinatorFixtureError.maintenance
        })
        let result = try await fixture.run(coordinator)
        #expect(result.exitCode == 0 && result.status == "succeeded")
        #expect(result.maintenanceReport == nil)
        #expect(result.maintenanceDiagnostics == ["maintenance"])
        #expect(result.orchestrationFailures.isEmpty && result.publicationFailures.isEmpty)
        let json = try StrictJSONDocument(data: result.jsonData()).root.requireObject()
        #expect(json.value(forKey: "maintenanceDiagnostics") == .array([.string("maintenance")]))
    }

    @Test(arguments: ["success", "native-failure", "mutated-raw"])
    func continuationRequiresCompleteNativeAndRawEvidenceWhileOwnersRemainHeld(_ mode: String) async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let continued = Mutex(false)
        let coordinator = fixture.coordinator { helper, _, _, descriptors, root, directory in
            let capture = try await fixture.worker(helper, descriptors: descriptors, root: root,
                directory: directory, script: mode == "native-failure" ? "exit 31" : "printf original")
            if mode == "mutated-raw" {
                let file = open(capture.rawCapture.standardOutput.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
                guard file >= 0 else { throw CoordinatorFixtureError.setup }
                defer { close(file) }
                #expect("changed!".withCString { pwrite(file, $0, 8, 0) } == 8)
                #expect(fsync(file) == 0)
            }
            return capture
        }
        let result = try await coordinator.runWithContinuation(repository: fixture.repository,
            request: NotikaActionRequest(makeRoute: .buildMacOS), helperExecutable: fixture.helper,
            registryRoot: fixture.registry, environment: fixture.environment, waitSeconds: 2,
            runID: fixture.runID) { context in
                continued.withLock { $0 = true }
                try await context.revalidateBeforeOperation()
                try fixture.expectAllOwnersHeld(cache: context.cacheCustody.cacheDirectory, compilationHeld: false)
                #expect(try context.borrowedLockDescriptors().count == 4)
                #expect(try fcntl(context.borrowedWorkingDirectoryDescriptor(), F_GETFD) >= 0)
                #expect(!FileManager.default.fileExists(atPath: fixture.manifestURL.path))
            }
        #expect(continued.withLock { $0 } == (mode == "success"))
        #expect(result.nativeTermination == RunTermination(kind: .exit, value: mode == "native-failure" ? 31 : 0))
        #expect(result.exitCode == (mode == "success" ? 0 : mode == "native-failure" ? 31 : 70))
        try await fixture.expectOwnersReleased(cache: rawCacheDirectory(#require(result.report)))
    }

    @Test func releaseBuildKeepsExactConfigurationWithoutResultOrPreflight() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let result = try await fixture.run(fixture.coordinator { helper, command, claim, descriptors, root, directory in
            #expect(claim.phase.requiresCompilation)
            let index = try #require(command.arguments.firstIndex(of: "-configuration"))
            #expect(command.arguments[index + 1] == "Release")
            #expect(!command.arguments.contains("-resultBundlePath"))
            return try await fixture.worker(helper, descriptors: descriptors, root: root, directory: directory, script: "exit 0")
        }, request: NotikaActionRequest(makeRoute: .buildReleaseMacOS))
        #expect(result.exitCode == 0)
        #expect(result.outcome?.observations.count == 1)
        #expect(result.resultSummary == nil && result.preflightEvidence == nil)
    }

    @Test(arguments: [Int32(0), 23])
    func leasedIPadPreparationUsesOnlyExportedSimulatorAndFailureBlocksXcode(_ preparationExit: Int32) async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let toolDirectory = fixture.root + "/bin"
        try FileManager.default.createDirectory(atPath: toolDirectory, withIntermediateDirectories: false)
        let tool = toolDirectory + "/simslim"
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: tool))
        #expect(chmod(tool, 0o755) == 0)
        let simulator = "8D62B0CA-3736-4D0A-9F14-7757FD7763CD"
        let environment = fixture.environment.merging([
            "PATH": toolDirectory + ":/usr/bin:/bin", "SIMLEASE_SESSION_ID": UUID().uuidString,
            "SIMULATOR_ID": simulator, "SIMULATOR_UDID": simulator,
        ]) { _, selected in selected }
        let sequence = Mutex([String]())
        let coordinator = fixture.coordinator({ helper, command, _, descriptors, root, directory in
            sequence.withLock { $0.append("xcode") }
            #expect(command.arguments.contains("platform=iOS Simulator,id=" + simulator))
            #expect(command.arguments.contains("NotikaiPad"))
            #expect(descriptors.count == 5)
            return try await fixture.worker(helper, descriptors: descriptors, root: root, directory: directory, script: "exit 0")
        }, preparation: { helper, command, descriptors, root, directory in
            sequence.withLock { $0.append("simslim") }
            #expect(command.executable == tool)
            #expect(command.arguments == ["on", simulator])
            #expect(descriptors.count == 4)
            try fixture.expectAllOwnersHeld(cache: #require(command.environment["NOTIKA_DERIVED_DATA"]), compilationHeld: false)
            return try await fixture.worker(helper, descriptors: descriptors, root: root,
                directory: directory, script: "exit \(preparationExit)")
        })
        let result = try await fixture.run(coordinator, environment: environment,
            request: NotikaActionRequest(makeRoute: .buildIOS, device: "iPad Air 13-inch (M4)"))
        #expect(sequence.withLock { $0 } == (preparationExit == 0 ? ["simslim", "xcode"] : ["simslim"]))
        #expect(result.exitCode == preparationExit)
        #expect(result.nativeTermination == RunTermination(kind: .exit, value: preparationExit))
        #expect(result.report?.destination == "platform=iOS Simulator,id=" + simulator)
        #expect(result.publicationFailures.isEmpty)
    }

    @Test func unitCoverageConsumesUnderProjectOwnersAfterCompilationGateIsReleased() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let calls = Mutex([[String]]())
        let coordinator = fixture.coordinator({ helper, command, claim, descriptors, root, directory in
            #expect(command.arguments.contains("-enableCodeCoverage"))
            let cache = try #require(command.environment["NOTIKA_DERIVED_DATA"])
            try fixture.expectAllOwnersHeld(cache: cache, compilationHeld: claim.phase.requiresCompilation)
            return try await fixture.worker(helper, descriptors: descriptors, root: root, directory: directory,
                script: claim.phase.requiresCompilation ? "exit 0" : fixture.createResultScript())
        }, summary: { helper, command, descriptors, root, directory in
            calls.withLock { $0.append(command.arguments) }
            #expect(descriptors.count == 4)
            try fixture.expectAllOwnersHeld(cache: #require(command.environment["NOTIKA_DERIVED_DATA"]), compilationHeld: false)
            if command.arguments.first == "xcresulttool" {
                return try await fixture.summaryWorker(helper, command: command, descriptors: descriptors,
                    root: root, directory: directory, passed: 4)
            }
            #expect(command.arguments == ["xccov", "view", "--report", "--only-targets", "."])
            return try await CapturedNativePhaseRunner().run(helperExecutable: helper,
                command: DarwinWorkloadCommand(executable: "/bin/sh", arguments: ["-c", "printf 'Fixture 100%%\\n'"],
                    workingDirectory: command.workingDirectory, environment: command.environment),
                retainedLockDescriptors: descriptors, nativeWorkingDirectoryDescriptor: directory, artifactRoot: root)
        })
        let result = try await fixture.run(coordinator, request: NotikaActionRequest(makeRoute: .testUnitCoverage))
        let diagnostics = String(decoding: try result.jsonData(), as: UTF8.self)
        #expect(result.exitCode == 0 && result.nativeTermination == RunTermination(kind: .exit, value: 0),
            "Native/consumer diagnostics: \(diagnostics)")
        #expect(calls.withLock { $0.count } == 2)
        #expect(result.rawCaptures.count == 4)
        #expect(result.resultConsumer?.provesSuccessfulConsumption == true,
            "Consumer failures: \(String(describing: result.resultConsumer?.failures))")
        #expect(result.preflightEvidence == nil && result.simulatorPreparation == nil)
        #expect(result.publicationFailures.isEmpty)
        _ = try NotikaBuildSessionReport(data: Data(contentsOf: fixture.manifestURL))
    }

    @Test(arguments: [1, 3])
    func focusedMacUIRetainsActualOuterHostAndRejectsUnexpectedTestCount(_ passed: Int) async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let host = try fixture.openMacUIHost()
        defer { close(host) }
        let environment = fixture.macUIEnvironment
        let sequence = Mutex([String]())
        let coordinator = fixture.coordinator({ helper, command, claim, descriptors, root, directory in
            sequence.withLock { $0.append(claim.phase.requiresCompilation ? "compile" : "runtime") }
            #expect(descriptors.count == (claim.phase.requiresCompilation ? 6 : 5))
            #expect(command.arguments.contains("-only-testing:NotikaUITests/PaperUITests/testPaper"))
            try fixture.expectAllOwnersHeld(cache: #require(command.environment["NOTIKA_DERIVED_DATA"]),
                compilationHeld: claim.phase.requiresCompilation)
            return try await fixture.worker(helper, descriptors: descriptors, root: root, directory: directory,
                script: claim.phase.requiresCompilation ? "exit 0" : fixture.createResultScript())
        }, summary: { helper, command, descriptors, root, directory in
            sequence.withLock { $0.append("summary") }
            #expect(descriptors.count == 5)
            return try await fixture.summaryWorker(helper, command: command, descriptors: descriptors,
                root: root, directory: directory, passed: passed)
        }, preparation: { helper, command, descriptors, root, directory in
            sequence.withLock { $0.append("applescripts") }
            #expect(try NotikaBuildCoordinator.validatesUIPreparation(command: command, repository: fixture.repository))
            #expect(command.arguments.last == (try NotikaBuildCoordinator.effectiveUIPreparationHome()))
            #expect(command.arguments.last != environment["HOME"])
            #expect(descriptors.count == 5)
            try fixture.expectAllOwnersHeld(cache: #require(command.environment["NOTIKA_DERIVED_DATA"]), compilationHeld: false)
            return try await fixture.worker(helper, descriptors: descriptors, root: root, directory: directory, script: "exit 0")
        })
        let result = try await fixture.run(coordinator, environment: environment,
            request: NotikaActionRequest(makeRoute: .testUIFile, testFile: "PaperUITests", testMethod: "testPaper"))
        #expect(sequence.withLock { $0 } == ["applescripts", "compile", "runtime", "summary"])
        #expect(result.nativeTermination == RunTermination(kind: .exit, value: 0))
        #expect(result.exitCode == (passed == 1 ? 0 : 3))
        #expect(result.resultSummary?.focusedMethod == true)
        #expect(result.preflightEvidence == nil)
        #expect(result.publicationFailures.isEmpty)
        #expect(flock(host, LOCK_EX | LOCK_NB) == 0) // The original outer owner still exists.
        _ = try NotikaBuildSessionReport(data: Data(contentsOf: fixture.manifestURL))
    }

    @Test func broadBuildAndTestStopsBeforeXcodeWhenObservedPreflightNativeCommandFails() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let host = try fixture.openMacUIHost()
        defer { close(host) }
        let entered = Mutex(false)
        let coordinator = fixture.coordinator({ _, _, _, _, _, _ in
            Issue.record("A failed required preflight must not compile or execute the requested Xcode workload")
            throw CoordinatorFixtureError.unexpectedExecution
        }, preparation: { helper, _, descriptors, root, directory in
            try await fixture.worker(helper, descriptors: descriptors, root: root, directory: directory, script: "exit 0")
        }, preflight: { helper, session, ownership, custody, sourceDigest, _, inherited, _ in
            do {
                entered.withLock { $0 = true }
                #expect(sourceDigest.count == 64 && inherited.count == 1)
                try fixture.expectAllOwnersHeld(cache: custody.cacheDirectory, compilationHeld: false)
                let directory = try #require(custody.inheritedDirectoryDescriptors().dropLast(3).last)
                let captured = try await fixture.worker(helper,
                    descriptors: session.inheritedDescriptors() + ownership.inheritedDescriptors() + inherited,
                    root: session.path, directory: directory, script: "exit 37")
                return NotikaDevelopmentPreflightEvidence(report: nil, capturedPhases: [captured], rustReports: [],
                    orchestrationFailures: ["fixture preflight stopped after observed native failure"], cancelled: false)
            } catch {
                Issue.record("Unexpected preflight fixture failure: \(error)")
                return NotikaDevelopmentPreflightEvidence(report: nil, capturedPhases: [], rustReports: [],
                    orchestrationFailures: [String(describing: error)], cancelled: false)
            }
        })
        let result = try await fixture.run(coordinator, environment: fixture.macUIEnvironment,
            request: NotikaActionRequest(makeRoute: .buildAndTest))
        #expect(entered.withLock { $0 })
        #expect(result.nativeTermination == RunTermination(kind: .exit, value: 37))
        #expect(result.exitCode == 37 && result.status == "failed")
        #expect(result.outcome == nil && result.resultSummary == nil)
        #expect(result.preflightEvidence?.nativeFailure == result.nativeTermination)
        #expect(result.rawCaptures.count == 2)
        #expect(!FileManager.default.fileExists(atPath: fixture.sessionPath + "/result.xcresult"))
        #expect(result.publicationFailures.isEmpty)
        _ = try NotikaBuildSessionReport(data: Data(contentsOf: fixture.manifestURL))
    }

    @Test(arguments: [NotikaMakeRoute.testTextInputHeavyDependencyPerformance, .testCanvasFramePacingPerformance])
    func performanceReservationBindsChildInputsButFailedExportCannotProveSuccess(_ route: NotikaMakeRoute) async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let host = try fixture.openMacUIHost()
        defer { close(host) }
        let canvas = route == .testCanvasFramePacingPerformance
        let exportAttempted = Mutex(false)
        let coordinator = fixture.coordinator({ helper, command, claim, descriptors, root, directory in
            #expect(command.environment["NOTIKA_AGENT_SESSION_ID"] == fixture.runID)
            #expect(command.environment["NOTIKA_AGENT_SESSION_DIR"] == fixture.sessionPath)
            #expect(command.environment["NOTIKA_AGENT_SOURCE_BEFORE_HASH"]?.count == 64)
            #expect(command.environment["NOTIKA_AGENT_SOURCE_HEAD"] == String(repeating: "a", count: 40))
            #expect(command.environment["NOTIKA_AGENT_TEST_PLATFORM"] == "macos-ui")
            if canvas {
                let evidence = try #require(command.environment["NOTIKA_CANVAS_FRAME_PACING_PERFORMANCE_PATH"])
                var metadata = stat()
                #expect(lstat(evidence + "/report.json", &metadata) == 0)
                #expect(String(metadata.st_dev) == command.environment["NOTIKA_CANVAS_FRAME_PACING_REPORT_DEVICE_ID"])
                #expect(String(metadata.st_ino) == command.environment["NOTIKA_CANVAS_FRAME_PACING_REPORT_INODE"])
            } else {
                #expect(command.environment["NOTIKA_TEXT_INPUT_HEAVY_DEPENDENCY_PERFORMANCE_PATH"] ==
                    fixture.sessionPath + "/text-input-heavy-dependency-performance")
            }
            return try await fixture.worker(helper, descriptors: descriptors, root: root, directory: directory,
                script: claim.phase.requiresCompilation ? "exit 0" : fixture.createResultScript(), environment: command.environment)
        }, summary: { helper, command, descriptors, root, directory in
            if command.arguments.prefix(2) == ["xcresulttool", "get"] {
                return try await fixture.summaryWorker(helper, command: command, descriptors: descriptors,
                    root: root, directory: directory, passed: canvas ? 1 : 2)
            }
            exportAttempted.withLock { $0 = true }
            #expect(command.arguments.prefix(5) == ["xcresulttool", "export", "attachments", "--path", "."])
            #expect(descriptors.count == 5)
            try fixture.expectAllOwnersHeld(cache: #require(command.environment["NOTIKA_DERIVED_DATA"]), compilationHeld: false)
            return try await CapturedNativePhaseRunner().run(helperExecutable: helper,
                command: DarwinWorkloadCommand(executable: "/bin/sh", arguments: ["-c", "exit 19"],
                    workingDirectory: command.workingDirectory, environment: command.environment),
                retainedLockDescriptors: descriptors, nativeWorkingDirectoryDescriptor: directory, artifactRoot: root)
        })
        let result = try await fixture.run(coordinator, environment: fixture.macUIEnvironment,
            request: NotikaActionRequest(makeRoute: route))
        #expect(exportAttempted.withLock { $0 })
        #expect(result.nativeTermination == RunTermination(kind: .exit, value: 0))
        #expect(result.exitCode == 3 && result.status == "inconclusive")
        #expect(result.performanceEvidence?.complete == false)
        #expect(result.performanceEvidence?.exportCapture?.observation.termination == RunTermination(kind: .exit, value: 19))
        #expect(result.resultConsumer == nil && result.simulatorPreparation == nil && result.uiPreparation == nil)
        #expect(result.publicationFailures.isEmpty)
        _ = try NotikaBuildSessionReport(data: Data(contentsOf: fixture.manifestURL))
    }

    @Test(arguments: [Int32(0), 65])
    func refusedInitialResultProbeSurvivesTerminalPublicationWithoutGrantingResultAuthority(_ nativeExit: Int32) async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator({ helper, _, claim, descriptors, root, directory in
            try await fixture.worker(helper, descriptors: descriptors, root: root, directory: directory,
                script: claim.phase.requiresCompilation ? "exit 0" : fixture.createResultScript(exitCode: nativeExit))
        }, summary: { helper, command, descriptors, root, directory in
            let probe = try await fixture.summaryWorker(helper, command: command, descriptors: descriptors,
                root: root, directory: directory, passed: 2)
            try Data("original native file changed during indexing".utf8).write(
                to: URL(fileURLWithPath: command.workingDirectory + "/evidence"))
            return probe
        }, prepareResultIndexes: true)
        let result = try await fixture.run(coordinator,
            request: NotikaActionRequest(makeRoute: .testUnitFile, testFile: "PaperTests"))
        #expect(result.nativeTermination == RunTermination(kind: .exit, value: nativeExit))
        #expect(result.exitCode == (nativeExit == 0 ? 70 : nativeExit))
        #expect(result.resultSummary == nil && result.resultConsumer == nil)
        let preparation = try #require(result.resultPreparation)
        let probe = try #require(preparation.probe)
        #expect(probe.observation.termination == RunTermination(kind: .exit, value: 0))
        #expect(probe.rawCapture.captureComplete)
        #expect(result.rawCaptures.count == 3)
        try preparation.revalidateForPublication()
        #expect(result.publicationFailures.isEmpty)
        let saved = try NotikaBuildSessionReport(data: Data(contentsOf: fixture.manifestURL))
        #expect(saved.nativeTermination == result.nativeTermination && saved.exitCode == result.exitCode)
        let report = try StrictJSONDocument(data: saved.originalData).root.requireObject()
        #expect(report.value(forKey: "resultEvidence") == .null)
        let refused = try report.requiredValue(forKey: "resultPreparation").requireObject()
        let recorded = try refused.requiredValue(forKey: "probe").requireObject()
        #expect(recorded.value(forKey: "publicationAdmitted") == .bool(false))
        #expect(recorded.value(forKey: "commandAdmission") == .string("diagnostic"))
    }
}

private struct CoordinatorFixture: Sendable {
    let root: String
    let repository: String
    let registry: String
    let compilationRegistry: String
    let capture: CoordinatorIdentityCapture
    let runID = UUID().uuidString

    init(mode: CoordinatorIdentityCapture.Mode = .ordinary) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("notika-build-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        guard let pointer = realpath(temporary.path, nil) else { throw CoordinatorFixtureError.setup }
        defer { free(pointer) }
        root = String(cString: pointer)
        repository = root + "/repository"
        registry = root + "/project-registry"
        compilationRegistry = root + "/compilation-registry"
        for directory in [repository, repository + "/Notika.xcodeproj",
                          repository + "/Notika.xcworkspace/xcshareddata/swiftpm"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try Data("graph fixture\n".utf8).write(to: URL(fileURLWithPath: repository + "/Project.swift"))
        try Data("{\"objects\":{}}".utf8).write(to: URL(fileURLWithPath: repository + "/Notika.xcodeproj/project.pbxproj"))
        try Data("{\"pins\":[],\"version\":3}".utf8).write(to: URL(fileURLWithPath: repository + "/Notika.xcworkspace/xcshareddata/swiftpm/Package.resolved"))
        capture = CoordinatorIdentityCapture(repository: repository, mode: mode)
    }

    var helper: String {
        AgentBuildTestPaths.packageRoot.appendingPathComponent(".build/debug/agentbuild").path
    }
    var sessionPath: String { repository + "/Artifacts/AgentSessions/" + runID }
    var manifestURL: URL { URL(fileURLWithPath: sessionPath + "/manifest.json") }
    var environment: [String: String] {
        ["PATH": "/usr/bin:/bin", "AGENTLEASE_COMPILE_HOME": compilationRegistry]
    }
    var macUIEnvironment: [String: String] {
        environment.merging(["SIMLEASE_HOME": root, "SIMLEASE_MACOS_UI": "1",
            "SIMLEASE_HOST_RESOURCE": "macos-ui", "SIMLEASE_SESSION_ID": runID,
            "HOME": root + "/untrusted-home"]) { _, selected in selected }
    }

    func openMacUIHost() throws -> Int32 {
        try FileManager.default.createDirectory(atPath: root + "/host-locks", withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let descriptor = open(root + "/host-locks/macos-ui.lock", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CoordinatorFixtureError.setup }
        guard fcntl(descriptor, F_SETFD, 0) == 0, fchmod(descriptor, 0o600) == 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw CoordinatorFixtureError.setup
        }
        return descriptor
    }
    func remove() { try? FileManager.default.removeItem(atPath: root) }

    func coordinator(_ native: @escaping NotikaBuildCoordinator.NativeOperation,
                     summary: NotikaBuildCoordinator.SummaryOperation? = nil,
                     preparation: NotikaBuildCoordinator.SummaryOperation? = nil,
                     preflight: NotikaBuildCoordinator.PreflightOperation? = nil,
                     maintenance: NotikaBuildCoordinator.MaintenanceOperation? = nil,
                     prepareResultIndexes: Bool = false) -> NotikaBuildCoordinator {
        NotikaBuildCoordinator(identityCapture: capture, nativeOperation: native, summaryOperation: summary,
            preparationOperation: preparation, preflightOperation: preflight, maintenanceOperation: maintenance,
            prepareFixtureResultIndexes: prepareResultIndexes)
    }

    func run(_ coordinator: NotikaBuildCoordinator, environment: [String: String]? = nil,
             waitSeconds: Double? = 2, request: NotikaActionRequest? = nil) async throws -> NotikaBuildCoordinatorResult {
        try await coordinator.run(repository: repository,
            request: request ?? NotikaActionRequest(makeRoute: .buildMacOS), helperExecutable: helper,
            registryRoot: registry, environment: environment ?? self.environment,
            waitSeconds: waitSeconds, runID: runID)
    }

    func worker(_ helper: String, descriptors: [Int32], root: String, directory: Int32,
                script: String, environment: [String: String]? = nil) async throws -> CapturedNativePhase {
        #expect(FileManager.default.isExecutableFile(atPath: helper))
        return try await CapturedNativePhaseRunner().run(helperExecutable: helper,
            command: DarwinWorkloadCommand(executable: "/bin/sh", arguments: ["-c", script],
                workingDirectory: repository, environment: environment ?? ["PATH": "/usr/bin:/bin"]),
            retainedLockDescriptors: descriptors, nativeWorkingDirectoryDescriptor: directory, artifactRoot: root)
    }

    func createResultScript(exitCode: Int32 = 0) -> String {
        "mkdir '\(sessionPath)/result.xcresult'; printf fixture > '\(sessionPath)/result.xcresult/evidence'; exit \(exitCode)"
    }

    func summaryWorker(_ helper: String, command: DarwinWorkloadCommand, descriptors: [Int32],
                       root: String, directory: Int32, passed: Int, exitCode: Int32 = 0) async throws -> CapturedNativePhase {
        let output = "{\"result\":\"Passed\",\"passedTests\":\(passed),\"failedTests\":0,\"skippedTests\":0,\"totalTestCount\":\(passed)}"
        return try await CapturedNativePhaseRunner().run(helperExecutable: helper,
            command: DarwinWorkloadCommand(executable: "/bin/sh",
                arguments: ["-c", "printf '%s' '\(output)'; exit \(exitCode)"],
                workingDirectory: command.workingDirectory, environment: command.environment),
            retainedLockDescriptors: descriptors, nativeWorkingDirectoryDescriptor: directory, artifactRoot: root)
    }

    func acquire(_ resource: String, compilation: Bool = false) throws -> FileLock {
        let paths = try AgentLeasePaths.open(selectedRoot: compilation ? compilationRegistry : registry)
        let lock = try FileLock(resource: ResourceName(resource), paths: paths)
        guard try lock.tryAcquire() else { throw CoordinatorFixtureError.setup }
        return lock
    }

    func available(_ resource: String, compilation: Bool = false) throws -> Bool {
        let paths = try AgentLeasePaths.open(selectedRoot: compilation ? compilationRegistry : registry)
        let lock = try FileLock(resource: ResourceName(resource), paths: paths)
        defer { lock.release() }
        return try lock.tryAcquire()
    }

    func expectAllOwnersHeld(cache: String, compilationHeld: Bool = true) throws {
        for resource in try ownerResources(cache: cache) { #expect(try !available(resource)) }
        #expect(try available("host:compile", compilation: true) == !compilationHeld)
    }

    func expectOwnersReleased(cache: String) async throws {
        try await coordinatorWaitUntil {
            try ownerResources(cache: cache).allSatisfy { try available($0) }
                && available("host:compile", compilation: true)
        }
    }

    private func ownerResources(cache: String) throws -> [String] {
        ["notika:sessions:" + repository,
         try CacheCompatibilityIdentity.graphResourceName(canonicalWorktree: repository),
         try CacheCompatibilityIdentity.cachePolicyResourceName(canonicalWorktree: repository),
         try CacheCompatibilityIdentity.cacheResourceName(canonicalWorktree: repository, canonicalCachePath: cache)]
    }
}

private final class CoordinatorIdentityCapture: RepositoryCommandCapturing {
    enum Mode: Sendable { case ordinary, changeCompatibilityOnSecondSource, failFinalSource, transientOrdinarySource }
    private struct State { var sourceCount = 0; var changed = false; var cancelledCalls = 0 }
    private let state = Mutex(State())
    private let repository: String
    private let mode: Mode

    init(repository: String, mode: Mode) { self.repository = repository; self.mode = mode }
    var sourceCount: Int { state.withLock { $0.sourceCount } }
    var cancelledCaptureCalls: Int { state.withLock { $0.cancelledCalls } }
    func changeOrdinarySource() { state.withLock { $0.changed = true } }

    func capture(arguments: [String], workingDirectory: String, environment: [String: String]) async throws -> Data {
        if Task.isCancelled { state.withLock { $0.cancelledCalls += 1 }; throw CancellationError() }
        if arguments == ["git", "rev-parse", "HEAD"] {
            let ordinal = state.withLock { $0.sourceCount += 1; return $0.sourceCount }
            if mode == .changeCompatibilityOnSecondSource && ordinal == 2 {
                try Data("changed graph\n".utf8).write(to: URL(fileURLWithPath: repository + "/Project.swift"))
            }
            if mode == .failFinalSource && ordinal >= 3 { throw RepositoryCaptureError.outputLimitExceeded }
            return Data((String(repeating: "a", count: 40) + "\n").utf8)
        }
        if arguments == ["git", "rev-parse", "--show-toplevel"] { return Data((repository + "\n").utf8) }
        if arguments.starts(with: ["git", "status"]) {
            return state.withLock {
                $0.changed || (mode == .transientOrdinarySource && $0.sourceCount == 2)
                    ? Data("1 fixture changed\0".utf8) : Data()
            }
        }
        if arguments.first == "git" { return Data() }
        if arguments.first == "/usr/bin/plutil" { return Data("{\"objects\":{}}".utf8) }
        if arguments == ["xcodebuild", "-version"] { return Data("Xcode fixture\n".utf8) }
        if arguments == ["swift", "--version"] { return Data("Swift fixture\n".utf8) }
        if arguments.first == "xcrun" { return Data("27.0\n".utf8) }
        if arguments == [repository + "/Scripts/tuist", "version"] { return Data("4.210.0\n".utf8) }
        throw CoordinatorFixtureError.unexpectedCapture(arguments)
    }
}

private enum CoordinatorFixtureError: Error { case setup, deadline, maintenance, unexpectedExecution, unexpectedCapture([String]) }

private func rawCacheDirectory(_ report: NotikaBuildSessionReport) throws -> String {
    let root = try StrictJSONDocument(data: report.originalData).root.requireObject()
    guard case .array(let phases) = try root.requiredValue(forKey: "physicalPlan"),
          let phase = phases.first,
          case .array(let arguments) = try phase.requireObject().requiredValue(forKey: "arguments"),
          arguments.count > 1, case .string(let directory) = arguments[1] else {
        throw CoordinatorFixtureError.setup
    }
    return directory
}

private func coordinatorWaitUntil(_ condition: () throws -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while clock.now < deadline {
        if try condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw CoordinatorFixtureError.deadline
}
