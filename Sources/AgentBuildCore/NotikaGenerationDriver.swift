import AgentLeaseCore
import Darwin
import Foundation
import Synchronization

public enum NotikaGenerationDriverError: Error, Equatable, Sendable {
    case invalidArgument(String)
    case repositoryIsNotWorktreeRoot
    case toolUnavailable(String)
    case invalidReport(String)
    case artifactIO(String, Int32)
    case artifactChanged
}

/// Generation evidence has its own closed schema; it never claims an Xcode
/// build request, compatible DerivedData cache, or graph-freshness receipt.
public struct NotikaGenerationSessionReport: Sendable {
    public static let namespace = "agentbuild.notika-generation"
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
        let document = try StrictJSONDocument(data: data)
        let root = try document.root.requireObject().project(requiredKeys: [
            "namespace", "schemaVersion", "toolVersion", "sessionID", "runUUID", "repository", "writerResource",
            "ownerUID", "directoryIdentity", "startedAt", "completedAt", "expiresAt", "localTimeZone",
            "lifecycle", "status", "exitCode", "nativeTermination", "cancelled", "cached", "executionComplete",
            "sourceBefore", "sourceAfter", "phases", "retiredGraphEntries", "removedWorkspaceScheme",
            "orchestrationFailures", "publicationFailures",
        ])
        let repository = try generationString(root, "repository")
        _ = try CacheCompatibilityIdentity.graphResourceName(canonicalWorktree: repository)
        let sessionID = try generationString(root, "sessionID")
        guard UUID(uuidString: sessionID)?.uuidString == sessionID,
              try generationString(root, "runUUID") == sessionID,
              try generationString(root, "namespace") == Self.namespace,
              try generationInteger(root, "schemaVersion") == 1,
              !(try generationString(root, "toolVersion")).isEmpty,
              try generationString(root, "writerResource").utf8.elementsEqual(("notika:sessions:" + repository).utf8),
              try generationUnsigned(root, "ownerUID") <= UInt64(UInt32.max) else { throw generationSchema("identity") }
        if let expectedRepository, !repository.utf8.elementsEqual(expectedRepository.utf8) { throw generationSchema("repository") }
        if let expectedSessionID, !sessionID.utf8.elementsEqual(expectedSessionID.utf8) { throw generationSchema("sessionID") }
        let directory = try root.requiredValue(forKey: "directoryIdentity").requireObject()
            .project(requiredKeys: ["deviceID", "inode"])
        _ = try generationUnsigned(directory, "deviceID")
        guard try generationUnsigned(directory, "inode") > 0 else { throw generationSchema("directoryIdentity") }
        let started = try generationDate(root, "startedAt")
        guard let zone = TimeZone(identifier: try generationString(root, "localTimeZone")) else { throw generationSchema("localTimeZone") }
        let lifecycle = try generationString(root, "lifecycle")
        let status = try generationString(root, "status")
        let cancelled = try generationBool(root, "cancelled")
        let cached = try generationBool(root, "cached")
        let complete = try generationBool(root, "executionComplete")
        let failures = try generationStrings(root, "orchestrationFailures")
        let publicationFailures = try generationStrings(root, "publicationFailures")
        let retired = try generationStrings(root, "retiredGraphEntries")
        let schemeRemoved = try generationBool(root, "removedWorkspaceScheme")
        for name in ["sourceBefore", "sourceAfter"] {
            let value = try root.requiredValue(forKey: name)
            if value != .null {
                let snapshot = try value.requireObject().project(requiredKeys: ["keyMaterial", "sha256"])
                let material = try snapshot.requiredValue(forKey: "keyMaterial").requireObject()
                guard try generationString(material, "canonicalWorktree").utf8.elementsEqual(repository.utf8),
                      try generationString(snapshot, "sha256") == CanonicalJSONDigest.sha256(generationCanonical(.object(material))) else {
                    throw generationSchema(name)
                }
            }
        }
        let phases = try generationPhases(root.requiredValue(forKey: "phases"), repository: repository,
                                          sessionID: sessionID, cached: cached)
        let native = try generationTermination(root.requiredValue(forKey: "nativeTermination"))
        let nativeFailure = phases.compactMap(\.termination).first { generationExitCode($0) != 0 }
        guard native == (nativeFailure ?? phases.compactMap(\.termination).last) else { throw generationSchema("nativeTermination") }
        let retirementNames = phases.filter { $0.succeeded && $0.step.hasPrefix("retire-") }.map { String($0.step.dropFirst(7)) }
        guard retired == Array(retirementNames.prefix(retired.count)),
              !phases.contains(where: { $0.cancelled }) || cancelled else { throw generationSchema("retiredGraphEntries") }
        if complete {
            guard phases.first?.step == "prepare-htt-mini.sh", phases.dropFirst().first?.step == "prepare-onnxruntime.sh",
                  phases.last?.step == "tuist-generate", phases.allSatisfy(\.succeeded),
                  retired == retirementNames, !cancelled,
                  root.value(forKey: "sourceBefore") != .null, root.value(forKey: "sourceAfter") != .null else {
                throw generationSchema("executionComplete")
            }
        } else if schemeRemoved {
            // A late cancellation may follow completed graph publication. Keep
            // that observed removal without advertising execution success.
            guard phases.last?.step == "tuist-generate", phases.last?.succeeded == true,
                  root.value(forKey: "sourceAfter") != .null else { throw generationSchema("removedWorkspaceScheme") }
        }
        let code: Int32?
        switch lifecycle {
        case "inProgress":
            guard status == "running", !complete, !cancelled, phases.isEmpty, native == nil,
                  failures.isEmpty, publicationFailures.isEmpty, retired.isEmpty, !schemeRemoved,
                  root.value(forKey: "completedAt") == .null, root.value(forKey: "expiresAt") == .null,
                  root.value(forKey: "exitCode") == .null,
                  root.value(forKey: "sourceBefore") == .null, root.value(forKey: "sourceAfter") == .null else {
                throw generationSchema("inProgress")
            }
            code = nil
        case "terminal":
            let completed = try generationDate(root, "completedAt"), expires = try generationDate(root, "expiresAt")
            let expectedExpiry = try LocalCalendarRetention(evaluatedAt: completed, timeZone: zone).nextLocalMidnight
            guard started <= completed, completed < expires, abs(expires.timeIntervalSince(expectedExpiry)) < 0.001 else {
                throw generationSchema("timestamps")
            }
            let expected = generationStatus(nativeFailure: nativeFailure, cancelled: cancelled,
                complete: complete, failures: failures + publicationFailures,
                capturesAdmitted: phases.allSatisfy(\.captureAdmitted))
            guard status == expected.0, try generationInteger(root, "exitCode") == Int64(expected.1) else {
                throw generationSchema("exitCode")
            }
            code = expected.1
        default: throw generationSchema("lifecycle")
        }
        originalData = data; canonicalValue = try generationCanonical(document.root); digest = document.digest
        self.sessionID = sessionID; self.repository = repository; self.lifecycle = lifecycle; self.status = status
        exitCode = code; nativeTermination = native; self.cancelled = cancelled
    }

    /// A package-only fixture uses the actual pinned writer and real shared
    /// lease, without claiming native execution or constructing a build request.
    internal static func publishDiagnosticFixture(
        repository: String, registryRoot: String, sessionID: String = UUID().uuidString,
        startedAt: Date, completedAt: Date?, timeZone: TimeZone
    ) async throws -> Self {
        guard UUID(uuidString: sessionID)?.uuidString == sessionID else { throw generationSchema("sessionID") }
        let paths = try AgentLeasePaths.open(selectedRoot: registryRoot)
        let resources = try ResourceSet(exclusive: [], shared: ["notika:sessions:" + repository])
        let pid = getpid(), timestamp = RunRecord.timestamp()
        let leases = try await LeaseSet.acquire(resources, paths: paths, waitSeconds: 0, initialMetadata: { lease in
            LockMetadata(resourceName: lease.resource.value, leaseMode: lease.mode, runID: sessionID,
                coordinatorPID: pid, childPID: nil, mode: .run, state: .acquired,
                label: "notika-generation-fixture", bead: nil, acquiredAt: timestamp)
        })
        defer { leases.release() }
        let session = try NotikaControllerSessionArtifacts(repository: repository, runID: sessionID), state = GenerationDriverState()
        let progress = try generationReport(session: session, runID: sessionID, repository: repository, cached: false,
            started: startedAt, completed: nil, timeZone: timeZone, state: state, report: nil)
        try session.publish(progress, name: "in-progress.json", validating: {})
        guard let completedAt else { return progress }
        state.failure(NotikaGenerationDriverError.invalidArgument("diagnostic fixture"), cancelled: false)
        let terminal = try generationReport(session: session, runID: sessionID, repository: repository, cached: false,
            started: startedAt, completed: completedAt, timeZone: timeZone, state: state, report: nil)
        try session.publish(terminal, name: "manifest.json", validating: {})
        return terminal
    }
}

