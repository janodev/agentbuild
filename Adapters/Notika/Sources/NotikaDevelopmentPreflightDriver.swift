import AgentBuildCore
import AgentLeaseCore
import Darwin
import Foundation
import Synchronization

public enum NotikaPreflightDriverError: Error, Equatable, Sendable {
    case invalidArgument(String)
    case repositoryIsNotWorktreeRoot
    case unavailableHelper
}

/// Standalone development gate evidence; this schema makes no Xcode build or
/// cache claim. The inner gate snapshot owns its exact closed command catalog.
public struct NotikaPreflightSessionReport: Sendable {
    public static let namespace = "agentbuild.notika-preflight"
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
            "startedAt", "completedAt", "expiresAt", "localTimeZone", "lifecycle", "status", "exitCode", "nativeTermination", "cancelled",
            "executionComplete", "sourceBeforeSHA256", "evidence", "orchestrationFailures", "publicationFailures",
        ])
        let repository = try controllerString(root, "repository"), id = try controllerString(root, "sessionID")
        _ = try CacheCompatibilityIdentity.graphResourceName(canonicalWorktree: repository)
        guard UUID(uuidString: id)?.uuidString == id, try controllerString(root, "runUUID") == id,
              try controllerString(root, "namespace") == Self.namespace, try controllerInteger(root, "schemaVersion") == 1,
              !(try controllerString(root, "toolVersion")).isEmpty, try controllerUnsigned(root, "ownerUID") <= UInt64(UInt32.max),
              controllerSame(try controllerString(root, "writerResource"), "notika:sessions:" + repository) else { throw StrictJSONError.invalidSchema }
        if let expectedRepository, !controllerSame(repository, expectedRepository) { throw StrictJSONError.invalidSchema }
        if let expectedSessionID, !controllerSame(id, expectedSessionID) { throw StrictJSONError.invalidSchema }
        let directory = try root.requiredValue(forKey: "directoryIdentity").requireObject().project(requiredKeys: ["deviceID", "inode"])
        _ = try controllerUnsigned(directory, "deviceID")
        guard try controllerUnsigned(directory, "inode") > 0 else { throw StrictJSONError.invalidSchema }
        let started = try preflightDriverDate(root, "startedAt")
        guard let zone = TimeZone(identifier: try controllerString(root, "localTimeZone")) else { throw StrictJSONError.invalidSchema }
        let lifecycle = try controllerString(root, "lifecycle"), status = try controllerString(root, "status")
        guard captureAdmissionPolicy != .historicalRetention || lifecycle == "terminal" else { throw StrictJSONError.invalidSchema }
        let cancelled = try controllerBool(root, "cancelled"), complete = try controllerBool(root, "executionComplete")
        let failures = try controllerStrings(root, "orchestrationFailures", maximum: 128)
        let publication = try controllerStrings(root, "publicationFailures", maximum: 128)
        let evidence = try root.requiredValue(forKey: "evidence"), source = try root.requiredValue(forKey: "sourceBeforeSHA256")
        var inner = (succeeded: false, nativeFailure: Optional<RunTermination>.none, cancelled: false)
        var native: [RunTermination] = []
        if evidence != .null {
            if source == .null {
                let object = try evidence.requireObject().project(requiredKeys: ["namespace", "schemaVersion", "report", "phases", "rustReports", "orchestrationFailures", "cancelled", "succeeded", "nativeFailure"])
                let errors = try controllerStrings(object, "orchestrationFailures", maximum: 128)
                let stopped = try controllerBool(object, "cancelled")
                guard try controllerString(object, "namespace") == "agentbuild.notika-development-preflight", try controllerInteger(object, "schemaVersion") == 1,
                      object.value(forKey: "report") == .null, object.value(forKey: "nativeFailure") == .null,
                      try controllerArray(object, "phases", maximum: 21).isEmpty, try controllerArray(object, "rustReports", maximum: 2).isEmpty,
                      !(try controllerBool(object, "succeeded")), !errors.isEmpty || stopped else { throw StrictJSONError.invalidSchema }
                inner = (false, nil, stopped)
            } else {
                inner = try NotikaDevelopmentPreflightEvidence.validateSnapshot(controllerCanonical(evidence),
                    sourceBeforeSHA256: controllerString(root, "sourceBeforeSHA256"), sessionPath: repository + "/Artifacts/AgentSessions/" + id,
                    captureAdmissionPolicy: captureAdmissionPolicy)
                let object = try evidence.requireObject()
                native = try controllerArray(object, "phases", maximum: 21).compactMap { try controllerTermination($0.requireObject().requiredValue(forKey: "nativeTermination")) }
            }
        } else if source != .null { throw StrictJSONError.invalidSchema }
        let termination = try controllerTermination(root.requiredValue(forKey: "nativeTermination"))
        guard termination == (inner.nativeFailure ?? native.last), !inner.cancelled || cancelled,
              complete == (inner.succeeded && !cancelled && failures.isEmpty) else { throw StrictJSONError.invalidSchema }
        let code: Int32?
        if lifecycle == "inProgress" {
            guard status == "running", !complete, !cancelled, evidence == .null, termination == nil, failures.isEmpty, publication.isEmpty,
                  root.value(forKey: "completedAt") == .null, root.value(forKey: "expiresAt") == .null,
                  root.value(forKey: "exitCode") == .null else { throw StrictJSONError.invalidSchema }
            code = nil
        } else {
            guard lifecycle == "terminal" else { throw StrictJSONError.invalidSchema }
            let completed = try preflightDriverDate(root, "completedAt"), expires = try preflightDriverDate(root, "expiresAt")
            let expiry = try LocalCalendarRetention(evaluatedAt: completed, timeZone: zone).nextLocalMidnight
            guard started <= completed, completed < expires, abs(expires.timeIntervalSince(expiry)) < 0.001 else { throw StrictJSONError.invalidSchema }
            let result = preflightDriverStatus(nativeFailure: inner.nativeFailure, cancelled: cancelled, complete: complete && publication.isEmpty)
            guard status == result.0, try controllerInteger(root, "exitCode") == Int64(result.1) else { throw StrictJSONError.invalidSchema }
            code = result.1
        }
        originalData = data; canonicalValue = try controllerCanonical(document.root); digest = document.digest
        sessionID = id; self.repository = repository; self.lifecycle = lifecycle; self.status = status; exitCode = code
        nativeTermination = termination; self.cancelled = cancelled
    }

    internal static func publishDiagnosticFixture(repository: String, registryRoot: String, sessionID: String = UUID().uuidString,
                                                   startedAt: Date, completedAt: Date?, timeZone: TimeZone) async throws -> Self {
        let writer = try await preflightDriverWriter(repository: repository, registry: registryRoot, runID: sessionID, wait: 0)
        defer { writer.release() }
        let artifacts = try ControllerSessionArtifacts(repository: repository, runID: sessionID), state = PreflightDriverState()
        let progress = try preflightDriverReport(artifacts: artifacts, repository: repository, runID: sessionID,
            started: startedAt, completed: nil, timeZone: timeZone, state: state)
        try artifacts.publish(sealedData: progress.originalData, name: "in-progress.json", validating: {})
        guard let completedAt else { return progress }
        state.failure(NotikaPreflightDriverError.invalidArgument("diagnostic fixture"))
        let terminal = try preflightDriverReport(artifacts: artifacts, repository: repository, runID: sessionID,
            started: startedAt, completed: completedAt, timeZone: timeZone, state: state)
        try artifacts.publish(sealedData: terminal.originalData, name: "manifest.json", validating: {})
        return terminal
    }
}

