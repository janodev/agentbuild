import AgentBuildCore
import AgentLeaseCore
import Darwin
import Foundation

/// Refusal after a real indexing probe preserves that probe's native outcome
/// and raw owner. It supplies no result-bundle admission or passing evidence.
public struct NotikaResultPreparationFailure: Error, Sendable {
    public let failure: ResultBundleFailure
    public let probe: CapturedNativePhase?

    fileprivate init(failure: ResultBundleFailure, probe: CapturedNativePhase?) {
        self.failure = failure; self.probe = probe
    }

    public func revalidateForPublication() throws { try probe?.revalidateForPublication() }
}

public struct NotikaResultCustody: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let sessionID: String
    public let sourceBeforeHash: String
    public let actionRequest: NotikaActionRequest
    public let invocationOrdinal: Int
    public let phaseOrdinal: Int
    public let physicalOrdinal: Int
    public let segment: String
    public let logicalArgumentsSHA256: String
    public let physicalArgumentsSHA256: String
    public let destination: String
    public let cacheDirectory: String
    public let resultPath: String
    public let resultDevice: Int64
    public let resultInode: UInt64
    public let contentSHA256: String
    public let contentBytes: Int64
    public let nativeTermination: RunTermination
}

/// Keeps both native outcomes and the probe's raw files separate. A failing
/// Xcode outcome remains authoritative even when a summary can be observed.
public final class NotikaResultSummaryEvidence: Sendable {
    public let nativeObservation: NativeObservation
    public let probe: CapturedNativePhase?
    public let tests: ExecutedTests?
    public let failures: [ResultBundleFailure]
    public let focusedMethod: Bool
    private let retainedBundle: NotikaRetainedResultBundle

    public var resultBundle: NotikaRetainedResultBundle { retainedBundle }

    fileprivate init(bundle: NotikaRetainedResultBundle, probe: CapturedNativePhase?, tests: ExecutedTests?,
                     failures: [ResultBundleFailure], focusedMethod: Bool) {
        retainedBundle = bundle; nativeObservation = bundle.nativeObservation
        self.probe = probe; self.tests = tests; self.failures = failures; self.focusedMethod = focusedMethod
    }

    public var provesPassingRun: Bool {
        guard nativeObservation.termination == RunTermination(kind: .exit, value: 0),
              !nativeObservation.cancelled, nativeObservation.failures.isEmpty,
              nativeObservation.retirement == .workerReaped,
              let probe, probe.observation.termination == RunTermination(kind: .exit, value: 0),
              !probe.observation.cancelled, probe.observation.failures.isEmpty,
              probe.observation.retirement == .workerReaped, probe.rawCapture.captureComplete,
              failures.isEmpty, let tests else { return false }
        return tests.satisfiesExpectedRun(focusedMethod: focusedMethod)
    }

    public func revalidateForPublication() throws {
        try retainedBundle.revalidateForPublication()
        try probe?.revalidateForPublication()
    }
}

/// Reserves the absent fixed result leaf before Xcode. This is artifact custody,
/// not permission to run a route; the executor still consumes its ledger claim.
public final class NotikaResultBundle: @unchecked Sendable {
    public let path: String
    public let sessionDirectory: String
    private let runID: String
    private let sourceBeforeHash: String
    private let request: NotikaActionRequest
    private let invocation: NotikaXcodeInvocation
    private let phase: NativeInvocationPhase
    private let repositoryDirectory: String
    private let retainedSession: RetainedArtifactDirectory
    fileprivate let sessionDescriptor: Int32
    private let sessionIdentity: ResultNodeIdentity
    private let sessionWatch: ResultMutationWatch
    private let lock = NSLock()
    private var admissionAttempted = false
    private var preparationActive = false

