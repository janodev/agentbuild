import AgentLeaseCore
import Foundation

public enum NotikaBuildSessionError: Error, Equatable, Sendable {
    case invalidSchema(String)
    case invalidLifecycle
    case expiredOwnership
    case unsafePath(String)
    case identityChanged(String)
    case io(operation: String, code: Int32)
}

/// Historical decoding is only for closed-session retention. It cannot mint a
/// live capture or establish that an unrecorded combined log exists.
internal enum NativeCaptureAdmissionPolicy: Equatable, Sendable {
    case current
    case historicalRetention
}

internal struct NativeLogCaptureRecord: Codable, Sendable {
    let standardOutput: NativeLogStreamResult
    let standardError: NativeLogStreamResult
    let combined: NativeLogStreamResult?
    let maximumBytes: Int64
    let captureComplete: Bool
    let failures: [NativeLogCaptureFailure]

    init(_ capture: NativeLogCaptureResult) {
        standardOutput = capture.standardOutput
        standardError = capture.standardError
        combined = capture.combined
        maximumBytes = capture.maximumBytes
        captureComplete = capture.captureComplete
        failures = capture.failures
    }
}

/// Validates the descriptor-free record; retained capture objects separately
/// establish file custody. Hashes commit the three actual files independently.
internal func admitNativeLogCaptureRecord(
    _ value: StrictJSONValue, sessionPath: String,
    policy: NativeCaptureAdmissionPolicy = .current
) throws -> NativeLogCaptureRecord {
    let fields = ["standardOutput", "standardError", "maximumBytes", "captureComplete", "failures"]
    let object = try value.requireObject().project(
        requiredKeys: policy == .current ? fields + ["combined"] : fields,
        optionalKeys: policy == .historicalRetention ? ["combined"] : []
    )
    guard case .array(let failures) = try object.requiredValue(forKey: "failures"), failures.count <= 128 else {
        throw StrictJSONError.invalidSchema
    }
    for failure in failures {
        let object = try failure.requireObject().project(requiredKeys: ["operation"], optionalKeys: ["code", "stream", "detail"])
        let decoded = try JSONDecoder().decode(NativeLogCaptureFailure.self, from: CanonicalJSONDigest.encode(sessionCanonical(.object(object))))
        guard !decoded.operation.isEmpty else { throw StrictJSONError.invalidSchema }
    }
    var directory: Data?
    for (field, leaf) in [("standardOutput", "stdout.log"), ("standardError", "stderr.log"), ("combined", "combined.log")] {
        guard let value = object.value(forKey: field) else { continue }
        let stream = try value.requireObject().project(requiredKeys: ["path", "observedBytes", "retainedBytes", "sha256", "reachedEOF"])
        let path = try sessionString(stream, "path"), prefix = sessionPath + "/"
        guard path.utf8.starts(with: prefix.utf8), !path.utf8.contains(0), sessionHex(try sessionString(stream, "sha256")) else {
            throw StrictJSONError.invalidSchema
        }
        let relative = String(decoding: path.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil,
              parts[1].utf8.elementsEqual(leaf.utf8) else { throw StrictJSONError.invalidSchema }
        let current = Data(parts[0].utf8)
        guard directory == nil || directory == current else { throw StrictJSONError.invalidSchema }
        directory = current
    }
    let record = try JSONDecoder().decode(NativeLogCaptureRecord.self,
        from: CanonicalJSONDigest.encode(sessionCanonical(.object(object))))
    guard nativeLogCaptureRecordAccountingIsValid(record, policy: policy) else { throw StrictJSONError.invalidSchema }
    return record
}

internal func nativeLogCaptureRecordAccountingIsValid(
    _ raw: NativeLogCaptureRecord, policy: NativeCaptureAdmissionPolicy = .current
) -> Bool {
    guard (0...NativeLogCapture.maximumRawBytes).contains(raw.maximumBytes), raw.failures.count <= 128,
          raw.combined != nil || policy == .historicalRetention else { return false }
    let streams = [raw.standardOutput, raw.standardError] + (raw.combined.map { [$0] } ?? [])
    guard streams.allSatisfy({ $0.observedBytes >= 0 && $0.retainedBytes >= 0
        && $0.retainedBytes <= $0.observedBytes && $0.retainedBytes <= raw.maximumBytes }) else { return false }
    let retained = raw.standardOutput.retainedBytes.addingReportingOverflow(raw.standardError.retainedBytes)
    guard !retained.overflow, retained.partialValue <= raw.maximumBytes else { return false }
    if let combined = raw.combined {
        let observed = raw.standardOutput.observedBytes.addingReportingOverflow(raw.standardError.observedBytes)
        guard !observed.overflow, combined.observedBytes == observed.partialValue,
              combined.reachedEOF == (raw.standardOutput.reachedEOF && raw.standardError.reachedEOF) else { return false }
    }
    if raw.captureComplete {
        guard raw.failures.isEmpty, streams.allSatisfy({ $0.reachedEOF && $0.retainedBytes == $0.observedBytes }) else { return false }
        if let combined = raw.combined {
            guard combined.retainedBytes == retained.partialValue else { return false }
        }
    }
    return true
}

/// Inputs observed by the trusted coordinator. Retained capsules, rather than
/// copied log paths, supply publication authority for native raw evidence.
public struct NotikaBuildSessionTerminalEvidence: Sendable {
    public let sourceBefore: NotikaSourceIdentity?
    public let sourceAfter: NotikaSourceIdentity?
    public let toolchainBefore: NotikaToolchainIdentity?
    public let toolchainAfter: NotikaToolchainIdentity?
    public let compatibilityIdentity: CacheCompatibilityIdentity?
    public let plan: NotikaXcodeInvocationPlan?
    public let outcome: NotikaOwnedExecutionOutcome?
    public let capturedPhases: [CapturedNativePhase]
    public let orchestrationFailures: [String]
    public let resultSummary: NotikaResultSummaryEvidence?
    public let resultPreparation: NotikaResultPreparationFailure?
    public let resultConsumer: NotikaResultConsumerEvidence?
    public let performanceEvidence: NotikaPerformanceEvidence?
    public let preflightEvidence: NotikaDevelopmentPreflightEvidence?
    public let simulatorPreparation: CapturedNativePhase?
    public let uiPreparation: CapturedNativePhase?
    public let cancelled: Bool
    public let sourceDriftObservedReverted: Bool
    public let toolchainDriftObservedReverted: Bool

    public init(
        sourceBefore: NotikaSourceIdentity? = nil,
        sourceAfter: NotikaSourceIdentity? = nil,
        toolchainBefore: NotikaToolchainIdentity? = nil,
        toolchainAfter: NotikaToolchainIdentity? = nil,
        compatibilityIdentity: CacheCompatibilityIdentity? = nil,
        plan: NotikaXcodeInvocationPlan? = nil,
        outcome: NotikaOwnedExecutionOutcome? = nil,
        capturedPhases: [CapturedNativePhase] = [],
        orchestrationFailures: [String] = [],
        resultSummary: NotikaResultSummaryEvidence? = nil,
        resultPreparation: NotikaResultPreparationFailure? = nil,
        resultConsumer: NotikaResultConsumerEvidence? = nil,
        performanceEvidence: NotikaPerformanceEvidence? = nil,
        preflightEvidence: NotikaDevelopmentPreflightEvidence? = nil,
        simulatorPreparation: CapturedNativePhase? = nil,
        uiPreparation: CapturedNativePhase? = nil,
        cancelled: Bool = false,
        sourceDriftObservedReverted: Bool = false,
        toolchainDriftObservedReverted: Bool = false
    ) {
        self.sourceBefore = sourceBefore
        self.sourceAfter = sourceAfter
        self.toolchainBefore = toolchainBefore
        self.toolchainAfter = toolchainAfter
        self.compatibilityIdentity = compatibilityIdentity
        self.plan = plan
        self.outcome = outcome
        self.capturedPhases = capturedPhases
        self.orchestrationFailures = orchestrationFailures
        self.resultSummary = resultSummary ?? resultConsumer?.summary
        self.resultPreparation = resultPreparation
        self.resultConsumer = resultConsumer
        self.performanceEvidence = performanceEvidence
        self.preflightEvidence = preflightEvidence
        self.simulatorPreparation = simulatorPreparation
        self.uiPreparation = uiPreparation
        self.cancelled = cancelled
        self.sourceDriftObservedReverted = sourceDriftObservedReverted
        self.toolchainDriftObservedReverted = toolchainDriftObservedReverted
    }
}

/// A closed Swift schema, deliberately distinct from Notika's Python manifest.
/// Admission validates shape and commitments; disk custody belongs to the
/// session writer, and cannot be recreated from this value alone.
public struct NotikaBuildSessionReport: Sendable {
    public static let namespace = "agentbuild.notika-session"
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
    public let destination: String

    public init(data: Data, expectedRepository: String? = nil, expectedSessionID: String? = nil) throws {
        try self.init(data: data, expectedRepository: expectedRepository, expectedSessionID: expectedSessionID,
                      captureAdmissionPolicy: .current)
    }

    internal init(data: Data, expectedRepository: String? = nil, expectedSessionID: String? = nil,
                  captureAdmissionPolicy: NativeCaptureAdmissionPolicy) throws {
        let document = try StrictJSONDocument(data: data)
        let root = try document.root.requireObject().project(requiredKeys: Self.fields,
            optionalKeys: ["resultEvidence", "resultPreparation", "destination", "outerLeaseEvidence", "resultConsumer", "performanceEvidence",
                           "preflightEvidence", "simulatorPreparation", "uiPreparation"])
        try sessionRequireString(root, "namespace", Self.namespace)
        guard try sessionInteger(root, "schemaVersion") == 1 else { throw sessionSchema("schemaVersion") }
        let session = try sessionString(root, "sessionID")
        guard let uuid = UUID(uuidString: session), uuid.uuidString == session,
              try sessionString(root, "runUUID") == session else { throw sessionSchema("runUUID") }
        let repository = try sessionString(root, "repository")
        _ = try CacheCompatibilityIdentity.graphResourceName(canonicalWorktree: repository)
        if let expectedRepository, !repository.utf8.elementsEqual(expectedRepository.utf8) {
            throw sessionSchema("repository")
        }
        if let expectedSessionID, !session.utf8.elementsEqual(expectedSessionID.utf8) {
            throw sessionSchema("sessionID")
        }
        try sessionRequireString(root, "writerResource", "notika:sessions:" + repository)
        guard !(try sessionString(root, "toolVersion")).isEmpty,
              try sessionUnsigned(root, "ownerUID") <= UInt64(UInt32.max) else { throw sessionSchema("owner") }
        let directory = try root.requiredValue(forKey: "directoryIdentity").requireObject()
            .project(requiredKeys: ["deviceID", "inode"])
        _ = try sessionUnsigned(directory, "deviceID")
        guard try sessionUnsigned(directory, "inode") > 0 else { throw sessionSchema("directoryIdentity") }
        let requestValue = try root.requiredValue(forKey: "request")
        let requestData = try CanonicalJSONDigest.encode(sessionCanonical(requestValue))
        let request = try JSONDecoder().decode(NotikaActionRequest.self, from: requestData)
        guard sessionSupportsRequest(request) else {
            throw sessionSchema("request")
        }
        let contextIsExplicit = root.value(forKey: "destination") != nil
        guard contextIsExplicit == (root.value(forKey: "outerLeaseEvidence") != nil) else {
            throw sessionSchema("executionContext")
        }
        let destination = contextIsExplicit ? try sessionString(root, "destination") : "platform=macOS,arch=arm64"
        let outerValue = root.value(forKey: "outerLeaseEvidence") ?? .null
        try sessionValidateExecutionContext(request: request, destination: destination, outerValue: outerValue)
        let started = try sessionDate(root, "startedAt")
        let lifecycle = try sessionString(root, "lifecycle")
        guard captureAdmissionPolicy != .historicalRetention || lifecycle == "terminal" else { throw sessionSchema("historicalRetention") }
        let status = try sessionString(root, "status")
        let cancelled = try sessionBool(root, "cancelled")
        let failures = try sessionStringArray(root, "orchestrationFailures")
        for field in ["sourceBefore", "sourceAfter", "toolchainBefore", "toolchainAfter"] {
            try sessionValidateSnapshot(root.requiredValue(forKey: field), repository: repository,
                                        source: field.hasPrefix("source"), field: field)
        }
        let compatibility = try root.requiredValue(forKey: "compatibilityIdentity")
        var admittedIdentity: CacheCompatibilityIdentity?
        if compatibility != .null {
            let object = try compatibility.requireObject().project(requiredKeys: ["keyMaterial", "executionSHA256", "cacheKey"])
            let identity = try CacheCompatibilityIdentity(
                keyMaterial: sessionCanonical(object.requiredValue(forKey: "keyMaterial")), expectedRepository: repository
            )
            try sessionRequireString(object, "executionSHA256", identity.executionDigest())
            try sessionRequireString(object, "cacheKey", identity.cacheKey())
            admittedIdentity = identity
        }
        let physical = try root.requiredValue(forKey: "physicalPlan")
        let phases = try sessionValidatePhysicalPlan(physical)
        if !phases.isEmpty {
            guard let identity = admittedIdentity else { throw sessionSchema("physicalPlan.identity") }
            let profile = NotikaCacheProfile(request: request)
            guard identity.scheme == profile.scheme, identity.configuration == profile.configuration,
                  identity.destinationFamily == profile.destinationFamily,
                  identity.buildFlags.map({ Data($0.utf8) }) == profile.buildFlags.map({ Data($0.utf8) }) else {
                throw sessionSchema("physicalPlan.profile")
            }
            let expected = try NotikaXcodeInvocationPlan(
                request: request, destination: destination,
                cacheDirectory: repository + "/DerivedData/AgentCaches/" + identity.cacheKey(),
                resultBundle: repository + "/Artifacts/AgentSessions/" + session + "/result.xcresult"
            )
            let expectedPhases = try CanonicalJSONDigest.encode(.array(NativeInvocationLedger(plan: expected).phases.map(sessionPhaseValue)))
            guard try StrictJSONDocument(data: expectedPhases).root == physical else {
                throw sessionSchema("physicalPlan.request")
            }
        }
        let observations = try sessionValidateObservations(root.requiredValue(forKey: "phaseObservations"), phases: phases)
        let logs = try sessionValidateRawLogs(root.requiredValue(forKey: "rawLogReports"), observations: observations,
                                             phases: phases, repository: repository,
                                             sessionPath: repository + "/Artifacts/AgentSessions/" + session, policy: captureAdmissionPolicy)
        let resultValue = root.value(forKey: "resultEvidence") ?? .null
        let resultPreparationValue = root.value(forKey: "resultPreparation") ?? .null
        let resultPreparationCancelled = try sessionValidateResultPreparation(resultPreparationValue,
            resultValue: resultValue, request: request, sessionPath: repository + "/Artifacts/AgentSessions/" + session, policy: captureAdmissionPolicy)
        let resultPasses = try sessionValidateResultEvidence(resultValue, root: root, request: request,
            destination: destination, identity: admittedIdentity, phases: phases, observations: observations,
            sessionPath: repository + "/Artifacts/AgentSessions/" + session, policy: captureAdmissionPolicy)
        let sessionPath = repository + "/Artifacts/AgentSessions/" + session
        let resultConsumerValue = root.value(forKey: "resultConsumer") ?? .null
        let consumerPasses = try sessionValidateConsumers(resultConsumerValue, resultValue: resultValue,
            request: request, sessionPath: sessionPath, policy: captureAdmissionPolicy)
        let preflightValue = root.value(forKey: "preflightEvidence") ?? .null
        let sourceValue = try root.requiredValue(forKey: "sourceBefore")
        let sourceHash = sourceValue == .null ? nil : try sessionString(sourceValue.requireObject(), "sha256")
        let toolchainValue = try root.requiredValue(forKey: "toolchainBefore")
        let toolchainHash = toolchainValue == .null ? nil : try sessionString(toolchainValue.requireObject(), "sha256")
        let performanceValue = root.value(forKey: "performanceEvidence") ?? .null
        let performancePasses = try sessionValidatePerformance(performanceValue, resultValue: resultValue,
            request: request, sourceHash: sourceHash, toolchainHash: toolchainHash, sessionPath: sessionPath,
            sourceValue: sourceValue, outerValue: outerValue, policy: captureAdmissionPolicy)
        let preflight = try sessionValidatePreflight(preflightValue, request: request, sourceHash: sourceHash, sessionPath: sessionPath, policy: captureAdmissionPolicy)
        let preparationValue = root.value(forKey: "simulatorPreparation") ?? .null
        let preparation = try sessionValidatePreparation(preparationValue, request: request, destination: destination,
            repository: repository, sessionPath: sessionPath, ui: false, policy: captureAdmissionPolicy)
        let uiPreparationValue = root.value(forKey: "uiPreparation") ?? .null
        let uiPreparation = try sessionValidatePreparation(uiPreparationValue, request: request, destination: destination,
            repository: repository, sessionPath: sessionPath, ui: true, policy: captureAdmissionPolicy)
        guard cancelled || (!preflight.cancelled && !preparation.cancelled && !uiPreparation.cancelled && !resultPreparationCancelled) else {
            throw sessionSchema("cancelled")
        }
        let native = try sessionTermination(root.requiredValue(forKey: "nativeTermination"))
        let drift = try root.requiredValue(forKey: "sourceDrift").requireObject().project(
            requiredKeys: ["sourceChanged", "toolchainChanged", "sourceObservedReverted", "toolchainObservedReverted"]
        )
        let sourceChanged = try sessionOptionalBool(drift.requiredValue(forKey: "sourceChanged"))
        let toolchainChanged = try sessionOptionalBool(drift.requiredValue(forKey: "toolchainChanged"))
        let reverted = try sessionBool(drift, "sourceObservedReverted") || sessionBool(drift, "toolchainObservedReverted")
        let expectedSourceChange = try sessionSnapshotChange(root, "sourceBefore", "sourceAfter")
        let expectedToolchainChange = try sessionSnapshotChange(root, "toolchainBefore", "toolchainAfter")
        guard sourceChanged == expectedSourceChange, toolchainChanged == expectedToolchainChange else {
            throw sessionSchema("sourceDrift")
        }
        let commitments = try root.requiredValue(forKey: "commitments").requireObject().project(
            requiredKeys: ["requestSHA256", "physicalPlanSHA256", "rawLogReportsSHA256"],
            optionalKeys: ["resultEvidenceSHA256", "resultPreparationSHA256", "executionContextSHA256", "resultConsumerSHA256", "performanceEvidenceSHA256",
                           "preflightEvidenceSHA256", "simulatorPreparationSHA256", "uiPreparationSHA256"]
        )
        for (field, value) in [("requestSHA256", requestValue), ("physicalPlanSHA256", physical),
                               ("rawLogReportsSHA256", try root.requiredValue(forKey: "rawLogReports"))] {
            try sessionRequireString(commitments, field, CanonicalJSONDigest.sha256(sessionCanonical(value)))
        }
        if root.value(forKey: "resultEvidence") != nil {
            try sessionRequireString(commitments, "resultEvidenceSHA256", CanonicalJSONDigest.sha256(sessionCanonical(resultValue)))
        } else if commitments.value(forKey: "resultEvidenceSHA256") != nil {
            throw sessionSchema("resultEvidenceSHA256")
        }
        if contextIsExplicit {
            let context = CanonicalJSONValue.object(["destination": .string(destination), "outerLeaseEvidence": try sessionCanonical(outerValue)])
            try sessionRequireString(commitments, "executionContextSHA256", CanonicalJSONDigest.sha256(context))
        } else if commitments.value(forKey: "executionContextSHA256") != nil { throw sessionSchema("executionContextSHA256") }
        for (field, digest) in [("resultPreparation", "resultPreparationSHA256"), ("resultConsumer", "resultConsumerSHA256"),
                               ("performanceEvidence", "performanceEvidenceSHA256"),
                               ("preflightEvidence", "preflightEvidenceSHA256"),
                               ("simulatorPreparation", "simulatorPreparationSHA256"),
                               ("uiPreparation", "uiPreparationSHA256")] {
            if let value = root.value(forKey: field) {
                try sessionRequireString(commitments, digest, CanonicalJSONDigest.sha256(sessionCanonical(value)))
            } else if commitments.value(forKey: digest) != nil { throw sessionSchema(digest) }
        }
        let execution = try root.requiredValue(forKey: "execution").requireObject().project(
            requiredKeys: ["complete", "plannedPhaseCount", "completedPhaseCount"]
        )
        let complete = try sessionBool(execution, "complete")
        guard try sessionInteger(execution, "plannedPhaseCount") == Int64(phases.count),
              try sessionInteger(execution, "completedPhaseCount") == Int64(observations.count) else {
            throw sessionSchema("execution")
        }
        let exitCode: Int32?
        switch lifecycle {
        case "inProgress":
            guard status == "running", root.value(forKey: "completedAt") == .null,
                  root.value(forKey: "expiresAt") == .null, root.value(forKey: "exitCode") == .null,
                  !cancelled, native == nil, !complete, phases.isEmpty, observations.isEmpty,
                  logs.isEmpty, failures.isEmpty, resultValue == .null, resultPreparationValue == .null, resultConsumerValue == .null,
                  performanceValue == .null, preflightValue == .null, preparationValue == .null, uiPreparationValue == .null,
                  ["sourceBefore", "sourceAfter", "toolchainBefore", "toolchainAfter", "compatibilityIdentity"]
                    .allSatisfy({ root.value(forKey: $0) == .null }) else { throw sessionSchema("inProgress") }
            exitCode = nil
        case "terminal":
            let completed = try sessionDate(root, "completedAt")
            let expires = try sessionDate(root, "expiresAt")
            guard started <= completed, completed < expires,
                  let zone = TimeZone(identifier: try sessionString(root, "localTimeZone")) else {
                throw sessionSchema("timestamps")
            }
            let expectedExpiry = try LocalCalendarRetention(evaluatedAt: completed, timeZone: zone).nextLocalMidnight
            guard abs(expires.timeIntervalSince(expectedExpiry)) < 0.001 else { throw sessionSchema("expiresAt") }
            let observedNative = observations.compactMap(\.termination)
            let nativeFailure = preparation.nativeFailure ?? uiPreparation.nativeFailure ?? preflight.nativeFailure
                ?? observedNative.first { sessionExitCode($0) != 0 }
            guard native == (nativeFailure ?? observedNative.last) else { throw sessionSchema("nativeTermination") }
            if complete {
                guard !phases.isEmpty, observations.count == phases.count,
                      observedNative.count == observations.count,
                      observations.allSatisfy({ $0.retirement == "workerReaped" && $0.failures.isEmpty }),
                      !cancelled else { throw sessionSchema("execution.complete") }
            }
            let expected: (String, Int32)
            if let nativeFailure { expected = ("failed", sessionExitCode(nativeFailure)) }
            else if cancelled { expected = ("cancelled", 130) }
            else if !failures.isEmpty || resultPreparationValue != .null { expected = ("inconclusive", 70) }
            else if !complete || !logs.allSatisfy({ $0.captureComplete && $0.publicationAdmitted }) || logs.count != observations.count
                        || sourceChanged == nil || toolchainChanged == nil || compatibility == .null
                        || (request.expectsResultBundle && !resultPasses)
                        || (sessionRequiresConsumer(request) && !consumerPasses)
                        || (sessionRequiresPerformance(request) && !performancePasses)
                        || (NotikaDevelopmentPreflight.requiresPreflight(for: request) && !preflight.succeeded)
                        || (request.platform == .iPadSimulator && !preparation.succeeded)
                        || (NotikaBuildCoordinator.requiresUIPreparation(for: request) && !uiPreparation.succeeded) {
                expected = ("inconclusive", 3)
            } else if sourceChanged == true || toolchainChanged == true || reverted {
                expected = ("inconclusive", 3)
            } else { expected = ("succeeded", 0) }
            guard status == expected.0, try sessionInteger(root, "exitCode") == Int64(expected.1) else {
                throw sessionSchema("exitCode")
            }
            exitCode = expected.1
        default: throw sessionSchema("lifecycle")
        }
        self.originalData = data
        canonicalValue = try sessionCanonical(document.root)
        digest = document.digest
        sessionID = session
        self.repository = repository
        self.lifecycle = lifecycle
        self.status = status
        self.exitCode = exitCode
        nativeTermination = native
        self.cancelled = cancelled
        self.destination = destination
    }

    static let fields = [
        "namespace", "schemaVersion", "toolVersion", "runUUID", "sessionID", "repository", "ownerUID",
        "directoryIdentity", "writerResource", "request", "lifecycle", "status", "startedAt", "completedAt",
        "expiresAt", "localTimeZone", "sourceBefore", "sourceAfter", "toolchainBefore", "toolchainAfter",
        "compatibilityIdentity", "physicalPlan", "phaseObservations", "rawLogReports", "nativeTermination",
        "orchestrationFailures", "cancelled", "sourceDrift", "commitments", "execution", "exitCode",
    ]

    static func make(
        repository: String, runID: String, ownerUID: UInt32, directoryDevice: UInt64, directoryInode: UInt64,
        request: NotikaActionRequest, startedAt: Date,
        destination: String = "platform=macOS,arch=arm64", outerLeaseEvidence: NotikaOuterLeaseEvidence? = nil,
        completedAt: Date?, timeZone: TimeZone,
        evidence: NotikaBuildSessionTerminalEvidence?, admitCaptures: Bool = true, allowFixtureCommands: Bool = false,
        publicationFailures: [String] = []
    ) throws -> Self {
        if let consumer = evidence?.resultConsumer, let summary = evidence?.resultSummary,
           consumer.summary !== summary { throw sessionSchema("resultConsumer.summary") }
        guard evidence?.resultPreparation == nil || evidence?.resultSummary == nil else { throw sessionSchema("resultPreparation.resultEvidence") }
        let requestValue = try sessionEncoded(request)
        let outerValue = try outerLeaseEvidence.map(sessionEncoded) ?? .null
        let context = CanonicalJSONValue.object(["destination": .string(destination), "outerLeaseEvidence": outerValue])
        let physical = try evidence?.plan.map { try NativeInvocationLedger(plan: $0).phases.map(sessionPhaseValue) } ?? []
        let observations = evidence?.outcome?.observations ?? []
        guard observations.count == (evidence?.capturedPhases.count ?? 0) else { throw sessionSchema("capturedPhases") }
        let observationValues = try observations.enumerated().map { index, value -> CanonicalJSONValue in
            let capsule = evidence!.capturedPhases[index]
            guard try sessionObservationValue(capsule.observation) == sessionObservationValue(value.workload) else {
                throw sessionSchema("capturedPhaseObservation")
            }
            return .object(["physicalOrdinal": .integer(Int64(value.phase.physicalOrdinal)),
                            "phase": sessionPhaseValue(value.phase), "native": try sessionObservationValue(value.workload)])
        }
        let logs = try observations.enumerated().map { index, value -> CanonicalJSONValue in
            let capsule = evidence!.capturedPhases[index]
            let admitted = admitCaptures && capsule.rawCapture.captureComplete
            let admission = admitted ? (allowFixtureCommands ? "trustedPackageFixture" : "production") : "diagnostic"
            return .object(["physicalOrdinal": .integer(Int64(value.phase.physicalOrdinal)),
                     "publicationAdmitted": .bool(admitted), "commandAdmission": .string(admission),
                     "command": try sessionCommandValue(capsule.command),
                     "capture": try sessionEncoded(capsule.rawCapture)])
        }
        let resultValue = try sessionResultEvidenceValue(evidence?.resultSummary,
            admitCaptures: admitCaptures, allowFixtureCommands: allowFixtureCommands)
        let resultPreparationValue = try sessionResultPreparationValue(evidence?.resultPreparation)
        let consumerValue = try sessionAncillaryValue(evidence?.resultConsumer?.canonicalValue,
            admitted: admitCaptures, allowFixtureCommands: allowFixtureCommands)
        let performanceValue = try sessionAncillaryValue(evidence?.performanceEvidence?.canonicalValue,
            admitted: admitCaptures, allowFixtureCommands: allowFixtureCommands)
        let preflightValue = try sessionAncillaryValue(evidence?.preflightEvidence?.canonicalValue,
            admitted: admitCaptures, allowFixtureCommands: allowFixtureCommands)
        let preparationValue = try sessionPreparationValue(evidence?.simulatorPreparation,
            admitted: admitCaptures, allowFixtureCommands: allowFixtureCommands)
        let uiPreparationValue = try sessionPreparationValue(evidence?.uiPreparation,
            admitted: admitCaptures, allowFixtureCommands: allowFixtureCommands)
        var failures = (evidence?.orchestrationFailures ?? []) + publicationFailures
        if let failure = evidence?.outcome?.orchestrationFailure { failures.append(failure) }
        let isCancelled = (evidence?.cancelled ?? false) || (evidence?.outcome?.cancelled ?? false)
            || (evidence?.preflightEvidence?.cancelled ?? false) || (evidence?.simulatorPreparation?.observation.cancelled ?? false)
            || (evidence?.uiPreparation?.observation.cancelled ?? false)
            || (evidence?.resultPreparation?.probe?.observation.cancelled ?? false)
        let complete = (evidence?.outcome?.complete ?? false) && !isCancelled
        let prepFailure = evidence?.simulatorPreparation?.observation.termination.flatMap { sessionExitCode($0) == 0 ? nil : $0 }
        let uiPrepFailure = evidence?.uiPreparation?.observation.termination.flatMap { sessionExitCode($0) == 0 ? nil : $0 }
        let native = prepFailure ?? uiPrepFailure ?? evidence?.preflightEvidence?.nativeFailure
            ?? evidence?.outcome?.nativeFailure ?? observations.compactMap(\.workload.termination).last
        let sourceBefore = try sessionSnapshot(evidence?.sourceBefore?.keyMaterial)
        let sourceAfter = try sessionSnapshot(evidence?.sourceAfter?.keyMaterial)
        let toolchainBefore = try sessionSnapshot(evidence?.toolchainBefore?.keyMaterial)
        let toolchainAfter = try sessionSnapshot(evidence?.toolchainAfter?.keyMaterial)
        let sourceChanged = evidence?.sourceBefore != nil && evidence?.sourceAfter != nil
            ? try evidence!.sourceBefore!.digest() != evidence!.sourceAfter!.digest() : nil
        let toolchainChanged = evidence?.toolchainBefore != nil && evidence?.toolchainAfter != nil
            ? try evidence!.toolchainBefore!.digest() != evidence!.toolchainAfter!.digest() : nil
        let status: String
        let exit: CanonicalJSONValue
        if evidence == nil { status = "running"; exit = .null }
        else if let native, sessionExitCode(native) != 0 { status = "failed"; exit = .integer(Int64(sessionExitCode(native))) }
        else if isCancelled { status = "cancelled"; exit = .integer(130) }
        else if !failures.isEmpty || evidence?.resultPreparation != nil { status = "inconclusive"; exit = .integer(70) }
        else if !complete || !admitCaptures || !evidence!.capturedPhases.allSatisfy({ $0.rawCapture.captureComplete })
                    || sourceChanged == nil || toolchainChanged == nil || evidence?.compatibilityIdentity == nil
                    || (request.expectsResultBundle && (!admitCaptures || evidence?.resultSummary?.provesPassingRun != true))
                    || (sessionRequiresConsumer(request) && (!admitCaptures || evidence?.resultConsumer?.provesSuccessfulConsumption != true))
                    || (sessionRequiresPerformance(request) && (!admitCaptures || evidence?.performanceEvidence?.complete != true))
                    || (NotikaDevelopmentPreflight.requiresPreflight(for: request) && (!admitCaptures || evidence?.preflightEvidence?.succeeded != true))
                    || (request.platform == .iPadSimulator && (!admitCaptures || !sessionPreparationSucceeded(evidence?.simulatorPreparation)))
                    || (NotikaBuildCoordinator.requiresUIPreparation(for: request) && (!admitCaptures || !sessionPreparationSucceeded(evidence?.uiPreparation)))
                    || sourceChanged == true || toolchainChanged == true
                    || evidence!.sourceDriftObservedReverted || evidence!.toolchainDriftObservedReverted {
            status = "inconclusive"; exit = .integer(3)
        } else { status = "succeeded"; exit = .integer(0) }
        let compatibility: CanonicalJSONValue
        if let identity = evidence?.compatibilityIdentity {
            compatibility = .object(["keyMaterial": identity.keyMaterial,
                                     "executionSHA256": .string(try identity.executionDigest()),
                                     "cacheKey": .string(try identity.cacheKey())])
        } else { compatibility = .null }
        let physicalValue = CanonicalJSONValue.array(physical)
        let logValue = CanonicalJSONValue.array(logs)
        let value: CanonicalJSONValue = .object([
            "namespace": .string(namespace), "schemaVersion": .integer(1), "toolVersion": .string(AgentBuild.version),
            "runUUID": .string(runID), "sessionID": .string(runID), "repository": .string(repository),
            "destination": .string(destination), "outerLeaseEvidence": outerValue,
            "ownerUID": .unsignedInteger(UInt64(ownerUID)),
            "directoryIdentity": .object(["deviceID": .unsignedInteger(directoryDevice), "inode": .unsignedInteger(directoryInode)]),
            "writerResource": .string("notika:sessions:" + repository), "request": requestValue,
            "lifecycle": .string(evidence == nil ? "inProgress" : "terminal"), "status": .string(status),
            "startedAt": .string(try sessionTimestamp(startedAt)), "completedAt": try completedAt.map { .string(try sessionTimestamp($0)) } ?? .null,
            "expiresAt": try completedAt.map { .string(try sessionTimestamp(LocalCalendarRetention(evaluatedAt: $0, timeZone: timeZone).nextLocalMidnight)) } ?? .null,
            "localTimeZone": .string(timeZone.identifier), "sourceBefore": sourceBefore, "sourceAfter": sourceAfter,
            "toolchainBefore": toolchainBefore, "toolchainAfter": toolchainAfter, "compatibilityIdentity": compatibility,
            "physicalPlan": physicalValue, "phaseObservations": .array(observationValues), "rawLogReports": logValue,
            "resultEvidence": resultValue, "resultPreparation": resultPreparationValue,
            "resultConsumer": consumerValue, "performanceEvidence": performanceValue,
            "preflightEvidence": preflightValue, "simulatorPreparation": preparationValue, "uiPreparation": uiPreparationValue,
            "nativeTermination": try native.map(sessionEncoded) ?? .null, "orchestrationFailures": .array(failures.map(CanonicalJSONValue.string)),
            "cancelled": .bool(isCancelled),
            "sourceDrift": .object(["sourceChanged": sourceChanged.map(CanonicalJSONValue.bool) ?? .null,
                                    "toolchainChanged": toolchainChanged.map(CanonicalJSONValue.bool) ?? .null,
                                    "sourceObservedReverted": .bool(evidence?.sourceDriftObservedReverted ?? false),
                                    "toolchainObservedReverted": .bool(evidence?.toolchainDriftObservedReverted ?? false)]),
            "commitments": .object(["requestSHA256": .string(try CanonicalJSONDigest.sha256(requestValue)),
                                    "physicalPlanSHA256": .string(try CanonicalJSONDigest.sha256(physicalValue)),
                                    "rawLogReportsSHA256": .string(try CanonicalJSONDigest.sha256(logValue)),
                                    "resultEvidenceSHA256": .string(try CanonicalJSONDigest.sha256(resultValue)),
                                    "resultPreparationSHA256": .string(try CanonicalJSONDigest.sha256(resultPreparationValue)),
                                    "executionContextSHA256": .string(try CanonicalJSONDigest.sha256(context)),
                                    "resultConsumerSHA256": .string(try CanonicalJSONDigest.sha256(consumerValue)),
                                    "performanceEvidenceSHA256": .string(try CanonicalJSONDigest.sha256(performanceValue)),
                                    "preflightEvidenceSHA256": .string(try CanonicalJSONDigest.sha256(preflightValue)),
                                    "simulatorPreparationSHA256": .string(try CanonicalJSONDigest.sha256(preparationValue)),
                                    "uiPreparationSHA256": .string(try CanonicalJSONDigest.sha256(uiPreparationValue))]),
            "execution": .object(["complete": .bool(complete), "plannedPhaseCount": .integer(Int64(physical.count)),
                                   "completedPhaseCount": .integer(Int64(observations.count))]), "exitCode": exit,
        ])
        var bytes = try CanonicalJSONDigest.encode(value)
        bytes.append(10)
        return try Self(data: bytes, expectedRepository: repository, expectedSessionID: runID)
    }
}

private func sessionSchema(_ field: String) -> NotikaBuildSessionError { .invalidSchema(field) }
private func sessionString(_ object: StrictJSONObject, _ field: String) throws -> String {
    guard case .string(let value) = try object.requiredValue(forKey: field) else { throw sessionSchema(field) }
    return value
}
private func sessionRequireString(_ object: StrictJSONObject, _ field: String, _ expected: String) throws {
    guard try sessionString(object, field).utf8.elementsEqual(expected.utf8) else { throw sessionSchema(field) }
}
private func sessionInteger(_ object: StrictJSONObject, _ field: String) throws -> Int64 {
    guard case .number(let value) = try object.requiredValue(forKey: field) else { throw sessionSchema(field) }
    return try value.int64()
}
private func sessionUnsigned(_ object: StrictJSONObject, _ field: String) throws -> UInt64 {
    guard case .number(let value) = try object.requiredValue(forKey: field) else { throw sessionSchema(field) }
    return try value.uint64()
}
private func sessionBool(_ object: StrictJSONObject, _ field: String) throws -> Bool {
    guard case .bool(let value) = try object.requiredValue(forKey: field) else { throw sessionSchema(field) }
    return value
}
private func sessionOptionalBool(_ value: StrictJSONValue) throws -> Bool? {
    if value == .null { return nil }
    guard case .bool(let flag) = value else { throw sessionSchema("boolean") }
    return flag
}
private func sessionStringArray(_ object: StrictJSONObject, _ field: String) throws -> [String] {
    guard case .array(let values) = try object.requiredValue(forKey: field) else { throw sessionSchema(field) }
    return try values.map { guard case .string(let value) = $0 else { throw sessionSchema(field) }; return value }
}
private func sessionDate(_ object: StrictJSONObject, _ field: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let string = try sessionString(object, field)
    guard let date = formatter.date(from: string), try sessionTimestamp(date) == string else { throw sessionSchema(field) }
    return date
}
private func sessionTimestamp(_ date: Date) throws -> String {
    guard date.timeIntervalSinceReferenceDate.isFinite else { throw sessionSchema("timestamp") }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}
private func sessionCanonical(_ value: StrictJSONValue) throws -> CanonicalJSONValue {
    switch value {
    case .array(let values): .array(try values.map(sessionCanonical))
    case .bool(let value): .bool(value)
    case .null: .null
    case .number(let value):
        value.lexicalValue.hasPrefix("-") ? .integer(try value.int64()) : .unsignedInteger(try value.uint64())
    case .object(let object):
        .object(try object.members.map { CanonicalJSONMember(key: $0.key, value: try sessionCanonical($0.value)) })
    case .string(let value): .string(value)
    }
}
private func sessionEncoded(_ value: some Encodable) throws -> CanonicalJSONValue {
    try sessionCanonical(StrictJSONDocument(data: JSONEncoder().encode(value)).root)
}
private func sessionSnapshot(_ value: CanonicalJSONValue?) throws -> CanonicalJSONValue {
    guard let value else { return .null }
    return .object(["keyMaterial": value, "sha256": .string(try CanonicalJSONDigest.sha256(value))])
}
private func sessionValidateSnapshot(_ value: StrictJSONValue, repository: String, source: Bool, field: String) throws {
    if value == .null { return }
    let object = try value.requireObject().project(requiredKeys: ["keyMaterial", "sha256"])
    let material = try object.requiredValue(forKey: "keyMaterial").requireObject()
    if source { try sessionRequireString(material, "canonicalWorktree", repository) }
    try sessionRequireString(object, "sha256", CanonicalJSONDigest.sha256(sessionCanonical(.object(material))))
}
private func sessionSnapshotChange(_ root: StrictJSONObject, _ before: String, _ after: String) throws -> Bool? {
    let left = try root.requiredValue(forKey: before), right = try root.requiredValue(forKey: after)
    guard left != .null, right != .null else { return nil }
    return try sessionString(left.requireObject(), "sha256") != sessionString(right.requireObject(), "sha256")
}
private func sessionExitCode(_ termination: RunTermination) -> Int32 {
    termination.kind == .exit ? termination.value : 128 + termination.value
}
private func sessionTermination(_ value: StrictJSONValue) throws -> RunTermination? {
    if value == .null { return nil }
    let object = try value.requireObject().project(requiredKeys: ["kind", "value"])
    let number = try sessionInteger(object, "value")
    guard let kind = RunTermination.Kind(rawValue: try sessionString(object, "kind")),
          (kind == .exit ? (0...255) : (1...31)).contains(number), let exact = Int32(exactly: number) else {
        throw sessionSchema("termination")
    }
    return RunTermination(kind: kind, value: exact)
}
private func sessionPhaseValue(_ phase: NativeInvocationPhase) -> CanonicalJSONValue {
    .object(["ordinal": .integer(Int64(phase.ordinal)), "phaseOrdinal": .integer(Int64(phase.phaseOrdinal)),
             "physicalOrdinal": .integer(Int64(phase.physicalOrdinal)), "segment": .string(phase.segment),
             "arguments": .array(phase.arguments.map(CanonicalJSONValue.string)),
             "requiresCompilation": .bool(phase.requiresCompilation), "argumentCommitment": .string(phase.argumentCommitment)])
}
private func sessionObservationValue(_ value: NotikaNativeObservation) throws -> CanonicalJSONValue {
    .object(["processIdentifier": value.processIdentifier.map { .integer(Int64($0)) } ?? .null,
             "termination": try value.termination.map(sessionEncoded) ?? .null,
             "retirement": .string(value.retirement.rawValue), "cancelled": .bool(value.cancelled),
             "failures": try sessionEncoded(value.failures), "worker": try value.worker.map(sessionEncoded) ?? .null,
             "helperTermination": try value.helperTermination.map(sessionEncoded) ?? .null])
}
private func sessionValidatePhysicalPlan(_ value: StrictJSONValue) throws -> [StrictJSONObject] {
    guard case .array(let values) = value else { throw sessionSchema("physicalPlan") }
    return try values.enumerated().map { index, value in
        let phase = try value.requireObject().project(requiredKeys: [
            "ordinal", "phaseOrdinal", "physicalOrdinal", "segment", "arguments", "requiresCompilation", "argumentCommitment",
        ])
        guard try sessionInteger(phase, "ordinal") >= 0, try sessionInteger(phase, "phaseOrdinal") >= 0,
              try sessionInteger(phase, "physicalOrdinal") == Int64(index),
              !(try sessionString(phase, "segment")).isEmpty else { throw sessionSchema("physicalPlan") }
        let arguments = try sessionStringArray(phase, "arguments")
        _ = try sessionBool(phase, "requiresCompilation")
        try sessionRequireString(phase, "argumentCommitment", ArgumentCommitment.digest(arguments: arguments))
        return phase
    }
}
private struct SessionAdmittedObservation {
    let physicalOrdinal: Int
    let termination: RunTermination?
    let retirement: String
    let failures: [StrictJSONValue]
    let cancelled: Bool
    let nativeValue: StrictJSONValue
}
private func sessionValidateObservations(_ value: StrictJSONValue, phases: [StrictJSONObject]) throws -> [SessionAdmittedObservation] {
    guard case .array(let values) = value, values.count <= phases.count else { throw sessionSchema("phaseObservations") }
    return try values.enumerated().map { index, value in
        let object = try value.requireObject().project(requiredKeys: ["physicalOrdinal", "phase", "native"])
        guard try sessionInteger(object, "physicalOrdinal") == Int64(index),
              try object.requiredValue(forKey: "phase") == .object(phases[index]) else { throw sessionSchema("phaseObservation") }
        return try sessionValidateNativeObservation(object.requiredValue(forKey: "native"), physicalOrdinal: index)
    }
}
private func sessionValidateNativeObservation(_ value: StrictJSONValue, physicalOrdinal: Int = -1) throws -> SessionAdmittedObservation {
    let native = try value.requireObject().project(requiredKeys: [
        "processIdentifier", "termination", "retirement", "cancelled", "failures", "worker", "helperTermination",
    ])
    let retirement = try sessionString(native, "retirement")
    guard ["notStarted", "workerReaped", "groupQuiescentWithoutReceipt"].contains(retirement),
          case .array(let failures) = try native.requiredValue(forKey: "failures") else { throw sessionSchema("native") }
    for failure in failures { try sessionValidateFailure(failure) }
    let pid = try native.requiredValue(forKey: "processIdentifier")
    if pid != .null {
        guard case .number(let number) = pid, try number.int64() > 0,
              try number.int64() <= Int64(Int32.max) else { throw sessionSchema("processIdentifier") }
    }
    let cancelled = try sessionBool(native, "cancelled")
    _ = try sessionTermination(native.requiredValue(forKey: "helperTermination"))
    let termination = try sessionTermination(native.requiredValue(forKey: "termination"))
    let workerValue = try native.requiredValue(forKey: "worker")
    if workerValue != .null {
        let worker = try workerValue.requireObject().project(requiredKeys: ["retirement", "failures"],
            optionalKeys: ["processIdentifier", "termination", "stopReason"])
        guard try sessionString(worker, "retirement") == (retirement == "notStarted" ? "notStarted" : "reaped"),
              try sessionTermination(worker.value(forKey: "termination") ?? .null) == termination,
              (worker.value(forKey: "processIdentifier") ?? .null) == pid,
              case .array(let workerFailures) = try worker.requiredValue(forKey: "failures") else {
            throw sessionSchema("worker")
        }
        for failure in workerFailures { try sessionValidateFailure(failure) }
        if let stop = worker.value(forKey: "stopReason") {
            guard case .string(let reason) = stop,
                  DarwinWorkloadStopReason(rawValue: reason) != nil else { throw sessionSchema("stopReason") }
        }
    }
    if retirement == "groupQuiescentWithoutReceipt", termination != nil || workerValue != .null {
        throw sessionSchema("unobservedNative")
    }
    if retirement == "notStarted", termination != nil || pid != .null { throw sessionSchema("notStarted") }
    return SessionAdmittedObservation(physicalOrdinal: physicalOrdinal, termination: termination,
        retirement: retirement, failures: failures, cancelled: cancelled, nativeValue: value)
}

private func sessionValidateFailure(_ value: StrictJSONValue) throws {
    let object = try value.requireObject().project(requiredKeys: ["operation"], optionalKeys: ["code", "detail", "stream"])
    guard !(try sessionString(object, "operation")).isEmpty else { throw sessionSchema("failure") }
    if let code = object.value(forKey: "code") { guard case .number(let value) = code, Int32(exactly: try value.int64()) != nil else { throw sessionSchema("code") } }
    if let detail = object.value(forKey: "detail"), case .string = detail {} else if object.value(forKey: "detail") != nil { throw sessionSchema("detail") }
    if let stream = object.value(forKey: "stream") {
        guard case .string(let name) = stream, NativeLogStream(rawValue: name) != nil else { throw sessionSchema("stream") }
    }
}
private struct SessionAdmittedLog { let captureComplete: Bool; let publicationAdmitted: Bool }
private func sessionValidateRawLogs(
    _ value: StrictJSONValue, observations: [SessionAdmittedObservation], phases: [StrictJSONObject],
    repository: String, sessionPath: String, policy: NativeCaptureAdmissionPolicy
) throws -> [SessionAdmittedLog] {
    guard case .array(let values) = value, values.count == observations.count else { throw sessionSchema("rawLogReports") }
    return try values.enumerated().map { index, value in
        let report = try value.requireObject().project(requiredKeys: [
            "physicalOrdinal", "publicationAdmitted", "commandAdmission", "command", "capture",
        ])
        guard try sessionInteger(report, "physicalOrdinal") == Int64(index) else { throw sessionSchema("rawLogOrdinal") }
        let complete = try sessionValidateCapture(report.requiredValue(forKey: "capture"), sessionPath: sessionPath, policy: policy)
        let admitted = try sessionBool(report, "publicationAdmitted")
        guard !admitted || complete else { throw sessionSchema("publicationAdmitted") }
        let command = try sessionValidateCommand(report.requiredValue(forKey: "command"))
        let executable = try sessionString(command, "executable")
        let arguments = try sessionStringArray(command, "arguments")
        let workingDirectory = try sessionString(command, "workingDirectory")
        let admission = try sessionString(report, "commandAdmission")
        if admitted {
            guard ["production", "trustedPackageFixture"].contains(admission) else { throw sessionSchema("commandAdmission") }
            if admission == "production" {
                guard executable.utf8.elementsEqual("/usr/bin/xcodebuild".utf8),
                      workingDirectory.utf8.elementsEqual(repository.utf8),
                      arguments.map({ Data($0.utf8) }) == (try sessionStringArray(phases[index], "arguments")).map({ Data($0.utf8) }) else {
                    throw sessionSchema("commandAdmission")
                }
            }
        } else if admission != "diagnostic" { throw sessionSchema("commandAdmission") }
        return SessionAdmittedLog(captureComplete: complete, publicationAdmitted: admitted)
    }
}
private func sessionCommandValue(_ command: DarwinWorkloadCommand) throws -> CanonicalJSONValue {
    let environment = CanonicalJSONValue.object(command.environment.mapValues(CanonicalJSONValue.string))
    var material: [String: CanonicalJSONValue] = [
        "executable": .string(command.executable),
        "arguments": .array(command.arguments.map(CanonicalJSONValue.string)),
        "workingDirectory": .string(command.workingDirectory),
        "environmentSHA256": .string(try CanonicalJSONDigest.sha256(environment)),
    ]
    material["sha256"] = .string(try CanonicalJSONDigest.sha256(.object(material)))
    return .object(material)
}
private func sessionHex(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}

private func sessionValidateCommand(_ value: StrictJSONValue) throws -> StrictJSONObject {
    let command = try value.requireObject().project(requiredKeys: [
        "executable", "arguments", "workingDirectory", "environmentSHA256", "sha256",
    ])
    let executable = try sessionString(command, "executable")
    let arguments = try sessionStringArray(command, "arguments")
    let workingDirectory = try sessionString(command, "workingDirectory")
    let environmentDigest = try sessionString(command, "environmentSHA256")
    guard executable.hasPrefix("/"), workingDirectory.hasPrefix("/"),
          !executable.utf8.contains(0), !workingDirectory.utf8.contains(0),
          !arguments.contains(where: { $0.utf8.contains(0) }), sessionHex(environmentDigest) else {
        throw sessionSchema("command")
    }
    let material = CanonicalJSONValue.object([
        "executable": .string(executable), "arguments": .array(arguments.map(CanonicalJSONValue.string)),
        "workingDirectory": .string(workingDirectory), "environmentSHA256": .string(environmentDigest),
    ])
    try sessionRequireString(command, "sha256", CanonicalJSONDigest.sha256(material))
    return command
}

private func sessionValidateCapture(
    _ value: StrictJSONValue, sessionPath: String, policy: NativeCaptureAdmissionPolicy
) throws -> Bool {
    try admitNativeLogCaptureRecord(value, sessionPath: sessionPath, policy: policy).captureComplete
}

internal func sessionSupportsRequest(_ request: NotikaActionRequest) -> Bool {
    guard !request.isInteractive, !request.isDocumentation,
          let route = request.makeRoute?.canonicalRoute else { return false }
    return [.build, .buildRelease, .buildAndTest, .test, .testShowOnlyErrors,
            .testUI, .testUIFile, .testUIOnly, .testUIOnlyFile, .testUnit, .testUnitFile,
            .testUnitFocused, .testUnitCoverage, .testTextInputHeavyDependencyPerformance,
            .testCanvasFramePacingPerformance, .coverage, .coverageFile, .coverageFileUnit,
            .coverageHTML, .coverageJSON, .coverageQuiet, .testCoverage,
            .resultsBrief, .resultsBundle, .resultsFile, .resultsSummary].contains(route)
}

private func sessionRequiresExactlyOneUIResult(_ request: NotikaActionRequest) -> Bool {
    guard let route = request.canonicalMakeRoute else { return false }
    if route == .testCanvasFramePacingPerformance { return true }
    guard
          [.testUI, .testUIFile, .testUIOnly, .testUIOnlyFile].contains(route) else { return false }
    return !request.testMethod.isEmpty || request.makeRoute?.fixedTestMethod != nil
}

private func sessionRequiresConsumer(_ request: NotikaActionRequest) -> Bool {
    guard let route = request.canonicalMakeRoute else { return false }
    return [.coverage, .coverageFile, .coverageFileUnit, .coverageHTML, .coverageJSON, .coverageQuiet,
            .testUnitCoverage, .resultsBrief, .resultsBundle, .resultsFile, .resultsSummary].contains(route)
}

private func sessionRequiresPerformance(_ request: NotikaActionRequest) -> Bool {
    request.canonicalMakeRoute.map {
        [.testTextInputHeavyDependencyPerformance, .testCanvasFramePacingPerformance].contains($0)
    } == true
}

private func sessionAncillaryValue(
    _ value: CanonicalJSONValue?, admitted: Bool, allowFixtureCommands: Bool
) -> CanonicalJSONValue {
    guard let value else { return .null }
    return .object(["publicationAdmitted": .bool(admitted),
                    "fixturePublication": .bool(admitted && allowFixtureCommands), "evidence": value])
}

private func sessionAncillaryObject(_ value: StrictJSONValue) throws -> (StrictJSONObject, Bool, Bool) {
    let object = try value.requireObject().project(requiredKeys: ["publicationAdmitted", "fixturePublication", "evidence"])
    let admitted = try sessionBool(object, "publicationAdmitted"), fixture = try sessionBool(object, "fixturePublication")
    guard admitted || !fixture else { throw sessionSchema("fixturePublication") }
    return (object, admitted, fixture)
}

private func sessionValidateConsumers(
    _ value: StrictJSONValue, resultValue: StrictJSONValue, request: NotikaActionRequest, sessionPath: String,
    policy: NativeCaptureAdmissionPolicy
) throws -> Bool {
    guard value != .null else { return false }
    guard resultValue != .null else { throw sessionSchema("resultConsumer.resultEvidence") }
    let (object, admitted, fixture) = try sessionAncillaryObject(value)
    let receipt = try sessionString(resultValue.requireObject(), "receiptSHA256")
    let identity = try sessionResultProbeIdentity(resultValue)
    let passed = try NotikaResultConsumerEvidence.validateCanonicalValue(
        sessionCanonical(object.requiredValue(forKey: "evidence")), request: request,
        resultReceiptSHA256: receipt, sessionPath: sessionPath, expectedResultIdentity: identity,
        allowFixtureAdmission: fixture || !admitted, captureAdmissionPolicy: policy)
    return admitted && passed
}

/// This projection follows result admission above; it does not recreate disk
/// custody. Consumers must bind their recorded directory to the same probe.
private func sessionResultProbeIdentity(_ resultValue: StrictJSONValue) throws -> NativeWorkingDirectoryIdentity? {
    guard resultValue != .null else { return nil }
    let result = try resultValue.requireObject()
    guard try sessionBool(result, "publicationAdmitted"), let probeValue = result.value(forKey: "probe"), probeValue != .null else {
        return nil
    }
    let probe = try probeValue.requireObject()
    guard try sessionBool(probe, "publicationAdmitted") else { return nil }
    return try JSONDecoder().decode(NativeWorkingDirectoryIdentity.self,
        from: CanonicalJSONDigest.encode(sessionCanonical(probe.requiredValue(forKey: "directoryIdentity"))))
}

private func sessionValidatePerformance(
    _ value: StrictJSONValue, resultValue: StrictJSONValue, request: NotikaActionRequest,
    sourceHash: String?, toolchainHash: String?, sessionPath: String, sourceValue: StrictJSONValue, outerValue: StrictJSONValue,
    policy: NativeCaptureAdmissionPolicy
) throws -> Bool {
    guard value != .null else { return false }
    guard let sourceHash, let toolchainHash, resultValue != .null else { throw sessionSchema("performanceEvidence.inputs") }
    let (object, admitted, fixture) = try sessionAncillaryObject(value)
    let outer = outerValue == .null ? nil : try JSONDecoder().decode(NotikaOuterLeaseEvidence.self,
        from: CanonicalJSONDigest.encode(sessionCanonical(outerValue)))
    let sourceHead = try sessionString(sourceValue.requireObject().requiredValue(forKey: "keyMaterial").requireObject(), "head")
    let passed = try NotikaPerformanceEvidence.validateCanonicalValue(
        sessionCanonical(object.requiredValue(forKey: "evidence")), request: request,
        sourceBeforeSHA256: sourceHash, toolchainBeforeSHA256: toolchainHash, sessionPath: sessionPath,
        resultReceiptSHA256: sessionString(resultValue.requireObject(), "receiptSHA256"),
        outerLeaseEvidence: outer, sourceHead: sourceHead, expectedResultIdentity: sessionResultProbeIdentity(resultValue),
        allowFixtureAdmission: fixture || !admitted, captureAdmissionPolicy: policy)
    return admitted && passed
}

private func sessionValidatePreflight(
    _ value: StrictJSONValue, request: NotikaActionRequest, sourceHash: String?, sessionPath: String,
    policy: NativeCaptureAdmissionPolicy
) throws -> (succeeded: Bool, nativeFailure: RunTermination?, cancelled: Bool) {
    guard value != .null else { return (false, nil, false) }
    guard let sourceHash else { throw sessionSchema("preflightEvidence.sourceBefore") }
    let (object, admitted, fixture) = try sessionAncillaryObject(value)
    let observed = try NotikaDevelopmentPreflightEvidence.validateCanonicalValue(
        sessionCanonical(object.requiredValue(forKey: "evidence")), request: request,
        sourceBeforeSHA256: sourceHash, sessionPath: sessionPath, allowFixtureAdmission: fixture || !admitted, captureAdmissionPolicy: policy)
    return (admitted && observed.succeeded, observed.nativeFailure, observed.cancelled)
}

private func sessionPreparationSucceeded(_ preparation: CapturedNativePhase?) -> Bool {
    guard let preparation else { return false }
    let native = preparation.observation
    return native.termination == RunTermination(kind: .exit, value: 0) && native.retirement == .workerReaped
        && !native.cancelled && native.failures.isEmpty && preparation.rawCapture.captureComplete
}

private func sessionPreparationValue(
    _ preparation: CapturedNativePhase?, admitted: Bool, allowFixtureCommands: Bool
) throws -> CanonicalJSONValue {
    guard let preparation else { return .null }
    let complete = admitted && preparation.rawCapture.captureComplete
    return .object([
        "publicationAdmitted": .bool(complete),
        "commandAdmission": .string(complete ? (allowFixtureCommands ? "trustedPackageFixture" : "production") : "diagnostic"),
        "command": try sessionCommandValue(preparation.command), "native": try sessionObservationValue(preparation.observation),
        "capture": try sessionEncoded(preparation.rawCapture),
    ])
}

private func sessionResultPreparationValue(_ failure: NotikaResultPreparationFailure?) throws -> CanonicalJSONValue {
    guard let failure else { return .null }
    let probe = try failure.probe.map { captured -> CanonicalJSONValue in
        .object(["publicationAdmitted": .bool(false), "commandAdmission": .string("diagnostic"),
                 "command": try sessionCommandValue(captured.command),
                 "directoryIdentity": try captured.workingDirectoryIdentity.map(sessionEncoded) ?? .null,
                 "native": try sessionObservationValue(captured.observation), "capture": try sessionEncoded(captured.rawCapture)])
    } ?? .null
    return .object(["failure": try sessionEncoded(failure.failure), "probe": probe])
}

/// A refused initial result probe remains diagnostic. No receipt, bundle
/// admission or passing counts can be derived from these recorded paths.
private func sessionValidateResultPreparation(
    _ value: StrictJSONValue, resultValue: StrictJSONValue, request: NotikaActionRequest, sessionPath: String,
    policy: NativeCaptureAdmissionPolicy
) throws -> Bool {
    guard value != .null else { return false }
    guard request.expectsResultBundle, resultValue == .null else { throw sessionSchema("resultPreparation.resultEvidence") }
    let object = try value.requireObject().project(requiredKeys: ["failure", "probe"])
    let failure = try object.requiredValue(forKey: "failure").requireObject().project(requiredKeys: ["operation"], optionalKeys: ["code", "detail"])
    try sessionValidateFailure(.object(failure))
    let probeValue = try object.requiredValue(forKey: "probe")
    guard probeValue != .null else { return false }
    let probe = try probeValue.requireObject().project(requiredKeys: ["publicationAdmitted", "commandAdmission", "command",
                                                                   "directoryIdentity", "native", "capture"])
    guard try !sessionBool(probe, "publicationAdmitted") else { throw sessionSchema("resultPreparation.admission") }
    try sessionRequireString(probe, "commandAdmission", "diagnostic")
    _ = try sessionValidateCommand(probe.requiredValue(forKey: "command"))
    _ = try sessionValidateCapture(probe.requiredValue(forKey: "capture"), sessionPath: sessionPath, policy: policy)
    let directory = try probe.requiredValue(forKey: "directoryIdentity")
    if directory != .null {
        let identity = try directory.requireObject().project(requiredKeys: ["device", "inode", "owner", "mode"])
        _ = try sessionInteger(identity, "device")
        let inode = try sessionUnsigned(identity, "inode"), owner = try sessionUnsigned(identity, "owner"), mode = try sessionUnsigned(identity, "mode")
        guard inode > 0, owner <= UInt64(UInt32.max), mode <= UInt64(UInt16.max) else { throw sessionSchema("resultPreparation.directoryIdentity") }
    }
    return try sessionValidateNativeObservation(probe.requiredValue(forKey: "native")).cancelled
}

private func sessionValidatePreparation(
    _ value: StrictJSONValue, request: NotikaActionRequest, destination: String, repository: String, sessionPath: String,
    ui: Bool, policy: NativeCaptureAdmissionPolicy
) throws -> (succeeded: Bool, nativeFailure: RunTermination?, cancelled: Bool) {
    guard value != .null else { return (false, nil, false) }
    let field = ui ? "uiPreparation" : "simulatorPreparation"
    guard request.platform == (ui ? .macOS : .iPadSimulator),
          !ui || NotikaBuildCoordinator.requiresUIPreparation(for: request) else { throw sessionSchema(field + ".platform") }
    let object = try value.requireObject().project(requiredKeys: ["publicationAdmitted", "commandAdmission", "command", "native", "capture"])
    let admitted = try sessionBool(object, "publicationAdmitted")
    let complete = try sessionValidateCapture(object.requiredValue(forKey: "capture"), sessionPath: sessionPath, policy: policy)
    let command = try sessionValidateCommand(object.requiredValue(forKey: "command"))
    let native = try sessionValidateNativeObservation(object.requiredValue(forKey: "native"))
    let admission = try sessionString(object, "commandAdmission")
    guard !admitted || complete else { throw sessionSchema(field + ".capture") }
    if admitted {
        guard ["production", "trustedPackageFixture"].contains(admission) else { throw sessionSchema(field + ".admission") }
        if admission == "production" {
            if ui {
                let actual = try DarwinWorkloadCommand(executable: sessionString(command, "executable"),
                    arguments: sessionStringArray(command, "arguments"), workingDirectory: sessionString(command, "workingDirectory"),
                    environment: [:])
                guard try NotikaBuildCoordinator.validatesUIPreparation(command: actual, repository: repository) else {
                    throw sessionSchema(field + ".command")
                }
            } else {
                let simulatorID = String(destination.dropFirst("platform=iOS Simulator,id=".count))
                guard URL(fileURLWithPath: try sessionString(command, "executable")).lastPathComponent == "simslim",
                      try sessionStringArray(command, "arguments").map({ Data($0.utf8) }) == ["on", simulatorID].map({ Data($0.utf8) }),
                      try sessionString(command, "workingDirectory").utf8.elementsEqual(repository.utf8) else {
                    throw sessionSchema(field + ".command")
                }
            }
        }
    } else if admission != "diagnostic" { throw sessionSchema(field + ".admission") }
    let failed = native.termination.flatMap { sessionExitCode($0) == 0 ? nil : $0 }
    let succeeded = admitted && complete && native.termination == RunTermination(kind: .exit, value: 0)
        && native.retirement == "workerReaped" && !native.cancelled && native.failures.isEmpty
    return (succeeded, failed, native.cancelled)
}

internal func sessionAdmitExecutionContext(
    request: NotikaActionRequest, destination: String?, outerLeaseEvidence: NotikaOuterLeaseEvidence?
) throws -> String {
    guard let selected = destination ?? (request.platform == .macOS ? "platform=macOS,arch=arm64" : nil) else {
        throw sessionSchema("destination")
    }
    let outer = try outerLeaseEvidence.map(sessionEncoded) ?? .null
    try sessionValidateExecutionContext(request: request, destination: selected,
        outerValue: StrictJSONDocument(data: CanonicalJSONDigest.encode(outer)).root)
    return selected
}

/// SimLease exports observed inherited facts. These checks match the reference
/// environment contract; serialized facts do not prove a kernel lease.
private func sessionValidateExecutionContext(
    request: NotikaActionRequest, destination: String, outerValue: StrictJSONValue
) throws {
    _ = try NotikaXcodeInvocationPlan(request: request, destination: destination,
        cacheDirectory: "/execution-context/cache", resultBundle: "/execution-context/result.xcresult")
    guard outerValue != .null else {
        if NotikaLeaseBoundary.requiresOuterLease(for: request) { throw sessionSchema("outerLeaseEvidence") }
        return
    }
    let outer = try outerValue.requireObject().project(requiredKeys: ["platform", "sessionID", "simulatorID", "hostResource"])
    let admitted = try JSONDecoder().decode(NotikaOuterLeaseEvidence.self,
        from: CanonicalJSONDigest.encode(sessionCanonical(outerValue)))
    guard admitted.destination.utf8.elementsEqual(destination.utf8) else { throw sessionSchema("outerLeaseEvidence.destination") }
    try sessionRequireString(outer, "platform", request.platform.rawValue)
    guard !(try sessionString(outer, "sessionID")).isEmpty else { throw sessionSchema("outerLeaseEvidence.sessionID") }
    if request.platform == .macOS {
        guard outer.value(forKey: "simulatorID") == .null else { throw sessionSchema("outerLeaseEvidence.simulatorID") }
        try sessionRequireString(outer, "hostResource", "macos-ui")
    } else {
        guard outer.value(forKey: "hostResource") == .null else { throw sessionSchema("outerLeaseEvidence.hostResource") }
        let simulator = try sessionString(outer, "simulatorID")
        guard !simulator.isEmpty,
              destination.utf8.elementsEqual(("platform=iOS Simulator,id=" + simulator).utf8) else {
            throw sessionSchema("outerLeaseEvidence.destination")
        }
    }
}

private func sessionResultEvidenceValue(
    _ summary: NotikaResultSummaryEvidence?, admitCaptures: Bool, allowFixtureCommands: Bool
) throws -> CanonicalJSONValue {
    guard let summary else { return .null }
    let retained = summary.resultBundle
    let probe: CanonicalJSONValue
    if let captured = summary.probe {
        let admitted = admitCaptures && captured.rawCapture.captureComplete
        probe = .object([
            "publicationAdmitted": .bool(admitted),
            "commandAdmission": .string(admitted ? (allowFixtureCommands ? "trustedPackageFixture" : "production") : "diagnostic"),
            "command": try sessionCommandValue(captured.command),
            "directoryIdentity": try captured.workingDirectoryIdentity.map(sessionEncoded) ?? .null,
            "native": try sessionObservationValue(captured.observation),
            "capture": try sessionEncoded(captured.rawCapture),
        ])
    } else { probe = .null }
    return .object([
        "publicationAdmitted": .bool(admitCaptures),
        "custody": try sessionEncoded(retained.custody),
        "custodySHA256": .string(try CanonicalJSONDigest.sha256(sessionEncoded(retained.custody))),
        "receiptPath": .string(retained.receiptPath), "receiptSHA256": .string(retained.receiptSHA256),
        "native": try sessionObservationValue(summary.nativeObservation),
        "tests": try summary.tests.map(sessionEncoded) ?? .null,
        "failures": try sessionEncoded(summary.failures), "focusedMethod": .bool(summary.focusedMethod),
        "provesPassingRun": .bool(admitCaptures && summary.provesPassingRun), "probe": probe,
    ])
}

/// This validates serialized facts and their exact request/source/phase binding.
/// Only the live retained producer capabilities establish filesystem custody.
private func sessionValidateResultEvidence(
    _ value: StrictJSONValue, root: StrictJSONObject, request: NotikaActionRequest, destination: String,
    identity: CacheCompatibilityIdentity?, phases: [StrictJSONObject], observations: [SessionAdmittedObservation],
    sessionPath: String, policy: NativeCaptureAdmissionPolicy
) throws -> Bool {
    guard value != .null else { return false }
    guard request.expectsResultBundle, let identity else { throw sessionSchema("resultEvidence.request") }
    let result = try value.requireObject().project(requiredKeys: [
        "publicationAdmitted", "custody", "custodySHA256", "receiptPath", "receiptSHA256",
        "native", "tests", "failures", "focusedMethod", "provesPassingRun", "probe",
    ])
    let custodyValue = try result.requiredValue(forKey: "custody")
    let custody = try custodyValue.requireObject().project(requiredKeys: [
        "schemaVersion", "kind", "sessionID", "sourceBeforeHash", "actionRequest",
        "invocationOrdinal", "phaseOrdinal", "physicalOrdinal", "segment",
        "logicalArgumentsSHA256", "physicalArgumentsSHA256", "destination", "cacheDirectory",
        "resultPath", "resultDevice", "resultInode", "contentSHA256", "contentBytes", "nativeTermination",
    ])
    let typed = try JSONDecoder().decode(NotikaResultCustody.self, from: CanonicalJSONDigest.encode(sessionCanonical(custodyValue)))
    let source = try root.requiredValue(forKey: "sourceBefore").requireObject()
    let cacheDirectory = try sessionString(root, "repository") + "/DerivedData/AgentCaches/" + identity.cacheKey()
    let plan = try NotikaXcodeInvocationPlan(request: request, destination: destination,
        cacheDirectory: cacheDirectory, resultBundle: sessionPath + "/result.xcresult")
    guard typed.schemaVersion == 2, typed.kind == "notika.session-result-custody",
          typed.actionRequest == request,
          try custody.requiredValue(forKey: "actionRequest") == root.requiredValue(forKey: "request"),
          typed.sessionID.utf8.elementsEqual((try sessionString(root, "sessionID")).utf8),
          typed.sourceBeforeHash.utf8.elementsEqual((try sessionString(source, "sha256")).utf8),
          typed.physicalOrdinal >= 0, typed.physicalOrdinal < observations.count,
          typed.invocationOrdinal >= 0, typed.invocationOrdinal < plan.invocations.count,
          typed.resultPath.utf8.elementsEqual((sessionPath + "/result.xcresult").utf8),
          typed.cacheDirectory.utf8.elementsEqual(cacheDirectory.utf8),
          typed.destination.utf8.elementsEqual(destination.utf8), typed.resultInode > 0, typed.contentBytes >= 0,
          sessionHex(typed.contentSHA256) else { throw sessionSchema("resultEvidence.custody") }
    let phase = phases[typed.physicalOrdinal]
    let runtime = observations[typed.physicalOrdinal]
    guard !(try sessionBool(phase, "requiresCompilation")),
          typed.invocationOrdinal == (try sessionInteger(phase, "ordinal")),
          typed.phaseOrdinal == (try sessionInteger(phase, "phaseOrdinal")),
          typed.segment.utf8.elementsEqual((try sessionString(phase, "segment")).utf8),
          typed.logicalArgumentsSHA256 == ArgumentCommitment.digest(arguments: plan.invocations[typed.invocationOrdinal].arguments),
          typed.physicalArgumentsSHA256 == (try sessionString(phase, "argumentCommitment")),
          try sessionTermination(custody.requiredValue(forKey: "nativeTermination")) == runtime.termination,
          try result.requiredValue(forKey: "native") == runtime.nativeValue else {
        throw sessionSchema("resultEvidence.runtime")
    }
    try sessionRequireString(result, "custodySHA256", CanonicalJSONDigest.sha256(sessionCanonical(custodyValue)))
    try sessionRequireString(result, "receiptPath", sessionPath + "/result-custody.json")
    let requiresOneUIResult = sessionRequiresExactlyOneUIResult(request)
    guard sessionHex(try sessionString(result, "receiptSHA256")),
          try sessionBool(result, "focusedMethod") == requiresOneUIResult,
          case .array(let failures) = try result.requiredValue(forKey: "failures") else {
        throw sessionSchema("resultEvidence.summary")
    }
    for failure in failures { try sessionValidateFailure(failure) }
    let testsValue = try result.requiredValue(forKey: "tests")
    var testsPass = false
    if testsValue != .null {
        _ = try testsValue.requireObject().project(requiredKeys: ["result", "passed", "failed", "skipped", "total", "executed"])
        let tests = try JSONDecoder().decode(NotikaExecutedTests.self, from: CanonicalJSONDigest.encode(sessionCanonical(testsValue)))
        guard ["Passed", "Failed", "Skipped", "Unknown"].contains(tests.result),
              tests.passed >= 0, tests.failed >= 0, tests.skipped >= 0, tests.total >= 0, tests.executed >= 0 else {
            throw sessionSchema("resultEvidence.counts")
        }
        let executed = tests.passed.addingReportingOverflow(tests.failed)
        let total = executed.partialValue.addingReportingOverflow(tests.skipped)
        guard !executed.overflow, !total.overflow, tests.executed == executed.partialValue,
              tests.total == total.partialValue else { throw sessionSchema("resultEvidence.counts") }
        testsPass = tests.satisfiesExpectedRun(focusedMethod: requiresOneUIResult)
    }
    let admitted = try sessionBool(result, "publicationAdmitted")
    let probeValue = try result.requiredValue(forKey: "probe")
    var probePass = false
    if probeValue != .null {
        let probe = try probeValue.requireObject().project(requiredKeys: [
            "publicationAdmitted", "commandAdmission", "command", "directoryIdentity", "native", "capture",
        ])
        let complete = try sessionValidateCapture(probe.requiredValue(forKey: "capture"), sessionPath: sessionPath, policy: policy)
        let probeAdmitted = try sessionBool(probe, "publicationAdmitted")
        let admission = try sessionString(probe, "commandAdmission")
        let command = try sessionValidateCommand(probe.requiredValue(forKey: "command"))
        let native = try sessionValidateNativeObservation(probe.requiredValue(forKey: "native"))
        guard !probeAdmitted || (admitted && complete) else { throw sessionSchema("resultEvidence.probeAdmission") }
        if probeAdmitted {
            guard ["production", "trustedPackageFixture"].contains(admission),
                  try sessionString(command, "workingDirectory").utf8.elementsEqual(typed.resultPath.utf8) else {
                throw sessionSchema("resultEvidence.probeCommand")
            }
            if admission == "production" {
                let arguments = ["xcresulttool", "get", "test-results", "summary", "--path", ".", "--compact"]
                guard try sessionString(command, "executable") == "/usr/bin/xcrun",
                      try sessionStringArray(command, "arguments").map({ Data($0.utf8) }) == arguments.map({ Data($0.utf8) }) else {
                    throw sessionSchema("resultEvidence.probeCommand")
                }
            }
            let directory = try probe.requiredValue(forKey: "directoryIdentity").requireObject()
                .project(requiredKeys: ["device", "inode", "owner", "mode"])
            let mode = try sessionUnsigned(directory, "mode")
            guard try sessionInteger(directory, "device") == typed.resultDevice,
                  try sessionUnsigned(directory, "inode") == typed.resultInode,
                  try sessionUnsigned(directory, "owner") == sessionUnsigned(root, "ownerUID"),
                  mode <= UInt64(UInt16.max), mode & 0o170000 == 0o040000, mode & 0o7022 == 0 else {
                throw sessionSchema("resultEvidence.probeDirectory")
            }
        } else if admission != "diagnostic" { throw sessionSchema("resultEvidence.probeAdmission") }
        probePass = probeAdmitted && complete && native.termination == RunTermination(kind: .exit, value: 0)
            && native.retirement == "workerReaped" && !native.cancelled && native.failures.isEmpty
    }
    let passes = admitted && runtime.termination == RunTermination(kind: .exit, value: 0)
        && runtime.retirement == "workerReaped" && !runtime.cancelled && runtime.failures.isEmpty
        && failures.isEmpty && testsPass && probePass
    guard try sessionBool(result, "provesPassingRun") == passes else { throw sessionSchema("resultEvidence.provesPassingRun") }
    return passes
}
