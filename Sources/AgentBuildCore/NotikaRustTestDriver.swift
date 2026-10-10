import AgentLeaseCore
import Darwin
import Foundation
import Synchronization

public enum NotikaRustTestDriverError: Error, Equatable, Sendable {
    case invalidArgument(String)
    case repositoryIsNotWorktreeRoot
    case unavailableHelper
}

/// A direct Rust workflow has a separate closed receipt. It claims no Xcode
/// request, DerivedData identity, or passing development-preflight gate.
public struct NotikaRustTestSessionReport: Sendable {
    public static let namespace = "agentbuild.notika-rust-test"
    public static let schemaVersion = 1
    public let originalData: Data
    public let canonicalValue: CanonicalJSONValue
    public let digest: String
    public let sessionID: String
    public let repository: String
    public let lifecycle: String
    public let status: String
    public let exitCode: Int32?
    public let nativeTermination: RunTermination?
    public let cancelled: Bool

    public init(data: Data, expectedRepository: String? = nil, expectedSessionID: String? = nil) throws {
        try self.init(data: data, expectedRepository: expectedRepository, expectedSessionID: expectedSessionID,
                      captureAdmissionPolicy: .current)
    }

    internal init(data: Data, expectedRepository: String? = nil, expectedSessionID: String? = nil,
                  captureAdmissionPolicy: NativeCaptureAdmissionPolicy) throws {
        let document = try StrictJSONDocument(data: data)
        let root = try document.root.requireObject().project(requiredKeys: [
            "namespace", "schemaVersion", "toolVersion", "sessionID", "runUUID", "repository", "writerResource", "ownerUID", "directoryIdentity",
            "startedAt", "completedAt", "expiresAt", "localTimeZone", "lifecycle", "family", "status", "exitCode", "nativeTermination", "cancelled",
            "executionComplete", "execution", "phases", "orchestrationFailures", "publicationFailures",
        ])
        let repository = try controllerString(root, "repository"), id = try controllerString(root, "sessionID")
        _ = try CacheCompatibilityIdentity.graphResourceName(canonicalWorktree: repository)
        guard UUID(uuidString: id)?.uuidString == id, try controllerString(root, "runUUID") == id,
              try controllerString(root, "namespace") == Self.namespace, try controllerInteger(root, "schemaVersion") == 1,
              !(try controllerString(root, "toolVersion")).isEmpty, try controllerUnsigned(root, "ownerUID") <= UInt64(UInt32.max),
              controllerSame(try controllerString(root, "writerResource"), "notika:sessions:" + repository),
              let family = NotikaRustTestFamily(rawValue: try controllerString(root, "family")) else { throw StrictJSONError.invalidSchema }
        if let expectedRepository, !repository.utf8.elementsEqual(expectedRepository.utf8) { throw StrictJSONError.invalidSchema }
        if let expectedSessionID, !id.utf8.elementsEqual(expectedSessionID.utf8) { throw StrictJSONError.invalidSchema }
        let directory = try root.requiredValue(forKey: "directoryIdentity").requireObject().project(requiredKeys: ["deviceID", "inode"])
        _ = try controllerUnsigned(directory, "deviceID")
        guard try controllerUnsigned(directory, "inode") > 0 else { throw StrictJSONError.invalidSchema }
        let started = try rustDriverDate(root, "startedAt")
        guard let zone = TimeZone(identifier: try controllerString(root, "localTimeZone")) else { throw StrictJSONError.invalidSchema }
        let lifecycle = try controllerString(root, "lifecycle"), status = try controllerString(root, "status")
        guard captureAdmissionPolicy != .historicalRetention || lifecycle == "terminal" else { throw StrictJSONError.invalidSchema }
        let cancelled = try controllerBool(root, "cancelled"), complete = try controllerBool(root, "executionComplete")
        let failures = try controllerStrings(root, "orchestrationFailures", maximum: 128)
        let publication = try controllerStrings(root, "publicationFailures", maximum: 128)
        let phases = try controllerArray(root, "phases", maximum: 2).map {
            try controllerValidatePhase($0, repository: repository, sessionPath: repository + "/Artifacts/AgentSessions/" + id,
                                        captureAdmissionPolicy: captureAdmissionPolicy)
        }
        let native = phases.compactMap(\.termination)
        let failed = native.first { controllerExitCode($0) != 0 }
        let termination = try controllerTermination(root.requiredValue(forKey: "nativeTermination"))
        guard termination == (failed ?? native.last), !phases.contains(where: { $0.cancelled }) || cancelled else { throw StrictJSONError.invalidSchema }
        var executionPassed = false
        if let execution = root.value(forKey: "execution"), execution != .null {
            let parsed = try controllerValidateRustReport(execution, repository: repository, sessionPath: repository + "/Artifacts/AgentSessions/" + id)
            guard parsed.identity.family == family, parsed.commands.count == phases.count else { throw StrictJSONError.invalidSchema }
            for index in phases.indices {
                guard try CanonicalJSONDigest.encode(parsed.commands[index]) == CanonicalJSONDigest.encode(phases[index].command),
                      parsed.outcomes[index] == phases[index].outcome else { throw StrictJSONError.invalidSchema }
            }
            executionPassed = parsed.outcome.succeeded
        } else {
            // Descriptive evidence of an interrupted executor remains bounded
            // and cannot manufacture a successful cache/usage observation.
            for (index, phase) in phases.enumerated() {
                let command = try StrictJSONDocument(data: CanonicalJSONDigest.encode(phase.command)).root.requireObject()
                let script = family == .svg ? "svg-path-importer-licenses.sh" : "liteparse-bridge-licenses.sh"
                if index == 0 {
                    guard controllerSame(try controllerString(command, "executable"), repository + "/Scripts/bridges/" + script),
                          try controllerStrings(command, "arguments", maximum: 128) == ["check"] else { throw StrictJSONError.invalidSchema }
                } else {
                    let args = ["exec"] + (family == .liteparse ? ["rust@1.88.0"] : []) + ["--", "cargo", "test", "--locked", "--manifest-path", "Rust/" + (family == .svg ? "SVGPathImporter" : "LiteParseBridge") + "/Cargo.toml"]
                    guard controllerSameArguments(try controllerStrings(command, "arguments", maximum: 128), args), phases[index - 1].succeeded else { throw StrictJSONError.invalidSchema }
                }
            }
            guard !complete else { throw StrictJSONError.invalidSchema }
        }
        guard complete == (executionPassed && !cancelled && failures.isEmpty) else { throw StrictJSONError.invalidSchema }
        let code: Int32?
        if lifecycle == "inProgress" {
            guard status == "running", !complete, !cancelled, phases.isEmpty, termination == nil, failures.isEmpty, publication.isEmpty,
                  root.value(forKey: "execution") == .null, root.value(forKey: "completedAt") == .null,
                  root.value(forKey: "expiresAt") == .null, root.value(forKey: "exitCode") == .null else { throw StrictJSONError.invalidSchema }
            code = nil
        } else {
            guard lifecycle == "terminal" else { throw StrictJSONError.invalidSchema }
            let completed = try rustDriverDate(root, "completedAt"), expires = try rustDriverDate(root, "expiresAt")
            let expected = try LocalCalendarRetention(evaluatedAt: completed, timeZone: zone).nextLocalMidnight
            guard started <= completed, completed < expires, abs(expires.timeIntervalSince(expected)) < 0.001 else { throw StrictJSONError.invalidSchema }
            let result = rustDriverStatus(nativeFailure: failed, cancelled: cancelled,
                complete: complete && publication.isEmpty && phases.allSatisfy(\.succeeded))
            guard status == result.0, try controllerInteger(root, "exitCode") == Int64(result.1) else { throw StrictJSONError.invalidSchema }
            code = result.1
        }
        originalData = data; canonicalValue = try controllerCanonical(document.root); digest = document.digest
        sessionID = id; self.repository = repository; self.lifecycle = lifecycle; self.status = status; exitCode = code
        nativeTermination = termination; self.cancelled = cancelled
    }