    public init(sessionDirectory: String, runID: String, sourceBeforeHash: String,
                request: NotikaActionRequest, invocation: NotikaXcodeInvocation,
                phase: NativeInvocationPhase) throws {
        let suffix = "/Artifacts/AgentSessions/" + runID
        guard UUID(uuidString: runID) != nil, sessionDirectory.hasSuffix(suffix),
              sourceBeforeHash.utf8.count == 64,
              sourceBeforeHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              !request.isDocumentation, !request.isInteractive, invocation.action == .test,
              invocation.resultBundle?.utf8.elementsEqual((sessionDirectory + "/result.xcresult").utf8) == true else {
            throw ResultBundleFailure(operation: "invalid result reservation", code: EINVAL)
        }
        let plan = try NotikaXcodeInvocationPlan(request: request, destination: invocation.destination,
                                                cacheDirectory: invocation.cacheDirectory,
                                                resultBundle: sessionDirectory + "/result.xcresult")
        let phases = try NativeInvocationLedger(plan: plan).phases
        guard plan.invocations.contains(invocation), phases.contains(phase), !phase.requiresCompilation,
              phase.ordinal == invocation.ordinal else {
            throw ResultBundleFailure(operation: "result phase binding mismatch", code: EINVAL)
        }
        let retained = try RetainedArtifactDirectory(path: sessionDirectory, requiredPermissions: 0o700)
        let descriptor = Darwin.open(sessionDirectory, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 3 else { throw resultFailure("open result session") }
        var transferred = false
        defer { if !transferred { _ = Darwin.close(descriptor) } }
        let identity = try resultDescriptorIdentity(descriptor)
        guard identity.device == retained.fingerprint.device, identity.inode == retained.fingerprint.inode else {
            throw ResultBundleFailure(operation: "result session changed", code: ESTALE)
        }
        let watch = try ResultMutationWatch()
        try watch.arm(descriptor, writes: false, label: "session directory")
        try Self.requireAbsent(descriptor, "result.xcresult")
        try Self.requireAbsent(descriptor, "result-custody.json")
        try retained.revalidate()
        try watch.check()
        self.sessionDirectory = sessionDirectory
        path = sessionDirectory + "/result.xcresult"
        self.runID = runID; self.sourceBeforeHash = sourceBeforeHash; self.request = request
        self.invocation = invocation; self.phase = phase
        repositoryDirectory = String(sessionDirectory.dropLast(suffix.utf8.count))
        retainedSession = retained; sessionDescriptor = descriptor; sessionIdentity = identity; sessionWatch = watch
        transferred = true
    }

    deinit { _ = Darwin.close(sessionDescriptor) }

    public func admitAfterRetirement(_ captured: CapturedNativePhase) throws -> NotikaRetainedResultBundle {
        try validateNativeCommand(captured, allowsTrustedShellFixture: false)
        return try admitCapturedPhase(captured)
    }

    /// The first official summary read creates a root SQLite index in a cold
    /// xcresult. Original native files stay watched throughout this one phase;
    /// only the known index names can be added before the final immutable seal.
    public func admitAfterRetirement(
        _ captured: CapturedNativePhase, environment: [String: String],
        operation: @Sendable (DarwinWorkloadCommand, Int32) async throws -> CapturedNativePhase
    ) async throws -> NotikaRetainedResultBundle {
        try await prepareAndAdmit(captured, environment: environment, allowsTrustedShellFixture: false,
                                  operation: operation)
    }

    private func validateNativeCommand(_ captured: CapturedNativePhase, allowsTrustedShellFixture: Bool) throws {
        if allowsTrustedShellFixture {
            guard captured.command.executable.utf8.elementsEqual("/bin/sh".utf8),
                  captured.command.workingDirectory.utf8.elementsEqual(repositoryDirectory.utf8) else {
                throw ResultBundleFailure(operation: "invalid fixture native command", code: EINVAL)
            }
            return
        }
        guard captured.command.executable.utf8.elementsEqual("/usr/bin/xcodebuild".utf8),
              resultArgumentsEqual(captured.command.arguments, phase.arguments),
              captured.command.workingDirectory.utf8.elementsEqual(repositoryDirectory.utf8) else {
            throw ResultBundleFailure(operation: "result native command mismatch", code: EINVAL)
        }
    }

    /// Trusted package fixtures may replace Xcode with a shell. Actual process,
    /// raw-capture, bundle and receipt custody are still required and retained.
    internal func admitAfterRetirementForTrustedFixture(_ captured: CapturedNativePhase) throws -> NotikaRetainedResultBundle {
        try validateNativeCommand(captured, allowsTrustedShellFixture: true)
        return try admitCapturedPhase(captured)
    }

    internal func admitAfterRetirementForTrustedFixture(
        _ captured: CapturedNativePhase, environment: [String: String],
        operation: @Sendable (DarwinWorkloadCommand, Int32) async throws -> CapturedNativePhase
    ) async throws -> NotikaRetainedResultBundle {
        try await prepareAndAdmit(captured, environment: environment, allowsTrustedShellFixture: true,
                                  operation: operation)
    }

    private func prepareAndAdmit(
        _ captured: CapturedNativePhase, environment: [String: String], allowsTrustedShellFixture: Bool,
        operation: @Sendable (DarwinWorkloadCommand, Int32) async throws -> CapturedNativePhase
    ) async throws -> NotikaRetainedResultBundle {
        try validateNativeCommand(captured, allowsTrustedShellFixture: allowsTrustedShellFixture)
        try captured.revalidateForPublication()
        try beginPreparation(nativeObservation: captured.observation, rawCapture: captured.rawCapture)
        var capturedProbe: CapturedNativePhase?
        do {
            try ResultBundleTree.ensureDescriptorBudget()
            let original = try ResultBundleTree(parent: sessionDescriptor, name: "result.xcresult",
                                                      allowsRootSQLitePreparation: true)
            let command = try resultSummaryCommand(path: path, environment: environment)
            let probe = try await operation(command, original.root)
            capturedProbe = probe
            // A retired nonzero probe is retained as its own failure; it never
            // replaces the native test outcome or supplies passing counts.
            try resultValidateConsumerCapture(probe, command: command, directoryDescriptor: original.root,
                                               allowsTrustedShellFixture: allowsTrustedShellFixture,
                                               requiresSuccessfulExit: false)
            _ = try resultReadCapturedStandardOutput(probe, maximumBytes: 1_024 * 1_024)
            try original.validateSQLitePreparation()
            return try admit(nativeObservation: captured.observation, rawCapture: captured.rawCapture,
                             nativeCapture: captured, preparedSummary: probe, preparationTree: original)
        } catch {
            finishFailedPreparation()
            let failure = error as? ResultBundleFailure
                ?? .init(operation: "prepare xcresult index", detail: String(describing: error))
            throw NotikaResultPreparationFailure(failure: failure, probe: capturedProbe)
        }
    }

    private func beginPreparation(nativeObservation: NativeObservation, rawCapture: NativeLogCaptureResult) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !admissionAttempted, !preparationActive else {
            throw ResultBundleFailure(operation: "result already admitted", code: EALREADY)
        }
        try Self.validateNativeEvidence(nativeObservation, rawCapture)
        try validateSessionLocked()
        preparationActive = true
    }

