import AgentBuildCore
import AgentLeaseCore
import CryptoKit
import Darwin
import Foundation
import Synchronization

public enum NotikaDocumentationDriverError: Error, Equatable, Sendable {
    case invalidArgument(String), invalidReport(String), incompatibleSource
    case toolUnavailable(String), unsafeArtifact, artifactChanged, treeBoundExceeded
    case artifactIO(String, Int32), previewNotReady
}

public struct NotikaDocumentationPreviewEvidence: Codable, Equatable, Sendable {
    public let protocolName: String
    public let host: String
    public let port: Int
    public let url: String
    public let processID: Int32
    public let site: String
    public let siteTreeSHA256: String
    private enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case host, port, url, processID, site, siteTreeSHA256
    }
}

/// Immutable schema admission, not filesystem custody or cleanup authority.
/// Snapshot JSON is recorded literally, with its canonical-byte SHA-256, so
/// source/toolchain/compatibility Unicode does not lose its exact commitment.
public struct NotikaDocumentationSessionReport: Sendable {
    public static let namespace = "agentbuild.notika-documentation"
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
    public let mode: NotikaDocumentationMode
    public let archivePath: String?
    public let sitePath: String?
    public let preview: NotikaDocumentationPreviewEvidence?
    internal let payload: DocumentationReportPayload

    public init(data: Data, expectedRepository: String? = nil, expectedSessionID: String? = nil) throws {
        try self.init(data: data, expectedRepository: expectedRepository, expectedSessionID: expectedSessionID,
                      captureAdmissionPolicy: .current)
    }