    internal static func publishDiagnosticFixture(repository: String, registryRoot: String, sessionID: String = UUID().uuidString,
                                                   startedAt: Date, completedAt: Date?, timeZone: TimeZone) async throws -> Self {
        let leases = try await rustDriverWriter(repository: repository, registry: registryRoot, runID: sessionID, wait: 0)
        defer { leases.release() }
        let artifacts = try NotikaControllerSessionArtifacts(repository: repository, runID: sessionID), state = RustDriverState()
        let progress = try rustDriverReport(artifacts: artifacts, repository: repository, runID: sessionID, family: .svg,
            started: startedAt, completed: nil, timeZone: timeZone, state: state)
        try artifacts.publish(sealedData: progress.originalData, name: "in-progress.json", validating: {})
        guard let completedAt else { return progress }
        state.failure(NotikaRustTestDriverError.invalidArgument("diagnostic fixture"))
        let terminal = try rustDriverReport(artifacts: artifacts, repository: repository, runID: sessionID, family: .svg,
            started: startedAt, completed: completedAt, timeZone: timeZone, state: state)
        try artifacts.publish(sealedData: terminal.originalData, name: "manifest.json", validating: {})
        return terminal
    }
}

public struct NotikaRustTestDriverResult: Sendable {
    public let runID: String
    public let sessionPath: String
    public let report: NotikaRustTestSessionReport?
    public let rawCaptures: [NativeLogCaptureResult]
    public let nativeTermination: RunTermination?
    public let cancelled: Bool
    public let orchestrationFailures: [String]
    public let publicationFailures: [String]
    public let maintenanceReport: NotikaArtifactMaintenanceReport?
    public let maintenanceFailures: [String]
    public var status: String { resultStatus.0 }
    public var exitCode: Int32 { resultStatus.1 }
    private var resultStatus: (String, Int32) {
        if let nativeTermination, controllerExitCode(nativeTermination) != 0 { return ("failed", controllerExitCode(nativeTermination)) }
        if cancelled { return ("cancelled", 130) }
        return report?.status == "succeeded" && orchestrationFailures.isEmpty && publicationFailures.isEmpty ? ("succeeded", 0) : ("inconclusive", 70)
    }
    public func jsonData() throws -> Data {
        try CanonicalJSONDigest.encode(.object(["namespace": .string("agentbuild.notika-rust-test-result"), "schemaVersion": .integer(1),
            "runID": .string(runID), "sessionPath": .string(sessionPath), "status": .string(status), "exitCode": .integer(Int64(exitCode)),
            "nativeTermination": try controllerEncoded(nativeTermination), "cancelled": .bool(cancelled),
            "orchestrationFailures": .array(orchestrationFailures.map(CanonicalJSONValue.string)),
            "publicationFailures": .array(publicationFailures.map(CanonicalJSONValue.string)), "sessionReport": report?.canonicalValue ?? .null,
            "maintenanceReport": try maintenanceReport.map(controllerEncoded) ?? .null,
            "maintenanceFailures": .array(maintenanceFailures.map(CanonicalJSONValue.string))]))
    }
}