public struct NotikaGenerationDriverResult: Sendable {
    public let runID: String
    public let sessionPath: String?
    public let report: NotikaGenerationSessionReport?
    public let rawCaptures: [NativeLogCaptureResult]
    public let nativeTermination: RunTermination?
    public let orchestrationFailures: [String]
    public let publicationFailures: [String]
    public let cancelled: Bool
    public let maintenanceReport: NotikaArtifactMaintenanceReport?
    public let maintenanceFailures: [String]
    public var status: String { finalStatus.0 }
    public var exitCode: Int32 { finalStatus.1 }
    private var finalStatus: (String, Int32) {
        generationStatus(nativeFailure: nativeTermination.flatMap { generationExitCode($0) != 0 ? $0 : nil },
            cancelled: cancelled, complete: report?.status == "succeeded",
            failures: orchestrationFailures + publicationFailures, capturesAdmitted: report != nil)
    }
    public func jsonData() throws -> Data {
        try CanonicalJSONDigest.encode(.object([
            "namespace": .string("agentbuild.notika-generation-result"), "schemaVersion": .integer(1),
            "runID": .string(runID), "sessionPath": sessionPath.map(CanonicalJSONValue.string) ?? .null,
            "status": .string(status), "exitCode": .integer(Int64(exitCode)), "cancelled": .bool(cancelled),
            "nativeTermination": generationTerminationValue(nativeTermination),
            "orchestrationFailures": .array(orchestrationFailures.map(CanonicalJSONValue.string)),
            "publicationFailures": .array(publicationFailures.map(CanonicalJSONValue.string)),
            "sessionReport": report?.canonicalValue ?? .null,
            "maintenanceReport": try maintenanceReport.map(controllerEncoded) ?? .null,
            "maintenanceFailures": .array(maintenanceFailures.map(CanonicalJSONValue.string)),
        ]))
    }
}

