import AgentBuildCore
import ArgumentParser
import Darwin
import Foundation
import MachO

struct NotikaBuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Build or test Notika with owned native phases and retained evidence.",
        discussion: "Uses the closed Notika build/test route catalog on macOS or one leased iPad simulator. Xcode runs directly; compilation ownership is released before test execution. UI and simulator actions enter or honor one outer SimLease boundary. This command does not launch applications or generate projects."
    )

    @Option(help: "Absolute path to the Notika Git worktree root.")
    var repository: String

    @Option(help: "Closed Notika build/test route or alias, such as build-macos, test-unit-file, test-ui-file, or coverage-json.")
    var route = "build-macos"

    @Option(help: "macos-ui or ipad-simulator; defaults to the route's platform or macos-ui.")
    var platform: String?

    @Option(help: "Test class or relative coverage source file, where the route accepts it.")
    var file = ""

    @Option(help: "Focused UI method, where the route accepts it.")
    var method = ""

    @Option(help: "Selected iPad device name; defaults to Notika's explicit iPad request default.")
    var device: String?

    @Option(name: .customLong("only-testing"), help: "Repeat an exact unit class or method selector for test-unit-focused.")
    var onlyTesting: [String] = []

    @Option(help: "Absolute checkout AgentLease registry; defaults to AGENTLEASE_HOME or the worktree's .agentlease.")
    var leaseHome: String?

    @Option(help: "Maximum seconds to wait at each ownership boundary.")
    var waitSeconds: Double?

    @Flag(help: "Print only the final closed JSON result to standard output.")
    var json = false

    mutating func run() async throws {
        let request: NotikaActionRequest
        do {
            guard let selectedRoute = NotikaMakeRoute(rawValue: route),
                  NotikaBuildCoordinator.supportedCanonicalRoutes.contains(selectedRoute.canonicalRoute) else {
                throw ValidationError("Unknown or unsupported Notika native route: \(route)")
            }
            let selectedPlatform: NotikaPlatform?
            if let platform {
                guard let parsed = NotikaPlatform(rawValue: platform) else {
                    throw ValidationError("Platform must be macos-ui or ipad-simulator.")
                }
                selectedPlatform = parsed
            } else { selectedPlatform = nil }
            guard repository.hasPrefix("/"), !repository.utf8.contains(0) else {
                throw ValidationError("--repository must be an absolute worktree path.")
            }
            if let leaseHome, !leaseHome.hasPrefix("/") || leaseHome.utf8.contains(0) {
                throw ValidationError("--lease-home must be an absolute registry path.")
            }
            if let waitSeconds, !waitSeconds.isFinite || waitSeconds < 0 {
                throw ValidationError("--wait-seconds must be finite and nonnegative.")
            }
            request = try NotikaActionRequest(makeRoute: selectedRoute, platform: selectedPlatform,
                testFile: file, testMethod: method, device: device, unitSelectors: onlyTesting)
        } catch let error as ValidationError { throw error }
        catch { throw ValidationError(String(describing: error)) }

        let helper = try notikaBuildCurrentExecutable()
        let environment = ProcessInfo.processInfo.environment
        try NotikaLeaseBoundary.reexecuteIfRequired(
            request: request, environment: environment, executable: helper,
            arguments: Array(CommandLine.arguments.dropFirst()), label: "Notika \(route)"
        )
        let relay = try SignalRelay()
        defer { relay.restore() }
        let result: NotikaBuildCoordinatorResult
        do {
            result = try await execute(request, helper: helper, environment: environment, relay: relay).get()
        } catch {
            writeError("Notika build setup failed: \(error)")
            throw ExitCode(error is CancellationError ? 130 : 70)
        }
        if json {
            print(String(decoding: try result.jsonData(), as: UTF8.self))
        } else {
            print("Notika build \(result.runID): \(result.status)")
            print("Execution status: \(result.exitCode)")
            if let native = result.nativeTermination { print("Native \(native.kind.rawValue): \(native.value)") }
            if let path = result.sessionPath { print("Session: \(path)") }
            if let tests = result.resultSummary?.tests {
                print("Tests: \(tests.executed) executed, \(tests.passed) passed, \(tests.failed) failed, \(tests.skipped) skipped")
            }
            if let output = result.resultConsumer?.consoleOutput { print(output) }
            for capture in result.rawCaptures {
                print("stdout: \(capture.standardOutput.path)")
                print("stderr: \(capture.standardError.path)")
                print("combined: \(capture.combined.path)")
            }
        }
        for failure in result.orchestrationFailures { writeError("Build diagnostic: \(failure)") }
        for failure in result.publicationFailures { writeError("Evidence publication: \(failure)") }
        for failure in result.maintenanceDiagnostics { writeError("Maintenance diagnostic: \(failure)") }
        for failure in result.resultConsumer?.failures ?? [] {
            writeError("Result consumer: \(failure.operation) (\(failure.code))")
        }
        for failure in result.performanceEvidence?.failures ?? [] {
            writeError("Performance evidence: \(failure.operation)")
        }
        if result.exitCode != 0 { throw ExitCode(result.exitCode) }
    }

    private enum ExecutionEvent: Sendable {
        case completed(Result<NotikaBuildCoordinatorResult, any Error>)
        case signal(Int32?)
    }

    private func execute(
        _ request: NotikaActionRequest,
        helper: String,
        environment: [String: String],
        relay: SignalRelay
    ) async -> Result<NotikaBuildCoordinatorResult, any Error> {
        let repository = repository, registry = leaseHome, wait = waitSeconds
        return await withTaskGroup(of: ExecutionEvent.self) { group in
            group.addTask {
                do {
                    return .completed(.success(try await NotikaBuildCoordinator().run(
                        repository: repository, request: request, helperExecutable: helper,
                        registryRoot: registry, environment: environment, waitSeconds: wait
                    )))
                } catch { return .completed(.failure(error)) }
            }
            group.addTask { .signal(await relay.nextSignal()) }
            var result: Result<NotikaBuildCoordinatorResult, any Error>?
            while let event = await group.next() {
                switch event {
                case .completed(let completed): result = completed; group.cancelAll()
                case .signal(let signal): if signal != nil { group.cancelAll() }
                }
            }
            // Structured cancellation awaits native group retirement, raw EOF,
            // final observations and terminal publication before dropping locks.
            return result ?? .failure(CancellationError())
        }
    }

    private func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// Query dyld for this process's executable, then resolve its existing regular
/// file. argv[0], mutable PATH and the current directory never select a helper.
private func notikaBuildCurrentExecutable() throws -> String {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    guard size > 0, size <= 1_024 * 1_024 else {
        throw ValidationError("Cannot resolve the current agentbuild executable.")
    }
    var bytes = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&bytes, &size) == 0,
          let resolved = bytes.withUnsafeBufferPointer({ realpath($0.baseAddress!, nil) }) else {
        throw ValidationError("Cannot resolve the current agentbuild executable.")
    }
    defer { free(resolved) }
    guard let path = String(validatingCString: resolved), path.hasPrefix("/") else {
        throw ValidationError("The current executable path is invalid.")
    }
    var metadata = stat()
    guard lstat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
          access(path, X_OK) == 0 else {
        throw ValidationError("The current executable is not an executable regular file.")
    }
    return path
}