/// Shared session writer -> shared graph -> Rust policy -> exact Rust cache ->
/// account compile. Every real child keeps the actual descriptor chain, and
/// the capsule runner awaits quiescence and raw EOF before ownership retires.
public struct NotikaRustTestDriver: Sendable {
    internal typealias CaptureOperation = @Sendable (String, DarwinWorkloadCommand, [Int32], String, Int32) async throws -> CapturedNativePhase
    internal typealias MaintenanceOperation = @Sendable (String, String, Date, TimeZone) async throws -> NotikaArtifactMaintenanceReport
    private let repositoryCapture: (any RepositoryCommandCapturing)?
    private let identityOperation: NotikaRustTestExecutor.IdentityOperation?
    private let sourceOperation: NotikaRustTestExecutor.SourceOperation?
    private let captureOperation: CaptureOperation
    private let maintenanceOperation: MaintenanceOperation
    public init() { repositoryCapture = nil; identityOperation = nil; sourceOperation = nil; captureOperation = Self.capture; maintenanceOperation = Self.maintenance }
    internal init(repositoryCapture: any RepositoryCommandCapturing, identityOperation: @escaping NotikaRustTestExecutor.IdentityOperation,
                  sourceOperation: @escaping NotikaRustTestExecutor.SourceOperation, captureOperation: CaptureOperation? = nil,
                  maintenanceOperation: MaintenanceOperation? = nil) {
        self.repositoryCapture = repositoryCapture; self.identityOperation = identityOperation; self.sourceOperation = sourceOperation
        self.captureOperation = captureOperation ?? Self.capture; self.maintenanceOperation = maintenanceOperation ?? Self.maintenance
    }
    private static let capture: CaptureOperation = { helper, command, descriptors, root, directory in
        try await CapturedNativePhaseRunner().run(helperExecutable: helper, command: command, retainedLockDescriptors: descriptors,
            nativeWorkingDirectoryDescriptor: directory, artifactRoot: root)
    }
    private static let maintenance: MaintenanceOperation = { repository, registry, date, zone in
        try await NotikaArtifactMaintenance(canonicalRepository: repository, registryRoot: registry, evaluatedAt: date, timeZone: zone).run(execute: true)
    }