/// The session-writer lease precedes exclusive graph ownership; the existing
/// coordinator admits account compilation only for Tuist. All actual commands,
/// including Trash, await worker retirement and bounded raw-pipe EOF.
public struct NotikaGenerationDriver: Sendable {
    internal typealias CaptureOperation = @Sendable (String, DarwinWorkloadCommand, [Int32], String, Int32) async throws -> CapturedNativePhase
    private let identityCapture: (any RepositoryCommandCapturing)?
    private let captureOperation: CaptureOperation
    public init() { identityCapture = nil; captureOperation = Self.capture }
    internal init(identityCapture: any RepositoryCommandCapturing) {
        self.identityCapture = identityCapture; captureOperation = Self.capture
    }
    internal init(identityCapture: any RepositoryCommandCapturing, captureOperation: @escaping CaptureOperation) {
        self.identityCapture = identityCapture; self.captureOperation = captureOperation
    }
    private static let capture: CaptureOperation = { helper, command, descriptors, root, directory in
        try await CapturedNativePhaseRunner().run(helperExecutable: helper, command: command,
            retainedLockDescriptors: descriptors, nativeWorkingDirectoryDescriptor: directory, artifactRoot: root)
    }

    public func run(repository: String, helperExecutable: String, registryRoot: String? = nil,
                    environment: [String: String] = ProcessInfo.processInfo.environment,
                    cached: Bool = false, waitSeconds: Double? = nil, runID: String = UUID().uuidString,
                    startedAt: Date = Date(), timeZone: TimeZone = .current) async throws -> NotikaGenerationDriverResult {
        guard UUID(uuidString: runID)?.uuidString == runID else { throw NotikaGenerationDriverError.invalidArgument("runID") }
        if let waitSeconds, !waitSeconds.isFinite || waitSeconds < 0 { throw NotikaGenerationDriverError.invalidArgument("waitSeconds") }
        _ = try LocalCalendarRetention(evaluatedAt: startedAt, timeZone: timeZone)
        let helper = try generationExecutable(helperExecutable)
        let capture = try identityCapture ?? RepositoryCommandCapture()
        let observer = try NotikaRepositoryIdentity(repository: repository, capture: capture, environment: environment)
        guard repository.utf8.elementsEqual(observer.repository.utf8) else { throw NotikaGenerationDriverError.invalidArgument("repository") }
        var childEnvironment = environment
        childEnvironment["PATH"] = repository + "/Scripts:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        let topLevel = repositoryDecodedText(try await capture.capture(arguments: ["git", "rev-parse", "--show-toplevel"],
            workingDirectory: repository, environment: childEnvironment))
        guard topLevel.utf8.elementsEqual(repository.utf8) else { throw NotikaGenerationDriverError.repositoryIsNotWorktreeRoot }
        let trash = try generationFindExecutable("trash", environment: childEnvironment)
        let registry = registryRoot ?? environment["AGENTLEASE_HOME"] ?? repository + "/.agentlease"
        guard registry.hasPrefix("/"), !registry.utf8.contains(0) else { throw NotikaGenerationDriverError.invalidArgument("registryRoot") }
        var maintenance: NotikaArtifactMaintenanceReport?, maintenanceFailures: [String] = []
        do { maintenance = try await NotikaArtifactMaintenance(canonicalRepository: repository, registryRoot: registry, evaluatedAt: startedAt, timeZone: timeZone).run(execute: true) }
        catch { maintenanceFailures.append(String(describing: error)) }
        try Task.checkCancellation()
        let paths = try AgentLeasePaths.open(selectedRoot: registry)
        let writerResource = "notika:sessions:" + repository
        let resources = try ResourceSet(exclusive: [], shared: [writerResource])
        let pid = getpid(), acquired = RunRecord.timestamp()
        let leases = try await LeaseSet.acquire(resources, paths: paths, waitSeconds: waitSeconds,
            initialMetadata: { lease in
                LockMetadata(resourceName: lease.resource.value, leaseMode: lease.mode, runID: runID, coordinatorPID: pid,
                    childPID: nil, mode: .run, state: .acquired, label: "notika-generation-session-writer", bead: nil, acquiredAt: acquired)
            })
        defer { leases.release() }
        try Task.checkCancellation()
        let session = try NotikaControllerSessionArtifacts(repository: repository, runID: runID)
        let state = GenerationDriverState()
        let writerDescriptors = leases.inheritedDescriptors
        let executionEnvironment = childEnvironment
        let nativeOperation = captureOperation
        do {
            let progress = try generationReport(session: session, runID: runID, repository: repository, cached: cached,
                started: startedAt, completed: nil, timeZone: timeZone, state: state, report: nil)
            try session.publish(progress, name: "in-progress.json", validating: {})
        } catch { state.publicationFailure(error) }
        if state.publicationFailures.isEmpty {
            do {
                let operation: @Sendable (String, DarwinWorkloadCommand, [Int32]) async throws -> NotikaGenerationCommandOutcome = { step, command, descriptors in
                    try session.revalidate()
                    let phase = try await nativeOperation(helper, command, writerDescriptors + descriptors, session.path, session.repositoryDescriptor)
                    let expected = try generationCommandValue(command)
                    guard try generationCommandValue(phase.command) == expected else { throw generationSchema("capturedCommand") }
                    state.retain(step: step, phase: phase)
                    try session.revalidate()
                    return generationOutcome(phase.observation)
                }
                let report = try await NotikaGenerationCoordinator().run(repository: repository, registryRoot: registry,
                    environment: executionEnvironment, cached: cached, waitSeconds: waitSeconds, identityCapture: capture,
                    commandOperation: { command, descriptors in
                        let name = command.executable == repository + "/Scripts/tuist" ? "tuist-generate" : URL(fileURLWithPath: command.executable).lastPathComponent
                        return try await operation(name, command, descriptors)
                    }, retirementOperation: { entry, descriptors in
                        try entry.validate()
                        var retirementEnvironment = try NotikaChildEnvironmentPolicy.inheritedEnvironment(from: executionEnvironment)
                        retirementEnvironment["SRCROOT"] = repository
                        let command = try DarwinWorkloadCommand(executable: trash, arguments: [entry.absolutePath],
                            workingDirectory: repository, environment: retirementEnvironment)
                        let outcome = try await operation("retire-" + entry.relativeName, command, descriptors)
                        if outcome.succeeded {
                            var named = stat()
                            if fstatat(entry.parentDescriptor, entry.relativeName, &named, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT {
                                state.retired(entry.relativeName)
                            }
                        }
                        return outcome
                    })
                state.completed(report)
            } catch { state.failure(error, cancelled: error is CancellationError || Task.isCancelled) }
        }
        state.markCancelled(Task.isCancelled)
        do {
            try state.revalidateCaptures()
        } catch { state.publicationFailure(error) }
        do {
            let terminal = try generationReport(session: session, runID: runID, repository: repository, cached: cached,
                started: startedAt, completed: Date(), timeZone: timeZone, state: state, report: state.generationReport)
            try session.publish(terminal, name: "manifest.json", validating: {
                if state.publicationFailures.isEmpty { try state.revalidateCaptures() }
            })
            state.published(terminal)
            if state.publicationFailures.isEmpty { try state.revalidateCaptures() }
            try session.revalidate()
        } catch { state.publicationFailure(error) }
        // Every capsule remains retained until final artifact checks finish;
        // helpers have already awaited quarantine when native receipt was lost.
        return state.result(runID: runID, sessionPath: session.path, maintenanceReport: maintenance, maintenanceFailures: maintenanceFailures)
    }
}