    internal init(data: Data, expectedRepository: String? = nil, expectedSessionID: String? = nil,
                  captureAdmissionPolicy: NativeCaptureAdmissionPolicy) throws {
        let document = try StrictJSONDocument(data: data)
        let payload = try JSONDecoder().decode(DocumentationReportPayload.self, from: data)
        let value = try documentationCanonical(document.root)
        // Closed typed re-encoding rejects foreign keys even in capture and
        // failure objects; the strict bridge rejects all floating-point numbers.
        guard try CanonicalJSONDigest.encode(value) == documentationEncoded(payload),
              payload.namespace == Self.namespace, payload.schemaVersion == 1,
              UUID(uuidString: payload.sessionID)?.uuidString == payload.sessionID,
              payload.ownerUID == geteuid(), payload.directoryIdentity.deviceID > 0,
              payload.directoryIdentity.inode > 0 else { throw documentationSchema("binding") }
        _ = try CacheCompatibilityIdentity.graphResourceName(canonicalWorktree: payload.repository)
        _ = try CacheCompatibilityIdentity.graphResourceName(canonicalWorktree: payload.registryRoot)
        let session = payload.repository + "/Artifacts/AgentSessions/" + payload.sessionID
        guard payload.sessionPath.utf8.elementsEqual(session.utf8),
              payload.writerResource.utf8.elementsEqual(("notika:sessions:" + payload.repository).utf8),
              expectedRepository == nil || expectedRepository!.utf8.elementsEqual(payload.repository.utf8),
              expectedSessionID == nil || expectedSessionID == payload.sessionID,
              (1_024...65_535).contains(payload.previewPort),
              let zone = TimeZone(identifier: payload.retentionTimeZone),
              payload.orchestrationFailures.count <= 128, payload.publicationFailures.count <= 128,
              payload.phases.count <= (payload.mode == .archive ? 1 : payload.mode == .rendered ? 2 : 3) else {
            throw documentationSchema("session")
        }
        let started = try documentationDate(payload.startedAt)
        guard captureAdmissionPolicy != .historicalRetention || payload.lifecycle == "terminal" else { throw documentationSchema("historicalRetention") }
        for snapshot in [payload.sourceBefore, payload.sourceAfter, payload.toolchainBefore, payload.toolchainAfter].compactMap({ $0 }) {
            try snapshot.validate()
        }
        if let material = payload.compatibilityIdentityJSON {
            let identity = try CacheCompatibilityIdentity(keyMaterial: documentationCanonical(StrictJSONDocument(data: Data(material.utf8)).root), expectedRepository: payload.repository)
            let source = try documentationSourceProjection(payload.sourceBefore, repository: payload.repository)
            let toolchain = try NotikaToolchainIdentity(keyMaterial: documentationSnapshotValue(payload.toolchainBefore))
            let expected = try NotikaCacheProfile(request: NotikaActionRequest(platform: .macOS, documentationMode: payload.mode)).identity(source: source, toolchain: toolchain)
            guard identity == expected,
                  payload.cachePath?.utf8.elementsEqual((payload.repository + "/DerivedData/AgentCaches/" + (try identity.cacheKey())).utf8) == true else { throw documentationSchema("compatibilityIdentity") }
        } else if payload.cachePath != nil { throw documentationSchema("cachePath") }
        if let tools = payload.tools {
            guard Set(tools.keys) == ["xcodebuild", "xcrun", "docc", "helper"] else { throw documentationSchema("tools") }
            for tool in tools.values {
                _ = try CacheCompatibilityIdentity.graphResourceName(canonicalWorktree: tool.path)
                guard documentationSHA(tool.sha256), tool.deviceID > 0, tool.inode > 0 else { throw documentationSchema("toolEvidence") }
            }
        }
        if !payload.phases.isEmpty {
            guard payload.compatibilityIdentityJSON != nil, payload.tools != nil else { throw documentationSchema("executionAdmission") }
        }
        let steps: [DocumentationStep] = [.docbuild, .transform, .preview]
        var captureDirectories = Set<String>()
        for (index, phase) in payload.phases.enumerated() {
            guard phase.step == steps[index],
                  phase.command.workingDirectory.utf8.elementsEqual(payload.repository.utf8),
                  documentationSHA(phase.command.environmentSHA256),
                  phase.command.executable.hasPrefix("/"), !phase.command.executable.utf8.contains(0),
                  phase.command.arguments.allSatisfy({ !$0.utf8.contains(0) }),
                  NativeRetirementEvidence(rawValue: phase.retirement) != nil,
                  (phase.retirement == "workerReaped") == (phase.nativeTermination != nil),
                  phase.processID == nil || phase.processID! > 0,
                  phase.retirement != "workerReaped" || phase.processID != nil,
                  phase.failures.count <= 128 else { throw documentationSchema("phase") }
            if index > 0, !payload.phases[index - 1].succeeded { throw documentationSchema("phaseOrder") }
            if let termination = phase.nativeTermination { try documentationValidateTermination(termination) }
            let captureDirectory = try documentationValidateCapture(phase.rawCapture, session: session, policy: captureAdmissionPolicy)
            guard captureDirectories.insert(captureDirectory).inserted else { throw documentationSchema("captureReuse") }
            if phase.publicationAdmitted && !phase.rawCapture.captureComplete { throw documentationSchema("captureAdmission") }
            if phase.step == .docbuild {
                guard payload.tools?["xcodebuild"]?.path.utf8.elementsEqual(phase.command.executable.utf8) == true,
                      documentationLiteralArguments(phase.command.arguments, documentationBuildArguments(cache: payload.cachePath ?? ""))
                        || documentationLegacyFailedBuild(payload, phase: phase) else { throw documentationSchema("docbuild") }
            } else if phase.step == .transform {
                guard payload.tools?["docc"]?.path.utf8.elementsEqual(phase.command.executable.utf8) == true,
                      documentationLiteralArguments(phase.command.arguments, documentationTransformArguments(session: session)) else { throw documentationSchema("transform") }
            } else {
                guard payload.tools?["helper"]?.path.utf8.elementsEqual(phase.command.executable.utf8) == true,
                      documentationLiteralArguments(phase.command.arguments, documentationPreviewArguments(repository: payload.repository, session: session,
                    registry: payload.registryRoot, port: payload.previewPort, hash: payload.site?.commitment.sha256 ?? "")) else { throw documentationSchema("previewCommand") }
            }
        }
        guard payload.buildNativeTermination == payload.phases.first?.nativeTermination,
              payload.sourceChanged == documentationChanged(payload.sourceBefore, payload.sourceAfter),
              payload.toolchainChanged == documentationChanged(payload.toolchainBefore, payload.toolchainAfter) else { throw documentationSchema("observations") }
        for (artifact, name) in [(payload.archive, "Notika.doccarchive"), (payload.renderer, "renderer"), (payload.site, "site")] {
            guard let artifact else { continue }
            guard artifact.path.utf8.elementsEqual((session + "/" + name).utf8) else { throw documentationSchema("artifactPath") }
            try documentationValidateCommitment(artifact.commitment)
        }
        guard payload.mode != .archive || (payload.renderer == nil && payload.site == nil && payload.preview == nil),
              payload.mode != .rendered || payload.preview == nil,
              payload.archive == nil || payload.phases.first?.succeeded == true,
              payload.site == nil || payload.phases.dropFirst().first?.succeeded == true else { throw documentationSchema("artifactAdmission") }
        if let preview = payload.preview {
            guard payload.mode == .preview, let site = payload.site,
                  preview.protocolName == "notika.docc-loopback-preview.v1", preview.host == "127.0.0.1",
                  preview.port == payload.previewPort, preview.processID > 0,
                  preview.url == documentationPreviewURL(payload.previewPort),
                  preview.site.utf8.elementsEqual(site.path.utf8), preview.siteTreeSHA256 == site.commitment.sha256,
                  payload.phases.last?.step == .preview, payload.phases.last?.processID == preview.processID else { throw documentationSchema("previewEvidence") }
        }
        if payload.executionComplete {
            guard payload.archive != nil, payload.phases.first?.succeeded == true,
                  payload.phases.count == (payload.mode == .archive ? 1 : payload.mode == .rendered ? 2 : 3),
                  payload.compatibilityIdentityJSON != nil, payload.cachePath != nil,
                  payload.sourceBefore != nil, payload.sourceAfter != nil,
                  payload.toolchainBefore != nil, payload.toolchainAfter != nil,
                  !payload.sourceChanged, !payload.toolchainChanged,
                  payload.orchestrationFailures.isEmpty, payload.publicationFailures.isEmpty,
                  payload.phases.allSatisfy({ $0.succeeded && $0.publicationAdmitted }), !payload.cancelled,
                  payload.mode == .archive || (payload.renderer != nil && payload.site != nil),
                  payload.mode != .preview || payload.preview != nil else { throw documentationSchema("executionComplete") }
        }
        if payload.lifecycle == "inProgress" {
            guard payload.status == "running", payload.exitCode == nil, payload.completedAt == nil, payload.expiresAt == nil,
                  payload.phases.isEmpty, !payload.executionComplete, !payload.cancelled,
                  payload.sourceBefore == nil, payload.sourceAfter == nil,
                  payload.toolchainBefore == nil, payload.toolchainAfter == nil,
                  payload.compatibilityIdentityJSON == nil, payload.cachePath == nil, payload.tools == nil,
                  payload.archive == nil, payload.renderer == nil, payload.site == nil, payload.preview == nil,
                  payload.orchestrationFailures.isEmpty, payload.publicationFailures.isEmpty else { throw documentationSchema("inProgress") }
        } else if payload.lifecycle == "terminal" {
            let completed = try documentationDate(try documentationRequired(payload.completedAt, "completedAt"))
            let expires = try documentationDate(try documentationRequired(payload.expiresAt, "expiresAt"))
            guard started <= completed,
                  abs(expires.timeIntervalSince(try LocalCalendarRetention(evaluatedAt: completed, timeZone: zone).nextLocalMidnight)) < 0.001 else { throw documentationSchema("expiry") }
            let outcome = documentationStatus(payload)
            guard payload.status == outcome.0, payload.exitCode == outcome.1 else { throw documentationSchema("status") }
        } else { throw documentationSchema("lifecycle") }
        self.payload = payload; originalData = data; canonicalValue = value; digest = document.digest
        sessionID = payload.sessionID; repository = payload.repository; lifecycle = payload.lifecycle
        status = payload.status; exitCode = payload.exitCode; nativeTermination = payload.buildNativeTermination
        cancelled = payload.cancelled; mode = payload.mode; preview = payload.preview
        archivePath = payload.archive?.path; sitePath = payload.site?.path
    }
}

public struct NotikaDocumentationDriverResult: Sendable {
    public let runID: String
    public let sessionPath: String?
    public let report: NotikaDocumentationSessionReport?
    public let rawCaptures: [NativeLogCaptureResult]
    public let nativeTermination: RunTermination?
    public let ancillaryTerminations: [RunTermination]
    public let orchestrationFailures: [String]
    public let publicationFailures: [String]
    public let maintenanceReport: NotikaArtifactMaintenanceReport?
    public let maintenanceFailures: [String]
    public let cancelled: Bool
    public var status: String { outcome.0 }
    public var exitCode: Int32 { outcome.1 }
    private var outcome: (String, Int32) {
        if let nativeTermination, let code = documentationFailureCode(nativeTermination) { return ("failed", code) }
        if cancelled { return ("cancelled", 130) }
        if let code = ancillaryTerminations.compactMap(documentationFailureCode).first { return ("failed", code) }
        if !orchestrationFailures.isEmpty || !publicationFailures.isEmpty { return ("inconclusive", 70) }
        return (report?.status ?? "inconclusive", report?.exitCode ?? 70)
    }
    public func jsonData() throws -> Data {
        try CanonicalJSONDigest.encode(.object([
            "namespace": .string("agentbuild.notika-documentation-result"), "schemaVersion": .integer(1),
            "runID": .string(runID), "sessionPath": sessionPath.map(CanonicalJSONValue.string) ?? .null,
            "status": .string(status), "exitCode": .integer(Int64(exitCode)), "cancelled": .bool(cancelled),
            "buildNativeTermination": try documentationValue(nativeTermination),
            "ancillaryTerminations": try documentationValue(ancillaryTerminations),
            "orchestrationFailures": .array(orchestrationFailures.map(CanonicalJSONValue.string)),
            "publicationFailures": .array(publicationFailures.map(CanonicalJSONValue.string)),
            "maintenanceReport": try maintenanceReport.map(documentationValue) ?? .null,
            "maintenanceFailures": .array(maintenanceFailures.map(CanonicalJSONValue.string)),
            "sessionReport": report?.canonicalValue ?? .null,
        ]))
    }
}

