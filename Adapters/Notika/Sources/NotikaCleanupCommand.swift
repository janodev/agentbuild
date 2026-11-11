import AgentBuildCLISupport
import AgentBuildCore
import ArgumentParser
import Foundation

struct NotikaCleanupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleanup",
        abstract: "Preview or Trash inactive Notika caches and finalized sessions from before today.",
        discussion: "The default is a preview. --execute moves only admitted eligible folders to Trash under exclusive ownership. Busy, incomplete, unknown or invalid evidence remains protected. AgentLease registry records are separate."
    )

    @Option(help: "Absolute path to the Notika Git worktree root.")
    var repository: String

    @Option(help: "Absolute registry; defaults to AGENTLEASE_HOME or the worktree's .agentlease.")
    var leaseHome: String?

    @Option(help: "Artifact namespace: all, caches, sessions, or rust-caches.")
    var scope = "all"

    @Flag(help: "Move eligible folders to Trash; otherwise only preview eligibility.")
    var execute = false

    @Flag(help: "Print the complete typed cleanup summary as JSON.")
    var json = false

    mutating func run() async throws {
        guard let selectedScope = NotikaArtifactCleanupScope(rawValue: scope) else {
            throw ValidationError("--scope must be all, caches, sessions, or rust-caches.")
        }
        if let leaseHome, !leaseHome.hasPrefix("/") || leaseHome.utf8.contains(0) {
            throw ValidationError("--lease-home must be an absolute registry path.")
        }
        let observer = try NotikaRepositoryIdentity(repository: repository)
        let source = try await observer.sourceIdentity()
        guard source.canonicalWorktree.utf8.elementsEqual(observer.repository.utf8) else {
            throw ValidationError("--repository must name the Git worktree root.")
        }
        let environment = ProcessInfo.processInfo.environment
        let registry = leaseHome ?? environment["AGENTLEASE_HOME"] ?? observer.repository + "/.agentlease"
        guard registry.hasPrefix("/"), !registry.utf8.contains(0) else {
            throw ValidationError("The selected registry must be an absolute path.")
        }
        let evaluatedAt = Date(), timeZone = TimeZone.current
        let maintenance = try NotikaArtifactMaintenance(
            canonicalRepository: observer.repository, registryRoot: registry,
            evaluatedAt: evaluatedAt, timeZone: timeZone
        )
        let relay = try SignalRelay()
        defer { relay.restore() }
        let execute = execute
        let result = await withTaskGroup(of: CleanupEvent.self) { group in
            group.addTask {
                do {
                    return .completed(.success(try await maintenance.run(scope: selectedScope, execute: execute)))
                } catch { return .completed(.failure(error)) }
            }
            group.addTask { .signal(await relay.nextSignal()) }
            var completed: Result<NotikaScopedArtifactCleanupReport, any Error>?
            while let event = await group.next() {
                switch event {
                case .completed(let value): completed = value; group.cancelAll()
                case .signal(let value): if value != nil { group.cancelAll() }
                }
            }
            return completed ?? .failure(CancellationError())
        }
        let summary: NotikaScopedArtifactCleanupReport
        do { summary = try result.get() }
        catch is CancellationError { throw ExitCode(130) }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            print(String(decoding: try encoder.encode(summary), as: UTF8.self))
        } else {
            let cacheCount = summary.caches?.entries.filter {
                $0.action == .wouldTrash || $0.action == .trashed
            }.count ?? 0
            let sessionCount = summary.sessions?.entries.filter {
                $0.action == .wouldTrash || $0.action == .trashed
            }.count ?? 0
            let rustCount = summary.rustCaches?.entries.filter {
                $0.action == .wouldTrash || $0.action == .trashed
            }.count ?? 0
            print("\(execute ? "Cleanup" : "Preview"): \(cacheCount) Xcode caches, \(rustCount) Rust caches, \(sessionCount) sessions eligible")
            if let caches = summary.caches { print("Xcode namespace: \(caches.rootState.rawValue)") }
            if let rust = summary.rustCaches { print("Rust namespace: \(rust.rootState.rawValue)") }
            if let sessions = summary.sessions { print("Session namespace: \(sessions.rootState.rawValue)") }
            if summary.attentionCount > 0 {
                print("Protected entries needing attention: \(summary.attentionCount); use --json for reasons")
            }
            if execute {
                if let caches = summary.caches { print("Allocated Xcode cache bytes moved to Trash: \(caches.movedToTrashAllocatedBytes)") }
                if let rust = summary.rustCaches { print("Allocated Rust cache bytes moved to Trash: \(rust.movedToTrashAllocatedBytes)") }
            }
        }
        if !summary.complete { throw ExitCode(3) }
    }

    private enum CleanupEvent: Sendable {
        case completed(Result<NotikaScopedArtifactCleanupReport, any Error>)
        case signal(Int32?)
    }
}
