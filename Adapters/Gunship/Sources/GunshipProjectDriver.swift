import AgentBuildCore
import AgentLeaseCore
import CryptoKit
import Darwin
import Dispatch
import Foundation
import Synchronization

public enum GunshipProjectDriverError: Error, Sendable, CustomStringConvertible {
    case invalidArgument(String)
    case ownershipExpired
    case changedInput(String)
    case archiveInUse(String, [Int32])
    case evidence(String)
    case io(String, Int32)

    public var description: String {
        switch self {
        case .invalidArgument(let detail): "invalid Gunship execution argument: \(detail)"
        case .ownershipExpired: "Gunship ownership expired"
        case .changedInput(let detail): "Gunship input changed: \(detail)"
        case .archiveInUse(let archive, let processes):
            "archive \(archive) is in use by process \(processes.map(String.init).joined(separator: ", ")); "
                + "close that game or choose another archive"
        case .evidence(let detail): "Gunship evidence: \(detail)"
        case .io(let operation, let code): "\(operation) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// Counts from the `index.json` Unreal exports for one automation run.
public struct GunshipAutomationSummary: Codable, Equatable, Sendable {
    public let succeeded: Int
    public let succeededWithWarnings: Int
    public let failed: Int
    public let notRun: Int
    public let failedTests: [String]
    public let reportSHA256: String

    public var passed: Bool { failed == 0 && notRun == 0 && succeeded + succeededWithWarnings > 0 }

    public static func parse(_ data: Data) throws -> GunshipAutomationSummary {
        // Unreal writes the report with a UTF-8 byte order mark.
        let body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        guard let report = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any] else {
            throw GunshipProjectDriverError.evidence("automation report is not a JSON object")
        }
        func count(_ name: String) throws -> Int {
            guard let value = report[name] as? Int, value >= 0 else {
                throw GunshipProjectDriverError.evidence("automation report has no \(name) count")
            }
            return value
        }
        let tests = report["tests"] as? [[String: Any]] ?? []
        return GunshipAutomationSummary(
            succeeded: try count("succeeded"), succeededWithWarnings: try count("succeededWithWarnings"),
            failed: try count("failed"), notRun: try count("notRun"),
            failedTests: tests.compactMap { $0["state"] as? String == "Fail" ? $0["fullTestPath"] as? String : nil }.sorted(),
            reportSHA256: CanonicalJSONDigest.digest(data))
    }
}

/// The verdict a packaged scenario wrote to its own `report.json`.
public struct GunshipValidationReport: Codable, Equatable, Sendable {
    public let path: String
    public let scenario: String?
    public let passed: Bool
    public let scenarioCompleted: Bool
    public let checks: Int
    public let failedChecks: [String]
    public let reportSHA256: String

    public static func parse(_ data: Data, path: String) throws -> GunshipValidationReport {
        guard let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GunshipProjectDriverError.evidence("validation report is not a JSON object: " + path)
        }
        let checks = report["checks"] as? [[String: Any]] ?? []
        return GunshipValidationReport(
            path: path, scenario: report["scenario"] as? String, passed: report["passed"] as? Bool == true,
            scenarioCompleted: report["scenario_completed"] as? Bool == true, checks: checks.count,
            failedChecks: checks.compactMap { $0["passed"] as? Bool == true ? nil : $0["name"] as? String ?? "unnamed" },
            reportSHA256: CanonicalJSONDigest.digest(data))
    }
}

public struct GunshipProjectResult: Sendable {
    public let runID: String
    public let sessionPath: String?
    public let productPath: String?
    public let status: String
    public let exitCode: Int32
    public let nativeTermination: RunTermination?
    public let rawCaptures: [NativeLogCaptureResult]
    public let automation: GunshipAutomationSummary?
    public let validationReports: [GunshipValidationReport]
    public let orchestrationFailures: [String]
    public let publicationFailures: [String]
    private let data: Data

