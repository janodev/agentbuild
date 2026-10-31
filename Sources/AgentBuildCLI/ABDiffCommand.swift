import AgentBuildCore
import ArgumentParser
import Darwin
import Foundation
import MachO

struct ABDiffCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "abdiff",
        abstract: "Build, test, generate, and run ABDiff with owned native execution.",
        subcommands: [ABDiffPlanCommand.self, ABDiffBuildCommand.self, ABDiffGenerateCommand.self, ABDiffRunCommand.self, ABDiffInstallCommand.self]
    )
}

private struct ABDiffCommonOptions: ParsableArguments {
    @Option(help: "Absolute path to the ABDiff Git worktree root.")
    var repository: String

    @Option(help: "Absolute AgentLease registry override for this worktree.")
    var leaseHome: String?

    @Option(help: "Maximum seconds to wait at an ownership boundary.")
    var waitSeconds: Double?

    @Flag(help: "Print the final JSON report.")
    var json = false

    func environment() throws -> [String: String] {
        guard repository.hasPrefix("/"), !repository.utf8.contains(0) else {
            throw ValidationError("--repository must be an absolute worktree path.")
        }
        if let waitSeconds, !waitSeconds.isFinite || waitSeconds < 0 {
            throw ValidationError("--wait-seconds must be finite and nonnegative.")
        }
        var values = ProcessInfo.processInfo.environment
        if let leaseHome {
            guard leaseHome.hasPrefix("/"), !leaseHome.utf8.contains(0) else {
                throw ValidationError("--lease-home must be an absolute registry path.")
            }
            values["AGENTLEASE_HOME"] = leaseHome
        }
        return values
    }
}

private struct ABDiffNativeOptions: ParsableArguments {
    @Option(help: "Closed build/test route, such as build, test-unit-file, or test-ui-file.")
    var route = "build"

    @Option(help: "macos, ipad-simulator, or ipad-device (build/install only).")
    var platform = "macos"

    @Option(name: .customLong("configuration"), help: "Debug, DebugUITests, or Release; tests default to DebugUITests.")
    var buildConfiguration: String?

    @Option(help: "Focused test class where the route accepts one.")
    var file: String?

    @Option(help: "Focused test method where the route accepts one.")
    var method: String?

    @Option(name: .customLong("only-testing"), help: "Repeat a literal test class or method selector.")
    var onlyTesting: [String] = []

    @Option(help: "iPad Simulator model, or explicit hardware UDID for ipad-device.")
    var device: String?

    @Option(name: .customLong("allow-source-change"), help: "Allow content changes to an exact repository-relative regular file; repeat for additional files. Changes remain recorded in the report.")
    var allowedSourceChanges: [String] = []

    func request(repository: String, action: ABDiffProjectAction) throws -> ABDiffProjectRequest {
        do {
            return try ABDiffProjectRequest(repository: repository, action: action, route: route,
                platform: platform, configuration: buildConfiguration, file: file, method: method,
                onlyTesting: onlyTesting, device: device, allowedSourceChanges: allowedSourceChanges)
        } catch { throw ValidationError(String(describing: error)) }
    }
}

struct ABDiffPlanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plan",
        abstract: "Inspect ABDiff inputs and native phases without ownership or execution."
    )
    @OptionGroup private var common: ABDiffCommonOptions
    @OptionGroup private var native: ABDiffNativeOptions

    mutating func run() async throws {
        let environment = try common.environment()
        let request = try native.request(repository: common.repository, action: .build)
        let plan = try await ABDiffProjectDriver().plan(request: request, environment: environment)
        // A plan is always explicitly marked unowned, including human output.
        print(String(decoding: try plan.jsonData(), as: UTF8.self))
    }
}

struct ABDiffBuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Build or test ABDiff and retain native results and raw logs."
    )
    @OptionGroup private var common: ABDiffCommonOptions
    @OptionGroup private var native: ABDiffNativeOptions

    mutating func run() async throws {
        try await executeABDiff(try native.request(repository: common.repository, action: .build), common: common)
    }
}

struct ABDiffGenerateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate",
        abstract: "Generate ABDiff's Tuist workspace under exclusive graph ownership."
    )
    @OptionGroup private var common: ABDiffCommonOptions
    @Flag(help: "Set USE_CACHED_DEPENDENCIES=1 for Tuist generation.")
    var cached = false

    mutating func run() async throws {
        let request: ABDiffProjectRequest
        do { request = try ABDiffProjectRequest(repository: common.repository, action: .generate, cached: cached) }
        catch { throw ValidationError(String(describing: error)) }
        try await executeABDiff(request, common: common)
    }
}

