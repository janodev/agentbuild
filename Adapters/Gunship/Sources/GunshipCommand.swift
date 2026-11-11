import AgentBuildCLISupport
import AgentBuildCore
import ArgumentParser
import Foundation

package struct GunshipCommand: AsyncParsableCommand {
    package init() {}

    package static let configuration = CommandConfiguration(
        commandName: "gunship",
        abstract: "Build, test, package, and validate the Gunship Unreal project with owned native execution.",
        subcommands: [GunshipPlanCommand.self, GunshipBuildCommand.self, GunshipTestCommand.self,
                      GunshipPackageCommand.self, GunshipValidateCommand.self]
    )
}

private struct GunshipCommonOptions: ParsableArguments {
    @Option(help: "Absolute path to the Gunship project root.")
    var repository: String

    @Option(help: "Absolute Unreal Engine root; defaults to GUNSHIP_UNREAL_ENGINE.")
    var engine: String?

    @Option(help: "Absolute AgentLease registry override for this project.")
    var leaseHome: String?

    @Option(help: "Maximum seconds to wait at an ownership boundary.")
    var waitSeconds: Double?

    @Flag(help: "Print the final JSON report.")
    var json = false

    func environment() throws -> [String: String] {
        guard repository.hasPrefix("/"), !repository.utf8.contains(0) else {
            throw ValidationError("--repository must be an absolute project path.")
        }
        if let waitSeconds, !waitSeconds.isFinite || waitSeconds < 0 {
            throw ValidationError("--wait-seconds must be finite and nonnegative.")
        }
        var values = ProcessInfo.processInfo.environment
        if let engine {
            guard engine.hasPrefix("/"), !engine.utf8.contains(0) else {
                throw ValidationError("--engine must be an absolute engine path.")
            }
            values[GunshipProjectPlanner.engineEnvironmentKey] = engine
        }
        if let leaseHome {
            guard leaseHome.hasPrefix("/"), !leaseHome.utf8.contains(0) else {
                throw ValidationError("--lease-home must be an absolute registry path.")
            }
            values["AGENTLEASE_HOME"] = leaseHome
        }
        return values
    }
}

private struct GunshipRouteOptions: ParsableArguments {
    @Option(help: "build: GunshipEditor (default) or Gunship.")
    var target: String?

    @Option(help: "Development (default) or Shipping; Shipping applies to the game target and package.")
    var configuration: String?

    @Option(help: "test: automation paths joined by +, such as Gunship.Zombies+Gunship.Sensor (default Gunship).")
    var filter: String?

    @Option(help: "package: /Game paths joined by +; validate: one map (slice uses L_Apron and rejects overrides).")
    var map: String?

    @Option(help: "package/validate: absolute archive directory that holds Mac/Gunship.app.")
    var archive: String?

    @Option(help: "validate: runs Scripts/validate_<scenario>_macos.sh; slice runs validate_macos.sh.")
    var scenario: String?

    func request(repository: String, action: GunshipProjectAction) throws -> GunshipProjectRequest {
        do {
            return try GunshipProjectRequest(repository: repository, action: action, target: target,
                configuration: configuration, testFilter: filter, map: map, archive: archive, scenario: scenario)
        } catch { throw ValidationError(String(describing: error)) }
    }
}

struct GunshipPlanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plan",
        abstract: "Inspect Gunship inputs and native phases without ownership or execution."
    )
    @OptionGroup private var common: GunshipCommonOptions
    @OptionGroup private var route: GunshipRouteOptions
    @Option(help: "build, test, package, or validate.")
    var action: String = "build"

    mutating func run() async throws {
        guard let selected = GunshipProjectAction(rawValue: action) else {
            throw ValidationError("--action must be build, test, package, or validate.")
        }
        let plan = try await GunshipProjectDriver().plan(
            request: try route.request(repository: common.repository, action: selected),
            environment: try common.environment())
        // A plan is always explicitly marked unowned, including human output.
        print(String(decoding: try plan.jsonData(), as: UTF8.self))
    }
}

struct GunshipBuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Compile the editor or game target under host:compile and retain raw logs."
    )
    @OptionGroup private var common: GunshipCommonOptions
    @OptionGroup private var route: GunshipRouteOptions

    mutating func run() async throws {
        try await executeGunship(try route.request(repository: common.repository, action: .build), common: common)
    }
}