private struct GenerationDriverPhase: Sendable { let step: String; let capsule: CapturedNativePhase }
private final class GenerationDriverState: Sendable {
    private struct Value: Sendable {
        var phases: [GenerationDriverPhase] = []; var report: NotikaGenerationReport?
        var terminal: NotikaGenerationSessionReport?; var failures: [String] = []; var publication: [String] = []; var cancelled = false
        var retired: [String] = []
    }
    private let state = Mutex(Value())
    var generationReport: NotikaGenerationReport? { state.withLock { $0.report } }
    var phases: [GenerationDriverPhase] { state.withLock { $0.phases } }
    var publicationFailures: [String] { state.withLock { $0.publication } }
    var orchestrationFailures: [String] { state.withLock { $0.failures } }
    var retiredGraphEntries: [String] { state.withLock { $0.retired } }
    var cancelled: Bool { state.withLock { $0.cancelled || $0.phases.contains { $0.capsule.observation.cancelled } } }
    func retain(step: String, phase: CapturedNativePhase) { state.withLock { $0.phases.append(.init(step: step, capsule: phase)) } }
    func completed(_ report: NotikaGenerationReport) { state.withLock { $0.report = report } }
    func retired(_ name: String) { state.withLock { $0.retired.append(name) } }
    func failure(_ error: any Error, cancelled: Bool) { state.withLock { $0.failures.append(String(describing: error)); $0.cancelled = $0.cancelled || cancelled } }
    func publicationFailure(_ error: any Error) { state.withLock { $0.publication.append(String(describing: error)) } }
    func markCancelled(_ value: Bool) { state.withLock { $0.cancelled = $0.cancelled || value } }
    func published(_ report: NotikaGenerationSessionReport) { state.withLock { $0.terminal = report } }
    func revalidateCaptures() throws { for phase in phases { try phase.capsule.revalidateForPublication() } }
    func result(runID: String, sessionPath: String, maintenanceReport: NotikaArtifactMaintenanceReport?, maintenanceFailures: [String]) -> NotikaGenerationDriverResult {
        state.withLock { value in
            let native = value.phases.compactMap { $0.capsule.observation.termination }
            return .init(runID: runID, sessionPath: sessionPath, report: value.terminal, rawCaptures: value.phases.map { $0.capsule.rawCapture },
                nativeTermination: native.first { generationExitCode($0) != 0 } ?? native.last,
                orchestrationFailures: value.failures, publicationFailures: value.publication,
                cancelled: value.cancelled || value.phases.contains { $0.capsule.observation.cancelled },
                maintenanceReport: maintenanceReport, maintenanceFailures: maintenanceFailures)
        }
    }
}