public struct NotikaPreflightDriverResult: Sendable {
    public let runID: String
    public let sessionPath: String
    public let report: NotikaPreflightSessionReport?
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
        preflightDriverStatus(nativeFailure: nativeTermination.flatMap { controllerExitCode($0) == 0 ? nil : $0 }, cancelled: cancelled,
            complete: report?.status == "succeeded" && orchestrationFailures.isEmpty && publicationFailures.isEmpty)
    }
    public func jsonData() throws -> Data {
        try CanonicalJSONDigest.encode(.object(["namespace": .string("agentbuild.notika-preflight-result"), "schemaVersion": .integer(1),
            "runID": .string(runID), "sessionPath": .string(sessionPath), "status": .string(status), "exitCode": .integer(Int64(exitCode)),
            "nativeTermination": try controllerEncoded(nativeTermination), "cancelled": .bool(cancelled),
            "orchestrationFailures": .array(orchestrationFailures.map(CanonicalJSONValue.string)),
            "publicationFailures": .array(publicationFailures.map(CanonicalJSONValue.string)), "sessionReport": report?.canonicalValue ?? .null,
            "maintenanceReport": try maintenanceReport.map(controllerEncoded) ?? .null, "maintenanceFailures": .array(maintenanceFailures.map(CanonicalJSONValue.string))]))
    }
}