internal enum DocumentationStep: String, Codable, Sendable { case docbuild, transform, preview }
internal struct DocumentationDirectoryIdentity: Codable, Sendable { let deviceID: UInt64; let inode: UInt64 }
internal struct DocumentationSnapshot: Codable, Sendable {
    let keyMaterialJSON: String
    let sha256: String
    init(_ value: CanonicalJSONValue) throws {
        let bytes = try CanonicalJSONDigest.encode(value)
        keyMaterialJSON = String(decoding: bytes, as: UTF8.self); sha256 = CanonicalJSONDigest.digest(bytes)
    }
    func validate() throws {
        guard documentationSHA(sha256), CanonicalJSONDigest.digest(Data(keyMaterialJSON.utf8)) == sha256,
              try CanonicalJSONDigest.encode(documentationCanonical(StrictJSONDocument(data: Data(keyMaterialJSON.utf8)).root)) == Data(keyMaterialJSON.utf8) else { throw documentationSchema("snapshot") }
    }
}
internal struct DocumentationArtifact: Codable, Sendable { let path: String; let commitment: NotikaDocumentationTreeCommitment }
internal struct DocumentationCommand: Codable, Equatable, Sendable {
    let executable: String; let arguments: [String]; let workingDirectory: String; let environmentSHA256: String
}
internal struct DocumentationPhaseRecord: Codable, Sendable {
    let step: DocumentationStep; let command: DocumentationCommand
    let processID: Int32?
    let nativeTermination: RunTermination?; let retirement: String; let cancelled: Bool
    let failures: [DarwinWorkloadFailure]; let rawCapture: NativeLogCaptureRecord; let publicationAdmitted: Bool
    var succeeded: Bool {
        nativeTermination == .init(kind: .exit, value: 0) && retirement == "workerReaped"
            && !cancelled && failures.isEmpty && rawCapture.captureComplete
    }
}
internal struct DocumentationToolEvidence: Codable, Sendable { let path: String; let sha256: String; let deviceID: Int64; let inode: UInt64 }
internal struct DocumentationReportPayload: Codable, Sendable {
    let namespace: String; let schemaVersion: Int; let toolVersion: String
    let repository: String; let sessionID: String; let sessionPath: String; let ownerUID: UInt32
    let directoryIdentity: DocumentationDirectoryIdentity; let writerResource: String; let registryRoot: String
    let lifecycle: String; var status: String; var exitCode: Int32?
    let mode: NotikaDocumentationMode; let previewPort: Int
    let startedAt: String; let completedAt: String?; let expiresAt: String?; let retentionTimeZone: String
    let sourceBefore: DocumentationSnapshot?; let sourceAfter: DocumentationSnapshot?; let sourceChanged: Bool
    let toolchainBefore: DocumentationSnapshot?; let toolchainAfter: DocumentationSnapshot?; let toolchainChanged: Bool
    let compatibilityIdentityJSON: String?; let cachePath: String?; let tools: [String: DocumentationToolEvidence]?
    let phases: [DocumentationPhaseRecord]; let buildNativeTermination: RunTermination?
    let archive: DocumentationArtifact?; let renderer: DocumentationArtifact?; let site: DocumentationArtifact?
    let preview: NotikaDocumentationPreviewEvidence?; let executionComplete: Bool; let cancelled: Bool
    let orchestrationFailures: [String]; let publicationFailures: [String]
}

/// A shared session writer surrounds graph/policy/cache ownership throughout
/// every supervised child. Only docbuild holds the account compilation gate.
/// Static rendering and the loopback server await worker retirement/raw EOF.
public struct NotikaDocumentationDriver: Sendable {
    internal typealias CaptureOperation = @Sendable (String, DarwinWorkloadCommand, [Int32], String, Int32) async throws -> CapturedNativePhase
    private let identityCapture: (any RepositoryCommandCapturing)?
    private let captureOperation: CaptureOperation
    public init() { identityCapture = nil; captureOperation = Self.capture }
    internal init(identityCapture: any RepositoryCommandCapturing, captureOperation: CaptureOperation? = nil) {
        self.identityCapture = identityCapture; self.captureOperation = captureOperation ?? Self.capture
    }
    private static let capture: CaptureOperation = { helper, command, descriptors, root, directory in
        try await CapturedNativePhaseRunner().run(helperExecutable: helper, command: command,
            retainedLockDescriptors: descriptors, nativeWorkingDirectoryDescriptor: directory, artifactRoot: root)
    }