    private func finishFailedPreparation() {
        lock.lock()
        defer { lock.unlock() }
        preparationActive = false
        admissionAttempted = true
    }

    private func admitCapturedPhase(_ captured: CapturedNativePhase) throws -> NotikaRetainedResultBundle {
        try captured.revalidateForPublication()
        return try admit(nativeObservation: captured.observation, rawCapture: captured.rawCapture, nativeCapture: captured)
    }

    /// Trusted test seam for filesystem fixtures; production requires the exact
    /// command-bound capture capsule above. It does not grant native authority.
    internal func admit(nativeObservation: NativeObservation, rawCapture: NativeLogCaptureResult,
                        nativeCapture: CapturedNativePhase? = nil, preparedSummary: CapturedNativePhase? = nil,
                        preparationTree: ResultBundleTree? = nil) throws -> NotikaRetainedResultBundle {
        lock.lock()
        defer { lock.unlock() }
        guard !admissionAttempted, preparationActive == (preparationTree != nil),
              (preparationTree != nil) == (preparedSummary != nil) else {
            throw ResultBundleFailure(operation: "result already admitted", code: EALREADY)
        }
        admissionAttempted = true
        preparationActive = false
        try Self.validateNativeEvidence(nativeObservation, rawCapture)
        try nativeCapture?.revalidateForPublication()
        try preparedSummary?.revalidateForPublication()
        try preparationTree?.validateSQLitePreparation()
        try validateSessionLocked()
        try ResultBundleTree.ensureDescriptorBudget()
        let tree = try ResultBundleTree(parent: sessionDescriptor, name: "result.xcresult")
        try preparationTree?.validateSQLitePreparation()
        let rootIdentity = try resultDescriptorIdentity(tree.root)
        let custody = NotikaResultCustody(
            schemaVersion: 2, kind: "notika.session-result-custody", sessionID: runID,
            sourceBeforeHash: sourceBeforeHash, actionRequest: request,
            invocationOrdinal: invocation.ordinal, phaseOrdinal: phase.phaseOrdinal, physicalOrdinal: phase.physicalOrdinal,
            segment: invocation.segment, logicalArgumentsSHA256: ArgumentCommitment.digest(arguments: invocation.arguments),
            physicalArgumentsSHA256: phase.argumentCommitment, destination: invocation.destination,
            cacheDirectory: invocation.cacheDirectory, resultPath: path, resultDevice: rootIdentity.device,
            resultInode: rootIdentity.inode, contentSHA256: tree.commitment, contentBytes: tree.byteCount,
            nativeTermination: nativeObservation.termination!)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(custody)
        let receipt = try publishReceipt(data)
        do {
            try tree.watch.arm(receipt, writes: true, label: "result-custody.json")
            let identity = try resultDescriptorIdentity(receipt)
            try tree.revalidate()
            try preparationTree?.validateSQLitePreparation()
            try nativeCapture?.revalidateForPublication()
            try preparedSummary?.revalidateForPublication()
            try validateSessionLocked()
            return NotikaRetainedResultBundle(reservation: self, tree: tree, custody: custody,
                                              receipt: receipt, receiptIdentity: identity, receiptData: data,
                                              nativeObservation: nativeObservation, nativeCapture: nativeCapture,
                                              preparedSummary: preparedSummary,
                                              focusedMethod: Self.requiresExactlyOneUIResult(request))
        } catch { _ = Darwin.close(receipt); throw error }
    }