public struct NotikaDevelopmentPreflightDriver: Sendable {
    private let repositoryCapture: (any RepositoryCommandCapturing)?
    private let identityOperation: NotikaDevelopmentPreflight.IdentityOperation?
    private let captureOperation: NotikaDevelopmentPreflight.CapturedOperation?
    private let maintenanceOperation: NotikaRustTestDriver.MaintenanceOperation
    public init() { repositoryCapture = nil; identityOperation = nil; captureOperation = nil; maintenanceOperation = Self.maintenance }
    internal init(repositoryCapture: any RepositoryCommandCapturing, identityOperation: @escaping NotikaDevelopmentPreflight.IdentityOperation,
                  captureOperation: NotikaDevelopmentPreflight.CapturedOperation? = nil,
                  maintenanceOperation: NotikaRustTestDriver.MaintenanceOperation? = nil) {
        self.repositoryCapture = repositoryCapture; self.identityOperation = identityOperation; self.captureOperation = captureOperation
        self.maintenanceOperation = maintenanceOperation ?? Self.maintenance
    }
    private static let maintenance: NotikaRustTestDriver.MaintenanceOperation = { repository, registry, date, zone in
        try await NotikaArtifactMaintenance(canonicalRepository: repository, registryRoot: registry, evaluatedAt: date, timeZone: zone).run(execute: true)
    }
    public func run(repository: String, helperExecutable: String, registryRoot: String? = nil,
                    environment: [String: String] = ProcessInfo.processInfo.environment, waitSeconds: Double? = nil,
                    runID: String = UUID().uuidString, startedAt: Date = Date(), timeZone: TimeZone = .current) async throws -> NotikaPreflightDriverResult {
        guard UUID(uuidString: runID)?.uuidString == runID else { throw NotikaPreflightDriverError.invalidArgument("runID") }
        if let waitSeconds, !waitSeconds.isFinite || waitSeconds < 0 { throw NotikaPreflightDriverError.invalidArgument("waitSeconds") }
        _ = try LocalCalendarRetention(evaluatedAt: startedAt, timeZone: timeZone)
        let helper = try preflightDriverHelper(helperExecutable), raw = try repositoryCapture ?? RepositoryCommandCapture()
        let observer = try NotikaRepositoryIdentity(repository: repository, capture: raw, environment: environment)
        guard controllerSame(observer.repository, repository) else { throw NotikaPreflightDriverError.invalidArgument("repository") }
        var child = environment
        child["PATH"] = repository + "/Scripts:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        let top = repositoryDecodedText(try await raw.capture(arguments: ["git", "rev-parse", "--show-toplevel"], workingDirectory: repository, environment: child))
        guard controllerSame(top, repository) else { throw NotikaPreflightDriverError.repositoryIsNotWorktreeRoot }
        let registry = registryRoot ?? environment["AGENTLEASE_HOME"] ?? repository + "/.agentlease"
        guard registry.hasPrefix("/"), !registry.utf8.contains(0) else { throw NotikaPreflightDriverError.invalidArgument("registryRoot") }
        var maintenance: NotikaArtifactMaintenanceReport?, maintenanceFailures: [String] = []
        do { maintenance = try await maintenanceOperation(repository, registry, startedAt, timeZone) }
        catch { maintenanceFailures.append(String(describing: error)) }
        try Task.checkCancellation()
        let writer = try await preflightDriverWriter(repository: repository, registry: registry, runID: runID, wait: waitSeconds)
        defer { writer.release() }
        let artifacts = try ControllerSessionArtifacts(repository: repository, runID: runID), state = PreflightDriverState()
        do {
            let progress = try preflightDriverReport(artifacts: artifacts, repository: repository, runID: runID,
                started: startedAt, completed: nil, timeZone: timeZone, state: state)
            try artifacts.publish(sealedData: progress.originalData, name: "in-progress.json", validating: {})
        } catch { state.publicationFailure(error) }
        if state.publicationFailures.isEmpty {
            do {
                let executionEnvironment = child, identity = identityOperation, capture = captureOperation
                let clean = try NotikaDevelopmentPreflight.environment(from: child)
                let identityProbe: NotikaDevelopmentPreflight.IdentityOperation = identity ?? {
                    try await NotikaDevelopmentPreflight.captureIdentity(repository: repository, environment: clean, capture: raw)
                }
                let trackIdentity: NotikaDevelopmentPreflight.IdentityOperation = {
                    let value = try await identityProbe(); state.observed(value); return value
                }
                let plan = try NotikaProjectOwnershipPlan(rustTestFor: repository)
                let evidence = try await NotikaProjectAdmission().withOwnership(plan, registryRoot: registry, label: "notika-development-preflight",
                    runID: runID, waitSeconds: waitSeconds) { ownership in
                    await NotikaDevelopmentPreflight().runCapturedBorrowingArtifacts(helperExecutable: helper, artifacts: artifacts, ownership: ownership,
                        retainedWriterDescriptors: writer.inheritedDescriptors, nativeDirectoryDescriptor: artifacts.repositoryDescriptor,
                        environment: executionEnvironment, waitSeconds: waitSeconds, identityOperation: trackIdentity, captureOperation: capture,
                        validate: { try artifacts.revalidate() })
                }
                state.completed(evidence)
            } catch { state.failure(error) }
        }
        state.markCancelled(Task.isCancelled)
        do { try state.revalidateCaptures() } catch { state.publicationFailure(error) }
        do {
            let terminal = try preflightDriverReport(artifacts: artifacts, repository: repository, runID: runID,
                started: startedAt, completed: Date(), timeZone: timeZone, state: state)
            try artifacts.publish(sealedData: terminal.originalData, name: "manifest.json", validating: {
                if state.publicationFailures.isEmpty { try state.revalidateCaptures() }
            })
            state.published(terminal)
        } catch { state.publicationFailure(error) }
        let phases = state.evidence?.capturedPhases ?? [], native = phases.compactMap { $0.observation.termination }
        return .init(runID: runID, sessionPath: artifacts.path, report: state.terminal, rawCaptures: phases.map(\.rawCapture),
            nativeTermination: native.first { controllerExitCode($0) != 0 } ?? native.last, cancelled: state.cancelled,
            orchestrationFailures: state.orchestrationFailures, publicationFailures: state.publicationFailures,
            maintenanceReport: maintenance, maintenanceFailures: maintenanceFailures)
    }
}