private func generationReport(session: NotikaControllerSessionArtifacts, runID: String, repository: String, cached: Bool,
                              started: Date, completed: Date?, timeZone: TimeZone, state: GenerationDriverState,
                              report: NotikaGenerationReport?) throws -> NotikaGenerationSessionReport {
    let phases = state.phases
    guard let device = UInt64(exactly: session.identity.st_dev) else { throw generationSchema("directoryIdentity.deviceID") }
    let native = phases.compactMap { $0.capsule.observation.termination }
    let failed = native.first { generationExitCode($0) != 0 }
    let admitted = state.publicationFailures.isEmpty
    let status = completed == nil ? ("running", Int32(0)) : generationStatus(nativeFailure: failed, cancelled: state.cancelled,
        complete: report != nil, failures: state.orchestrationFailures + state.publicationFailures, capturesAdmitted: admitted)
    let retired = state.retiredGraphEntries
    let value = CanonicalJSONValue.object([
        "namespace": .string(NotikaGenerationSessionReport.namespace), "schemaVersion": .integer(1), "toolVersion": .string(AgentBuild.version),
        "sessionID": .string(runID), "runUUID": .string(runID), "repository": .string(repository), "writerResource": .string("notika:sessions:" + repository),
        "ownerUID": .unsignedInteger(UInt64(geteuid())),
        "directoryIdentity": .object(["deviceID": .unsignedInteger(device), "inode": .unsignedInteger(UInt64(session.identity.st_ino))]),
        "startedAt": .string(try generationTimestamp(started)),
        "completedAt": try completed.map { .string(try generationTimestamp($0)) } ?? .null,
        "expiresAt": try completed.map { .string(try generationTimestamp(LocalCalendarRetention(evaluatedAt: $0, timeZone: timeZone).nextLocalMidnight)) } ?? .null,
        "localTimeZone": .string(timeZone.identifier), "lifecycle": .string(completed == nil ? "inProgress" : "terminal"),
        "status": .string(status.0), "exitCode": completed == nil ? .null : .integer(Int64(status.1)),
        "nativeTermination": generationTerminationValue(failed ?? native.last), "cancelled": .bool(state.cancelled), "cached": .bool(cached),
        "executionComplete": .bool(report != nil && !state.cancelled), "sourceBefore": try generationSnapshot(report?.sourceBefore), "sourceAfter": try generationSnapshot(report?.sourceAfter),
        "phases": .array(try phases.map { phase in
            let capsule = phase.capsule
            return .object([
                "step": .string(phase.step), "command": try generationCommandValue(capsule.command),
                "nativeTermination": generationTerminationValue(capsule.observation.termination),
                "retirement": .string(capsule.observation.retirement.rawValue), "cancelled": .bool(capsule.observation.cancelled),
                "failures": try generationEncoded(capsule.observation.failures),
                "rawCapture": try generationEncoded(capsule.rawCapture), "publicationAdmitted": .bool(admitted),
            ])
        }),
        "retiredGraphEntries": .array(retired.map(CanonicalJSONValue.string)), "removedWorkspaceScheme": .bool(report?.removedWorkspaceScheme ?? false),
        "orchestrationFailures": .array(state.orchestrationFailures.map(CanonicalJSONValue.string)),
        "publicationFailures": .array(state.publicationFailures.map(CanonicalJSONValue.string)),
    ])
    return try NotikaGenerationSessionReport(data: CanonicalJSONDigest.encode(value), expectedRepository: repository, expectedSessionID: runID)
}