struct GunshipTestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test",
        abstract: "Compile the editor, then run headless automation after releasing host:compile."
    )
    @OptionGroup private var common: GunshipCommonOptions
    @OptionGroup private var route: GunshipRouteOptions

    mutating func run() async throws {
        try await executeGunship(try route.request(repository: common.repository, action: .test), common: common)
    }
}

struct GunshipPackageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "package",
        abstract: "Compile both targets, then cook and package after releasing host:compile."
    )
    @OptionGroup private var common: GunshipCommonOptions
    @OptionGroup private var route: GunshipRouteOptions

    mutating func run() async throws {
        try await executeGunship(try route.request(repository: common.repository, action: .package), common: common)
    }
}

struct GunshipValidateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Run a packaged gameplay scenario inside one SimLease macOS UI boundary."
    )
    @OptionGroup private var common: GunshipCommonOptions
    @OptionGroup private var route: GunshipRouteOptions

    mutating func run() async throws {
        try await executeGunship(try route.request(repository: common.repository, action: .validate), common: common)
    }
}

private enum GunshipExecutionEvent: Sendable {
    case completed(Result<GunshipProjectResult, any Error>)
    case signal(Int32?)
}

private func executeGunship(_ request: GunshipProjectRequest, common: GunshipCommonOptions) async throws {
    let environment = try common.environment()
    let executable = try currentAgentBuildExecutable()
    try GunshipLeaseBoundary.reexecuteIfRequired(request: request, environment: environment,
        executable: executable, arguments: Array(CommandLine.arguments.dropFirst()), label: "Gunship validation")
    let relay = try SignalRelay()
    defer { relay.restore() }
    let waitSeconds = common.waitSeconds
    let completed: Result<GunshipProjectResult, any Error> = await withTaskGroup(of: GunshipExecutionEvent.self) { group in
        group.addTask {
            do {
                return .completed(.success(try await GunshipProjectDriver().run(request: request,
                    helperExecutable: executable, environment: environment, waitSeconds: waitSeconds,
                    cancellationSignal: { relay.firstSignal })))
            } catch { return .completed(.failure(error)) }
        }
        group.addTask { .signal(await relay.nextSignal()) }
        var result: Result<GunshipProjectResult, any Error>?
        while let event = await group.next() {
            switch event {
            case .completed(let value): result = value; group.cancelAll()
            case .signal(let number): if number != nil { group.cancelAll() }
            }
        }
        return result ?? .failure(CancellationError())
    }
    let result: GunshipProjectResult
    do { result = try completed.get() }
    catch {
        gunshipWriteError("Gunship development failed: \(error)")
        throw ExitCode(relay.firstSignal.map { 128 + $0 } ?? (error is CancellationError ? 130 : 70))
    }
    let data = try result.jsonData()
    if common.json { print(String(decoding: data, as: UTF8.self)) }
    else {
        print("Gunship \(request.action.rawValue): \(result.status) (status \(result.exitCode))")
        if let path = result.sessionPath { print("Session: \(path)") }
        if let path = result.productPath, result.exitCode == 0 { print("Product: \(path)") }
        if let tests = result.automation {
            print("Automation: \(tests.succeeded) passed, \(tests.succeededWithWarnings) with warnings, "
                + "\(tests.failed) failed, \(tests.notRun) not run")
            for name in tests.failedTests { gunshipWriteError("FAIL \(name)") }
        }
        for report in result.validationReports {
            print("Validation: \(report.passed ? "PASS" : "FAIL") \(report.scenario ?? "scenario"), "
                + "\(report.checks) checks; \(report.path)")
            for name in report.failedChecks { gunshipWriteError("FAIL \(name)") }
        }
        if let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if fields["sourceDrift"] as? Bool == true {
                gunshipWriteError("Source changes observed during this run; see the session manifest.")
            }
            if fields["toolDrift"] as? Bool == true {
                gunshipWriteError("Toolchain observations changed during this run; see the session manifest.")
            }
        }
        for message in result.orchestrationFailures + result.publicationFailures { gunshipWriteError(message) }
    }
    if result.exitCode != 0 { throw ExitCode(result.exitCode) }
}

private func gunshipWriteError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