    fileprivate init(report: GunshipSessionReport) throws {
        runID = report.runID; sessionPath = report.sessionPath; productPath = report.productPath
        status = report.status; exitCode = report.exitCode ?? 70; nativeTermination = report.nativeTermination
        rawCaptures = report.phases.map(\.rawCapture)
        automation = report.automation; validationReports = report.validationReports
        orchestrationFailures = report.orchestrationFailures; publicationFailures = report.publicationFailures
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        data = try encoder.encode(report)
    }

    public func jsonData() throws -> Data { data }
}

/// Gunship's Unreal workflows share AgentBuild's ownership, supervision, and
/// raw capture. Only Unreal Build Tool compiles enter host:compile.
public struct GunshipProjectDriver: Sendable {
    public init() {}

    public func plan(
        request: GunshipProjectRequest,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> GunshipProjectPlan {
        try await GunshipProjectPlanner.plan(request: request, environment: environment)
    }

    public func run(
        request: GunshipProjectRequest, helperExecutable: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        waitSeconds: Double? = nil,
        cancellationSignal: @escaping @Sendable () -> Int32? = { nil }
    ) async throws -> GunshipProjectResult {
        try GunshipLeaseBoundary.admit(request: request, environment: environment)
        guard helperExecutable.hasPrefix("/"), access(helperExecutable, X_OK) == 0 else {
            throw GunshipProjectDriverError.invalidArgument("helper executable")
        }
        let planning = environment.filter { $0.key != GunshipProjectPlanner.sessionEnvironmentKey }
        let initial = try await plan(request: request, environment: planning)
        // Refuse before waiting for leases: replacing or relaunching a running
        // game would disturb whoever is playing it.
        if let archive = initial.archive { try gunshipEnsureArchiveIdle(archive) }
        let runID = UUID().uuidString
        return try await GunshipProjectOwnership.withOwnership(
            plan: initial, runID: runID, environment: environment, waitSeconds: waitSeconds
        ) { ownership in
            var executionEnvironment = planning
            executionEnvironment[GunshipProjectPlanner.sessionEnvironmentKey] = ownership.session.path
            let admitted = try await plan(request: request, environment: executionEnvironment)
            guard admitted.identityKey == initial.identityKey, admitted.archive == initial.archive,
                  admitted.repository.utf8.elementsEqual(initial.repository.utf8) else {
                throw GunshipProjectDriverError.changedInput("toolchain, repository, or archive changed during admission")
            }
            let state = GunshipDriverState(plan: admitted, runID: runID, sessionPath: ownership.session.path)
            do {
                if let archive = admitted.archive { try gunshipEnsureArchiveIdle(archive) }
                let before = try await RepositorySourceSnapshot.capture(repository: admitted.repository, allowedPaths: [],
                    environment: executionEnvironment, projectFiles: [])
                state.value.withLock { $0.sourceBefore = before }
                if request.action == .validate, let product = admitted.productPath {
                    let digest = try gunshipFileSHA256(product + "/Contents/MacOS/Gunship")
                    state.value.withLock { $0.archiveExecutableBefore = digest }
                }
                try publish(state: state, ownership: ownership, lifecycle: "inProgress", name: "in-progress.json")
                let inherited = executionEnvironment.filter { ChildEnvironmentPolicy.inheritedNames.contains($0.key) }
                for phase in admitted.phases where state.succeededSoFar {
                    // Compilation can take minutes. Recheck at the last boundary
                    // before replacing or launching this archive, under its lease.
                    if let archive = admitted.archive, phase.kind == "package" || phase.kind == "validation" {
                        try gunshipEnsureArchiveIdle(archive)
                    }
                    _ = try await perform(phase, environment: inherited.merging(phase.environment) { $1 },
                        state: state, ownership: ownership, helper: helperExecutable,
                        admissionEnvironment: executionEnvironment, waitSeconds: waitSeconds)
                    // A failed run still reports which tests or checks failed.
                    if phase.kind == "test" { inspectAutomation(state: state, session: ownership.session.path) }
                    if phase.kind == "validation" { inspectValidation(state: state, session: ownership.session.path) }
                }
                if let product = admitted.productPath, state.succeededSoFar {
                    let executable = product + "/Contents/MacOS/" + URL(fileURLWithPath: product).deletingPathExtension().lastPathComponent
                    let digest = try gunshipFileSHA256(executable)
                    state.value.withLock { state in
                        if request.action == .validate {
                            state.archiveExecutableAfter = digest
                            if state.archiveExecutableBefore != digest { state.failures.append("archive changed during validation") }
                        } else { state.productExecutable = digest }
                    }
                }
                let after = try await RepositorySourceSnapshot.capture(repository: admitted.repository, allowedPaths: [],
                    environment: executionEnvironment, projectFiles: [])
                let closing = try await plan(request: request, environment: executionEnvironment)
                let complete = state.succeededSoFar
                state.value.withLock {
                    $0.sourceAfter = after
                    $0.sourceDrift = before.raw != after.raw
                    $0.toolDrift = admitted.identityKey != closing.identityKey
                    $0.executionComplete = complete
                }
            } catch {
                state.value.withLock {
                    $0.cancelled = $0.cancelled || error is CancellationError || Task.isCancelled
                    $0.failures.append(String(describing: error))
                }
            }
            // Freeze cancellation before publication so the manifest, returned
            // report, and CLI all use the same observed signal and exit code.
            state.value.withLock {
                $0.cancellationSignal = cancellationSignal()
                $0.cancelled = $0.cancelled || $0.cancellationSignal != nil
            }
            do { try publish(state: state, ownership: ownership, lifecycle: "terminal", name: "manifest.json") }
            catch { state.value.withLock { $0.publicationFailures.append(String(describing: error)) } }
            return try state.result(lifecycle: "terminal")
        }
    }

    private func perform(
        _ phase: GunshipProjectPhase, environment: [String: String], state: GunshipDriverState,
        ownership: GunshipProjectOwnership, helper: String, admissionEnvironment: [String: String], waitSeconds: Double?
    ) async throws -> CapturedNativePhase {
        try Task.checkCancellation()
        try ownership.revalidate()
        let command = try DarwinWorkloadCommand(executable: phase.executable, arguments: phase.arguments,
            workingDirectory: ownership.plan.repository, environment: environment, retirementScope: .session)
        let execute: @Sendable (CompilationLease?) async throws -> CapturedNativePhase = { lease in
            let descriptors = try ownership.descriptors() + (lease?.inheritedDescriptors() ?? [])
            return try await CapturedNativePhaseRunner().run(helperExecutable: helper, command: command,
                retainedLockDescriptors: descriptors,
                nativeWorkingDirectoryDescriptor: ownership.session.repositoryDescriptor,
                artifactRoot: ownership.session.path)
        }
        let capture: CapturedNativePhase
        if phase.requiresCompilation {
            capture = try await HostCompilationAdmission().withLease(environment: admissionEnvironment,
                label: "Gunship " + phase.step, waitSeconds: waitSeconds) { try await execute($0) }
        } else { capture = try await execute(nil) }
        state.value.withLock {
            $0.captures.append(capture)
            $0.phases.append(GunshipPhaseReport(phase: phase, capture: capture))
            $0.cancelled = $0.cancelled || capture.observation.cancelled
            if !capture.rawCapture.captureComplete { $0.failures.append("Incomplete raw evidence: " + phase.step) }
            if capture.observation.termination == nil { $0.failures.append("Missing native outcome: " + phase.step) }
            $0.failures.append(contentsOf: capture.observation.failures.map {
                "\(phase.step): \($0.operation): \($0.detail ?? String($0.code ?? 0))"
            })
        }
        return capture
    }

    private func inspectAutomation(state: GunshipDriverState, session: String) {
        do {
            let summary = try GunshipAutomationSummary.parse(
                gunshipReadRegularFile(session + "/Automation/index.json", limit: 256 * 1_024 * 1_024))
            state.value.withLock {
                $0.automation = summary
                if !summary.passed { $0.failures.append("Automation report does not establish a nonempty passing run") }
            }
        } catch { state.value.withLock { $0.failures.append(String(describing: error)) } }
    }

    private func inspectValidation(state: GunshipDriverState, session: String) {
        let root = session + "/Evidence"
        var reports: [GunshipValidationReport] = []
        do {
            let paths = FileManager.default.enumerator(atPath: root)?.compactMap { $0 as? String } ?? []
            for path in paths.sorted() where path.hasSuffix("/report.json") && path.contains("/Saved/Validation/") {
                reports.append(try GunshipValidationReport.parse(
                    gunshipReadRegularFile(root + "/" + path, limit: 64 * 1_024 * 1_024), path: "Evidence/" + path))
            }
            state.value.withLock {
                $0.validationReports = reports
                if reports.isEmpty || !reports.allSatisfy(\.passed) {
                    $0.failures.append("Validation evidence does not contain only passing scenario reports")
                }
            }
        } catch { state.value.withLock { $0.validationReports = reports; $0.failures.append(String(describing: error)) } }
    }

    private func publish(state: GunshipDriverState, ownership: GunshipProjectOwnership, lifecycle: String, name: String) throws {
        let result = try state.result(lifecycle: lifecycle)
        try ownership.session.publish(sealedData: result.jsonData(), name: name) {
            try ownership.revalidate()
            try state.revalidateEvidence()
        }
        try state.revalidateEvidence()
        try ownership.revalidate()
    }
}

/// One foreground SimLease macOS UI boundary surrounds packaged validation.
public enum GunshipLeaseBoundary {
    public static func admit(request: GunshipProjectRequest, environment: [String: String]) throws {
        guard request.needsOuterLease else { return }
        guard !(environment["SIMLEASE_SESSION_ID"] ?? "").isEmpty else {
            throw GunshipProjectDriverError.invalidArgument("missing outer SimLease")
        }
        guard environment["SIMLEASE_MACOS_UI"] == "1", environment["SIMLEASE_HOST_RESOURCE"] == "macos-ui",
              (environment["SIMULATOR_ID"] ?? "").isEmpty else {
            throw GunshipProjectDriverError.invalidArgument("conflicting macOS UI lease")
        }
    }

