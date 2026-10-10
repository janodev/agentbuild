import AgentBuildCore
import ArgumentParser
import Darwin
import Foundation
import MachO

struct NotikaRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Build and launch the exact Notika macOS product in one live owned session.",
        discussion: "Starts one outer SimLease macos-ui boundary when needed. Reports the admitted running process, then remains its supervisor until the app exits. Graph, cache and session ownership remain live; this command does not use open or a stale app from another cache."
    )

    @Option(help: "Absolute path to the Notika Git worktree root.")
    var repository: String

    @Option(help: "Absolute checkout AgentLease registry; defaults to AGENTLEASE_HOME or the worktree's .agentlease.")
    var leaseHome: String?

    @Option(help: "Maximum seconds to wait at each project ownership boundary.")
    var waitSeconds: Double?

    @Flag(help: "Emit a running JSON receipt and, after app exit, a terminal JSON result.")
    var json = false

    mutating func run() async throws {
        guard repository.hasPrefix("/"), !repository.utf8.contains(0) else {
            throw ValidationError("--repository must be an absolute worktree path.")
        }
        if let leaseHome, !leaseHome.hasPrefix("/") || leaseHome.utf8.contains(0) {
            throw ValidationError("--lease-home must be an absolute registry path.")
        }
        if let waitSeconds, !waitSeconds.isFinite || waitSeconds < 0 {
            throw ValidationError("--wait-seconds must be finite and nonnegative.")
        }
        let helper = try interactiveCurrentExecutable()
        let environment = ProcessInfo.processInfo.environment
        let request = try NotikaActionRequest(platform: .macOS, interactiveMode: .run)
        // Literal argv reexecution occurs before any writer/graph/cache scope.
        try NotikaLeaseBoundary.reexecuteIfRequired(request: request, environment: environment,
            executable: helper, arguments: Array(CommandLine.arguments.dropFirst()), label: "Build and launch Notika")
        let relay = try SignalRelay()
        defer { relay.restore() }
        let repository = repository, registry = leaseHome, wait = waitSeconds, json = json
        let result = await withTaskGroup(of: InteractiveCLIEvent.self) { group in
            group.addTask {
                do {
                    let result = try await NotikaInteractiveDriver().run(repository: repository,
                        helperExecutable: helper, registryRoot: registry, environment: environment,
                        waitSeconds: wait, receivedSignal: { relay.firstSignal }, onRunning: { report in
                            let message: String
                            if json { message = String(decoding: try report.jsonData(), as: UTF8.self) + "\n" }
                            else {
                                message = "Notika is running (PID \(report.process.processID)).\n"
                                    + "Session: \(report.sessionPath)\nApplication logs: \(report.rawLogDirectory)\n"
                                    + "The supervisor remains open until the app exits.\n"
                            }
                            FileHandle.standardOutput.write(Data(message.utf8))
                        })
                    return .completed(.success(result))
                } catch { return .completed(.failure(error)) }
            }
            group.addTask { .signal(await relay.nextSignal()) }
            var result: Result<NotikaInteractiveResult, any Error>?
            while let event = await group.next() {
                switch event {
                case .completed(let completed): result = completed; group.cancelAll()
                case .signal(let signal): if signal != nil { group.cancelAll() }
                }
            }
            return result ?? .failure(CancellationError())
        }
        let completed: NotikaInteractiveResult
        do { completed = try result.get() }
        catch {
            FileHandle.standardError.write(Data("Notika launch failed: \(error)\n".utf8))
            throw ExitCode(relay.firstSignal.map { 128 + $0 } ?? (error is CancellationError ? 130 : 70))
        }
        if json { print(String(decoding: try completed.jsonData(), as: UTF8.self)) }
        else {
            print("Notika session ended with status \(completed.exitCode).")
            if let raw = completed.rawCapture {
                print("Application stdout: \(raw.standardOutput.path)")
                print("Application stderr: \(raw.standardError.path)")
            }
        }
        for failure in completed.failures + completed.build.orchestrationFailures + completed.build.publicationFailures {
            FileHandle.standardError.write(Data(("Launch diagnostic: " + failure + "\n").utf8))
        }
        if completed.exitCode != 0 { throw ExitCode(completed.exitCode) }
    }
}

private enum InteractiveCLIEvent: Sendable {
    case completed(Result<NotikaInteractiveResult, any Error>)
    case signal(Int32?)
}

private func interactiveCurrentExecutable() throws -> String {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    guard size > 0, size <= 1_024 * 1_024 else { throw ValidationError("Cannot resolve the current executable.") }
    var bytes = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&bytes, &size) == 0,
          let resolved = bytes.withUnsafeBufferPointer({ realpath($0.baseAddress!, nil) }) else {
        throw ValidationError("Cannot resolve the current executable.")
    }
    defer { free(resolved) }
    guard let path = String(validatingCString: resolved) else { throw ValidationError("The current executable path is invalid.") }
    var metadata = stat()
    guard lstat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
          access(path, X_OK) == 0 else { throw ValidationError("The current executable is not runnable.") }
    return path
}