private func generationOutcome(_ observation: NotikaNativeObservation) -> NotikaGenerationCommandOutcome {
    .init(nativeTermination: observation.termination, retirementProven: observation.retirement == .workerReaped || observation.retirement == .notStarted,
          cancelled: observation.cancelled, failures: observation.failures)
}
private func generationStatus(nativeFailure: RunTermination?, cancelled: Bool, complete: Bool,
                              failures: [String], capturesAdmitted: Bool) -> (String, Int32) {
    if let nativeFailure { return ("failed", generationExitCode(nativeFailure)) }
    if cancelled { return ("cancelled", 130) }
    if !complete || !failures.isEmpty || !capturesAdmitted { return ("inconclusive", 70) }
    return ("succeeded", 0)
}
private func generationExitCode(_ value: RunTermination) -> Int32 { value.kind == .exit ? value.value : 128 + value.value }
private func generationTerminationValue(_ value: RunTermination?) -> CanonicalJSONValue {
    value.map { .object(["kind": .string($0.kind.rawValue), "value": .integer(Int64($0.value))]) } ?? .null
}
private func generationCommandValue(_ command: DarwinWorkloadCommand) throws -> CanonicalJSONValue {
    .object(["executable": .string(command.executable), "arguments": .array(command.arguments.map(CanonicalJSONValue.string)),
             "workingDirectory": .string(command.workingDirectory),
             "environmentSHA256": .string(try CanonicalJSONDigest.sha256(.object(command.environment.mapValues(CanonicalJSONValue.string))))])
}
private func generationSnapshot(_ source: NotikaSourceIdentity?) throws -> CanonicalJSONValue {
    guard let source else { return .null }
    return .object(["keyMaterial": source.keyMaterial, "sha256": .string(try source.digest())])
}