    public func run(family: NotikaRustTestFamily, repository: String, helperExecutable: String, registryRoot: String? = nil,
                    environment: [String: String] = ProcessInfo.processInfo.environment, waitSeconds: Double? = nil,
                    runID: String = UUID().uuidString, startedAt: Date = Date(), timeZone: TimeZone = .current) async throws -> NotikaRustTestDriverResult {
        guard UUID(uuidString: runID)?.uuidString == runID else { throw NotikaRustTestDriverError.invalidArgument("runID") }
        if let waitSeconds, !waitSeconds.isFinite || waitSeconds < 0 { throw NotikaRustTestDriverError.invalidArgument("waitSeconds") }
        _ = try LocalCalendarRetention(evaluatedAt: startedAt, timeZone: timeZone)
        let helper = try rustDriverHelper(helperExecutable), raw = try repositoryCapture ?? RepositoryCommandCapture()
        let observer = try NotikaRepositoryIdentity(repository: repository, capture: raw, environment: environment)
        guard observer.repository.utf8.elementsEqual(repository.utf8) else { throw NotikaRustTestDriverError.invalidArgument("repository") }
        var child = environment
        child["PATH"] = repository + "/Scripts:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        let top = repositoryDecodedText(try await raw.capture(arguments: ["git", "rev-parse", "--show-toplevel"], workingDirectory: repository, environment: child))
        guard top.utf8.elementsEqual(repository.utf8) else { throw NotikaRustTestDriverError.repositoryIsNotWorktreeRoot }
        let registry = registryRoot ?? environment["AGENTLEASE_HOME"] ?? repository + "/.agentlease"
        guard registry.hasPrefix("/"), !registry.utf8.contains(0) else { throw NotikaRustTestDriverError.invalidArgument("registryRoot") }
        var maintenance: NotikaArtifactMaintenanceReport?, maintenanceFailures: [String] = []
        do { maintenance = try await maintenanceOperation(repository, registry, startedAt, timeZone) }
        catch { maintenanceFailures.append(String(describing: error)) }
        try Task.checkCancellation()
        let writer = try await rustDriverWriter(repository: repository, registry: registry, runID: runID, wait: waitSeconds)
        defer { writer.release() }
        let artifacts = try NotikaControllerSessionArtifacts(repository: repository, runID: runID), state = RustDriverState()
        let writerDescriptors = writer.inheritedDescriptors, executionEnvironment = child
        do {
            let progress = try rustDriverReport(artifacts: artifacts, repository: repository, runID: runID, family: family,
                started: startedAt, completed: nil, timeZone: timeZone, state: state)
            try artifacts.publish(sealedData: progress.originalData, name: "in-progress.json", validating: {})
        } catch { state.publicationFailure(error) }
        if state.publicationFailures.isEmpty {
            do {
                let temporary = try artifacts.createPrivateDirectory(named: "tmp")
                let bindings = try NotikaRustTestExecutionBindings(sessionID: runID, temporaryDirectory: artifacts.path + "/tmp")
                let plan = try NotikaProjectOwnershipPlan(rustTestFor: repository)
                let operation = captureOperation, identity = identityOperation, source = sourceOperation
                let report = try await NotikaProjectAdmission().withOwnership(plan, registryRoot: registry, label: "notika-rust-test:" + family.rawValue,
                    runID: runID, waitSeconds: waitSeconds) { ownership in
                    let context = NotikaPreflightRustContext(repository: repository, environment: executionEnvironment, ownership: ownership,
                        retainedLockDescriptors: writerDescriptors + (try ownership.inheritedDescriptors()))
                    return try await NotikaRustTestExecutor().run(family: family, context: context, bindings: bindings, capture: raw,
                        identityOperation: identity, sourceOperation: source, commandOperation: { command, descriptors in
                            try artifacts.revalidate(); try temporary.revalidate()
                            let phase = try await operation(helper, command, descriptors, artifacts.path, artifacts.repositoryDescriptor)
                            state.retain(phase)
                            guard try CanonicalJSONDigest.encode(controllerCommandValue(phase.command)) == CanonicalJSONDigest.encode(controllerCommandValue(command)) else {
                                throw StrictJSONError.invalidSchema
                            }
                            try artifacts.revalidate(); try temporary.revalidate()
                            return controllerOutcome(phase)
                        }, waitSeconds: waitSeconds)
                }
                state.completed(report)
            } catch { state.failure(error) }
        }
        state.markCancelled(Task.isCancelled)
        do { try state.revalidateCaptures() } catch { state.publicationFailure(error) }
        do {
            let terminal = try rustDriverReport(artifacts: artifacts, repository: repository, runID: runID, family: family,
                started: startedAt, completed: Date(), timeZone: timeZone, state: state)
            try artifacts.publish(sealedData: terminal.originalData, name: "manifest.json", validating: {
                if state.publicationFailures.isEmpty { try state.revalidateCaptures() }
            })
            state.published(terminal)
        } catch { state.publicationFailure(error) }
        let phases = state.phases, native = phases.compactMap { $0.observation.termination }
        return .init(runID: runID, sessionPath: artifacts.path, report: state.terminal, rawCaptures: phases.map(\.rawCapture),
            nativeTermination: native.first { controllerExitCode($0) != 0 } ?? native.last, cancelled: state.cancelled,
            orchestrationFailures: state.orchestrationFailures, publicationFailures: state.publicationFailures,
            maintenanceReport: maintenance, maintenanceFailures: maintenanceFailures)
    }
}