    public static func reexecuteIfRequired(
        request: GunshipProjectRequest, environment: [String: String],
        executable: String, arguments: [String], label: String
    ) throws {
        guard request.needsOuterLease else { return }
        if !(environment["SIMLEASE_SESSION_ID"] ?? "").isEmpty {
            try admit(request: request, environment: environment)
            return
        }
        guard executable.hasPrefix("/"), !executable.utf8.contains(0),
              !arguments.contains(where: { $0.utf8.contains(0) }) else {
            throw GunshipProjectDriverError.invalidArgument("SimLease reexecution")
        }
        guard let tool = ExecutableToolResolver.resolve("simlease", environment: environment) else {
            throw GunshipProjectDriverError.invalidArgument("unavailable tool: simlease")
        }
        let values = [tool, "macos-ui", "--label", label, "--", "/usr/bin/caffeinate", "-dimsu", executable] + arguments
        var pointers = values.map { strdup($0) }
        guard !pointers.contains(where: { $0 == nil }) else {
            for case let pointer? in pointers { free(pointer) }
            throw GunshipProjectDriverError.io("allocate reexecution", ENOMEM)
        }
        pointers.append(nil)
        defer { for case let pointer? in pointers { free(pointer) } }
        _ = pointers.withUnsafeMutableBufferPointer { execv(tool, $0.baseAddress!) }
        throw GunshipProjectDriverError.io("exec SimLease", errno)
    }
}

/// Gunship namespaces are separate from Notika's and ABDiff's.
internal final class GunshipProjectOwnership: Sendable {
    let plan: GunshipProjectPlan
    let runID: String
    let session: ControllerSessionArtifacts
    let repository: RetainedArtifactDirectory
    private let held: [LeaseSet]

