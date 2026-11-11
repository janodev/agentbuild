@testable import AgentBuildCore
import AgentBuildTestSupport
import AgentLeaseCore
import CryptoKit
import Darwin
import Foundation
@testable import GunshipAdapter
import Testing

@Suite("Gunship native command planning")
struct GunshipProjectPlanTests {
    @Test(arguments: [
        (GunshipProjectAction.build, "Gunship", "Shipping", nil, nil, nil, nil),
        (.test, nil, nil, "Gunship.Zombies", nil, nil, nil),
        (.package, nil, "Shipping", nil, "/Game/Gunship/Maps/L_Defense_Blockout+/Game/Gunship/Maps/L_Apron", "/fixture/Archive", nil),
        (.validate, nil, nil, nil, nil, "/fixture/Archive", "zombies"),
    ] as [(GunshipProjectAction, String?, String?, String?, String?, String?, String?)])
    func closedRequestsAcceptTheirOwnOptions(
        _ action: GunshipProjectAction, _ target: String?, _ configuration: String?, _ filter: String?,
        _ map: String?, _ archive: String?, _ scenario: String?
    ) throws {
        let request = try GunshipProjectRequest(repository: "/fixture/Gunship", action: action, target: target,
            configuration: configuration, testFilter: filter, map: map, archive: archive, scenario: scenario)
        #expect(request.needsOuterLease == (action == .validate))
        #expect(request.usesEngine == (action != .validate))
    }

    @Test func testsDefaultToTheProjectFilterAndBuildsToTheEditor() throws {
        #expect(try GunshipProjectRequest(repository: "/fixture/Gunship", action: .test).testFilter == "Gunship")
        #expect(try GunshipProjectRequest(repository: "/fixture/Gunship", action: .build).target == "GunshipEditor")
    }

