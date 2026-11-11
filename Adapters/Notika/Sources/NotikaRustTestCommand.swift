import AgentBuildCLISupport
import AgentBuildCore
import ArgumentParser
import Darwin
import Foundation

struct NotikaRustTestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run-rust-test",
        abstract: "Run a managed native Notika Rust family with retained raw evidence.",
        discussion: "Checks the family’s license artifacts and runs pinned mise Cargo tests beneath shared graph, Rust policy/cache, and account compilation ownership."
    )
    @Option(help: "Absolute canonical path to the Notika Git worktree root.")
    var repository: String
    @Argument(help: "Closed Rust test family: svg or liteparse.")
    var family: String
    @Option(help: "Absolute checkout AgentLease registry; defaults to AGENTLEASE_HOME or the worktree’s .agentlease.")
    var leaseHome: String?
    @Option(help: "Maximum seconds to wait at each ownership boundary.")
    var waitSeconds: Double?
    @Flag(help: "Print only the final closed JSON result to standard output.")
    var json = false

    mutating func run() async throws {
        guard repository.hasPrefix("/"), !repository.utf8.contains(0) else {
            throw ValidationError("--repository must be an absolute canonical worktree path.")
        }
        if let leaseHome, !leaseHome.hasPrefix("/") || leaseHome.utf8.contains(0) {
            throw ValidationError("--lease-home must be an absolute registry path.")
        }
        if let waitSeconds, !waitSeconds.isFinite || waitSeconds < 0 {
            throw ValidationError("--wait-seconds must be finite and nonnegative.")
        }
        guard let selectedFamily = NotikaRustTestFamily(rawValue: family) else { throw ValidationError("Family must be svg or liteparse.") }
        let helper = try currentAgentBuildExecutable(), relay = try SignalRelay()
        defer { relay.restore() }
        let result: NotikaRustTestDriverResult
        do { result = try await execute(family: selectedFamily, helper: helper, environment: ProcessInfo.processInfo.environment, relay: relay).get() }
        catch {
            writeError("Notika Rust setup failed: \(error)")
            throw ExitCode(error is CancellationError ? 130 : 70)
        }
        if json { print(String(decoding: try result.jsonData(), as: UTF8.self)) }
        else {
            print("Notika Rust \(result.runID): \(result.status)")
            print("Execution status: \(result.exitCode)")
            if let native = result.nativeTermination { print("Native \(native.kind.rawValue): \(native.value)") }
            if result.cancelled { print("Cancellation requested: true") }
            print("Session: \(result.sessionPath)")
            for capture in result.rawCaptures {
                print("stdout: \(capture.standardOutput.path)")
                print("stderr: \(capture.standardError.path)")
                print("combined: \(capture.combined.path)")
            }
        }
        for failure in result.orchestrationFailures { writeError("Rust diagnostic: \(failure)") }
        for failure in result.publicationFailures { writeError("Evidence publication: \(failure)") }
        for failure in result.maintenanceFailures { writeError("Artifact maintenance: \(failure)") }
        if let report = result.maintenanceReport, report.attentionCount > 0 { writeError("Artifact maintenance attention: \(report.attentionCount)") }
        if result.exitCode != 0 { throw ExitCode(result.exitCode) }
    }

    private enum ExecutionEvent: Sendable {
        case completed(Result<NotikaRustTestDriverResult, any Error>)
        case signal(Int32?)
    }
    private func execute(family: NotikaRustTestFamily, helper: String, environment: [String: String], relay: SignalRelay) async -> Result<NotikaRustTestDriverResult, any Error> {
        let repository = repository, registry = leaseHome, wait = waitSeconds
        return await withTaskGroup(of: ExecutionEvent.self) { group in
            group.addTask {
                do {
                    return .completed(.success(try await NotikaRustTestDriver().run(family: family, repository: repository,
                        helperExecutable: helper, registryRoot: registry, environment: environment, waitSeconds: wait)))
                } catch { return .completed(.failure(error)) }
            }
            group.addTask { .signal(await relay.nextSignal()) }
            var result: Result<NotikaRustTestDriverResult, any Error>?
            while let event = await group.next() {
                switch event {
                case .completed(let completed): result = completed; group.cancelAll()
                case .signal(let signal): if signal != nil { group.cancelAll() }
                }
            }
            // Do not release writer/graph/compilation leases or exit while a
            // quarantined helper group or raw pipe still has an owner.
            return result ?? .failure(CancellationError())
        }
    }
    private func writeError(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }
}
