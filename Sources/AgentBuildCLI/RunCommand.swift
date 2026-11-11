import AgentBuildCLISupport
import AgentBuildCore
import ArgumentParser
import Foundation

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run an explicitly leased command and retain its output and native status.",
        discussion: "Pass an absolute executable after --. Child output is written to session logs."
    )

    @Option(help: "Acquire an exclusive resource; repeat for multiple resources.")
    var resource: [String] = []

    @Option(help: "Acquire a shared resource; repeat for multiple resources.")
    var sharedResource: [String] = []

    @Option(help: "Absolute AgentLease registry directory.")
    var leaseHome: String?

    @Option(help: "Absolute child working directory; defaults to the current directory.")
    var workingDirectory: String?

    @Option(help: "Absolute evidence directory; defaults to Artifacts/AgentBuild in the working directory.")
    var artifactsRoot: String?

    @Option(help: "Human-readable lease label.")
    var label = "agentbuild command"

    @Option(help: "Maximum seconds to wait for resource admission.")
    var waitSeconds: Double?

    @Flag(help: "Print only the final JSON report to standard output.")
    var json = false

    @Argument(parsing: .captureForPassthrough, help: "Absolute executable followed by its literal arguments.")
    var command: [String] = []

    mutating func run() async throws {
        // captureForPassthrough retains the option terminator. Remove only its
        // leading occurrence; later -- values belong to the child unchanged.
        let invocation = command.first == "--" ? Array(command.dropFirst()) : command
        guard let executable = invocation.first else {
            throw ValidationError("Provide an absolute executable after --.")
        }
        let directory = workingDirectory ?? FileManager.default.currentDirectoryPath
        let request: ManagedCommand
        do {
            request = try ManagedCommand(
                executable: executable,
                arguments: Array(invocation.dropFirst()),
                workingDirectory: directory,
                artifactsRoot: artifactsRoot ?? URL(fileURLWithPath: directory)
                    .appendingPathComponent("Artifacts/AgentBuild").path,
                exclusiveResources: resource,
                sharedResources: sharedResource,
                leaseHome: leaseHome,
                label: label,
                waitSeconds: waitSeconds
            )
        } catch {
            throw ValidationError(String(describing: error))
        }

        let relay = try SignalRelay()
        defer { relay.restore() }
        let environment = ProcessInfo.processInfo.environment
        let outcome = await execute(request, environment: environment, relay: relay)
        do {
            let report = try outcome.get()
            try printReport(report)
            // A signal arriving after native completion/publication must not
            // rewrite the finalized manifest's observed result.
            let status = report.exitCode
            if status != 0 { throw ExitCode(status) }
        } catch let error as ManagedExecutionError {
            if case .evidencePublication(let report, let detail) = error {
                // Publication failure does not erase an already observed native result.
                try printReport(report)
                writeError("Evidence publication failed: \(detail)")
                let nativeStatus = report.exitCode
                let status = nativeStatus == 0 ? 70 : nativeStatus
                throw ExitCode(status)
            }
            writeError("Execution failed: \(error)")
            throw ExitCode(70)
        } catch let status as ExitCode {
            throw status
        } catch {
            writeError("Execution failed: \(error)")
            throw ExitCode(70)
        }
    }

    private enum ExecutionEvent: Sendable {
        case completed(Result<ManagedExecutionReport, any Error>)
        case signal(Int32?)
    }

    private func execute(
        _ request: ManagedCommand,
        environment: [String: String],
        relay: SignalRelay
    ) async -> Result<ManagedExecutionReport, any Error> {
        await withTaskGroup(of: ExecutionEvent.self) { group in
            group.addTask {
                do {
                    return .completed(.success(try await ManagedCommandRunner().run(
                        request, environment: environment, receivedSignal: { relay.firstSignal }
                    )))
                } catch {
                    return .completed(.failure(error))
                }
            }
            group.addTask { .signal(await relay.nextSignal()) }
            var outcome: Result<ManagedExecutionReport, any Error>?
            while let event = await group.next() {
                switch event {
                case .completed(let result):
                    outcome = result
                    group.cancelAll()
                case .signal(let number):
                    if number != nil { group.cancelAll() }
                }
            }
            // The task group does not return until cancellation has torn down and
            // reaped the child and the runner has published its final observation.
            return outcome ?? .failure(CancellationError())
        }
    }

    private func printReport(_ report: ManagedExecutionReport) throws {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
        } else {
            print("Run \(report.runID): \(report.state.rawValue)")
            print("Execution status: \(report.exitCode)")
            print("stdout: \(report.standardOutputPath)")
            print("stderr: \(report.standardErrorPath)")
            if let failure = report.failure { writeError(failure.message) }
            for failure in report.metadataFailures { writeError("Lease metadata: \(failure.message)") }
        }
    }

    private func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