    private static func validateNativeEvidence(_ observation: NativeObservation,
                                               _ rawCapture: NativeLogCaptureResult) throws {
        guard observation.retirement == .workerReaped, observation.termination != nil,
              !observation.cancelled, observation.failures.isEmpty, rawCapture.captureComplete else {
            throw ResultBundleFailure(operation: "incomplete native result evidence", code: EPROTO)
        }
    }

    fileprivate func validateSession() throws {
        lock.lock()
        defer { lock.unlock() }
        try validateSessionLocked()
    }

    private func validateSessionLocked() throws {
        try sessionWatch.check()
        try retainedSession.revalidate()
        let current = try resultDescriptorIdentity(sessionDescriptor)
        var status = stat()
        guard lstat(sessionDirectory, &status) == 0,
              sessionIdentity.sameDirectoryBinding(current), current.sameDirectoryBinding(ResultNodeIdentity(status)) else {
            throw ResultBundleFailure(operation: "result session binding changed", code: ESTALE)
        }
        try sessionWatch.check()
    }

    private func publishReceipt(_ data: Data) throws -> Int32 {
        guard data.count <= 256 * 1_024 else { throw ResultBundleFailure(operation: "result receipt byte limit", code: EFBIG) }
        let stage = ".result-custody-" + UUID().uuidString
        let writer = openat(sessionDescriptor, stage, O_WRONLY | O_EXCL | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard writer >= 3 else { throw resultFailure("reserve result receipt") }
        defer { _ = Darwin.close(writer) }
        let writerIdentity = try resultDescriptorIdentity(writer)
        defer {
            if let current = try? resultEntryIdentity(sessionDescriptor, stage),
               current.device == writerIdentity.device, current.inode == writerIdentity.inode {
                _ = unlinkat(sessionDescriptor, stage, 0)
            }
        }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.write(writer, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw resultFailure("write result receipt", code: count < 0 ? errno : EIO) }
            offset += count
        }
        guard fchmod(writer, 0o400) == 0, fsync(writer) == 0 else { throw resultFailure("seal result receipt") }
        try validateSessionLocked()
        guard linkat(sessionDescriptor, stage, sessionDescriptor, "result-custody.json", 0) == 0 else {
            throw resultFailure("publish result receipt")
        }
        guard unlinkat(sessionDescriptor, stage, 0) == 0, fsync(sessionDescriptor) == 0 else {
            throw resultFailure("sync result receipt publication")
        }
        let reader = openat(sessionDescriptor, "result-custody.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard reader >= 3 else { throw resultFailure("retain result receipt") }
        do {
            let identity = try resultDescriptorIdentity(reader)
            guard identity.regular, identity.owner == UInt32(geteuid()), identity.links == 1,
                  identity.mode & 0o7777 == 0o400, identity.size == Int64(data.count),
                  identity.device == writerIdentity.device, identity.inode == writerIdentity.inode else {
                throw ResultBundleFailure(operation: "result receipt binding mismatch", code: ESTALE)
            }
            return reader
        } catch { _ = Darwin.close(reader); throw error }
    }

    private static func requireAbsent(_ descriptor: Int32, _ name: String) throws {
        var status = stat()
        guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == -1, errno == ENOENT else {
            throw ResultBundleFailure(operation: "result leaf already exists", code: EEXIST, detail: name)
        }
    }

    private static func requiresExactlyOneUIResult(_ request: NotikaActionRequest) -> Bool {
        if request.makeRoute?.canonicalRoute == .testCanvasFramePacingPerformance { return true }
        guard let route = request.makeRoute?.canonicalRoute,
              [.testUI, .testUIFile, .testUIOnly, .testUIOnlyFile].contains(route) else { return false }
        return !request.testMethod.isEmpty || request.makeRoute?.fixedTestMethod != nil
    }
}

/// Holds the actual result and immutable receipt descriptors through probing
/// and publication; a string path cannot substitute for this capability.
public final class NotikaRetainedResultBundle: @unchecked Sendable {
    public let custody: NotikaResultCustody
    public let receiptPath: String
    public let receiptSHA256: String
    public let nativeObservation: NativeObservation
    private let reservation: NotikaResultBundle
    private let tree: ResultBundleTree
    private let receipt: Int32
    private let receiptIdentity: ResultNodeIdentity
    private let receiptData: Data
    private let nativeCapture: CapturedNativePhase?
    private let preparedSummary: CapturedNativePhase?
    private let focusedMethod: Bool
    private let lock = NSLock()

    public var sessionDirectory: String { reservation.sessionDirectory }
    internal var resultDirectoryDescriptor: Int32 { tree.root }
    internal var sessionDirectoryDescriptor: Int32 { reservation.sessionDescriptor }

    fileprivate init(reservation: NotikaResultBundle, tree: ResultBundleTree, custody: NotikaResultCustody,
                     receipt: Int32, receiptIdentity: ResultNodeIdentity, receiptData: Data,
                     nativeObservation: NativeObservation, nativeCapture: CapturedNativePhase?,
                     preparedSummary: CapturedNativePhase?, focusedMethod: Bool) {
        self.reservation = reservation; self.tree = tree; self.custody = custody; self.receipt = receipt
        self.receiptIdentity = receiptIdentity; self.receiptData = receiptData; self.nativeCapture = nativeCapture
        self.preparedSummary = preparedSummary
        self.nativeObservation = nativeObservation; self.focusedMethod = focusedMethod
        receiptPath = reservation.sessionDirectory + "/result-custody.json"
        receiptSHA256 = CanonicalJSONDigest.digest(receiptData)
    }

    deinit { _ = Darwin.close(receipt) }

    public func revalidateForPublication() throws {
        lock.lock()
        defer { lock.unlock() }
        try reservation.validateSession()
        try tree.revalidate()
        let identity = try resultDescriptorIdentity(receipt)
        guard identity == receiptIdentity,
              try resultEntryIdentity(reservation.sessionDescriptor, "result-custody.json") == receiptIdentity,
              try readReceipt() == receiptData else {
            throw ResultBundleFailure(operation: "result receipt changed", code: ESTALE)
        }
        try nativeCapture?.revalidateForPublication()
        try preparedSummary?.revalidateForPublication()
        try tree.watch.check()
        try reservation.validateSession()
    }

    /// The operation must forward the borrowed descriptor as a directory
    /// capability to the trusted native helper. It must not substitute a path.
    public func observeSummary(
        environment: [String: String],
        operation: @Sendable (DarwinWorkloadCommand, Int32) async throws -> CapturedNativePhase
    ) async -> NotikaResultSummaryEvidence {
        await observeSummary(environment: environment, allowsTrustedShellFixture: false, operation: operation)
    }

    /// Only package fixture coordinators can substitute a shell for xcresulttool.
    /// Pinning, actual outcomes, raw capture and final publication checks remain.
    internal func observeSummaryForTrustedFixture(
        environment: [String: String],
        operation: @Sendable (DarwinWorkloadCommand, Int32) async throws -> CapturedNativePhase
    ) async -> NotikaResultSummaryEvidence {
        await observeSummary(environment: environment, allowsTrustedShellFixture: true, operation: operation)
    }

    private func observeSummary(
        environment: [String: String], allowsTrustedShellFixture: Bool,
        operation: @Sendable (DarwinWorkloadCommand, Int32) async throws -> CapturedNativePhase
    ) async -> NotikaResultSummaryEvidence {
        var probe: CapturedNativePhase?
        var tests: ExecutedTests?
        var failures: [ResultBundleFailure] = []
        do {
            try revalidateForPublication()
            let command = try resultSummaryCommand(path: custody.resultPath, environment: environment)
            let captured: CapturedNativePhase
            if let preparedSummary { captured = preparedSummary }
            else { captured = try await operation(command, tree.root) }
            probe = captured
            try validateConsumerCapture(captured, command: command, directoryDescriptor: tree.root,
                                        allowsTrustedShellFixture: allowsTrustedShellFixture)
            tests = try ExecutedTests.parse(readCapturedStandardOutput(captured, maximumBytes: 1_024 * 1_024))
            try revalidateForPublication()
        } catch let failure as ResultBundleFailure { failures.append(failure) }
        catch { failures.append(ResultBundleFailure(operation: "observe xcresult summary", detail: String(describing: error))) }
        return NotikaResultSummaryEvidence(bundle: self, probe: probe, tests: tests, failures: failures, focusedMethod: focusedMethod)
    }

    private func readReceipt() throws -> Data {
        var data = Data(count: receiptData.count)
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeMutableBytes { pread(receipt, $0.baseAddress!.advanced(by: offset), $0.count - offset, off_t(offset)) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw resultFailure("read retained result receipt", code: count < 0 ? errno : EIO) }
            offset += count
        }
        return data
    }

    internal func validateConsumerCapture(_ captured: CapturedNativePhase, command: DarwinWorkloadCommand,
                                         directoryDescriptor: Int32,
                                         allowsTrustedShellFixture: Bool = false) throws {
        try resultValidateConsumerCapture(captured, command: command, directoryDescriptor: directoryDescriptor,
                                           allowsTrustedShellFixture: allowsTrustedShellFixture)
        try revalidateForPublication()
    }

    internal func readCapturedStandardOutput(_ captured: CapturedNativePhase, maximumBytes: Int64) throws -> Data {
        try resultReadCapturedStandardOutput(captured, maximumBytes: maximumBytes)
    }
}

private func resultSummaryCommand(path: String, environment: [String: String]) throws -> DarwinWorkloadCommand {
    try DarwinWorkloadCommand(executable: "/usr/bin/xcrun",
        arguments: ["xcresulttool", "get", "test-results", "summary", "--path", ".", "--compact"],
        workingDirectory: path, environment: environment)
}

private func resultValidateConsumerCapture(_ captured: CapturedNativePhase, command: DarwinWorkloadCommand,
                                          directoryDescriptor: Int32, allowsTrustedShellFixture: Bool = false,
                                          requiresSuccessfulExit: Bool = true) throws {
        let fixtureCommandMatches = allowsTrustedShellFixture
            && captured.command.executable.utf8.elementsEqual("/bin/sh".utf8)
            && captured.command.workingDirectory.utf8.elementsEqual(command.workingDirectory.utf8)
            && resultEnvironmentsEqual(captured.command.environment, command.environment)
        guard resultCommandsEqual(captured.command, command) || fixtureCommandMatches else {
            throw ResultBundleFailure(operation: "result probe command mismatch", code: EINVAL)
        }
        let root = try resultDescriptorIdentity(directoryDescriptor)
        guard let directory = captured.workingDirectoryIdentity,
              directory.device == root.device, directory.inode == root.inode,
              directory.owner == root.owner, directory.mode == root.mode else {
            throw ResultBundleFailure(operation: "result probe was not bound to retained directory", code: EINVAL)
        }
        try captured.revalidateForPublication()
        guard captured.observation.retirement == .workerReaped,
              captured.observation.termination != nil,
              !requiresSuccessfulExit || captured.observation.termination == RunTermination(kind: .exit, value: 0),
              !captured.observation.cancelled, captured.observation.failures.isEmpty,
              captured.rawCapture.captureComplete else {
            throw ResultBundleFailure(operation: "result consumer failed", code: EPROTO)
        }
}

private func resultReadCapturedStandardOutput(_ captured: CapturedNativePhase, maximumBytes: Int64) throws -> Data {
        try captured.revalidateForPublication()
        let stream = captured.rawCapture.standardOutput
        // Raw capture may retain 64 MiB, while materialized artifact readers
        // and structured result parsers admit at most 16 MiB.
        let readLimit = min(maximumBytes, 16 * 1_024 * 1_024)
        guard stream.reachedEOF, stream.observedBytes == stream.retainedBytes,
              readLimit > 0, stream.retainedBytes >= 0, stream.retainedBytes <= readLimit,
              let boundedMaximum = Int(exactly: readLimit) else {
            throw ResultBundleFailure(operation: "result consumer byte limit", code: EFBIG)
        }
        let directory = try RetainedArtifactDirectory(path: URL(fileURLWithPath: stream.path).deletingLastPathComponent().path,
                                                      requiredPermissions: 0o700)
        let file = try directory.openFile(named: "stdout.log", policy: ArtifactFilePolicy(minimumBytes: 0,
                                             maximumBytes: boundedMaximum, requiredPermissions: 0o600))
        let data = try file.readBounded()
        guard Int64(data.count) == stream.retainedBytes, CanonicalJSONDigest.digest(data) == stream.sha256 else {
            throw ResultBundleFailure(operation: "result consumer raw commitment mismatch", code: ESTALE)
        }
        try captured.revalidateForPublication()
        return data
}

private func resultArgumentsEqual(_ left: [String], _ right: [String]) -> Bool {
    left.count == right.count && zip(left, right).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
}

private func resultCommandsEqual(_ left: DarwinWorkloadCommand, _ right: DarwinWorkloadCommand) -> Bool {
    left.executable.utf8.elementsEqual(right.executable.utf8) && resultArgumentsEqual(left.arguments, right.arguments)
        && left.workingDirectory.utf8.elementsEqual(right.workingDirectory.utf8)
        && resultEnvironmentsEqual(left.environment, right.environment)
}

private func resultEnvironmentsEqual(_ left: [String: String], _ right: [String: String]) -> Bool {
    left.count == right.count
        && left.allSatisfy { key, value in right[key]?.utf8.elementsEqual(value.utf8) == true }
}