    private init(plan: GunshipProjectPlan, runID: String, held: [LeaseSet],
                 session: ControllerSessionArtifacts, repository: RetainedArtifactDirectory) {
        self.plan = plan; self.runID = runID; self.held = held; self.session = session; self.repository = repository
    }

    static func withOwnership<T: Sendable>(
        plan: GunshipProjectPlan, runID: String, environment: [String: String], waitSeconds: Double?,
        operation: @Sendable (GunshipProjectOwnership) async throws -> T
    ) async throws -> T {
        if let waitSeconds, !waitSeconds.isFinite || waitSeconds < 0 {
            throw GunshipProjectDriverError.invalidArgument("waitSeconds")
        }
        let registry = try environment["AGENTLEASE_HOME"] ?? HostCompilationAdmission.selectedRoot(environment: [:])
        guard registry.hasPrefix("/"), !registry.utf8.contains(0) else {
            throw GunshipProjectDriverError.invalidArgument("AGENTLEASE_HOME")
        }
        let paths = try AgentLeasePaths.open(selectedRoot: registry)
        let started = DispatchTime.now().uptimeNanoseconds
        let timestamp = RunRecord.timestamp(), pid = getpid()
        var held: [LeaseSet] = []
        defer { for item in held.reversed() { item.release() } }
        for requirement in plan.resources {
            try Task.checkCancellation()
            let remaining: Double?
            if let waitSeconds, waitSeconds > 0 {
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
                guard elapsed < waitSeconds else { throw LeaseSetError.timedOut(requirement.resource) }
                remaining = waitSeconds - elapsed
            } else { remaining = waitSeconds }
            let set = try ResourceSet(exclusive: requirement.exclusive ? [requirement.resource] : [],
                                      shared: requirement.exclusive ? [] : [requirement.resource])
            held.append(try await LeaseSet.acquire(set, paths: paths, waitSeconds: remaining, initialMetadata: { lease in
                LockMetadata(resourceName: lease.resource.value, leaseMode: lease.mode, runID: runID,
                    coordinatorPID: pid, childPID: nil, mode: .run, state: .acquired,
                    label: "Gunship " + plan.request.action.rawValue, bead: nil, acquiredAt: timestamp)
            }))
        }
        let repository = try RetainedArtifactDirectory(path: plan.repository)
        let session = try ControllerSessionArtifacts(repository: plan.repository, runID: runID)
        let ownership = GunshipProjectOwnership(plan: plan, runID: runID, held: held, session: session, repository: repository)
        try ownership.revalidate()
        return try await operation(ownership)
    }

    func descriptors() throws -> [Int32] {
        let values = held.flatMap(\.inheritedDescriptors)
        guard values.count == held.count else { throw GunshipProjectDriverError.ownershipExpired }
        return values
    }

    func revalidate() throws {
        _ = try descriptors()
        try repository.revalidate(); try session.revalidate()
    }
}

private struct GunshipPhaseReport: Encodable, Sendable {
    let step: String
    let kind: String
    let compilation: Bool
    let executable: String
    let arguments: [String]
    let projectEnvironment: [String: String]
    let workingDirectory: String
    let environmentSHA256: String
    let processIdentifier: Int32?
    let nativeTermination: RunTermination?
    let retirement: String
    let retirementScope: String
    let cancelled: Bool
    let rawCapture: NativeLogCaptureResult

    init(phase: GunshipProjectPhase, capture: CapturedNativePhase) {
        step = phase.step; kind = phase.kind; compilation = phase.requiresCompilation
        executable = capture.command.executable; arguments = capture.command.arguments
        projectEnvironment = phase.environment
        workingDirectory = capture.command.workingDirectory
        environmentSHA256 = (try? CanonicalJSONDigest.sha256(.object(capture.command.environment.mapValues { .string($0) }))) ?? "unavailable"
        processIdentifier = capture.observation.processIdentifier
        nativeTermination = capture.observation.termination
        retirement = capture.observation.retirement.rawValue
        retirementScope = capture.command.retirementScope.rawValue
        cancelled = capture.observation.cancelled; rawCapture = capture.rawCapture
    }
}

private struct GunshipSessionReport: Encodable, Sendable {
    let namespace = "agentbuild.gunship"
    let schemaVersion = 1
    let toolVersion = AgentBuild.version
    let admissionEstablished = true
    let runID: String
    let repository: String
    let request: GunshipProjectRequest
    let sessionPath: String
    let engine: String?
    let archive: String?
    let productPath: String?
    let productExecutableSHA256: String?
    let archiveExecutableBeforeSHA256: String?
    let archiveExecutableAfterSHA256: String?
    let resources: [GunshipLeaseRequirement]
    let lifecycle: String
    let status: String
    let exitCode: Int32?
    let nativeTermination: RunTermination?
    let cancelled: Bool
    let cancellationSignal: Int32?
    let executionComplete: Bool
    let sourceBefore: [String: String]?
    let sourceAfter: [String: String]?
    let sourceDrift: Bool
    let toolIdentity: [String: String]
    let toolDrift: Bool
    let startedAt: String
    let completedAt: String?
    let phases: [GunshipPhaseReport]
    let automation: GunshipAutomationSummary?
    let validationReports: [GunshipValidationReport]
    let orchestrationFailures: [String]
    let publicationFailures: [String]
    let retention = "Manual retention; no automatic deletion. Retire only inactive Gunship sessions while owning their namespace leases."
}

private final class GunshipDriverState: Sendable {
    struct State {
        var captures: [CapturedNativePhase] = []
        var phases: [GunshipPhaseReport] = []
        var sourceBefore: RepositorySourceSnapshot?
        var sourceAfter: RepositorySourceSnapshot?
        var sourceDrift = false
        var toolDrift = false
        var executionComplete = false
        var cancelled = false
        var cancellationSignal: Int32?
        var failures: [String] = []
        var publicationFailures: [String] = []
        var automation: GunshipAutomationSummary?
        var validationReports: [GunshipValidationReport] = []
        var productExecutable: String?
        var archiveExecutableBefore: String?
        var archiveExecutableAfter: String?
    }
    let value = Mutex(State())
    let plan: GunshipProjectPlan
    let runID: String
    let sessionPath: String
    let startedAt = RunRecord.timestamp()