    public func run(repository: String, mode: NotikaDocumentationMode, helperExecutable: String,
                    registryRoot: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment,
                    rendererRoot: String? = nil, previewPort: Int = 8_000, waitSeconds: Double? = nil,
                    runID: String = UUID().uuidString, startedAt: Date = Date(), timeZone: TimeZone = .current,
                    onPreviewReady: @escaping @Sendable (NotikaDocumentationPreviewEvidence) -> Void = { _ in }) async throws -> NotikaDocumentationDriverResult {
        guard UUID(uuidString: runID)?.uuidString == runID else { throw NotikaDocumentationDriverError.invalidArgument("runID") }
        guard (1_024...65_535).contains(previewPort) else { throw NotikaDocumentationDriverError.invalidArgument("previewPort") }
        if let waitSeconds, !waitSeconds.isFinite || waitSeconds < 0 { throw NotikaDocumentationDriverError.invalidArgument("waitSeconds") }
        let request = try NotikaActionRequest(platform: .macOS, documentationMode: mode)
        guard try NotikaLeaseBoundary.admit(request: request, environment: environment) == nil else {
            throw NotikaDocumentationDriverError.invalidArgument("documentation requires an unleased outer context")
        }
        let helper = try DocumentationTool(path: helperExecutable)
        let capture = try identityCapture ?? RepositoryCommandCapture()
        let observer = try NotikaRepositoryIdentity(repository: repository, capture: capture, environment: environment)
        guard observer.repository.utf8.elementsEqual(repository.utf8) else { throw NotikaDocumentationDriverError.invalidArgument("repository") }
        let registry = registryRoot ?? environment["AGENTLEASE_HOME"] ?? repository + "/.agentlease"
        _ = try LocalCalendarRetention(evaluatedAt: startedAt, timeZone: timeZone)
        var maintenance: NotikaArtifactMaintenanceReport?, maintenanceFailures: [String] = []
        do {
            maintenance = try await NotikaArtifactMaintenance(canonicalRepository: repository, registryRoot: registry,
                evaluatedAt: startedAt, timeZone: timeZone).run(execute: true)
        } catch { maintenanceFailures.append(String(describing: error)) }
        try Task.checkCancellation()
        let paths = try AgentLeasePaths.open(selectedRoot: registry)
        let pid = getpid(), acquired = RunRecord.timestamp()
        let writer = try await LeaseSet.acquire(ResourceSet(exclusive: [], shared: ["notika:sessions:" + repository]),
            paths: paths, waitSeconds: waitSeconds, initialMetadata: { lease in
                LockMetadata(resourceName: lease.resource.value, leaseMode: lease.mode, runID: runID, coordinatorPID: pid,
                    childPID: nil, mode: .run, state: .acquired, label: "notika-documentation-writer", bead: nil, acquiredAt: acquired)
            })
        defer { writer.release() }
        try Task.checkCancellation()
        let session = try ControllerSessionArtifacts(repository: repository, runID: runID)
        let state = DocumentationState(session: session, runID: runID, repository: repository, mode: mode,
            registry: registry, previewPort: previewPort, startedAt: startedAt, timeZone: timeZone)
        let operation = captureOperation
        do { try session.publish(sealedData: state.report(completedAt: nil).originalData, name: "in-progress.json", validating: {}) }
        catch { state.publicationFailure(error) }
        if state.publicationFailures.isEmpty {
            do {
                let source = try await observer.sourceIdentity(), toolchain = try await observer.toolchainIdentity()
                guard source.canonicalWorktree.utf8.elementsEqual(repository.utf8) else { throw NotikaDocumentationDriverError.invalidArgument("worktree root") }
                state.identities(source: source, toolchain: toolchain, initial: true)
                let profile = NotikaCacheProfile(request: request), identity = try profile.identity(source: source, toolchain: toolchain)
                state.identity(identity)
                try await NotikaProjectAdmission().withOwnership(NotikaProjectOwnershipPlan(identity: identity), registryRoot: registry,
                    label: "Notika DocC", runID: runID, waitSeconds: waitSeconds) { ownership in
                    let currentSource = try await observer.sourceIdentity(), currentToolchain = try await observer.toolchainIdentity()
                    guard try currentSource.digest() == source.digest(), try currentToolchain.digest() == toolchain.digest(),
                          try profile.identity(source: currentSource, toolchain: currentToolchain).executionDigest() == identity.executionDigest() else {
                        throw NotikaDocumentationDriverError.incompatibleSource
                    }
                    _ = try NotikaGeneratedWorkspace.validate(repository: repository)
                    let tools = try await DocumentationTools.observe(environment: environment, repository: repository, capture: capture, helper: helper)
                    state.tools(tools)
                    let rendererSource: NotikaDocumentationTree?
                    let rendererCommitment: NotikaDocumentationTreeCommitment?
                    if mode != .archive {
                        let selected = rendererRoot ?? URL(fileURLWithPath: repository).deletingLastPathComponent().appendingPathComponent("swift-docc-render/dist").path
                        rendererSource = try NotikaDocumentationTree(path: selected)
                        rendererCommitment = try rendererSource!.commitment()
                    } else { rendererSource = nil; rendererCommitment = nil }
                    let custody = try NotikaCacheCustody(identity: identity, ownership: ownership)
                    try custody.revalidateBeforeOperation()
                    _ = try custody.publishUsage(sessionID: runID)
                    let nativeEnvironment = try NotikaChildEnvironmentPolicy.nativeEnvironment(from: environment,
                        bindings: NotikaNativeEnvironmentBindings(repository: repository,
                            toolSearchPath: environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin", derivedData: custody.cacheDirectory))
                    let execute: @Sendable (DocumentationStep, DarwinWorkloadCommand, [Int32]) async throws -> CapturedNativePhase = { step, command, extra in
                        try session.revalidate(); try custody.revalidateBeforeOperation(); try tools.revalidate()
                        let phase = try await operation(helper.path, command,
                            try writer.inheritedDescriptors + ownership.inheritedDescriptors() + extra, session.path, session.repositoryDescriptor)
                        state.retain(step: step, phase: phase)
                        guard try documentationEncoded(documentationCommand(phase.command)) == documentationEncoded(documentationCommand(command)) else { throw documentationSchema("capturedCommand") }
                        try custody.revalidateBeforeOperation(); try tools.revalidate(); try session.revalidate()
                        return phase
                    }
                    let build = try DarwinWorkloadCommand(executable: tools.xcodebuild.path,
                        arguments: documentationBuildArguments(cache: custody.cacheDirectory), workingDirectory: repository, environment: nativeEnvironment)
                    let built = try await HostCompilationAdmission().withLease(environment: environment, label: "Notika DocC compilation", waitSeconds: waitSeconds) { compile in
                        try await execute(.docbuild, build, compile.inheritedDescriptors())
                    }
                    _ = try custody.publishUsage(sessionID: runID)
                    guard documentationSucceeded(built) else { return }
                    let cacheArchive = try NotikaDocumentationTree(path: custody.cacheDirectory + "/Build/Products/Debug/Notika.doccarchive")
                    _ = try session.createPrivateDirectory(named: "Notika.doccarchive", additionalAllowedNames: ["Notika.doccarchive"])
                    let archive = try NotikaDocumentationTree(path: session.path + "/Notika.doccarchive", privateRoot: true)
                    let archiveCommitment = try cacheArchive.copy(into: archive)
                    state.artifact(name: "archive", tree: archive, commitment: archiveCommitment)
                    if let rendererSource, let rendererCommitment {
                        _ = try session.createPrivateDirectory(named: "renderer")
                        let renderer = try NotikaDocumentationTree(path: session.path + "/renderer", privateRoot: true)
                        let snapshot = try rendererSource.copy(into: renderer, expected: rendererCommitment)
                        state.artifact(name: "renderer", tree: renderer, commitment: snapshot)
                        _ = try session.createPrivateDirectory(named: "site")
                        let transform = try DarwinWorkloadCommand(executable: tools.docc.path,
                            arguments: documentationTransformArguments(session: session.path), workingDirectory: repository, environment: nativeEnvironment)
                        let transformed = try await execute(.transform, transform, [])
                        guard documentationSucceeded(transformed) else { return }
                        let site = try NotikaDocumentationTree(path: session.path + "/site", privateRoot: true)
                        try renderer.merge(into: site)
                        let commitment = try site.commitment()
                        state.artifact(name: "site", tree: site, commitment: commitment)
                        if mode == .preview {
                            let preview = try DarwinWorkloadCommand(executable: helper.path,
                                arguments: documentationPreviewArguments(repository: repository, session: session.path, registry: registry,
                                    port: previewPort, hash: commitment.sha256), workingDirectory: repository, environment: nativeEnvironment)
                            await documentationRunPreview(session: session, state: state, expected: commitment, port: previewPort,
                                onReady: onPreviewReady, operation: { try await execute(.preview, preview, []) })
                        }
                    }
                    state.complete()
                }
            } catch { state.failure(error) }
        }
        do { state.identities(source: try await observer.sourceIdentity(), toolchain: try await observer.toolchainIdentity(), initial: false) }
        catch { state.failure(error) }
        do { try state.revalidate() } catch { state.publicationFailure(error) }
        do {
            let terminal = try state.report(completedAt: Date())
            try session.publish(sealedData: terminal.originalData, name: "manifest.json", validating: {
                try state.revalidate(admitArtifacts: state.publicationFailures.isEmpty)
            })
            state.published(terminal)
            try session.revalidate()
        } catch { state.publicationFailure(error) }
        return state.result(maintenanceReport: maintenance, maintenanceFailures: maintenanceFailures)
    }
}

private final class DocumentationState: Sendable {
    private struct Contents: Sendable {
        var sourceBefore: DocumentationSnapshot?; var sourceAfter: DocumentationSnapshot?
        var toolchainBefore: DocumentationSnapshot?; var toolchainAfter: DocumentationSnapshot?
        var identity: CacheCompatibilityIdentity?; var tools: DocumentationTools?
        var phases: [(DocumentationStep, CapturedNativePhase)] = []
        var artifacts: [String: (NotikaDocumentationTree, NotikaDocumentationTreeCommitment)] = [:]
        var preview: NotikaDocumentationPreviewEvidence?; var readyFile: RetainedArtifactFile?
        var failures: [String] = []; var publication: [String] = []; var complete = false; var cancelled = false
        var terminal: NotikaDocumentationSessionReport?
    }
    private let value = Mutex(Contents())
    let session: ControllerSessionArtifacts
    let runID: String; let repository: String; let mode: NotikaDocumentationMode
    let registry: String; let previewPort: Int; let startedAt: Date; let timeZone: TimeZone
    init(session: ControllerSessionArtifacts, runID: String, repository: String, mode: NotikaDocumentationMode,
         registry: String, previewPort: Int, startedAt: Date, timeZone: TimeZone) {
        self.session = session; self.runID = runID; self.repository = repository; self.mode = mode
        self.registry = registry; self.previewPort = previewPort; self.startedAt = startedAt; self.timeZone = timeZone
    }
    var publicationFailures: [String] { value.withLock { $0.publication } }
    func identities(source: NotikaSourceIdentity, toolchain: NotikaToolchainIdentity, initial: Bool) {
        do {
            let source = try DocumentationSnapshot(source.keyMaterial), toolchain = try DocumentationSnapshot(toolchain.keyMaterial)
            value.withLock { if initial { $0.sourceBefore = source; $0.toolchainBefore = toolchain } else { $0.sourceAfter = source; $0.toolchainAfter = toolchain } }
        } catch { failure(error) }
    }
    func identity(_ identity: CacheCompatibilityIdentity) { value.withLock { $0.identity = identity } }
    func tools(_ tools: DocumentationTools) { value.withLock { $0.tools = tools } }
    func retain(step: DocumentationStep, phase: CapturedNativePhase) { value.withLock { $0.phases.append((step, phase)); $0.cancelled = $0.cancelled || phase.observation.cancelled } }
    func artifact(name: String, tree: NotikaDocumentationTree, commitment: NotikaDocumentationTreeCommitment) { value.withLock { $0.artifacts[name] = (tree, commitment) } }
    func ready(_ preview: NotikaDocumentationPreviewEvidence, file: RetainedArtifactFile) { value.withLock { $0.preview = preview; $0.readyFile = file } }
    func complete() { value.withLock { $0.complete = true } }
    func failure(_ error: any Error) { value.withLock { $0.failures.append(String(String(describing: error).prefix(4_096))); $0.cancelled = $0.cancelled || error is CancellationError || Task.isCancelled } }
    func publicationFailure(_ error: any Error) { value.withLock { $0.publication.append(String(String(describing: error).prefix(4_096))) } }
    func published(_ report: NotikaDocumentationSessionReport) { value.withLock { $0.terminal = report } }
    func revalidate(admitArtifacts: Bool = true) throws {
        try session.revalidate()
        let current = value.withLock { $0 }
        if admitArtifacts {
            try current.tools?.revalidate()
            for (_, phase) in current.phases { try phase.revalidateForPublication() }
            for (_, artifact) in current.artifacts {
                guard try artifact.0.commitment(checkCancellation: false) == artifact.1 else { throw NotikaDocumentationDriverError.artifactChanged }
            }
            try current.readyFile?.revalidate()
        }
    }
    func report(completedAt: Date?) throws -> NotikaDocumentationSessionReport {
        let current = value.withLock { $0 }, admitted = current.publication.isEmpty
        let phases = try current.phases.map { step, phase in
            DocumentationPhaseRecord(step: step, command: try documentationCommand(phase.command),
                processID: phase.observation.processIdentifier,
                nativeTermination: phase.observation.termination, retirement: phase.observation.retirement.rawValue,
                cancelled: phase.observation.cancelled, failures: phase.observation.failures, rawCapture: NativeLogCaptureRecord(phase.rawCapture),
                publicationAdmitted: admitted && phase.rawCapture.captureComplete)
        }
        func artifact(_ name: String) -> DocumentationArtifact? {
            current.artifacts[name].map { DocumentationArtifact(path: $0.0.path, commitment: $0.1) }
        }
        let cancelled = current.cancelled || Task.isCancelled
        let complete = current.complete && !cancelled && admitted && current.failures.isEmpty
            && !documentationChanged(current.sourceBefore, current.sourceAfter) && !documentationChanged(current.toolchainBefore, current.toolchainAfter)
            && phases.allSatisfy { $0.succeeded && $0.publicationAdmitted }
        var payload = DocumentationReportPayload(namespace: NotikaDocumentationSessionReport.namespace, schemaVersion: 1,
            toolVersion: AgentBuild.version, repository: repository, sessionID: runID, sessionPath: session.path, ownerUID: geteuid(),
            directoryIdentity: .init(deviceID: UInt64(session.identity.st_dev), inode: session.identity.st_ino),
            writerResource: "notika:sessions:" + repository, registryRoot: registry,
            lifecycle: completedAt == nil ? "inProgress" : "terminal", status: "running", exitCode: nil,
            mode: mode, previewPort: previewPort, startedAt: documentationTimestamp(startedAt),
            completedAt: completedAt.map(documentationTimestamp),
            expiresAt: try completedAt.map { documentationTimestamp(try LocalCalendarRetention(evaluatedAt: $0, timeZone: timeZone).nextLocalMidnight) },
            retentionTimeZone: timeZone.identifier, sourceBefore: current.sourceBefore, sourceAfter: current.sourceAfter,
            sourceChanged: documentationChanged(current.sourceBefore, current.sourceAfter),
            toolchainBefore: current.toolchainBefore, toolchainAfter: current.toolchainAfter,
            toolchainChanged: documentationChanged(current.toolchainBefore, current.toolchainAfter),
            compatibilityIdentityJSON: try current.identity.map { String(decoding: try CanonicalJSONDigest.encode($0.keyMaterial), as: UTF8.self) },
            cachePath: try current.identity.map { repository + "/DerivedData/AgentCaches/" + (try $0.cacheKey()) },
            tools: current.tools?.evidence, phases: phases, buildNativeTermination: phases.first?.nativeTermination,
            archive: artifact("archive"), renderer: artifact("renderer"), site: artifact("site"), preview: current.preview,
            executionComplete: complete, cancelled: cancelled, orchestrationFailures: current.failures, publicationFailures: current.publication)
        if completedAt != nil { let status = documentationStatus(payload); payload.status = status.0; payload.exitCode = status.1 }
        return try NotikaDocumentationSessionReport(data: documentationEncoded(payload), expectedRepository: repository, expectedSessionID: runID)
    }
    func result(maintenanceReport: NotikaArtifactMaintenanceReport?, maintenanceFailures: [String]) -> NotikaDocumentationDriverResult {
        value.withLock { current in
            NotikaDocumentationDriverResult(runID: runID, sessionPath: session.path, report: current.terminal,
                rawCaptures: current.phases.map { $0.1.rawCapture }, nativeTermination: current.phases.first?.1.observation.termination,
                ancillaryTerminations: current.phases.dropFirst().compactMap { $0.1.observation.termination },
                orchestrationFailures: current.failures, publicationFailures: current.publication,
                maintenanceReport: maintenanceReport, maintenanceFailures: maintenanceFailures,
                cancelled: current.cancelled || Task.isCancelled)
        }
    }
}

private final class DocumentationTool: Sendable {
    let path: String
    let evidence: DocumentationToolEvidence
    private let descriptor: DocumentationDescriptor
    private let identity: stat
    init(path: String) throws {
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              let canonical = path.withCString({ realpath($0, nil) }) else { throw NotikaDocumentationDriverError.toolUnavailable(path) }
        defer { free(canonical) }
        self.path = String(cString: canonical)
        let opened = open(self.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard opened >= 0 else { throw documentationIO("open DocC executable") }
        descriptor = DocumentationDescriptor(opened); identity = try documentationStatus(opened)
        guard identity.st_mode & S_IFMT == S_IFREG, identity.st_mode & 0o111 != 0, identity.st_mode & 0o022 == 0,
              identity.st_uid == 0 || identity.st_uid == geteuid(), identity.st_nlink > 0,
              identity.st_size >= 0, identity.st_size <= 256 * 1_024 * 1_024 else { throw NotikaDocumentationDriverError.toolUnavailable(path) }
        // System executables may have several hardlinked names. Their observed
        // inode/link count and retained bytes stay fixed; generated artifacts
        // continue to require a single link through their separate admission.
        evidence = .init(path: self.path, sha256: try Self.digest(opened, size: identity.st_size),
                         deviceID: Int64(identity.st_dev), inode: identity.st_ino)
        try revalidate()
    }
    private static func digest(_ opened: Int32, size: Int64) throws -> String {
        var hash = SHA256(), offset: Int64 = 0, buffer = [UInt8](repeating: 0, count: 128 * 1_024)
        while offset < size {
            let count = buffer.withUnsafeMutableBytes { pread(opened, $0.baseAddress!, $0.count, off_t(offset)) }
            if count < 0, errno == EINTR { continue }
            guard count > 0, offset + Int64(count) <= size else { throw NotikaDocumentationDriverError.artifactChanged }
            hash.update(data: Data(buffer.prefix(count))); offset += Int64(count)
        }
        return documentationHex(hash.finalize())
    }
    func revalidate() throws {
        try revalidateIdentity()
        guard try Self.digest(descriptor.value, size: identity.st_size) == evidence.sha256 else {
            throw NotikaDocumentationDriverError.artifactChanged
        }
        try revalidateIdentity()
    }
    private func revalidateIdentity() throws {
        var named = stat()
        guard lstat(path, &named) == 0, documentationSameFile(named, identity),
              documentationSameFile(try documentationStatus(descriptor.value), identity) else { throw NotikaDocumentationDriverError.artifactChanged }
    }
}

private struct DocumentationTools: Sendable {
    let xcodebuild: DocumentationTool; let xcrun: DocumentationTool; let docc: DocumentationTool; let helper: DocumentationTool
    var evidence: [String: DocumentationToolEvidence] { ["xcodebuild": xcodebuild.evidence, "xcrun": xcrun.evidence, "docc": docc.evidence, "helper": helper.evidence] }
    func revalidate() throws { try xcodebuild.revalidate(); try xcrun.revalidate(); try docc.revalidate(); try helper.revalidate() }
    static func observe(environment: [String: String], repository: String, capture: any RepositoryCommandCapturing, helper: DocumentationTool) async throws -> Self {
        let xcode = try DocumentationTool(path: documentationFind("xcodebuild", environment: environment))
        let xcrun = try DocumentationTool(path: documentationFind("xcrun", environment: environment))
        let encoded = try await capture.capture(arguments: [xcrun.path, "--find", "docc"], workingDirectory: repository, environment: environment)
        guard let raw = String(data: encoded, encoding: .utf8) else { throw NotikaDocumentationDriverError.toolUnavailable("docc") }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try CacheCompatibilityIdentity.graphResourceName(canonicalWorktree: path)
        return Self(xcodebuild: xcode, xcrun: xcrun, docc: try DocumentationTool(path: path), helper: helper)
    }
}

private enum DocumentationPreviewEvent: Sendable {
    case capture(Result<CapturedNativePhase, any Error>)
    case ready(Result<(NotikaDocumentationPreviewEvidence, RetainedArtifactFile), any Error>)
}
private func documentationRunPreview(session: ControllerSessionArtifacts, state: DocumentationState,
    expected: NotikaDocumentationTreeCommitment, port: Int, onReady: @escaping @Sendable (NotikaDocumentationPreviewEvidence) -> Void,
    operation: @escaping @Sendable () async throws -> CapturedNativePhase) async {
    await withTaskGroup(of: DocumentationPreviewEvent.self) { group in
        group.addTask { do { return .capture(.success(try await operation())) } catch { return .capture(.failure(error)) } }
        group.addTask {
            do {
                // Readiness follows bounded whole-site verification. Its cost
                // scales with the archive; helper retirement and cancellation
                // govern this wait, rather than a socket-start wall-clock limit.
                while true {
                    try Task.checkCancellation()
                    let directory = try RetainedArtifactDirectory(path: session.path, requiredPermissions: 0o700)
                    do {
                        let file = try directory.openFile(named: "preview-ready.json",
                            policy: ArtifactFilePolicy(minimumBytes: 1, maximumBytes: 8_192, requiredPermissions: 0o400))
                        let data = try file.readBounded(), document = try StrictJSONDocument(data: data)
                        let ready = try JSONDecoder().decode(NotikaDocumentationPreviewEvidence.self, from: data)
                        guard try CanonicalJSONDigest.encode(documentationCanonical(document.root)) == documentationEncoded(ready),
                              ready.protocolName == "notika.docc-loopback-preview.v1", ready.host == "127.0.0.1", ready.port == port,
                              ready.url == documentationPreviewURL(port), ready.processID > 0,
                              ready.site == session.path + "/site", ready.siteTreeSHA256 == expected.sha256 else { throw documentationSchema("previewReady") }
                        return .ready(.success((ready, file)))
                    } catch RetainedArtifactError.systemCall(_, ENOENT) {}
                    try await Task.sleep(for: .milliseconds(25))
                }
            } catch { return .ready(.failure(error)) }
        }
        var phase: CapturedNativePhase?, preview: NotikaDocumentationPreviewEvidence?
        while let event = await group.next() {
            switch event {
            case .ready(.success(let admitted)):
                preview = admitted.0; state.ready(admitted.0, file: admitted.1); onReady(admitted.0)
            case .ready(.failure(let error)):
                if !(error is CancellationError) { state.failure(error); group.cancelAll() }
            case .capture(.success(let captured)):
                phase = captured; group.cancelAll()
            case .capture(.failure(let error)):
                state.failure(error); group.cancelAll()
            }
        }
        if let phase, let preview {
            if phase.observation.processIdentifier != preview.processID { state.failure(documentationSchema("previewProcess")) }
        } else if !Task.isCancelled { state.failure(NotikaDocumentationDriverError.previewNotReady) }
    }
}

private func documentationBuildArguments(cache: String) -> [String] {
    ["-derivedDataPath", cache, "-disableAutomaticPackageResolution", "docbuild", "-workspace", "Notika.xcworkspace",
     "-scheme", "Notika", "-destination", "platform=macOS,arch=arm64"]
}
private func documentationLegacyFailedBuild(_ payload: DocumentationReportPayload, phase: DocumentationPhaseRecord) -> Bool {
    // Retention can still read the original generic-destination native failure.
    // It cannot establish successful arm64 output or become a new invocation.
    guard payload.lifecycle == "terminal", payload.status == "failed", !payload.executionComplete,
          payload.phases.count == 1, payload.archive == nil, payload.renderer == nil, payload.site == nil, payload.preview == nil,
          phase.nativeTermination.flatMap(documentationFailureCode) != nil else { return false }
    var legacy = documentationBuildArguments(cache: payload.cachePath ?? "")
    legacy[legacy.count - 1] = "generic/platform=macOS"
    return documentationLiteralArguments(phase.command.arguments, legacy)
}
private func documentationLiteralArguments(_ lhs: [String], _ rhs: [String]) -> Bool {
    lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { pair in pair.0.utf8.elementsEqual(pair.1.utf8) }
}
private func documentationTransformArguments(session: String) -> [String] {
    ["process-archive", "transform-for-static-hosting", session + "/Notika.doccarchive", "--output-path", session + "/site", "--hosting-base-path", "/"]
}
internal func documentationPreviewArguments(repository: String, session: String, registry: String, port: Int, hash: String) -> [String] {
    ["_notika-doc-preview", "--repository", repository, "--session-dir", session, "--lease-home", registry,
     "--port", String(port), "--site-sha256", hash]
}
internal func documentationPreviewURL(_ port: Int) -> String { "http://127.0.0.1:\(port)/documentation/notika" }
internal func documentationSHA(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
private func documentationSucceeded(_ phase: CapturedNativePhase) -> Bool {
    phase.observation.termination == .init(kind: .exit, value: 0) && phase.observation.retirement == .workerReaped
        && phase.observation.failures.isEmpty && !phase.observation.cancelled && phase.rawCapture.captureComplete
}
private func documentationFailureCode(_ native: RunTermination) -> Int32? {
    if native.kind == .signal { return native.value > 0 && native.value < 128 ? 128 + native.value : 70 }
    return native.value == 0 ? nil : native.value
}
private func documentationValidateTermination(_ native: RunTermination) throws {
    guard native.kind == .exit ? (0...255).contains(native.value) : (1..<128).contains(native.value) else {
        throw documentationSchema("nativeTermination")
    }
}
private func documentationStatus(_ value: DocumentationReportPayload) -> (String, Int32) {
    if let native = value.buildNativeTermination, let code = documentationFailureCode(native) { return ("failed", code) }
    if value.cancelled { return ("cancelled", 130) }
    if let code = value.phases.dropFirst().compactMap({ $0.nativeTermination.flatMap(documentationFailureCode) }).first { return ("failed", code) }
    if !value.executionComplete || !value.orchestrationFailures.isEmpty || !value.publicationFailures.isEmpty { return ("inconclusive", 70) }
    return ("succeeded", 0)
}
private func documentationChanged(_ before: DocumentationSnapshot?, _ after: DocumentationSnapshot?) -> Bool {
    guard let before else { return false }
    return before.sha256 != after?.sha256
}
private func documentationCommand(_ command: DarwinWorkloadCommand) throws -> DocumentationCommand {
    DocumentationCommand(executable: command.executable, arguments: command.arguments, workingDirectory: command.workingDirectory,
        environmentSHA256: try CanonicalJSONDigest.sha256(.object(command.environment.mapValues(CanonicalJSONValue.string))))
}
internal func documentationEncoded<T: Encodable>(_ value: T) throws -> Data {
    let encoded = try JSONEncoder().encode(value)
    return try CanonicalJSONDigest.encode(documentationCanonical(StrictJSONDocument(data: encoded).root))
}
internal func documentationValue<T: Encodable>(_ value: T) throws -> CanonicalJSONValue {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try documentationCanonical(StrictJSONDocument(data: encoder.encode(value)).root)
}
internal func documentationCanonical(_ value: StrictJSONValue) throws -> CanonicalJSONValue {
    switch value {
    case .null: return .null
    case .bool(let value): return .bool(value)
    case .string(let value): return .string(value)
    case .number(let value):
        if let integer = try? value.int64() { return .integer(integer) }
        return .unsignedInteger(try value.uint64())
    case .array(let values): return .array(try values.map(documentationCanonical))
    case .object(let object): return .object(try object.members.map { CanonicalJSONMember(key: $0.key, value: try documentationCanonical($0.value)) })
    }
}
private func documentationSnapshotValue(_ snapshot: DocumentationSnapshot?) throws -> CanonicalJSONValue {
    guard let snapshot else { throw documentationSchema("snapshotAbsent") }
    return try documentationCanonical(StrictJSONDocument(data: Data(snapshot.keyMaterialJSON.utf8)).root)
}
private func documentationSourceProjection(_ snapshot: DocumentationSnapshot?, repository: String) throws -> NotikaSourceIdentity {
    let value = try documentationSnapshotValue(snapshot)
    let object = try StrictJSONDocument(data: CanonicalJSONDigest.encode(value)).root.requireObject()
    func string(_ object: StrictJSONObject, _ name: String) throws -> String {
        guard case .string(let value) = try object.requiredValue(forKey: name) else { throw documentationSchema(name) }; return value
    }
    guard try string(object, "canonicalWorktree").utf8.elementsEqual(repository.utf8),
          case .array(let links) = try object.requiredValue(forKey: "gitlinks") else { throw documentationSchema("source") }
    let gitlinks = try links.map { item -> CacheGitlink in
        let item = try item.requireObject().project(requiredKeys: ["path", "commit"])
        return try CacheGitlink(path: string(item, "path"), commit: string(item, "commit"))
    }
    return try NotikaSourceIdentity(canonicalWorktree: repository, head: string(object, "head"), gitlinks: gitlinks,
        statusDigest: string(object, "statusDigest"), stagedDiffDigest: string(object, "stagedDiffDigest"), unstagedDiffDigest: string(object, "unstagedDiffDigest"),
        submoduleStatusDigest: string(object, "submoduleStatusDigest"), submoduleWorktreeDigest: string(object, "submoduleWorktreeDigest"),
        projectGraphDigest: string(object, "projectGraphDigest"), generatedGraphDigest: string(object, "generatedGraphDigest"),
        resolvedDependenciesDigest: string(object, "resolvedDependenciesDigest"), keyMaterial: value)
}
private func documentationValidateCapture(
    _ raw: NativeLogCaptureRecord, session: String, policy: NativeCaptureAdmissionPolicy
) throws -> String {
    let value = try StrictJSONDocument(data: JSONEncoder().encode(raw)).root
    let admitted = try admitNativeLogCaptureRecord(value, sessionPath: session, policy: policy)
    return URL(fileURLWithPath: admitted.standardOutput.path).deletingLastPathComponent().lastPathComponent
}

private func documentationValidateCommitment(_ value: NotikaDocumentationTreeCommitment) throws {
    guard value.algorithm == "notika.docc-owned-tree.sha256.v1", documentationSHA(value.sha256),
          (0...NotikaDocumentationTree.maximumEntries).contains(value.entries),
          (0...NotikaDocumentationTree.maximumBytes).contains(value.bytes),
          value.maximumEntries == NotikaDocumentationTree.maximumEntries, value.maximumBytes == NotikaDocumentationTree.maximumBytes,
          value.maximumDepth == NotikaDocumentationTree.maximumDepth else { throw documentationSchema("treeCommitment") }
}
private func documentationRequired<T>(_ value: T?, _ name: String) throws -> T { guard let value else { throw documentationSchema(name) }; return value }
private func documentationDate(_ value: String) throws -> Date {
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = formatter.date(from: value), date.timeIntervalSinceReferenceDate.isFinite else { throw documentationSchema("timestamp") }
    return date
}
private func documentationTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}
internal func documentationSchema(_ name: String) -> NotikaDocumentationDriverError { .invalidReport(name) }
private func documentationFind(_ name: String, environment: [String: String]) throws -> String {
    for directory in (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":", omittingEmptySubsequences: false) where directory.hasPrefix("/") {
        let path = String(directory) + "/" + name
        if access(path, X_OK) == 0 { return path }
    }
    throw NotikaDocumentationDriverError.toolUnavailable(name)
}

extension NotikaDocumentationSessionReport {
    /// Collector fixtures use genuine writer custody and the production sealed
    /// publisher. Diagnostic terminal evidence deliberately claims no build.
    internal static func publishDiagnosticFixture(repository: String, registryRoot: String, sessionID: String,
        startedAt: Date, completedAt: Date?, timeZone: TimeZone) async throws -> Self {
        let paths = try AgentLeasePaths.open(selectedRoot: registryRoot)
        let acquired = RunRecord.timestamp(), pid = getpid()
        let writer = try await LeaseSet.acquire(ResourceSet(exclusive: [], shared: ["notika:sessions:" + repository]),
            paths: paths, waitSeconds: 0, initialMetadata: { lease in
                LockMetadata(resourceName: lease.resource.value, leaseMode: lease.mode, runID: sessionID,
                    coordinatorPID: pid, childPID: nil, mode: .run, state: .acquired,
                    label: "notika-documentation-diagnostic-fixture", bead: nil, acquiredAt: acquired)
            })
        defer { writer.release() }
        let session = try ControllerSessionArtifacts(repository: repository, runID: sessionID)
        let state = DocumentationState(session: session, runID: sessionID, repository: repository, mode: .archive,
            registry: registryRoot, previewPort: 8_000, startedAt: startedAt, timeZone: timeZone)
        let progress = try state.report(completedAt: nil)
        try session.publish(sealedData: progress.originalData, name: "in-progress.json", validating: {})
        guard let completedAt else { return progress }
        state.failure(documentationSchema("diagnostic fixture; no native build attempted"))
        let terminal = try state.report(completedAt: completedAt)
        try session.publish(sealedData: terminal.originalData, name: "manifest.json", validating: { try state.revalidate() })
        return terminal
    }
}