private final class RustDriverState: Sendable {
    private struct State: Sendable { var phases: [CapturedNativePhase] = []; var execution: NotikaRustTestReport?; var terminal: NotikaRustTestSessionReport?; var failures: [String] = []; var publication: [String] = []; var cancelled = false }
    private let state = Mutex(State())
    var phases: [CapturedNativePhase] { state.withLock { $0.phases } }
    var execution: NotikaRustTestReport? { state.withLock { $0.execution } }
    var terminal: NotikaRustTestSessionReport? { state.withLock { $0.terminal } }
    var orchestrationFailures: [String] { state.withLock { $0.failures } }
    var publicationFailures: [String] { state.withLock { $0.publication } }
    var cancelled: Bool { state.withLock { $0.cancelled || $0.phases.contains { $0.observation.cancelled } } }
    func retain(_ phase: CapturedNativePhase) { state.withLock { $0.phases.append(phase) } }
    func completed(_ report: NotikaRustTestReport) { state.withLock { $0.execution = report } }
    func published(_ report: NotikaRustTestSessionReport) { state.withLock { $0.terminal = report } }
    func failure(_ error: Error) { state.withLock { $0.failures.append(String(describing: error)); $0.cancelled = $0.cancelled || error is CancellationError || Task.isCancelled } }
    func publicationFailure(_ error: Error) { state.withLock { $0.publication.append(String(describing: error)) } }
    func markCancelled(_ value: Bool) { state.withLock { $0.cancelled = $0.cancelled || value } }
    func revalidateCaptures() throws { for phase in phases { try phase.revalidateForPublication() } }
}
private func rustDriverWriter(repository: String, registry: String, runID: String, wait: Double?) async throws -> LeaseSet {
    let paths = try AgentLeasePaths.open(selectedRoot: registry), resources = try ResourceSet(exclusive: [], shared: ["notika:sessions:" + repository])
    let pid = getpid(), timestamp = RunRecord.timestamp()
    return try await LeaseSet.acquire(resources, paths: paths, waitSeconds: wait, initialMetadata: { lease in
        LockMetadata(resourceName: lease.resource.value, leaseMode: lease.mode, runID: runID, coordinatorPID: pid, childPID: nil,
            mode: .run, state: .acquired, label: "notika-rust-test-session-writer", bead: nil, acquiredAt: timestamp)
    })
}
private func rustDriverReport(artifacts: NotikaControllerSessionArtifacts, repository: String, runID: String, family: NotikaRustTestFamily,
                              started: Date, completed: Date?, timeZone: TimeZone, state: RustDriverState) throws -> NotikaRustTestSessionReport {
    guard let device = UInt64(exactly: artifacts.identity.st_dev) else { throw StrictJSONError.invalidSchema }
    let phases = state.phases, native = phases.compactMap { $0.observation.termination }
    let failed = native.first { controllerExitCode($0) != 0 }
    let complete = state.execution?.outcome.succeeded == true && !state.cancelled && state.orchestrationFailures.isEmpty
    let result = completed == nil ? ("running", Int32(0)) : rustDriverStatus(nativeFailure: failed, cancelled: state.cancelled,
        complete: complete && state.publicationFailures.isEmpty && phases.allSatisfy { controllerOutcome($0).succeeded })
    let value = CanonicalJSONValue.object([
        "namespace": .string(NotikaRustTestSessionReport.namespace), "schemaVersion": .integer(1), "toolVersion": .string(AgentBuild.version),
        "sessionID": .string(runID), "runUUID": .string(runID), "repository": .string(repository), "writerResource": .string("notika:sessions:" + repository),
        "ownerUID": .unsignedInteger(UInt64(geteuid())), "directoryIdentity": .object(["deviceID": .unsignedInteger(device), "inode": .unsignedInteger(UInt64(artifacts.identity.st_ino))]),
        "startedAt": .string(try rustDriverTimestamp(started)), "completedAt": try completed.map { .string(try rustDriverTimestamp($0)) } ?? .null,
        "expiresAt": try completed.map { .string(try rustDriverTimestamp(LocalCalendarRetention(evaluatedAt: $0, timeZone: timeZone).nextLocalMidnight)) } ?? .null,
        "localTimeZone": .string(timeZone.identifier), "lifecycle": .string(completed == nil ? "inProgress" : "terminal"), "family": .string(family.rawValue),
        "status": .string(result.0), "exitCode": completed == nil ? .null : .integer(Int64(result.1)),
        "nativeTermination": try controllerEncoded(failed ?? native.last), "cancelled": .bool(state.cancelled), "executionComplete": .bool(complete),
        "execution": try state.execution.map(controllerRustReportValue) ?? .null, "phases": .array(try phases.map(controllerPhaseValue)),
        "orchestrationFailures": .array(state.orchestrationFailures.map(CanonicalJSONValue.string)), "publicationFailures": .array(state.publicationFailures.map(CanonicalJSONValue.string)),
    ])
    return try NotikaRustTestSessionReport(data: CanonicalJSONDigest.encode(value), expectedRepository: repository, expectedSessionID: runID)
}
private func rustDriverStatus(nativeFailure: RunTermination?, cancelled: Bool, complete: Bool) -> (String, Int32) {
    if let nativeFailure { return ("failed", controllerExitCode(nativeFailure)) }
    if cancelled { return ("cancelled", 130) }
    return complete ? ("succeeded", 0) : ("inconclusive", 70)
}
private func rustDriverHelper(_ path: String) throws -> String {
    guard path.hasPrefix("/"), !path.utf8.contains(0), let resolved = path.withCString({ realpath($0, nil) }) else { throw NotikaRustTestDriverError.unavailableHelper }
    defer { free(resolved) }
    guard let result = String(validatingCString: resolved) else { throw NotikaRustTestDriverError.unavailableHelper }
    var metadata = stat()
    guard lstat(result, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, access(result, X_OK) == 0 else { throw NotikaRustTestDriverError.unavailableHelper }
    return result
}
private func rustDriverDate(_ root: StrictJSONObject, _ key: String) throws -> Date {
    let text = try controllerString(root, key), formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let value = formatter.date(from: text), try rustDriverTimestamp(value) == text else { throw StrictJSONError.invalidSchema }; return value
}
private func rustDriverTimestamp(_ value: Date) throws -> String {
    guard value.timeIntervalSinceReferenceDate.isFinite else { throw StrictJSONError.invalidSchema }
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: value)
}
