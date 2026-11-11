import AgentBuildCLISupport
import AgentBuildCore
import ArgumentParser
import Darwin
import Foundation

struct NotikaDocsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "run-docs",
        abstract: "Build a retained DocC archive, static site, or supervised loopback preview.",
        discussion: "Graph and cache ownership spans all tools and preview lifetime. Only docbuild acquires host compilation ownership. Preview prints its loopback URL and stays supervised until interrupted.")
    @Argument(help: "archive, rendered, or preview.")
    var mode: String
    @Option(help: "Absolute canonical Notika worktree root.")
    var repository: String
    @Option(help: "Stable user-owned renderer dist tree; defaults to ../swift-docc-render/dist.")
    var rendererRoot: String?
    @Option(help: "Loopback preview port, 1024 through 65535.")
    var port = 8_000
    @Option(help: "Absolute checkout AgentLease registry.")
    var leaseHome: String?
    @Option(help: "Maximum seconds to wait at each ownership boundary.")
    var waitSeconds: Double?
    @Flag(help: "Print only the final JSON result to standard output.")
    var json = false

    mutating func run() async throws {
        guard let admittedMode = NotikaDocumentationMode(rawValue: mode) else { throw ValidationError("mode must be archive, rendered, or preview.") }
        for path in [repository, rendererRoot, leaseHome].compactMap({ $0 }) {
            guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw ValidationError("Paths must be absolute and contain no NUL.") }
        }
        guard (1_024...65_535).contains(port) else { throw ValidationError("--port must be between 1024 and 65535.") }
        if let waitSeconds, !waitSeconds.isFinite || waitSeconds < 0 { throw ValidationError("--wait-seconds must be finite and nonnegative.") }
        let helper = try currentAgentBuildExecutable(), relay = try SignalRelay()
        defer { relay.restore() }
        let result: NotikaDocumentationDriverResult
        do { result = try await execute(mode: admittedMode, helper: helper, relay: relay).get() }
        catch {
            documentationCLIError("Documentation setup: \(error)")
            throw ExitCode(error is CancellationError ? 130 : 70)
        }
        if json { print(String(decoding: try result.jsonData(), as: UTF8.self)) }
        else {
            print("Notika documentation \(result.runID): \(result.status)")
            print("Execution status: \(result.exitCode)")
            if let native = result.nativeTermination { print("Docbuild native \(native.kind.rawValue): \(native.value)") }
            for native in result.ancillaryTerminations { print("Rendering/preview native \(native.kind.rawValue): \(native.value)") }
            if let path = result.sessionPath { print("Session: \(path)") }
            if let archive = result.report?.archivePath { print("Archive: \(archive)") }
            if let site = result.report?.sitePath { print("Static site: \(site)") }
            for capture in result.rawCaptures {
                print("stdout: \(capture.standardOutput.path)")
                print("stderr: \(capture.standardError.path)")
                print("combined: \(capture.combined.path)")
            }
        }
        for failure in result.orchestrationFailures { documentationCLIError("Documentation diagnostic: \(failure)") }
        for failure in result.publicationFailures { documentationCLIError("Evidence publication: \(failure)") }
        for failure in result.maintenanceFailures { documentationCLIError("Artifact maintenance: \(failure)") }
        if let report = result.maintenanceReport, report.attentionCount > 0 { documentationCLIError("Artifact maintenance attention: \(report.attentionCount)") }
        if result.exitCode != 0 { throw ExitCode(result.exitCode) }
    }
    private enum Event: Sendable {
        case completed(Result<NotikaDocumentationDriverResult, any Error>)
        case signal(Int32?)
    }
    private func execute(mode: NotikaDocumentationMode, helper: String, relay: SignalRelay) async -> Result<NotikaDocumentationDriverResult, any Error> {
        let repository = repository, renderer = rendererRoot, registry = leaseHome, port = port, wait = waitSeconds, json = json
        return await withTaskGroup(of: Event.self) { group in
            group.addTask {
                do {
                    return .completed(.success(try await NotikaDocumentationDriver().run(repository: repository, mode: mode,
                        helperExecutable: helper, registryRoot: registry, rendererRoot: renderer, previewPort: port, waitSeconds: wait,
                        onPreviewReady: { ready in if !json { print("Preview: " + ready.url) } })))
                } catch { return .completed(.failure(error)) }
            }
            group.addTask { .signal(await relay.nextSignal()) }
            var completed: Result<NotikaDocumentationDriverResult, any Error>?
            while let event = await group.next() {
                switch event {
                case .completed(let result): completed = result; group.cancelAll()
                case .signal(let signal): if signal != nil { group.cancelAll() }
                }
            }
            return completed ?? .failure(CancellationError())
        }
    }
}

package struct NotikaDocPreviewCommand: AsyncParsableCommand {
    package init() {}

    package static let configuration = CommandConfiguration(commandName: "_notika-doc-preview", shouldDisplay: false)
    @Option var repository: String
    @Option var sessionDir: String
    @Option var leaseHome: String
    @Option var port: Int
    @Option(name: .customLong("site-sha256")) var siteSHA256: String

    package mutating func run() async throws {
        // The hidden helper is a native child, never a route into Xcode/Make.
        // Its true shared writer and inherited controller descriptors span all
        // socket operations and are retired before this command returns.
        let repository = repository, session = sessionDir, registry = leaseHome, port = port, hash = siteSHA256
        let relay = try SignalRelay()
        defer { relay.restore() }
        enum Event: Sendable { case completed(Result<Void, any Error>), signal(Int32?) }
        let result = await withTaskGroup(of: Event.self) { group in
            group.addTask {
                do {
                    try await NotikaDocumentationPreviewServer.run(repository: repository, sessionDirectory: session,
                        registryRoot: registry, port: port, siteSHA256: hash)
                    return .completed(.success(()))
                } catch { return .completed(.failure(error)) }
            }
            group.addTask { .signal(await relay.nextSignal()) }
            var completed: Result<Void, any Error>?
            while let event = await group.next() {
                switch event {
                case .completed(let result): completed = result; group.cancelAll()
                case .signal(let signal): if signal != nil { group.cancelAll() }
                }
            }
            return completed ?? .failure(CancellationError())
        }
        do { try result.get() }
        catch is CancellationError { return }
        catch { documentationCLIError("Preview helper: \(error)"); throw ExitCode(70) }
    }
}

private func documentationCLIError(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }
