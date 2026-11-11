import AgentBuildCore
import AgentLeaseCore
import Darwin
import Foundation
import Synchronization

public enum NotikaBuildCoordinatorError: Error, Equatable, Sendable {
    case unsupportedRequest
    case invalidHelperExecutable
    case invalidRegistryRoot
    case invalidWaitSeconds
    case repositoryIsNotWorktreeRoot
    case compatibilityChangedBeforeExecution
    case continuationRequiresSuccessfulBuild
    case continuationSourceChanged
    case toolUnavailable(String)
    case accountHomeUnavailable
}

/// A diagnostic return value. A native observation remains authoritative even
/// when terminal publication fails; copied paths grant no artifact authority.
public struct NotikaBuildCoordinatorResult: Sendable {
    public let runID: String
    public let sessionPath: String?
    public let report: NotikaBuildSessionReport?
    public let outcome: NotikaOwnedExecutionOutcome?
    public let rawCaptures: [NativeLogCaptureResult]
    public let resultSummary: NotikaResultSummaryEvidence?
    public let resultPreparation: NotikaResultPreparationFailure?
    public let resultConsumer: NotikaResultConsumerEvidence?
    public let performanceEvidence: NotikaPerformanceEvidence?
    public let preflightEvidence: NotikaDevelopmentPreflightEvidence?
    public let simulatorPreparation: CapturedNativePhase?
    public let uiPreparation: CapturedNativePhase?
    public let maintenanceReport: NotikaArtifactMaintenanceReport?
    public let maintenanceDiagnostics: [String]
    public let orchestrationFailures: [String]
    public let publicationFailures: [String]
    public let cancelled: Bool

    public var nativeTermination: RunTermination? {
        if let preparation = uiPreparation?.observation.termination,
           notikaBuildNativeFailureCode(preparation) != nil { return preparation }
        if let preparation = simulatorPreparation?.observation.termination,
           notikaBuildNativeFailureCode(preparation) != nil { return preparation }
        return preflightEvidence?.nativeFailure ?? outcome?.nativeFailure ?? outcome?.observations.compactMap(\.workload.termination).last
            ?? report?.nativeTermination
    }

    public var exitCode: Int32 {
        if let nativeTermination, let failure = notikaBuildNativeFailureCode(nativeTermination) { return failure }
        if cancelled { return 130 }
        if !publicationFailures.isEmpty { return 70 }
        return report?.exitCode ?? 70
    }

    public var status: String {
        if let nativeTermination, notikaBuildNativeFailureCode(nativeTermination) != nil { return "failed" }
        if cancelled { return "cancelled" }
        if !publicationFailures.isEmpty { return "inconclusive" }
        return report?.status ?? "inconclusive"
    }

    /// Closed CLI envelope keeps its process status distinct from a terminal
    /// report whose final custody check may subsequently have failed.
    public func jsonData() throws -> Data {
        let native: CanonicalJSONValue = nativeTermination.map {
            .object(["kind": .string($0.kind.rawValue), "value": .integer(Int64($0.value))])
        } ?? .null
        let maintenance: CanonicalJSONValue
        if let maintenanceReport {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            maintenance = try notikaBuildCanonical(StrictJSONDocument(data: encoder.encode(maintenanceReport)).root)
        } else { maintenance = .null }
        return try CanonicalJSONDigest.encode(.object([
            "namespace": .string("agentbuild.notika-build"), "schemaVersion": .integer(1),
            "toolVersion": .string(AgentBuild.version), "runID": .string(runID),
            "sessionPath": sessionPath.map(CanonicalJSONValue.string) ?? .null,
            "status": .string(status), "exitCode": .integer(Int64(exitCode)),
            "nativeTermination": native, "cancelled": .bool(cancelled),
            "orchestrationFailures": .array(orchestrationFailures.map(CanonicalJSONValue.string)),
            "publicationFailures": .array(publicationFailures.map(CanonicalJSONValue.string)),
            "maintenanceReport": maintenance,
            "maintenanceDiagnostics": .array(maintenanceDiagnostics.map(CanonicalJSONValue.string)),
            "sessionReport": report?.canonicalValue ?? .null,
        ]))
    }
}

/// Closed Notika native builds and tests beneath an inherited device/UI lease,
/// when required, and an outer shared
/// session writer, shared graph/policy, exclusive compatible cache and finally
/// account compilation admission. It never dispatches back to Python or Make.
public struct NotikaBuildCoordinator: Sendable {
    internal typealias NativeOperation = @Sendable (
        String, DarwinWorkloadCommand, NativeInvocationClaim, [Int32], String, Int32
    ) async throws -> CapturedNativePhase
    internal typealias SummaryOperation = @Sendable (
        String, DarwinWorkloadCommand, [Int32], String, Int32
    ) async throws -> CapturedNativePhase
    internal typealias PreflightOperation = @Sendable (
        String, NotikaBuildSession, ProjectOwnership, NotikaCacheCustody, String, [String: String], [Int32], Double?
    ) async -> NotikaDevelopmentPreflightEvidence
    internal typealias MaintenanceOperation = @Sendable (
        String, String, Date, TimeZone
    ) async throws -> NotikaArtifactMaintenanceReport

    private let identityCapture: (any RepositoryCommandCapturing)?
    private let nativeOperation: NativeOperation
    private let summaryOperation: SummaryOperation
    private let preparationOperation: SummaryOperation
    private let preflightOperation: PreflightOperation
    private let maintenanceOperation: MaintenanceOperation
    private let allowsTrustedFixturePublication: Bool
    private let prepareFixtureResultIndexes: Bool

    public init() {
        identityCapture = nil
        allowsTrustedFixturePublication = false
        prepareFixtureResultIndexes = false
        nativeOperation = { helper, command, _, descriptors, root, workingDirectory in
            try await CapturedNativePhaseRunner().run(
                helperExecutable: helper, command: command,
                retainedLockDescriptors: descriptors, nativeWorkingDirectoryDescriptor: workingDirectory,
                artifactRoot: root
            )
        }
        summaryOperation = Self.captureSummary
        preparationOperation = Self.captureSummary
        preflightOperation = Self.capturePreflight
        maintenanceOperation = Self.performMaintenance
    }

    /// Only trusted package fixtures can substitute execution. They still
    /// receive the exact admitted command and claim, never a caller-made plan.
    internal init(identityCapture: any RepositoryCommandCapturing,
                  nativeOperation: @escaping NativeOperation,
                  summaryOperation: SummaryOperation? = nil,
                  preparationOperation: SummaryOperation? = nil,
                  preflightOperation: PreflightOperation? = nil,
                  maintenanceOperation: MaintenanceOperation? = nil,
                  prepareFixtureResultIndexes: Bool = false) {
        self.identityCapture = identityCapture
        self.nativeOperation = nativeOperation
        self.summaryOperation = summaryOperation ?? Self.captureSummary
        self.preparationOperation = preparationOperation ?? Self.captureSummary
        self.preflightOperation = preflightOperation ?? Self.capturePreflight
        self.maintenanceOperation = maintenanceOperation ?? Self.performMaintenance
        self.prepareFixtureResultIndexes = prepareFixtureResultIndexes
        allowsTrustedFixturePublication = true
    }

    private static let captureSummary: SummaryOperation = { helper, command, descriptors, root, workingDirectory in
        try await CapturedNativePhaseRunner().run(
            helperExecutable: helper, command: command,
            retainedLockDescriptors: descriptors, nativeWorkingDirectoryDescriptor: workingDirectory,
            artifactRoot: root
        )
    }

    private static let capturePreflight: PreflightOperation = { helper, session, ownership, custody, sourceDigest, environment, descriptors, wait in
        await NotikaDevelopmentPreflight().runCaptured(
            helperExecutable: helper, session: session, ownership: ownership, custody: custody,
            admittedSourceDigest: sourceDigest, environment: environment,
            additionalRetainedDescriptors: descriptors, waitSeconds: wait
        )
    }

    private static let performMaintenance: MaintenanceOperation = { repository, registry, date, zone in
        try await NotikaArtifactMaintenance(canonicalRepository: repository, registryRoot: registry,
            evaluatedAt: date, timeZone: zone).run(execute: true)
    }

    public static let supportedCanonicalRoutes: Set<NotikaMakeRoute> = [
        .build, .buildRelease, .buildAndTest, .test, .testShowOnlyErrors,
        .testUI, .testUIFile, .testUIOnly, .testUIOnlyFile, .testUnit, .testUnitFile, .testUnitFocused,
        .testUnitCoverage, .testTextInputHeavyDependencyPerformance, .testCanvasFramePacingPerformance,
        .coverage, .coverageFile, .coverageFileUnit, .coverageHTML, .coverageJSON, .coverageQuiet,
        .testCoverage, .resultsBrief, .resultsBundle, .resultsFile, .resultsSummary,
    ]

    public static func requiresUIPreparation(for request: NotikaActionRequest) -> Bool {
        request.platform == .macOS && request.canonicalMakeRoute.map {
            [.test, .testShowOnlyErrors, .buildAndTest, .testUI, .testUIFile, .testUIOnly, .testUIOnlyFile].contains($0)
        } == true
    }

    public static let uiPreparationScript = """
    set -eu
    for bundle in dev.jano.Notika.ui-tests.xctrunner com.apple.XCTRunner; do
        target="$2/Library/Application Scripts/$bundle"
        /bin/mkdir -p "$target"
        for source in "$1"/UITests/Resources/AppleScripts/*.applescript; do
            [ -f "$source" ] || continue
            /bin/cp "$source" "$target/"
        done
        /usr/bin/install -m 755 "$1/UITests/Resources/AppleScripts/NotikaCtlTestRunner.sh" "$target/"
    done
    """

    /// Exact fixed script invocation; paths remain literal positional arguments.
    public static func uiPreparationArguments(repository: String, home: String) -> [String] {
        ["-c", uiPreparationScript, "prepare-ui-applescripts", repository, home]
    }

    public static func effectiveUIPreparationHome() throws -> String {
        try notikaBuildAccountHome()
    }

    /// This pure command check grants no filesystem or process authority.
    public static func validatesUIPreparation(command: DarwinWorkloadCommand, repository: String) throws -> Bool {
        let home = try effectiveUIPreparationHome()
        return command.executable.utf8.elementsEqual("/bin/sh".utf8)
            && command.workingDirectory.utf8.elementsEqual(repository.utf8)
            && command.arguments.map { Data($0.utf8) } == uiPreparationArguments(
                repository: repository, home: home
            ).map { Data($0.utf8) }
    }

    public func run(
        repository: String,
        request: NotikaActionRequest,
        helperExecutable: String,
        registryRoot: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        waitSeconds: Double? = nil,
        runID: String = UUID().uuidString,
        startedAt: Date = Date(),
        timeZone: TimeZone = .current
    ) async throws -> NotikaBuildCoordinatorResult {
        try await execute(repository: repository, request: request, helperExecutable: helperExecutable,
            registryRoot: registryRoot, environment: environment, waitSeconds: waitSeconds,
            runID: runID, startedAt: startedAt, timeZone: timeZone, continuation: nil)
    }

    internal func runWithContinuation(
        repository: String, request: NotikaActionRequest, helperExecutable: String,
        registryRoot: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment,
        waitSeconds: Double? = nil, runID: String = UUID().uuidString, startedAt: Date = Date(),
        timeZone: TimeZone = .current,
        continuation: @escaping @Sendable (NotikaBuildContinuationContext) async throws -> Void
    ) async throws -> NotikaBuildCoordinatorResult {
        guard let route = request.canonicalMakeRoute, [.build, .buildRelease].contains(route) else {
            throw NotikaBuildCoordinatorError.unsupportedRequest
        }
        return try await execute(repository: repository, request: request, helperExecutable: helperExecutable,
            registryRoot: registryRoot, environment: environment, waitSeconds: waitSeconds,
            runID: runID, startedAt: startedAt, timeZone: timeZone, continuation: continuation)
    }

    private func execute(
        repository: String, request: NotikaActionRequest, helperExecutable: String,
        registryRoot: String?, environment: [String: String], waitSeconds: Double?,
        runID: String, startedAt: Date, timeZone: TimeZone,
        continuation: (@Sendable (NotikaBuildContinuationContext) async throws -> Void)?
    ) async throws -> NotikaBuildCoordinatorResult {
        guard let route = request.canonicalMakeRoute, Self.supportedCanonicalRoutes.contains(route),
              !request.isInteractive, !request.isDocumentation else {
            throw NotikaBuildCoordinatorError.unsupportedRequest
        }
        let outer = try NotikaLeaseBoundary.admit(request: request, environment: environment)
        let destination = outer?.destination ?? "platform=macOS,arch=arm64"
        let outerHostLease = outer?.platform == .macOS
            ? try NotikaInteractiveHostLease.admit(environment: environment) : nil
        let outerDescriptors = outerHostLease.map { [$0.descriptor] } ?? []
        guard helperExecutable.hasPrefix("/"), !helperExecutable.utf8.contains(0) else {
            throw NotikaBuildCoordinatorError.invalidHelperExecutable
        }
        if let waitSeconds, !waitSeconds.isFinite || waitSeconds < 0 {
            throw NotikaBuildCoordinatorError.invalidWaitSeconds
        }
        let capture = try identityCapture ?? RepositoryCommandCapture()
        let observer = try NotikaRepositoryIdentity(repository: repository, capture: capture, environment: environment)
        let selectedRegistry = registryRoot ?? environment["AGENTLEASE_HOME"] ?? observer.repository + "/.agentlease"
        guard selectedRegistry.hasPrefix("/"), !selectedRegistry.utf8.contains(0) else {
            throw NotikaBuildCoordinatorError.invalidRegistryRoot
        }
        let state = NotikaBuildObservationState(runID: runID)
        do { state.observeMaintenance(try await maintenanceOperation(observer.repository, selectedRegistry, startedAt, timeZone)) }
        catch { state.failMaintenance(error) }
        do {
            return try await NotikaBuildSession.withSession(
                canonicalRepository: observer.repository, registryRoot: selectedRegistry,
                request: request, destination: destination, outerLeaseEvidence: outer,
                runID: runID, startedAt: startedAt,
                timeZone: timeZone, waitSeconds: waitSeconds
            ) { session in
                state.started(session.path)
                do {
                    let source = try await observer.sourceIdentity()
                    state.observeSource(source, initial: true)
                    guard source.canonicalWorktree.utf8.elementsEqual(observer.repository.utf8) else {
                        throw NotikaBuildCoordinatorError.repositoryIsNotWorktreeRoot
                    }
                    let toolchain = try await observer.toolchainIdentity()
                    state.observeToolchain(toolchain, initial: true)
                    let profile = NotikaCacheProfile(request: request)
                    let identity = try profile.identity(source: source, toolchain: toolchain)
                    state.admit(identity: identity)
                    let ownershipPlan = try NotikaProjectOwnershipPlan(identity: identity)
                    return try await NotikaProjectAdmission().withOwnership(
                        ownershipPlan, registryRoot: selectedRegistry,
                        label: "Notika \(route.rawValue)", runID: runID, waitSeconds: waitSeconds
                    ) { ownership in
                        do {
                            let ownedSource = try await observer.sourceIdentity()
                            state.observeSource(ownedSource)
                            let ownedToolchain = try await observer.toolchainIdentity()
                            state.observeToolchain(ownedToolchain)
                            let current = try profile.identity(source: ownedSource, toolchain: ownedToolchain)
                            guard try current.executionDigest() == identity.executionDigest() else {
                                throw NotikaBuildCoordinatorError.compatibilityChangedBeforeExecution
                            }
                            _ = try NotikaGeneratedWorkspace.validate(repository: observer.repository)
                            let custody = try NotikaCacheCustody(identity: identity, ownership: ownership)
                            _ = try await NotikaGeneratedWorkspace.hideLocalBuildProducts(
                                repository: observer.repository, capture: capture, environment: environment
                            )
                            try custody.revalidateBeforeOperation()
                            _ = try custody.publishUsage(sessionID: runID)
                            if Self.requiresUIPreparation(for: request) {
                                try outerHostLease?.revalidate()
                                guard let directory = try custody.inheritedDirectoryDescriptors().dropLast(3).last else {
                                    throw NotikaCacheCustodyError.ownershipMismatch
                                }
                                let child = try NotikaChildEnvironmentPolicy.nativeEnvironment(
                                    from: environment, bindings: NotikaNativeEnvironmentBindings(
                                        repository: observer.repository, toolSearchPath: environment["PATH"] ?? "/usr/bin:/bin",
                                        derivedData: custody.cacheDirectory
                                    )
                                )
                                let command = try DarwinWorkloadCommand(executable: "/bin/sh",
                                    arguments: Self.uiPreparationArguments(repository: observer.repository, home: Self.effectiveUIPreparationHome()),
                                    workingDirectory: observer.repository, environment: child)
                                let preparation = try await preparationOperation(
                                    helperExecutable, command, try session.inheritedDescriptors() + ownership.inheritedDescriptors()
                                        + outerDescriptors, session.path, directory
                                )
                                state.retainUIPreparation(preparation)
                                guard notikaBuildPreparationSucceeded(preparation) else {
                                    return await finalize(state, observer: observer, session: session)
                                }
                                try preparation.revalidateForPublication()
                            }
                            if request.platform == .iPadSimulator {
                                guard let simulator = outer?.simulatorID,
                                      let directory = try custody.inheritedDirectoryDescriptors().dropLast(3).last else {
                                    throw NotikaLeaseBoundaryError.missingLease
                                }
                                let child = try NotikaChildEnvironmentPolicy.nativeEnvironment(
                                    from: environment, bindings: NotikaNativeEnvironmentBindings(
                                        repository: observer.repository, toolSearchPath: environment["PATH"] ?? "/usr/bin:/bin",
                                        derivedData: custody.cacheDirectory
                                    )
                                )
                                let command = try DarwinWorkloadCommand(
                                    executable: notikaBuildExecutable("simslim", environment: child),
                                    arguments: ["on", simulator], workingDirectory: observer.repository, environment: child
                                )
                                let preparation = try await preparationOperation(
                                    helperExecutable, command, try session.inheritedDescriptors() + ownership.inheritedDescriptors()
                                        + outerDescriptors, session.path, directory
                                )
                                state.retainPreparation(preparation)
                                guard notikaBuildPreparationSucceeded(preparation) else {
                                    return await finalize(state, observer: observer, session: session)
                                }
                                try preparation.revalidateForPublication()
                            }
                            if NotikaDevelopmentPreflight.requiresPreflight(for: request) {
                                try outerHostLease?.revalidate()
                                let evidence = try await preflightOperation(
                                    helperExecutable, session, ownership, custody, source.digest(), environment, outerDescriptors, waitSeconds
                                )
                                state.retain(evidence)
                                guard evidence.succeeded else {
                                    return await finalize(state, observer: observer, session: session)
                                }
                                try evidence.revalidateForPublication()
                            }
                            let plan = try NotikaXcodeInvocationPlan(
                                request: request, destination: destination,
                                cacheDirectory: custody.cacheDirectory,
                                resultBundle: session.path + (request.expectsResultBundle ? "/result.xcresult" : "/unused.xcresult")
                            )
                            state.admit(plan: plan)
                            let reservation: NotikaResultBundle?
                            if request.expectsResultBundle {
                                let phases = try NativeInvocationLedger(plan: plan).phases
                                guard let invocation = plan.invocations.last, let runtime = phases.last,
                                      invocation.action == .test, !runtime.requiresCompilation else {
                                    throw NotikaBuildCoordinatorError.unsupportedRequest
                                }
                                reservation = try NotikaResultBundle(
                                    sessionDirectory: session.path, runID: runID, sourceBeforeHash: source.digest(),
                                    request: request, invocation: invocation, phase: runtime
                                )
                            } else { reservation = nil }
                            let performance: NotikaPerformanceReservation?
                            if [.testTextInputHeavyDependencyPerformance, .testCanvasFramePacingPerformance].contains(route) {
                                guard let lease = outer, lease.platform == .macOS else {
                                    throw NotikaLeaseBoundaryError.missingLease
                                }
                                performance = try NotikaPerformanceReservation(
                                    sessionDirectory: session.path, runID: runID, request: request,
                                    sourceBeforeHash: source.digest(), sourceHead: source.head,
                                    toolchainBeforeHash: toolchain.digest(), leaseSessionID: lease.sessionID
                                )
                            } else { performance = nil }
                            let metalToolchain = try await observer.metalToolchainPath()
                            let outcome = try await NotikaOwnedNativeExecutor().run(
                                plan, identity: identity, ownership: ownership,
                                environment: environment, metalToolchain: metalToolchain,
                                compilationWaitSeconds: waitSeconds
                            ) { command, claim, descriptors in
                                try outerHostLease?.revalidate()
                                try custody.revalidateBeforeOperation()
                                // The final three pins are DerivedData, its
                                // AgentCaches namespace, and this cache leaf.
                                guard let directory = try custody.inheritedDirectoryDescriptors().dropLast(3).last else {
                                    throw NotikaCacheCustodyError.ownershipMismatch
                                }
                                let admittedCommand: DarwinWorkloadCommand
                                if let performance {
                                    let environment = command.environment.merging(performance.childEnvironment) { _, admitted in admitted }
                                    admittedCommand = try DarwinWorkloadCommand(
                                        executable: command.executable, arguments: command.arguments,
                                        workingDirectory: command.workingDirectory, environment: environment
                                    )
                                } else { admittedCommand = command }
                                let capsule = try await nativeOperation(
                                    helperExecutable, admittedCommand, claim,
                                    try session.inheritedDescriptors() + descriptors + outerDescriptors, session.path, directory
                                )
                                state.retain(capsule)
                                return capsule.observation
                            }
                            state.observe(outcome)
                            if let reservation, let runtime = state.runtimeCapture(), !Task.isCancelled {
                                do {
                                    let probeEnvironment = try NotikaChildEnvironmentPolicy.nativeEnvironment(
                                        from: environment, bindings: NotikaNativeEnvironmentBindings(
                                            repository: observer.repository,
                                            toolSearchPath: environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
                                            derivedData: custody.cacheDirectory
                                        )
                                    )
                                    let descriptors = try session.inheritedDescriptors() + ownership.inheritedDescriptors() + outerDescriptors
                                    let operation: @Sendable (DarwinWorkloadCommand, Int32) async throws -> CapturedNativePhase = { command, directory in
                                        try custody.revalidateBeforeOperation()
                                        try outerHostLease?.revalidate()
                                        return try await summaryOperation(
                                            helperExecutable, command, descriptors, session.path, directory
                                        )
                                    }
                                    let retained: NotikaRetainedResultBundle
                                    if allowsTrustedFixturePublication {
                                        if prepareFixtureResultIndexes {
                                            retained = try await reservation.admitAfterRetirementForTrustedFixture(
                                                runtime, environment: probeEnvironment, operation: operation
                                            )
                                        } else { retained = try reservation.admitAfterRetirementForTrustedFixture(runtime) }
                                    } else {
                                        retained = try await reservation.admitAfterRetirement(
                                            runtime, environment: probeEnvironment, operation: operation
                                        )
                                    }
                                    let summary: NotikaResultSummaryEvidence
                                    if allowsTrustedFixturePublication {
                                        summary = await retained.observeSummaryForTrustedFixture(environment: probeEnvironment, operation: operation)
                                    } else {
                                        summary = await retained.observeSummary(environment: probeEnvironment, operation: operation)
                                    }
                                    state.retain(summary)
                                    if let performance {
                                        let evidence: NotikaPerformanceEvidence
                                        if allowsTrustedFixturePublication {
                                            evidence = await performance.consumeForTrustedFixture(
                                                summary: summary, environment: probeEnvironment, operation: operation
                                            )
                                        } else {
                                            evidence = await performance.consume(
                                                summary: summary, environment: probeEnvironment, operation: operation
                                            )
                                        }
                                        state.retain(evidence)
                                    } else {
                                        let genhtml = route == .coverageHTML
                                            ? try notikaBuildExecutable("genhtml", environment: probeEnvironment) : nil
                                        let consumers = NotikaResultConsumers(summary: summary)
                                        let evidence: NotikaResultConsumerEvidence
                                        if allowsTrustedFixturePublication {
                                            evidence = await consumers.runForTrustedFixture(
                                                environment: probeEnvironment, genhtmlExecutable: genhtml, operation: operation
                                            )
                                        } else {
                                            evidence = await consumers.run(
                                                environment: probeEnvironment, genhtmlExecutable: genhtml, operation: operation
                                            )
                                        }
                                        state.retain(evidence)
                                    }
                                } catch let failure as NotikaResultPreparationFailure {
                                    state.retain(failure)
                                    state.fail(failure.failure, cancelled: failure.probe?.observation.cancelled == true || Task.isCancelled)
                                } catch {
                                    state.fail(error, cancelled: error is CancellationError || Task.isCancelled)
                                }
                            }
                            try custody.revalidateBeforeOperation()
                            _ = try custody.publishUsage(sessionID: runID)
                            if let continuation {
                                guard outcome.complete, !Task.isCancelled else {
                                    throw NotikaBuildCoordinatorError.continuationRequiresSuccessfulBuild
                                }
                                let capsules = state.nativeCaptures()
                                try validateContinuationCaptures(capsules, outcome: outcome, repository: observer.repository)
                                let context = NotikaBuildContinuationContext(
                                    session: session, observer: observer, cacheCustody: custody, ownership: ownership,
                                    compatibilityIdentity: identity, sourceBefore: source, toolchainBefore: toolchain,
                                    helperExecutable: helperExecutable, environment: environment, capsules: capsules,
                                    outerHostLease: outerHostLease
                                )
                                try await context.revalidateBeforeOperation()
                                try await continuation(context)
                            }
                        } catch {
                            state.fail(error, cancelled: error is CancellationError || Task.isCancelled)
                        }
                        do { try outerHostLease?.revalidate() }
                        catch { state.fail(error, cancelled: Task.isCancelled) }
                        return await finalize(state, observer: observer, session: session)
                    }
                } catch {
                    state.fail(error, cancelled: error is CancellationError || Task.isCancelled)
                    return await finalize(state, observer: observer, session: session)
                }
            }
        } catch {
            // Scope-exit publication/custody errors must not erase an observed
            // native result or turn an in-memory success into published success.
            state.failPublication(error)
            state.markCancelled(Task.isCancelled || error is CancellationError)
            return state.result()
        }
    }

    private func finalize(
        _ state: NotikaBuildObservationState,
        observer: NotikaRepositoryIdentity,
        session: NotikaBuildSession
    ) async -> NotikaBuildCoordinatorResult {
        state.markCancelled(Task.isCancelled)
        // A cancelled build still needs final source/tool observations. This
        // detached, bounded capture is awaited while the owning scopes remain
        // live; cancellation cannot silently replace the final evidence.
        let final = await Task.detached {
            var source: NotikaSourceIdentity?
            var toolchain: NotikaToolchainIdentity?
            var failures: [String] = []
            do { source = try await observer.sourceIdentity() }
            catch { failures.append("final source observation: \(error)") }
            do { toolchain = try await observer.toolchainIdentity() }
            catch { failures.append("final toolchain observation: \(error)") }
            return NotikaBuildFinalObservations(source: source, toolchain: toolchain, failures: failures)
        }.value
        state.finishObservations(final)
        state.markCancelled(Task.isCancelled)
        let evidence = state.evidence()
        do {
            if allowsTrustedFixturePublication {
                state.published(try session.publishTerminalForTrustedFixture(evidence))
            } else {
                state.published(try session.publishTerminal(evidence))
            }
        } catch {
            state.failPublication(error)
            if !session.hasTerminal {
                do {
                    state.published(try session.publishDiagnosticTerminal(
                        evidence, publicationFailure: String(describing: error)
                    ))
                } catch { state.failPublication(error) }
            }
        }
        return state.result()
    }

    private func validateContinuationCaptures(
        _ capsules: [CapturedNativePhase], outcome: NotikaOwnedExecutionOutcome, repository: String
    ) throws {
        guard capsules.count == outcome.observations.count, !capsules.isEmpty else {
            throw NotikaBuildCoordinatorError.continuationRequiresSuccessfulBuild
        }
        for (capsule, observed) in zip(capsules, outcome.observations) {
            guard capsule.rawCapture.captureComplete,
                  capsule.observation.termination == RunTermination(kind: .exit, value: 0),
                  capsule.observation.failures.isEmpty, !capsule.observation.cancelled,
                  capsule.observation.retirement == .workerReaped,
                  capsule.command.workingDirectory.utf8.elementsEqual(repository.utf8),
                  allowsTrustedFixturePublication || (
                    capsule.command.executable.utf8.elementsEqual("/usr/bin/xcodebuild".utf8)
                        && capsule.command.arguments.map({ Data($0.utf8) }) == observed.phase.arguments.map({ Data($0.utf8) })
                  ) else { throw NotikaBuildCoordinatorError.continuationRequiresSuccessfulBuild }
            try capsule.revalidateForPublication()
        }
    }
}

/// Only this file can mint a continuation while every build owner is live.
/// Callers cannot reconstruct it from a completed build report or pathname.
internal final class NotikaBuildContinuationContext: Sendable {
    let session: NotikaBuildSession
    let observer: NotikaRepositoryIdentity
    let cacheCustody: NotikaCacheCustody
    let ownership: ProjectOwnership
    let compatibilityIdentity: CacheCompatibilityIdentity
    let sourceBefore: NotikaSourceIdentity
    let toolchainBefore: NotikaToolchainIdentity
    let helperExecutable: String
    let environment: [String: String]
    let outerHostLease: NotikaInteractiveHostLease?
    private let capsules: [CapturedNativePhase]

    fileprivate init(
        session: NotikaBuildSession, observer: NotikaRepositoryIdentity,
        cacheCustody: NotikaCacheCustody, ownership: ProjectOwnership,
        compatibilityIdentity: CacheCompatibilityIdentity, sourceBefore: NotikaSourceIdentity,
        toolchainBefore: NotikaToolchainIdentity, helperExecutable: String,
        environment: [String: String], capsules: [CapturedNativePhase], outerHostLease: NotikaInteractiveHostLease?
    ) {
        self.session = session; self.observer = observer; self.cacheCustody = cacheCustody
        self.ownership = ownership; self.compatibilityIdentity = compatibilityIdentity
        self.sourceBefore = sourceBefore; self.toolchainBefore = toolchainBefore
        self.helperExecutable = helperExecutable; self.environment = environment; self.capsules = capsules
        self.outerHostLease = outerHostLease
    }

    func revalidateBeforeOperation() async throws {
        try validateCapabilities()
        let source = try await observer.sourceIdentity()
        let toolchain = try await observer.toolchainIdentity()
        guard try source.digest() == sourceBefore.digest(), try toolchain.digest() == toolchainBefore.digest() else {
            throw NotikaBuildCoordinatorError.continuationSourceChanged
        }
        try validateCapabilities()
    }

    func borrowedLockDescriptors() throws -> [Int32] {
        try validateCapabilities()
        return try session.inheritedDescriptors() + ownership.inheritedDescriptors() + (outerHostLease.map { [$0.descriptor] } ?? [])
    }

    func borrowedWorkingDirectoryDescriptor() throws -> Int32 {
        try validateCapabilities()
        guard let descriptor = try cacheCustody.inheritedDirectoryDescriptors().dropLast(3).last else {
            throw NotikaCacheCustodyError.ownershipMismatch
        }
        return descriptor
    }

    private func validateCapabilities() throws {
        try cacheCustody.revalidateBeforeOperation()
        try outerHostLease?.revalidate()
        _ = try ownership.inheritedDescriptors()
        _ = try session.inheritedDescriptors()
        for capsule in capsules { try capsule.revalidateForPublication() }
    }
}

private struct NotikaBuildFinalObservations: Sendable {
    let source: NotikaSourceIdentity?
    let toolchain: NotikaToolchainIdentity?
    let failures: [String]
}

private final class NotikaBuildObservationState: Sendable {
    private struct State {
        var sessionPath: String?
        var sourceBefore: NotikaSourceIdentity?
        var sourceAfter: NotikaSourceIdentity?
        var toolchainBefore: NotikaToolchainIdentity?
        var toolchainAfter: NotikaToolchainIdentity?
        var sourceDigests: [String] = []
        var toolchainDigests: [String] = []
        var identity: CacheCompatibilityIdentity?
        var plan: NotikaXcodeInvocationPlan?
        var outcome: NotikaOwnedExecutionOutcome?
        var captures: [CapturedNativePhase] = []
        var resultSummary: NotikaResultSummaryEvidence?
        var resultPreparation: NotikaResultPreparationFailure?
        var resultConsumer: NotikaResultConsumerEvidence?
        var performanceEvidence: NotikaPerformanceEvidence?
        var preflightEvidence: NotikaDevelopmentPreflightEvidence?
        var simulatorPreparation: CapturedNativePhase?
        var uiPreparation: CapturedNativePhase?
        var maintenanceReport: NotikaArtifactMaintenanceReport?
        var maintenanceDiagnostics: [String] = []
        var failures: [String] = []
        var publicationFailures: [String] = []
        var cancelled = false
        var report: NotikaBuildSessionReport?
    }
    private let state = Mutex(State())
    private let runID: String

    init(runID: String) { self.runID = runID }

    func started(_ path: String) { state.withLock { $0.sessionPath = path } }
    func admit(identity: CacheCompatibilityIdentity) { state.withLock { $0.identity = identity } }
    func admit(plan: NotikaXcodeInvocationPlan) { state.withLock { $0.plan = plan } }
    func retain(_ capture: CapturedNativePhase) { state.withLock { $0.captures.append(capture) } }
    func retain(_ summary: NotikaResultSummaryEvidence) { state.withLock { $0.resultSummary = summary } }
    func retain(_ preparation: NotikaResultPreparationFailure) {
        state.withLock {
            $0.resultPreparation = preparation
            $0.cancelled = $0.cancelled || preparation.probe?.observation.cancelled == true
        }
    }
    func retain(_ evidence: NotikaResultConsumerEvidence) { state.withLock { $0.resultConsumer = evidence } }
    func retain(_ evidence: NotikaPerformanceEvidence) { state.withLock { $0.performanceEvidence = evidence } }
    func retain(_ evidence: NotikaDevelopmentPreflightEvidence) {
        state.withLock {
            $0.preflightEvidence = evidence
            $0.cancelled = $0.cancelled || evidence.cancelled
            $0.failures += evidence.orchestrationFailures
        }
    }
    func nativeCaptures() -> [CapturedNativePhase] { state.withLock { $0.captures } }
    func retainPreparation(_ capsule: CapturedNativePhase) {
        state.withLock {
            $0.simulatorPreparation = capsule
            $0.cancelled = $0.cancelled || capsule.observation.cancelled
            if !capsule.observation.failures.isEmpty {
                $0.failures += capsule.observation.failures.map { "simulator preparation: \($0.operation)" }
            }
        }
    }
    func retainUIPreparation(_ capsule: CapturedNativePhase) {
        state.withLock {
            $0.uiPreparation = capsule
            $0.cancelled = $0.cancelled || capsule.observation.cancelled
            $0.failures += capsule.observation.failures.map { "UI preparation: \($0.operation)" }
        }
    }
    func observeMaintenance(_ report: NotikaArtifactMaintenanceReport) { state.withLock { $0.maintenanceReport = report } }
    func failMaintenance(_ error: any Error) { state.withLock { $0.maintenanceDiagnostics.append(String(describing: error)) } }
    func runtimeCapture() -> CapturedNativePhase? {
        state.withLock {
            guard let last = $0.outcome?.observations.last, !last.phase.requiresCompilation else { return nil }
            return $0.captures.last
        }
    }
    func published(_ report: NotikaBuildSessionReport) { state.withLock { $0.report = report } }
    func markCancelled(_ cancelled: Bool) { state.withLock { $0.cancelled = $0.cancelled || cancelled } }

    func observeSource(_ source: NotikaSourceIdentity, initial: Bool = false) {
        state.withLock {
            if initial { $0.sourceBefore = source }
            if let digest = try? source.digest() { $0.sourceDigests.append(digest) }
        }
    }

    func observeToolchain(_ toolchain: NotikaToolchainIdentity, initial: Bool = false) {
        state.withLock {
            if initial { $0.toolchainBefore = toolchain }
            if let digest = try? toolchain.digest() { $0.toolchainDigests.append(digest) }
        }
    }

    func observe(_ outcome: NotikaOwnedExecutionOutcome) {
        state.withLock {
            $0.outcome = outcome
            $0.cancelled = $0.cancelled || outcome.cancelled
        }
    }

    func fail(_ error: any Error, cancelled: Bool) {
        state.withLock {
            if !(error is CancellationError) { $0.failures.append(String(describing: error)) }
            $0.cancelled = $0.cancelled || cancelled
        }
    }

    func failPublication(_ error: any Error) {
        state.withLock { $0.publicationFailures.append(String(describing: error)) }
    }

    func finishObservations(_ final: NotikaBuildFinalObservations) {
        state.withLock {
            $0.sourceAfter = final.source
            $0.toolchainAfter = final.toolchain
            $0.failures += final.failures
        }
    }

    func evidence() -> NotikaBuildSessionTerminalEvidence {
        state.withLock { state in
            let sourceAfter = try? state.sourceAfter?.digest()
            let toolchainAfter = try? state.toolchainAfter?.digest()
            let sourceReverted = sourceAfter != nil && state.sourceDigests.first == sourceAfter
                && state.sourceDigests.dropFirst().contains { $0 != sourceAfter }
            let toolchainReverted = toolchainAfter != nil && state.toolchainDigests.first == toolchainAfter
                && state.toolchainDigests.dropFirst().contains { $0 != toolchainAfter }
            return NotikaBuildSessionTerminalEvidence(
                sourceBefore: state.sourceBefore, sourceAfter: state.sourceAfter,
                toolchainBefore: state.toolchainBefore, toolchainAfter: state.toolchainAfter,
                compatibilityIdentity: state.identity, plan: state.plan, outcome: state.outcome,
                capturedPhases: state.captures, orchestrationFailures: state.failures,
                resultSummary: state.resultSummary,
                resultPreparation: state.resultPreparation,
                resultConsumer: state.resultConsumer,
                performanceEvidence: state.performanceEvidence,
                preflightEvidence: state.preflightEvidence,
                simulatorPreparation: state.simulatorPreparation,
                uiPreparation: state.uiPreparation,
                cancelled: state.cancelled, sourceDriftObservedReverted: sourceReverted,
                toolchainDriftObservedReverted: toolchainReverted
            )
        }
    }

    func result() -> NotikaBuildCoordinatorResult {
        state.withLock {
            NotikaBuildCoordinatorResult(
                runID: runID, sessionPath: $0.sessionPath, report: $0.report, outcome: $0.outcome,
                rawCaptures: ($0.uiPreparation.map { [$0.rawCapture] } ?? [])
                    + ($0.simulatorPreparation.map { [$0.rawCapture] } ?? [])
                    + ($0.preflightEvidence?.capturedPhases.map(\.rawCapture) ?? [])
                    + $0.captures.map(\.rawCapture)
                    + ($0.resultPreparation?.probe.map { [$0.rawCapture] } ?? [])
                    + ($0.resultSummary?.probe.map { [$0.rawCapture] } ?? [])
                    + ($0.resultConsumer?.captures.map { $0.capture.rawCapture } ?? [])
                    + ($0.performanceEvidence?.exportCapture.map { [$0.rawCapture] } ?? []),
                resultSummary: $0.resultSummary,
                resultPreparation: $0.resultPreparation,
                resultConsumer: $0.resultConsumer,
                performanceEvidence: $0.performanceEvidence,
                preflightEvidence: $0.preflightEvidence,
                simulatorPreparation: $0.simulatorPreparation,
                uiPreparation: $0.uiPreparation,
                maintenanceReport: $0.maintenanceReport, maintenanceDiagnostics: $0.maintenanceDiagnostics,
                orchestrationFailures: $0.failures + ($0.outcome?.orchestrationFailure.map { [$0] } ?? []),
                publicationFailures: $0.publicationFailures, cancelled: $0.cancelled
            )
        }
    }
}

private func notikaBuildNativeFailureCode(_ termination: RunTermination) -> Int32? {
    let code = termination.kind == .exit ? termination.value : 128 + termination.value
    return code == 0 ? nil : code
}

private func notikaBuildCanonical(_ value: StrictJSONValue) throws -> CanonicalJSONValue {
    switch value {
    case .array(let values): .array(try values.map(notikaBuildCanonical))
    case .bool(let value): .bool(value)
    case .null: .null
    case .number(let value):
        value.lexicalValue.hasPrefix("-") ? .integer(try value.int64()) : .unsignedInteger(try value.uint64())
    case .object(let object):
        .object(try object.members.map { CanonicalJSONMember(key: $0.key, value: try notikaBuildCanonical($0.value)) })
    case .string(let value): .string(value)
    }
}

private func notikaBuildPreparationSucceeded(_ capsule: CapturedNativePhase) -> Bool {
    capsule.observation.termination == RunTermination(kind: .exit, value: 0)
        && capsule.observation.retirement == .workerReaped && capsule.observation.failures.isEmpty
        && !capsule.observation.cancelled && capsule.rawCapture.captureComplete
}

private func notikaBuildAccountHome() throws -> String {
    var entry = passwd(), result: UnsafeMutablePointer<passwd>?
    var bytes = [CChar](repeating: 0, count: 64 * 1_024)
    return try bytes.withUnsafeMutableBufferPointer { storage in
        guard getpwuid_r(geteuid(), &entry, storage.baseAddress!, storage.count, &result) == 0,
              result != nil, let path = entry.pw_dir,
              let value = String(validatingCString: path), value.hasPrefix("/"), !value.utf8.contains(0) else {
            throw NotikaBuildCoordinatorError.accountHomeUnavailable
        }
        return value
    }
}

private func notikaBuildExecutable(_ name: String, environment: [String: String]) throws -> String {
    for component in (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":", omittingEmptySubsequences: false) {
        guard component.hasPrefix("/") else { continue }
        let candidate = String(component) + "/" + name
        guard !candidate.utf8.contains(0), access(candidate, X_OK) == 0,
              let pointer = realpath(candidate, nil) else { continue }
        defer { free(pointer) }
        guard let resolved = String(validatingCString: pointer) else { continue }
        var metadata = stat()
        guard lstat(resolved, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { continue }
        return resolved
    }
    throw NotikaBuildCoordinatorError.toolUnavailable(name)
}