private struct GenerationParsedPhase { let step: String; let termination: RunTermination?; let succeeded: Bool; let captureAdmitted: Bool; let cancelled: Bool }
private func generationPhases(_ value: StrictJSONValue, repository: String, sessionID: String, cached: Bool) throws -> [GenerationParsedPhase] {
    guard case .array(let values) = value, values.count <= 5 else { throw generationSchema("phases") }
    let ordered = ["prepare-htt-mini.sh", "prepare-onnxruntime.sh", "retire-Notika.xcodeproj", "retire-Notika.xcworkspace", "tuist-generate"]
    var previous = -1, parsed: [GenerationParsedPhase] = []
    for value in values {
        let phase = try value.requireObject().project(requiredKeys: ["step", "command", "nativeTermination", "retirement", "cancelled", "failures", "rawCapture", "publicationAdmitted"])
        let step = try generationString(phase, "step")
        guard let index = ordered.firstIndex(of: step), index > previous,
              (parsed.isEmpty ? index == 0 : previous >= 1 || index == 1), parsed.allSatisfy(\.succeeded) else { throw generationSchema("phaseOrder") }
        previous = index
        let command = try phase.requiredValue(forKey: "command").requireObject()
            .project(requiredKeys: ["executable", "arguments", "workingDirectory", "environmentSHA256"])
        let executable = try generationString(command, "executable"), arguments = try generationStrings(command, "arguments")
        guard executable.hasPrefix("/"), !executable.utf8.contains(0),
              try generationString(command, "workingDirectory").utf8.elementsEqual(repository.utf8),
              generationSHA(try generationString(command, "environmentSHA256")) else { throw generationSchema("command") }
        if index < 2 {
            guard executable.utf8.elementsEqual((repository + "/Scripts/bridges/" + step).utf8), arguments.isEmpty else { throw generationSchema("preparation") }
        } else if index == 4 {
            guard executable.utf8.elementsEqual((repository + "/Scripts/tuist").utf8), arguments == ["generate", "--no-open"] else { throw generationSchema("tuist") }
        } else if arguments.map({ Data($0.utf8) }) != [Data((repository + "/" + String(step.dropFirst(7))).utf8)] { throw generationSchema("retirement") }
        let native = try generationTermination(phase.requiredValue(forKey: "nativeTermination"))
        let retirement = try generationString(phase, "retirement")
        guard NotikaNativeRetirementEvidence(rawValue: retirement) != nil else { throw generationSchema("retirementEvidence") }
        if retirement == "workerReaped", native == nil { throw generationSchema("nativeTermination") }
        if retirement != "workerReaped", native != nil { throw generationSchema("nativeTermination") }
        let cancelled = try generationBool(phase, "cancelled")
        try generationValidateFailures(phase.requiredValue(forKey: "failures"), capture: false)
        let failureData = try CanonicalJSONDigest.encode(generationCanonical(phase.requiredValue(forKey: "failures")))
        let failures = try JSONDecoder().decode([DarwinWorkloadFailure].self, from: failureData)
        // Validate exact capture shape before Codable, which tolerates unknown fields.
        let captureObject = try phase.requiredValue(forKey: "rawCapture").requireObject().project(
            requiredKeys: ["standardOutput", "standardError", "maximumBytes", "captureComplete", "failures"])
        for name in ["standardOutput", "standardError"] {
            let stream = try captureObject.requiredValue(forKey: name).requireObject().project(requiredKeys: ["path", "observedBytes", "retainedBytes", "sha256", "reachedEOF"])
            let path = try generationString(stream, "path")
            let root = repository + "/Artifacts/AgentSessions/" + sessionID + "/"
            let relative = path.utf8.starts(with: root.utf8) ? String(path.dropFirst(root.count)) : ""
            let pieces = relative.split(separator: "/", omittingEmptySubsequences: false)
            guard pieces.count == 2, UUID(uuidString: String(pieces[0]))?.uuidString.lowercased() == pieces[0].lowercased(),
                  pieces[1] == (name == "standardOutput" ? "stdout.log" : "stderr.log"),
                  generationSHA(try generationString(stream, "sha256")),
                  try generationUnsigned(stream, "retainedBytes") <= generationUnsigned(stream, "observedBytes") else { throw generationSchema("rawLog") }
            _ = try generationBool(stream, "reachedEOF")
        }
        try generationValidateFailures(captureObject.requiredValue(forKey: "failures"), capture: true)
        let raw = try JSONDecoder().decode(NativeLogCaptureResult.self,
            from: CanonicalJSONDigest.encode(generationCanonical(.object(captureObject))))
        guard (0...NativeLogCapture.maximumRawBytes).contains(raw.maximumBytes),
              (0...raw.maximumBytes).contains(raw.standardOutput.retainedBytes),
              (0...raw.maximumBytes).contains(raw.standardError.retainedBytes),
              raw.standardOutput.retainedBytes + raw.standardError.retainedBytes <= raw.maximumBytes else { throw generationSchema("rawCapture") }
        if raw.captureComplete {
            guard raw.failures.isEmpty, raw.standardOutput.reachedEOF, raw.standardError.reachedEOF,
                  raw.standardOutput.observedBytes == raw.standardOutput.retainedBytes,
                  raw.standardError.observedBytes == raw.standardError.retainedBytes else { throw generationSchema("captureComplete") }
        }
        let admitted = try generationBool(phase, "publicationAdmitted")
        let succeeded = native == .init(kind: .exit, value: 0) && retirement == "workerReaped" && !cancelled && failures.isEmpty && raw.captureComplete
        parsed.append(.init(step: step, termination: native, succeeded: succeeded, captureAdmitted: admitted && raw.captureComplete, cancelled: cancelled))
    }
    _ = cached // Explicit request flag is recorded; environment bytes are committed separately.
    return parsed
}

private func generationValidateFailures(_ value: StrictJSONValue, capture: Bool) throws {
    guard case .array(let values) = value, values.count <= 128 else { throw generationSchema("failures") }
    for value in values {
        let object = try value.requireObject().project(requiredKeys: ["operation"], optionalKeys: capture ? ["code", "detail", "stream"] : ["code", "detail"])
        guard !(try generationString(object, "operation")).isEmpty else { throw generationSchema("failure.operation") }
        if let code = object.value(forKey: "code"), code != .null {
            guard case .number(let value) = code, Int32(exactly: try value.int64()) != nil else { throw generationSchema("failure.code") }
        }
        if let detail = object.value(forKey: "detail"), detail != .null {
            guard case .string = detail else { throw generationSchema("failure.detail") }
        }
        if let stream = object.value(forKey: "stream"), stream != .null {
            guard case .string(let value) = stream, NativeLogStream(rawValue: value) != nil else { throw generationSchema("failure.stream") }
        }
    }
}