    @Test(arguments: [
        "Gunship Zombies", "Gunship;touch pwn", "$(touch pwn)", "Gunship.", "+Gunship", "Gunship++Sensor", "-Gunship",
    ])
    func testFiltersAreLiteralAutomationPaths(_ filter: String) {
        #expect(throws: GunshipProjectError.self) {
            try GunshipProjectRequest(repository: "/fixture/Gunship", action: .test, testFilter: filter)
        }
    }

    @Test(arguments: ["Game/Gunship/Maps/L_Apron", "/Game/../Secrets", "/Game/Maps/L Apron", "/Game", "/Game/Maps/L;rm"])
    func mapsAreGamePackagePaths(_ map: String) {
        #expect(throws: GunshipProjectError.self) {
            try GunshipProjectRequest(repository: "/fixture/Gunship", action: .package, map: map, archive: "/fixture/Archive")
        }
    }

    @Test(arguments: ["Zombies", "../zombies", "zombies.sh", "", "zombies macos"])
    func scenariosNameValidationScripts(_ scenario: String) {
        #expect(throws: GunshipProjectError.self) {
            try GunshipProjectRequest(repository: "/fixture/Gunship", action: .validate, archive: "/fixture/Archive", scenario: scenario)
        }
    }

    @Test func requestsRejectOptionsOutsideTheirRoute() {
        let invalid: [() throws -> GunshipProjectRequest] = [
            { try GunshipProjectRequest(repository: "/fixture/Gunship", action: .build, configuration: "Shipping") },
            { try GunshipProjectRequest(repository: "/fixture/Gunship", action: .build, target: "UnrealEditor") },
            { try GunshipProjectRequest(repository: "/fixture/Gunship", action: .build, archive: "/fixture/Archive") },
            { try GunshipProjectRequest(repository: "/fixture/Gunship", action: .test, archive: "/fixture/Archive") },
            { try GunshipProjectRequest(repository: "/fixture/Gunship", action: .package) },
            { try GunshipProjectRequest(repository: "/fixture/Gunship", action: .package, archive: "relative/Archive") },
            { try GunshipProjectRequest(repository: "/fixture/Gunship", action: .package, archive: "/fixture/../Archive") },
            { try GunshipProjectRequest(repository: "/fixture/Gunship", action: .validate, archive: "/fixture/Archive") },
            { try GunshipProjectRequest(repository: "/fixture/Gunship", action: .validate, configuration: "Shipping",
                                        archive: "/fixture/Archive", scenario: "zombies") },
            { try GunshipProjectRequest(repository: "relative", action: .build) },
        ]
        for request in invalid { #expect(throws: GunshipProjectError.self) { try request() } }
    }

    @Test func packageCompilesBothTargetsBeforeAnUncompiledPackagePhase() async throws {
        let fixture = try await GunshipFixture()
        defer { fixture.remove() }
        let request = try GunshipProjectRequest(repository: fixture.repository, action: .package,
            configuration: "Shipping", map: "/Game/Gunship/Maps/L_Defense_Blockout", archive: fixture.archive)
        let plan = try await GunshipProjectPlanner.plan(request: request, environment: fixture.environment)

        #expect(plan.phases.map(\.step) == ["build-GunshipEditor", "build-Gunship", "package"])
        #expect(plan.phases.map(\.requiresCompilation) == [true, true, false])
        #expect(plan.phases[1].environment["GUNSHIP_CONFIGURATION"] == "Shipping")
        let package = plan.phases[2]
        #expect(package.arguments == ["-f", fixture.repository + "/Scripts/package_macos.sh"])
        #expect(package.environment["GUNSHIP_SKIP_BUILD"] == "1")
        #expect(package.environment["GUNSHIP_ARCHIVE_DIR"] == fixture.archive)
        #expect(package.environment["GUNSHIP_MAP"] == "/Game/Gunship/Maps/L_Defense_Blockout")
        #expect(package.environment["GUNSHIP_UNREAL_ENGINE"] == fixture.engine)
        #expect(plan.productPath == fixture.archive + "/Mac/Gunship-Mac-Shipping.app")
        #expect(plan.resources == [
            GunshipLeaseRequirement(resource: "gunship:sessions:" + fixture.repository, exclusive: false),
            GunshipLeaseRequirement(resource: "gunship:workspace:" + fixture.repository, exclusive: true),
            GunshipLeaseRequirement(resource: "gunship:archive:" + fixture.archive, exclusive: true),
        ])
        #expect(plan.toolIdentity["engineVersion"] == "5.8.3-58210709")
        #expect(!plan.needsOuterLease)
        #expect(!plan.admissionEstablished)
        // Planning is read-only.
        #expect(!FileManager.default.fileExists(atPath: fixture.repository + "/Artifacts"))
        #expect(!FileManager.default.fileExists(atPath: fixture.archive))
    }

    @Test func testsRunAutomationWithTheFilterOutsideCompilation() async throws {
        let fixture = try await GunshipFixture()
        defer { fixture.remove() }
        let request = try GunshipProjectRequest(repository: fixture.repository, action: .test,
                                                testFilter: "Gunship.Zombies+Gunship.Sensor")
        var environment = fixture.environment
        environment[GunshipProjectPlanner.sessionEnvironmentKey] = fixture.directory.path + "/session"
        let plan = try await GunshipProjectPlanner.plan(request: request, environment: environment)

        #expect(plan.phases.map(\.requiresCompilation) == [true, false])
        #expect(plan.phases[1].environment["GUNSHIP_TEST_FILTER"] == "Gunship.Zombies+Gunship.Sensor")
        #expect(plan.phases[1].environment["GUNSHIP_TEST_REPORT_DIR"] == fixture.directory.path + "/session/Automation")
        #expect(plan.productPath == nil)
    }

    @Test func archiveSpellingsThroughSymlinksShareOneLease() async throws {
        let fixture = try await GunshipFixture()
        defer { fixture.remove() }
        let real = fixture.directory.path + "/Packaged"
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: fixture.directory.path + "/Link", withDestinationPath: real)
        let request = try GunshipProjectRequest(repository: fixture.repository, action: .package,
                                                archive: fixture.directory.path + "/Link/Horde")
        let plan = try await GunshipProjectPlanner.plan(request: request, environment: fixture.environment)
        #expect(plan.archive == real + "/Horde")
        #expect(plan.resources.last?.resource == "gunship:archive:" + real + "/Horde")
    }

    @Test func archivesCannotContainTheProject() async throws {
        let fixture = try await GunshipFixture()
        defer { fixture.remove() }
        let request = try GunshipProjectRequest(repository: fixture.repository, action: .package,
                                                archive: fixture.directory.path)
        await #expect(throws: GunshipProjectError.self) {
            try await GunshipProjectPlanner.plan(request: request, environment: fixture.environment)
        }
    }

    @Test func compiledRoutesRequireAnEngine() async throws {
        let fixture = try await GunshipFixture()
        defer { fixture.remove() }
        var environment = fixture.environment
        environment.removeValue(forKey: GunshipProjectPlanner.engineEnvironmentKey)
        await #expect(throws: GunshipProjectError.invalidEngine("pass --engine or set GUNSHIP_UNREAL_ENGINE")) {
            try await GunshipProjectPlanner.plan(request: GunshipProjectRequest(repository: fixture.repository, action: .build),
                                                 environment: environment)
        }
    }

    @Test func sessionsMustBeIgnoredByGit() async throws {
        let fixture = try await GunshipFixture(ignoresSessions: false)
        defer { fixture.remove() }
        await #expect(throws: GunshipProjectError.self) {
            try await GunshipProjectPlanner.plan(request: GunshipProjectRequest(repository: fixture.repository, action: .build),
                                                 environment: fixture.environment)
        }
    }

    @Test func validationNeedsAPackagedGameAndTheDesktopButNoEngine() async throws {
        let fixture = try await GunshipFixture()
        defer { fixture.remove() }
        var environment = fixture.environment
        environment.removeValue(forKey: GunshipProjectPlanner.engineEnvironmentKey)
        let request = try GunshipProjectRequest(repository: fixture.repository, action: .validate,
                                                archive: fixture.archive, scenario: "zombies")
        await #expect(throws: GunshipProjectError.self) {
            try await GunshipProjectPlanner.plan(request: request, environment: environment)
        }
        try fixture.installGame()
        let plan = try await GunshipProjectPlanner.plan(request: request, environment: environment)
        #expect(plan.engine == nil)
        #expect(plan.toolIdentity.isEmpty)
        #expect(plan.needsOuterLease)
        #expect(plan.phases.map(\.step) == ["validate-zombies"])
        #expect(plan.phases[0].arguments == ["-f", fixture.repository + "/Scripts/validate_zombies_macos.sh"])
        #expect(plan.phases[0].requiresCompilation == false)
        #expect(!plan.resources.contains { $0.resource.hasPrefix("gunship:workspace:") })
        #expect(throws: GunshipProjectDriverError.self) {
            try GunshipLeaseBoundary.admit(request: request, environment: [:])
        }
        try GunshipLeaseBoundary.admit(request: request, environment: GunshipFixture.desktopLease)
    }

    @Test func automationReportsAreReadThroughTheirByteOrderMark() throws {
        let report = Data([0xEF, 0xBB, 0xBF]) + Data(#"""
        {"succeeded":2,"succeededWithWarnings":1,"failed":1,"notRun":0,
         "tests":[{"fullTestPath":"Gunship.B","state":"Fail"},{"fullTestPath":"Gunship.A","state":"Success"}]}
        """#.utf8)
        let summary = try GunshipAutomationSummary.parse(report)
        #expect(summary.succeeded == 2 && summary.succeededWithWarnings == 1 && summary.failed == 1)
        #expect(summary.failedTests == ["Gunship.B"])
        #expect(!summary.passed)
        #expect(throws: GunshipProjectDriverError.self) { try GunshipAutomationSummary.parse(Data("{}".utf8)) }
    }
}

@Suite("Gunship owned execution", .serialized)
struct GunshipProjectDriverTests {
    @Test func testsCompileThenRunAutomationAndRetainCounts() async throws {
        let fixture = try await GunshipFixture()
        defer { fixture.remove() }
        let result = try await GunshipProjectDriver().run(
            request: GunshipProjectRequest(repository: fixture.repository, action: .test, testFilter: "Gunship.Zombies"),
            helperExecutable: fixture.helper, environment: fixture.environment, waitSeconds: 30)
        let report = try fixture.report(result)

        #expect(result.status == "succeeded", fixture.comment(result))
        #expect(result.exitCode == 0)
        #expect(result.automation?.succeeded == 3)
        #expect(result.automation?.passed == true)
        #expect(result.rawCaptures.count == 2 && result.rawCaptures.allSatisfy(\.captureComplete))
        let phases = try #require(report["phases"] as? [[String: Any]])
        #expect(phases.map { $0["step"] as? String } == ["build-GunshipEditor", "automation"])
        #expect(phases.map { $0["compilation"] as? Bool } == [true, false])
        #expect(phases.allSatisfy { $0["retirementScope"] as? String == "session" })
        #expect(report["sourceDrift"] as? Bool == false)
        #expect(report["toolDrift"] as? Bool == false)
        let session = try #require(result.sessionPath)
        #expect(session.hasPrefix(fixture.repository + "/Artifacts/AgentSessions/"))
        let persisted = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: session + "/manifest.json"))) as? [String: Any])
        #expect(persisted["status"] as? String == "succeeded")
        #expect(persisted["namespace"] as? String == "agentbuild.gunship")
    }

    @Test func failingAutomationKeepsTheNativeStatusAndFailedTestNames() async throws {
        let fixture = try await GunshipFixture(failingTests: true)
        defer { fixture.remove() }
        let result = try await GunshipProjectDriver().run(
            request: GunshipProjectRequest(repository: fixture.repository, action: .test),
            helperExecutable: fixture.helper, environment: fixture.environment, waitSeconds: 30)
        #expect(result.status == "failed", fixture.comment(result))
        #expect(result.exitCode == 1)
        #expect(result.automation?.failedTests == ["Gunship.Example.Fails"])
    }

    @Test func packageSkipsTheScriptBuildAndRecordsTheProduct() async throws {
        let fixture = try await GunshipFixture()
        defer { fixture.remove() }
        let result = try await GunshipProjectDriver().run(
            request: GunshipProjectRequest(repository: fixture.repository, action: .package, archive: fixture.archive),
            helperExecutable: fixture.helper, environment: fixture.environment, waitSeconds: 30)
        let report = try fixture.report(result)
        #expect(result.status == "succeeded", fixture.comment(result))
        #expect(result.productPath == fixture.archive + "/Mac/Gunship.app")
        let expected = SHA256.hash(data: Data("packaged game\n".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(report["productExecutableSHA256"] as? String == expected)
        let phases = try #require(report["phases"] as? [[String: Any]])
        #expect(phases.map { $0["compilation"] as? Bool } == [true, true, false])
    }

    @Test func sourceChangesDuringABuildMakeItInconclusive() async throws {
        let fixture = try await GunshipFixture(buildEditsSource: true)
        defer { fixture.remove() }
        let result = try await GunshipProjectDriver().run(
            request: GunshipProjectRequest(repository: fixture.repository, action: .build),
            helperExecutable: fixture.helper, environment: fixture.environment, waitSeconds: 30)
        #expect(result.status == "inconclusive", fixture.comment(result))
        #expect(result.exitCode == 70)
        #expect(try fixture.report(result)["sourceDrift"] as? Bool == true)
    }

    @Test func validationRunsInsideTheDesktopLeaseAndReadsScenarioReports() async throws {
        let fixture = try await GunshipFixture()
        defer { fixture.remove() }
        try fixture.installGame()
        let request = try GunshipProjectRequest(repository: fixture.repository, action: .validate,
                                                archive: fixture.archive, scenario: "zombies")
        await #expect(throws: GunshipProjectDriverError.self) {
            try await GunshipProjectDriver().run(request: request, helperExecutable: fixture.helper,
                                                 environment: fixture.environment, waitSeconds: 30)
        }
        let result = try await GunshipProjectDriver().run(request: request, helperExecutable: fixture.helper,
            environment: fixture.environment.merging(GunshipFixture.desktopLease) { $1 }, waitSeconds: 30)
        #expect(result.status == "succeeded", fixture.comment(result))
        #expect(result.validationReports.count == 1)
        #expect(result.validationReports.first?.passed == true)
        #expect(result.validationReports.first?.path == "Evidence/run/Saved/Validation/Zombies/report.json")
        let report = try fixture.report(result)
        #expect(report["archiveExecutableBeforeSHA256"] as? String == report["archiveExecutableAfterSHA256"] as? String)
    }

    @Test func aRunningGameKeepsItsArchiveFromBeingReplaced() async throws {
        let fixture = try await GunshipFixture()
        defer { fixture.remove() }
        let game = try await fixture.startArchiveProcess()
        defer { game.stop() }
        let request = try GunshipProjectRequest(repository: fixture.repository, action: .package, archive: fixture.archive)
        do {
            _ = try await GunshipProjectDriver().run(request: request, helperExecutable: fixture.helper,
                                                     environment: fixture.environment, waitSeconds: 30)
            Issue.record("Packaging over a running game was admitted")
        } catch GunshipProjectDriverError.archiveInUse(let archive, let processes) {
            #expect(archive == fixture.archive)
            #expect(processes == [game.processIdentifier])
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.repository + "/Artifacts"))
    }

    @Test func aGameStartedDuringCompilationPreventsThePackagePhase() async throws {
        let fixture = try await GunshipFixture(blockGameCompile: true)
        defer { fixture.remove() }
        let request = try GunshipProjectRequest(repository: fixture.repository, action: .package, archive: fixture.archive)
        let run = Task {
            try await GunshipProjectDriver().run(request: request, helperExecutable: fixture.helper,
                                                 environment: fixture.environment, waitSeconds: 30)
        }
        do {
            try await fixture.waitForGameCompile()
            let game = try await fixture.startArchiveProcess()
            defer { game.stop() }
            try fixture.releaseGameCompile()

            let result = try await run.value
            let report = try fixture.report(result)
            let phases = try #require(report["phases"] as? [[String: Any]])
            #expect(result.status == "inconclusive", fixture.comment(result))
            #expect(result.exitCode == 70)
            #expect(result.nativeTermination == RunTermination(kind: .exit, value: 0))
            #expect(phases.map { $0["step"] as? String } == ["build-GunshipEditor", "build-Gunship"])
            #expect(result.orchestrationFailures.contains { $0.contains("archive") && $0.contains("is in use") })
            #expect(!FileManager.default.fileExists(atPath: fixture.archive + "/Mac/Gunship.app"))
            #expect(game.isRunning)
        } catch {
            run.cancel()
            try? fixture.releaseGameCompile()
            _ = await run.result
            throw error
        }
    }
}

struct GunshipFixture: Sendable {
    enum Failure: Error { case fileSystem(Int32) }
    static let desktopLease = [
        "SIMLEASE_SESSION_ID": "fixture-session", "SIMLEASE_MACOS_UI": "1", "SIMLEASE_HOST_RESOURCE": "macos-ui",
    ]
    let directory: URL
    let helper: String

    var repository: String { directory.path + "/checkout" }
    var engine: String { directory.path + "/UE_5.8" }
    var archive: String { directory.path + "/Archive" }
    var environment: [String: String] {
        [
            "PATH": directory.path + "/tools:/usr/bin:/bin",
            "AGENTLEASE_HOME": directory.path + "/registry",
            "AGENTLEASE_COMPILE_HOME": directory.path + "/registry",
            GunshipProjectPlanner.engineEnvironmentKey: engine,
        ]
    }

    init(ignoresSessions: Bool = true, failingTests: Bool = false, buildEditsSource: Bool = false,
         blockGameCompile: Bool = false) async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentbuild-gunship-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        // Retained custody requires the physical /private spelling.
        guard let canonical = temporary.path.withCString({ realpath($0, nil) }) else { throw Failure.fileSystem(errno) }
        directory = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        free(canonical)
        let sourceRoot = AgentBuildTestPaths.packageRoot
        helper = sourceRoot.appendingPathComponent(".build/debug/agentbuild").path

        try write("checkout/.gitignore", ignoresSessions ? "/Artifacts\n/Binaries\n" : "/Binaries\n")
        try write("checkout/Gunship.uproject", #"{"EngineAssociation": "5.8"}"# + "\n")
        try write("checkout/Source/Gunship.cpp", "// Original source\n")
        let edit = buildEditsSource ? "printf '%s\\n' '// Edited during build' > Source/Gunship.cpp\n" : ""
        // These gates are outside the checkout, so coordinating the fixture
        // cannot itself look like a source change.
        let gate = blockGameCompile ? """
            if [ "$1" = Gunship ]; then
                : > '\(directory.path)/game-compile-started'
                for attempt in {1..500}; do
                    [ ! -f '\(directory.path)/game-compile-release' ] || break
                    sleep 0.02
                done
                [ -f '\(directory.path)/game-compile-release' ] || exit 98
            fi
            """ : ""
        try write("checkout/Scripts/build_macos.sh", """
            [ "$GUNSHIP_UNREAL_ENGINE" = '\(engine)' ] || exit 96
            [ "$1" = Gunship ] || [ -z "${GUNSHIP_CONFIGURATION:-}" ] || exit 95
            \(gate)
            \(edit)printf 'Fixture compiled %s\\n' "$1"
            """)
        let report = failingTests
            ? #"{"succeeded":2,"succeededWithWarnings":0,"failed":1,"notRun":0,"tests":[{"fullTestPath":"Gunship.Example.Fails","state":"Fail"}]}"#
            : #"{"succeeded":3,"succeededWithWarnings":0,"failed":0,"notRun":0,"tests":[]}"#
        try write("checkout/Scripts/test_macos.sh", """
            [ -n "$GUNSHIP_TEST_FILTER" ] || exit 94
            mkdir -p "$GUNSHIP_TEST_REPORT_DIR"
            printf '\\357\\273\\277%s' '\(report)' > "$GUNSHIP_TEST_REPORT_DIR/index.json"
            exit \(failingTests ? 1 : 0)
            """)
        try write("checkout/Scripts/package_macos.sh", """
            [ "$GUNSHIP_SKIP_BUILD" = 1 ] || exit 97
            game="$GUNSHIP_ARCHIVE_DIR/Mac/Gunship.app/Contents/MacOS"
            mkdir -p "$game"
            printf 'packaged game\\n' > "$game/Gunship"
            chmod 700 "$game/Gunship"
            """)
        try write("checkout/Scripts/validate_zombies_macos.sh", """
            [ "$SIMLEASE_MACOS_UI" = 1 ] || exit 93
            evidence="$GUNSHIP_RUN_DIR/run/Saved/Validation/Zombies"
            mkdir -p "$evidence"
            printf '%s' '{"scenario":"GunshipZombieTest","passed":true,"scenario_completed":true,"checks":[{"name":"crowd","passed":true}]}' > "$evidence/report.json"
            """)
        try write("UE_5.8/Engine/Build/Build.version",
                  #"{"MajorVersion":5,"MinorVersion":8,"PatchVersion":3,"Changelist":58210709}"#)
        try write("UE_5.8/Engine/Build/BatchFiles/Mac/Build.sh", "exit 99\n")
        try script("tools/xcode-select", #"[ "$*" = -p ] && printf '%s\n' /Fixture/Xcode/Developer"#)
        try script("tools/xcrun", #"[ "$*" = '--find xcodebuild' ] && printf '%s\n' "${0%/*}/xcodebuild""#)
        try script("tools/xcodebuild", #"[ "$*" = -version ] && printf '%s\n' 'Xcode 27.0' 'Build version Fixture'"#)

        let capture = try RepositoryCommandCapture()
        for arguments in [
            ["git", "init", "-q"], ["git", "add", "."],
            ["git", "-c", "user.name=AgentBuild Fixture", "-c", "user.email=fixture@example.invalid",
             "-c", "commit.gpgsign=false", "commit", "-qm", "Initial fixture"],
        ] {
            _ = try await capture.capture(arguments: arguments, workingDirectory: repository,
                                          environment: ["PATH": "/usr/bin:/bin"])
        }
    }

    func installGame() throws {
        try script("Archive/Mac/Gunship.app/Contents/MacOS/Gunship", "exit 0")
    }

    func waitForGameCompile() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !FileManager.default.fileExists(atPath: directory.path + "/game-compile-started") {
            try #require(ContinuousClock.now < deadline, "Fixture never entered the game compilation phase")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func releaseGameCompile() throws {
        try Data().write(to: directory.appendingPathComponent("game-compile-release"))
    }

    /// A process under the archive, without any application bundle or GUI.
    /// Replace Apple's platform signature before execution: relocating a system
    /// binary unchanged can trigger an AMFI rejection and a Gatekeeper dialog.
    func startArchiveProcess() async throws -> GunshipArchiveProcess {
        try FileManager.default.createDirectory(atPath: archive, withIntermediateDirectories: true)
        let executable = archive + "/FixtureWorker"
        try FileManager.default.copyItem(atPath: "/bin/cat", toPath: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable)
        let capture = try RepositoryCommandCapture()
        for arguments in [
            ["/usr/bin/codesign", "--remove-signature", executable],
            ["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", "dev.jano.agentbuild.gunship-fixture", executable],
            ["/usr/bin/codesign", "--verify", "--strict", executable],
        ] {
            _ = try await capture.capture(arguments: arguments, workingDirectory: directory.path,
                                          environment: ["PATH": "/usr/bin:/bin"])
        }

        let input = Pipe(), output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForReading.close()
        try output.fileHandleForWriting.close()
        let worker = GunshipArchiveProcess(process: process, input: input.fileHandleForWriting)
        var ready = false
        defer {
            try? output.fileHandleForReading.close()
            if !ready { worker.stop() }
        }
        let marker = Data("READY\n".utf8)
        try input.fileHandleForWriting.write(contentsOf: marker)
        var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        var result: Int32
        repeat { result = poll(&descriptor, 1, 5_000) } while result < 0 && errno == EINTR
        try #require(result > 0, "Archive fixture did not acknowledge startup")
        let acknowledgement = try output.fileHandleForReading.read(upToCount: marker.count)
        try #require(acknowledgement == marker,
                     "Archive fixture failed before executing its readiness handshake")
        try #require(process.isRunning, "Archive fixture exited before the guard could observe it")
        ready = true
        return worker
    }

    func report(_ result: GunshipProjectResult) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: result.jsonData()) as? [String: Any])
    }

    func comment(_ result: GunshipProjectResult) -> Comment {
        Comment(rawValue: (try? String(decoding: result.jsonData(), as: UTF8.self)) ?? "unavailable report")
    }

    private func write(_ relative: String, _ contents: String) throws {
        let file = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data(contents.utf8).write(to: file)
    }

    private func script(_ relative: String, _ body: String) throws {
        try write(relative, "#!/bin/sh\nset -eu\n" + body + "\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: directory.appendingPathComponent(relative).path)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

final class GunshipArchiveProcess {
    private let process: Process
    private let input: FileHandle

    init(process: Process, input: FileHandle) {
        self.process = process
        self.input = input
    }

    var processIdentifier: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    func stop() {
        try? input.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
}