struct ABDiffInstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Build, install, and launch ABDiff on an explicit physical iPad, then return."
    )
    @OptionGroup private var common: ABDiffCommonOptions
    @OptionGroup private var native: ABDiffNativeOptions

    mutating func run() async throws {
        try await executeABDiff(try native.request(repository: common.repository, action: .install), common: common)
    }
}

struct ABDiffRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Build and supervise the exact ABDiff app inside one SimLease workflow."
    )
    @OptionGroup private var common: ABDiffCommonOptions
    @OptionGroup private var native: ABDiffNativeOptions

    mutating func run() async throws {
        try await executeABDiff(try native.request(repository: common.repository, action: .run), common: common)
    }
}

private enum ABDiffExecutionEvent: Sendable {
    case completed(Result<ABDiffProjectResult, any Error>)
    case signal(Int32?)
}

private func executeABDiff(_ request: ABDiffProjectRequest, common: ABDiffCommonOptions) async throws {
    let environment = try common.environment()
    let executable = try abdiffCurrentExecutable()
    try ABDiffLeaseBoundary.reexecuteIfRequired(request: request, environment: environment,
        executable: executable, arguments: Array(CommandLine.arguments.dropFirst()), label: "ABDiff development")
    let relay = try SignalRelay()
    defer { relay.restore() }
    let waitSeconds = common.waitSeconds
    let completed: Result<ABDiffProjectResult, any Error> = await withTaskGroup(of: ABDiffExecutionEvent.self) { group in
        group.addTask {
            do {
                return .completed(.success(try await ABDiffProjectDriver().run(request: request,
                    helperExecutable: executable, environment: environment, waitSeconds: waitSeconds)))
            } catch { return .completed(.failure(error)) }
        }
        group.addTask { .signal(await relay.nextSignal()) }
        var result: Result<ABDiffProjectResult, any Error>?
        while let event = await group.next() {
            switch event {
            case .completed(let value): result = value; group.cancelAll()
            case .signal(let number): if number != nil { group.cancelAll() }
            }
        }
        return result ?? .failure(CancellationError())
    }
    let result: ABDiffProjectResult
    do { result = try completed.get() }
    catch {
        abdiffWriteError("ABDiff development failed: \(error)")
        throw ExitCode(relay.firstSignal.map { 128 + $0 } ?? (error is CancellationError ? 130 : 70))
    }
    let data = try result.jsonData()
    if common.json { print(String(decoding: data, as: UTF8.self)) }
    else {
        print("ABDiff: \(result.status) (status \(result.exitCode))")
        if let path = result.sessionPath { print("Session: \(path)") }
        if let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let path = fields["productPath"] as? String { print("Product: \(path)") }
            if result.exitCode != 0, fields["unexpectedSourceDrift"] as? Bool == true {
                abdiffWriteError("Unexpected source changes observed during this run; see the session manifest.")
            }
            if fields["toolDrift"] as? Bool == true {
                abdiffWriteError("Toolchain observations changed during this run; see the session manifest.")
            }
            for name in ["orchestrationFailures", "publicationFailures", "diagnostics"] {
                for message in fields[name] as? [String] ?? [] { abdiffWriteError(message) }
            }
        }
    }
    let exitCode = relay.firstSignal.map { 128 + $0 } ?? result.exitCode
    if exitCode != 0 { throw ExitCode(exitCode) }
}

private func abdiffWriteError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private func abdiffCurrentExecutable() throws -> String {
    var count: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &count)
    guard count > 0, count <= 1_048_576 else { throw ValidationError("Cannot resolve the AgentBuild executable.") }
    var bytes = [CChar](repeating: 0, count: Int(count))
    guard _NSGetExecutablePath(&bytes, &count) == 0,
          let pointer = bytes.withUnsafeBufferPointer({ realpath($0.baseAddress!, nil) }) else {
        throw ValidationError("Cannot resolve the AgentBuild executable.")
    }
    defer { free(pointer) }
    let path = String(cString: pointer)
    var metadata = stat()
    guard lstat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
          access(path, X_OK) == 0 else { throw ValidationError("AgentBuild must be an executable regular file.") }
    return path
}