private extension NotikaControllerSessionArtifacts {
    func publish(_ report: NotikaGenerationSessionReport, name: String, validating: () throws -> Void) throws {
        try publish(sealedData: report.originalData, name: name, validating: validating)
    }
}

private func generationSchema(_ name: String) -> NotikaGenerationDriverError { .invalidReport(name) }
private func generationIO(_ operation: String) -> NotikaGenerationDriverError { .artifactIO(operation, errno) }
private func generationStat(_ descriptor: Int32) throws -> stat { var result = stat(); guard fstat(descriptor, &result) == 0 else { throw generationIO("stat generation inode") }; return result }
private func generationExecutable(_ path: String) throws -> String {
    guard path.hasPrefix("/"), !path.utf8.contains(0), let resolved = path.withCString({ realpath($0, nil) }) else { throw NotikaGenerationDriverError.toolUnavailable(path) }
    defer { free(resolved) }
    guard let result = String(validatingCString: resolved) else { throw NotikaGenerationDriverError.toolUnavailable(path) }
    var metadata = stat()
    guard lstat(result, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, access(result, X_OK) == 0 else { throw NotikaGenerationDriverError.toolUnavailable(path) }
    return result
}
private func generationFindExecutable(_ name: String, environment: [String: String]) throws -> String {
    for directory in (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":", omittingEmptySubsequences: false) where directory.hasPrefix("/") {
        let candidate = String(directory) + "/" + name
        if access(candidate, X_OK) == 0 { return try generationExecutable(candidate) }
    }
    throw NotikaGenerationDriverError.toolUnavailable(name)
}
private func generationSHA(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
private func generationString(_ object: StrictJSONObject, _ name: String) throws -> String { guard case .string(let value) = try object.requiredValue(forKey: name) else { throw generationSchema(name) }; return value }
private func generationInteger(_ object: StrictJSONObject, _ name: String) throws -> Int64 { guard case .number(let value) = try object.requiredValue(forKey: name) else { throw generationSchema(name) }; return try value.int64() }
private func generationUnsigned(_ object: StrictJSONObject, _ name: String) throws -> UInt64 { guard case .number(let value) = try object.requiredValue(forKey: name) else { throw generationSchema(name) }; return try value.uint64() }
private func generationBool(_ object: StrictJSONObject, _ name: String) throws -> Bool { guard case .bool(let value) = try object.requiredValue(forKey: name) else { throw generationSchema(name) }; return value }
private func generationStrings(_ object: StrictJSONObject, _ name: String) throws -> [String] { guard case .array(let values) = try object.requiredValue(forKey: name) else { throw generationSchema(name) }; return try values.map { guard case .string(let value) = $0 else { throw generationSchema(name) }; return value } }
private func generationTermination(_ value: StrictJSONValue) throws -> RunTermination? {
    if value == .null { return nil }
    let object = try value.requireObject().project(requiredKeys: ["kind", "value"])
    guard let kind = RunTermination.Kind(rawValue: try generationString(object, "kind")),
          let code = Int32(exactly: try generationInteger(object, "value")),
          (kind == .exit ? (0...255).contains(code) : (1...127).contains(code)) else { throw generationSchema("nativeTermination") }
    return .init(kind: kind, value: code)
}
private func generationDate(_ root: StrictJSONObject, _ field: String) throws -> Date {
    let string = try generationString(root, field), formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let value = formatter.date(from: string), try generationTimestamp(value) == string else { throw generationSchema(field) }
    return value
}
private func generationTimestamp(_ date: Date) throws -> String {
    guard date.timeIntervalSinceReferenceDate.isFinite else { throw generationSchema("timestamp") }
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}
private func generationEncoded(_ value: some Encodable) throws -> CanonicalJSONValue { try generationCanonical(StrictJSONDocument(data: JSONEncoder().encode(value)).root) }
private func generationCanonical(_ value: StrictJSONValue) throws -> CanonicalJSONValue {
    switch value {
    case .array(let values): .array(try values.map(generationCanonical))
    case .bool(let value): .bool(value)
    case .null: .null
    case .number(let value): value.lexicalValue.hasPrefix("-") ? .integer(try value.int64()) : .unsignedInteger(try value.uint64())
    case .object(let object): .object(try object.members.map { CanonicalJSONMember(key: $0.key, value: try generationCanonical($0.value)) })
    case .string(let value): .string(value)
    }
}