    init(plan: GunshipProjectPlan, runID: String, sessionPath: String) {
        self.plan = plan; self.runID = runID; self.sessionPath = sessionPath
    }

    var succeededSoFar: Bool {
        value.withLock { state in
            !state.cancelled && state.failures.isEmpty
                && state.phases.allSatisfy { $0.nativeTermination == RunTermination(kind: .exit, value: 0) }
        }
    }

    func revalidateEvidence() throws {
        try value.withLock { state in
            for capture in state.captures { try capture.revalidateForPublication() }
        }
    }

    func result(lifecycle: String) throws -> GunshipProjectResult {
        try value.withLock { state in
            let failure = state.phases.compactMap(\.nativeTermination).first { gunshipNativeCode($0) != 0 }
            let native = failure ?? state.phases.compactMap(\.nativeTermination).last
            let status: String, code: Int32?
            if lifecycle != "terminal" { status = "preparing"; code = nil }
            else if let signal = state.cancellationSignal { status = "cancelled"; code = 128 + signal }
            else if let failure { status = "failed"; code = gunshipNativeCode(failure) }
            else if state.cancelled { status = "cancelled"; code = 130 }
            else if !state.failures.isEmpty || !state.publicationFailures.isEmpty || state.sourceDrift
                || state.toolDrift || !state.executionComplete {
                status = "inconclusive"; code = 70
            } else { status = "succeeded"; code = 0 }
            return try GunshipProjectResult(report: GunshipSessionReport(
                runID: runID, repository: plan.repository, request: plan.request, sessionPath: sessionPath,
                engine: plan.engine, archive: plan.archive, productPath: plan.productPath,
                productExecutableSHA256: state.productExecutable,
                archiveExecutableBeforeSHA256: state.archiveExecutableBefore,
                archiveExecutableAfterSHA256: state.archiveExecutableAfter, resources: plan.resources,
                lifecycle: lifecycle, status: status, exitCode: code, nativeTermination: native,
                cancelled: state.cancelled, cancellationSignal: state.cancellationSignal,
                executionComplete: state.executionComplete,
                sourceBefore: state.sourceBefore?.raw, sourceAfter: state.sourceAfter?.raw, sourceDrift: state.sourceDrift,
                toolIdentity: plan.toolIdentity, toolDrift: state.toolDrift,
                startedAt: startedAt, completedAt: lifecycle == "terminal" ? RunRecord.timestamp() : nil,
                phases: state.phases, automation: state.automation, validationReports: state.validationReports,
                orchestrationFailures: state.failures, publicationFailures: state.publicationFailures))
        }
    }
}

private func gunshipNativeCode(_ result: RunTermination) -> Int32 {
    result.kind == .exit ? result.value : 128 + result.value
}

/// Processes whose executable lies inside the archive, such as a game someone is playing.
func gunshipProcessesInside(_ directory: String) -> [Int32] {
    let prefix = directory.hasSuffix("/") ? directory : directory + "/"
    let estimate = proc_listallpids(nil, 0)
    guard estimate > 0 else { return [] }
    var identifiers = [pid_t](repeating: 0, count: Int(estimate) + 256)
    let count = identifiers.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    guard count > 0 else { return [] }
    var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
    var users: [Int32] = []
    for identifier in identifiers.prefix(Int(count)) where identifier > 0 {
        let length = buffer.withUnsafeMutableBytes { proc_pidpath(identifier, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { continue }
        if String(decoding: buffer.prefix(Int(length)), as: UTF8.self).hasPrefix(prefix) { users.append(identifier) }
    }
    return users.sorted()
}

func gunshipEnsureArchiveIdle(_ archive: String) throws {
    let users = gunshipProcessesInside(archive)
    guard users.isEmpty else { throw GunshipProjectDriverError.archiveInUse(archive, users) }
}

private func gunshipOpenRegularFile(_ path: String) throws -> (descriptor: Int32, size: Int64) {
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else { throw GunshipProjectDriverError.io("open " + path, errno) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
        _ = close(descriptor)
        throw GunshipProjectDriverError.evidence("not a regular file: " + path)
    }
    return (descriptor, Int64(metadata.st_size))
}

private func gunshipReadChunks(_ descriptor: Int32, path: String, _ body: (UnsafeRawBufferPointer) throws -> Void) throws {
    var buffer = [UInt8](repeating: 0, count: 256 * 1_024)
    while true {
        let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        if count < 0, errno == EINTR { continue }
        guard count >= 0 else { throw GunshipProjectDriverError.io("read " + path, errno) }
        if count == 0 { return }
        try buffer.withUnsafeBytes { try body(UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
    }
}

func gunshipReadRegularFile(_ path: String, limit: Int) throws -> Data {
    let file = try gunshipOpenRegularFile(path)
    defer { _ = close(file.descriptor) }
    guard file.size <= limit else { throw GunshipProjectDriverError.evidence("file exceeds \(limit) bytes: " + path) }
    var data = Data()
    data.reserveCapacity(Int(file.size))
    try gunshipReadChunks(file.descriptor, path: path) { chunk in
        data.append(contentsOf: chunk)
        guard data.count <= limit else { throw GunshipProjectDriverError.evidence("file grew past \(limit) bytes: " + path) }
    }
    return data
}

func gunshipFileSHA256(_ path: String) throws -> String {
    let file = try gunshipOpenRegularFile(path)
    defer { _ = close(file.descriptor) }
    var digest = SHA256()
    try gunshipReadChunks(file.descriptor, path: path) { digest.update(bufferPointer: $0) }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}