private final class PreflightDriverState: Sendable {
    private struct State: Sendable { var evidence: NotikaDevelopmentPreflightEvidence?; var source: String?; var terminal: NotikaPreflightSessionReport?; var failures: [String] = []; var publication: [String] = []; var cancelled = false }
    private let state = Mutex(State())
    var evidence: NotikaDevelopmentPreflightEvidence? { state.withLock { $0.evidence } }
    var source: String? { state.withLock { $0.source } }
    var terminal: NotikaPreflightSessionReport? { state.withLock { $0.terminal } }
    var orchestrationFailures: [String] { state.withLock { $0.failures + ($0.evidence?.orchestrationFailures ?? []) } }
    var publicationFailures: [String] { state.withLock { $0.publication } }
    var cancelled: Bool { state.withLock { $0.cancelled || $0.evidence?.cancelled == true } }
    func observed(_ identity: NotikaPreflightIdentity) { state.withLock { if $0.source == nil { $0.source = identity.sourceDigest } } }
    func completed(_ evidence: NotikaDevelopmentPreflightEvidence) { state.withLock { $0.evidence = evidence } }
    func published(_ report: NotikaPreflightSessionReport) { state.withLock { $0.terminal = report } }
    func failure(_ error: Error) { state.withLock { $0.failures.append(String(describing: error)); $0.cancelled = $0.cancelled || error is CancellationError || Task.isCancelled } }
    func publicationFailure(_ error: Error) { state.withLock { $0.publication.append(String(describing: error)) } }
    func markCancelled(_ value: Bool) { state.withLock { $0.cancelled = $0.cancelled || value } }
    func revalidateCaptures() throws { try evidence?.revalidateForPublication() }
}
private func preflightDriverReport(artifacts: ControllerSessionArtifacts, repository: String, runID: String,
                                   started: Date, completed: Date?, timeZone: TimeZone, state: PreflightDriverState) throws -> NotikaPreflightSessionReport {
    guard let device = UInt64(exactly: artifacts.identity.st_dev) else { throw StrictJSONError.invalidSchema }
    let evidence = state.evidence, native = evidence?.capturedPhases.compactMap { $0.observation.termination } ?? []
    let failed = native.first { controllerExitCode($0) != 0 }, complete = evidence?.succeeded == true && !state.cancelled && state.orchestrationFailures.isEmpty
    let status = completed == nil ? ("running", Int32(0)) : preflightDriverStatus(nativeFailure: failed, cancelled: state.cancelled, complete: complete && state.publicationFailures.isEmpty)
    let value = CanonicalJSONValue.object([
        "namespace": .string(NotikaPreflightSessionReport.namespace), "schemaVersion": .integer(1), "toolVersion": .string(AgentBuild.version),
        "sessionID": .string(runID), "runUUID": .string(runID), "repository": .string(repository), "writerResource": .string("notika:sessions:" + repository),
        "ownerUID": .unsignedInteger(UInt64(geteuid())), "directoryIdentity": .object(["deviceID": .unsignedInteger(device), "inode": .unsignedInteger(UInt64(artifacts.identity.st_ino))]),
        "startedAt": .string(try preflightDriverTimestamp(started)), "completedAt": try completed.map { .string(try preflightDriverTimestamp($0)) } ?? .null,
        "expiresAt": try completed.map { .string(try preflightDriverTimestamp(LocalCalendarRetention(evaluatedAt: $0, timeZone: timeZone).nextLocalMidnight)) } ?? .null,
        "localTimeZone": .string(timeZone.identifier), "lifecycle": .string(completed == nil ? "inProgress" : "terminal"), "status": .string(status.0),
        "exitCode": completed == nil ? .null : .integer(Int64(status.1)), "nativeTermination": try controllerEncoded(failed ?? native.last), "cancelled": .bool(state.cancelled),
        "executionComplete": .bool(complete), "sourceBeforeSHA256": evidence == nil ? .null : state.source.map(CanonicalJSONValue.string) ?? .null,
        "evidence": try evidence?.canonicalValue ?? .null, "orchestrationFailures": .array(state.orchestrationFailures.map(CanonicalJSONValue.string)),
        "publicationFailures": .array(state.publicationFailures.map(CanonicalJSONValue.string)),
    ])
    return try NotikaPreflightSessionReport(data: CanonicalJSONDigest.encode(value), expectedRepository: repository, expectedSessionID: runID)
}
private func preflightDriverWriter(repository: String, registry: String, runID: String, wait: Double?) async throws -> LeaseSet {
    let paths = try AgentLeasePaths.open(selectedRoot: registry), resources = try ResourceSet(exclusive: [], shared: ["notika:sessions:" + repository])
    let pid = getpid(), timestamp = RunRecord.timestamp()
    return try await LeaseSet.acquire(resources, paths: paths, waitSeconds: wait, initialMetadata: { lease in
        LockMetadata(resourceName: lease.resource.value, leaseMode: lease.mode, runID: runID, coordinatorPID: pid, childPID: nil,
            mode: .run, state: .acquired, label: "notika-preflight-session-writer", bead: nil, acquiredAt: timestamp)
    })
}
private func preflightDriverStatus(nativeFailure: RunTermination?, cancelled: Bool, complete: Bool) -> (String, Int32) {
    if let nativeFailure { return ("failed", controllerExitCode(nativeFailure)) }
    if cancelled { return ("cancelled", 130) }
    return complete ? ("succeeded", 0) : ("inconclusive", 70)
}
private func preflightDriverHelper(_ path: String) throws -> String {
    guard path.hasPrefix("/"), !path.utf8.contains(0), let resolved = path.withCString({ realpath($0, nil) }) else { throw NotikaPreflightDriverError.unavailableHelper }
    defer { free(resolved) }
    guard let value = String(validatingCString: resolved) else { throw NotikaPreflightDriverError.unavailableHelper }
    var metadata = stat()
    guard lstat(value, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, access(value, X_OK) == 0 else { throw NotikaPreflightDriverError.unavailableHelper }; return value
}
private func preflightDriverDate(_ object: StrictJSONObject, _ key: String) throws -> Date {
    let text = try controllerString(object, key), formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = formatter.date(from: text), try preflightDriverTimestamp(date) == text else { throw StrictJSONError.invalidSchema }; return date
}
private func preflightDriverTimestamp(_ date: Date) throws -> String {
    guard date.timeIntervalSinceReferenceDate.isFinite else { throw StrictJSONError.invalidSchema }
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}
