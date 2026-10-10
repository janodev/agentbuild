import AgentLeaseCore
import Darwin
import Foundation
import Synchronization

/// Holds the Python-compatible shared session-writer lease outside every
/// graph/cache/compilation scope. Descriptors are borrowed only while the
/// callback is active; the callback must retire native work before returning.
public final class NotikaBuildSession: Sendable {
    public static let progressFilename = "in-progress.json"
    public static let terminalFilename = "manifest.json"
    public let path: String
    public let runID: String
    public let canonicalRepository: String
    public let writerResource: String
    public let startedAt: Date
    public let request: NotikaActionRequest
    public let plannedDestination: String
    public let outerLeaseEvidence: NotikaOuterLeaseEvidence?

    private struct State: @unchecked Sendable {
        var active = true
        var progress: SessionSealedJSON?
        var terminal: SessionSealedJSON?
        var capsules: [CapturedNativePhase] = []
        var resultSummary: NotikaResultSummaryEvidence?
        var resultPreparation: NotikaResultPreparationFailure?
        var resultConsumer: NotikaResultConsumerEvidence?
        var performanceEvidence: NotikaPerformanceEvidence?
        var preflightEvidence: NotikaDevelopmentPreflightEvidence?
        var simulatorPreparation: CapturedNativePhase?
        var uiPreparation: CapturedNativePhase?
        var admitCaptures = true
    }
    private let state = Mutex(State())
    private let repository: RetainedArtifactDirectory
    private let directories: [SessionDirectoryPin]
    private let leases: LeaseSet
    private let paths: AgentLeasePaths
    private let timeZone: TimeZone

    /// This is the outer project boundary. No unchecked artifact path is opened
    /// before ownership, and an incomplete callback cannot return as success.
    public static func withSession<Result: Sendable>(
        canonicalRepository: String,
        registryRoot: String,
        request: NotikaActionRequest,
        destination: String? = nil,
        outerLeaseEvidence: NotikaOuterLeaseEvidence? = nil,
        runID: String = UUID().uuidString,
        startedAt: Date = Date(),
        timeZone: TimeZone = .current,
        waitSeconds: Double? = nil,
        operation: @Sendable (NotikaBuildSession) async throws -> Result
    ) async throws -> Result {
        _ = try CacheCompatibilityIdentity.graphResourceName(canonicalWorktree: canonicalRepository)
        guard let uuid = UUID(uuidString: runID), uuid.uuidString == runID else {
            throw NotikaBuildSessionError.invalidSchema("runID")
        }
        guard sessionSupportsRequest(request) else {
            throw NotikaBuildSessionError.invalidSchema("request")
        }
        let selectedDestination = try sessionAdmitExecutionContext(request: request,
            destination: destination, outerLeaseEvidence: outerLeaseEvidence)
        _ = try LocalCalendarRetention(evaluatedAt: startedAt, timeZone: timeZone)
        let resource = "notika:sessions:" + canonicalRepository
        let paths = try AgentLeasePaths.open(selectedRoot: registryRoot)
        let resources = try ResourceSet(exclusive: [], shared: [resource])
        let pid = getpid(), acquiredAt = RunRecord.timestamp()
        let leases = try await LeaseSet.acquire(resources, paths: paths, waitSeconds: waitSeconds,
            initialMetadata: { lease in
                LockMetadata(resourceName: lease.resource.value, leaseMode: lease.mode, runID: runID,
                             coordinatorPID: pid, childPID: nil, mode: .run, state: .acquired,
                             label: "notika-session-writer", bead: nil, acquiredAt: acquiredAt)
            })
        defer { leases.release() }
        try Task.checkCancellation()
        let session = try Self(canonicalRepository: canonicalRepository, paths: paths, leases: leases,
                               request: request, destination: selectedDestination, outerLeaseEvidence: outerLeaseEvidence,
                               runID: runID, startedAt: startedAt, timeZone: timeZone)
        defer { session.close() }
        do {
            let result = try await operation(session)
            try session.revalidateTerminal()
            return result
        } catch {
            // Preserve the original error. A best-effort driver-failure report
            // never replaces a previously published native observation.
            if !session.hasTerminal {
                _ = try? session.publishTerminal(.init(orchestrationFailures: [String(describing: error)],
                                                       cancelled: Task.isCancelled))
            }
            throw error
        }
    }

    private init(
        canonicalRepository: String, paths: AgentLeasePaths, leases: LeaseSet,
        request: NotikaActionRequest, destination: String, outerLeaseEvidence: NotikaOuterLeaseEvidence?,
        runID: String, startedAt: Date, timeZone: TimeZone
    ) throws {
        let repository = try RetainedArtifactDirectory(path: canonicalRepository)
        let directories = try sessionOpenDirectories(repository: repository, runID: runID)
        self.repository = repository
        self.directories = directories
        self.paths = paths
        self.leases = leases
        self.request = request
        plannedDestination = destination
        self.outerLeaseEvidence = outerLeaseEvidence
        self.runID = runID
        self.startedAt = startedAt
        self.timeZone = timeZone
        self.canonicalRepository = canonicalRepository
        writerResource = "notika:sessions:" + canonicalRepository
        path = canonicalRepository + "/Artifacts/AgentSessions/" + runID
        try state.withLock { state in
            try validateOwnershipAndDirectories()
            let progress = try makeReport(completedAt: nil, evidence: nil)
            state.progress = try SessionSealedJSON.publish(progress, filename: Self.progressFilename,
                directory: directories.last!, validateBeforeLink: { try validateOwnershipAndDirectories() })
        }
    }

    public var hasTerminal: Bool { state.withLock { $0.terminal != nil } }
    public var metadataWriteIssues: [MetadataWriteIssue] { leases.metadataWriteIssues }

    public func inheritedDescriptors() throws -> [Int32] {
        try state.withLock { state in
            guard state.active else { throw NotikaBuildSessionError.expiredOwnership }
            try validateOwnershipAndDirectories()
            return leases.inheritedDescriptors
        }
    }

    public func inheritedLeaseDescriptors() throws -> [InheritedLeaseDescriptor] {
        try state.withLock { state in
            guard state.active else { throw NotikaBuildSessionError.expiredOwnership }
            try validateOwnershipAndDirectories()
            return leases.inheritedLeaseDescriptors
        }
    }

    /// Final bytes are private until the writable descriptor has been retired.
    /// The raw producer capsules are checked again after sealing the candidate
    /// and immediately before linking the no-overwrite public name.
    @discardableResult
    public func publishTerminal(
        _ evidence: NotikaBuildSessionTerminalEvidence,
        completedAt: Date = Date()
    ) throws -> NotikaBuildSessionReport {
        try publish(evidence, completedAt: completedAt, admitCaptures: true, allowFixtureCommands: false, publicationFailures: [])
    }

    /// Only trusted package fixtures may substitute a shell for Xcode. Their
    /// reports expose that substitution and retain the exact command commitment.
    /// No public production entry point selects this policy.
    @discardableResult
    internal func publishTerminalForTrustedFixture(
        _ evidence: NotikaBuildSessionTerminalEvidence,
        completedAt: Date = Date()
    ) throws -> NotikaBuildSessionReport {
        try publish(evidence, completedAt: completedAt, admitCaptures: true, allowFixtureCommands: true, publicationFailures: [])
    }

    /// Recovery can retain an observed native failure after raw admission fails.
    /// It explicitly marks every raw report as unadmitted diagnostic evidence;
    /// copied paths cannot produce success through this entry point.
    @discardableResult
    public func publishDiagnosticTerminal(
        _ evidence: NotikaBuildSessionTerminalEvidence,
        publicationFailure: String,
        completedAt: Date = Date()
    ) throws -> NotikaBuildSessionReport {
        guard !publicationFailure.isEmpty else { throw NotikaBuildSessionError.invalidSchema("publicationFailure") }
        return try publish(evidence, completedAt: completedAt, admitCaptures: false, allowFixtureCommands: false,
                           publicationFailures: [publicationFailure])
    }

    private func publish(
        _ evidence: NotikaBuildSessionTerminalEvidence, completedAt: Date,
        admitCaptures: Bool, allowFixtureCommands: Bool, publicationFailures: [String]
    ) throws -> NotikaBuildSessionReport {
        try state.withLock { state in
            guard state.active, state.terminal == nil else { throw NotikaBuildSessionError.invalidLifecycle }
            try validateOwnershipAndDirectories()
            try state.progress?.revalidate(directory: directories.last!)
            try validateCapturedCommands(evidence, admitCaptures: admitCaptures, allowFixtureCommands: allowFixtureCommands)
            for capsule in evidence.capturedPhases where admitCaptures && capsule.rawCapture.captureComplete {
                try capsule.revalidateForPublication()
            }
            try revalidateResult(evidence.resultSummary, preparation: evidence.resultPreparation, admitted: admitCaptures)
            try revalidateAncillary(evidence.resultConsumer, performance: evidence.performanceEvidence, preflight: evidence.preflightEvidence,
                preparation: evidence.simulatorPreparation, uiPreparation: evidence.uiPreparation, admitted: admitCaptures)
            let report = try makeReport(completedAt: completedAt, evidence: evidence, admitCaptures: admitCaptures,
                                        allowFixtureCommands: allowFixtureCommands,
                                        publicationFailures: publicationFailures)
            let terminal = try SessionSealedJSON.publish(report, filename: Self.terminalFilename,
                directory: directories.last!, validateBeforeLink: {
                    try validateOwnershipAndDirectories()
                    try state.progress?.revalidate(directory: directories.last!)
                    try validateCapturedCommands(evidence, admitCaptures: admitCaptures, allowFixtureCommands: allowFixtureCommands)
                    for capsule in evidence.capturedPhases where admitCaptures && capsule.rawCapture.captureComplete {
                        try capsule.revalidateForPublication()
                    }
                    try revalidateResult(evidence.resultSummary, preparation: evidence.resultPreparation, admitted: admitCaptures)
                    try revalidateAncillary(evidence.resultConsumer, performance: evidence.performanceEvidence, preflight: evidence.preflightEvidence,
                        preparation: evidence.simulatorPreparation, uiPreparation: evidence.uiPreparation, admitted: admitCaptures)
                })
            // Transfer receipt ownership before any later fallible verification.
            state.terminal = terminal
            state.capsules = evidence.capturedPhases
            state.resultSummary = evidence.resultSummary
            state.resultPreparation = evidence.resultPreparation
            state.resultConsumer = evidence.resultConsumer
            state.performanceEvidence = evidence.performanceEvidence
            state.preflightEvidence = evidence.preflightEvidence
            state.simulatorPreparation = evidence.simulatorPreparation
            state.uiPreparation = evidence.uiPreparation
            state.admitCaptures = admitCaptures
            try terminal.revalidate(directory: directories.last!)
            for capsule in state.capsules where state.admitCaptures && capsule.rawCapture.captureComplete {
                try capsule.revalidateForPublication()
            }
            try revalidateResult(state.resultSummary, preparation: state.resultPreparation, admitted: state.admitCaptures)
            try revalidateAncillary(state.resultConsumer, performance: state.performanceEvidence, preflight: state.preflightEvidence,
                preparation: state.simulatorPreparation, uiPreparation: state.uiPreparation, admitted: state.admitCaptures)
            return report
        }
    }

    /// Reads only the retained exact read-only inode, never a reopened pathname.
    /// Exact bytes, metadata, both names, and the mutation watch must still bind.
    public func revalidateTerminal() throws {
        try state.withLock { state in
            guard state.active, let terminal = state.terminal else { throw NotikaBuildSessionError.invalidLifecycle }
            try validateOwnershipAndDirectories()
            try state.progress?.revalidate(directory: directories.last!)
            for capsule in state.capsules where state.admitCaptures && capsule.rawCapture.captureComplete {
                try capsule.revalidateForPublication()
            }
            try revalidateResult(state.resultSummary, preparation: state.resultPreparation, admitted: state.admitCaptures)
            try revalidateAncillary(state.resultConsumer, performance: state.performanceEvidence, preflight: state.preflightEvidence,
                preparation: state.simulatorPreparation, uiPreparation: state.uiPreparation, admitted: state.admitCaptures)
            try terminal.revalidate(directory: directories.last!)
            try validateOwnershipAndDirectories()
        }
    }

    private func makeReport(
        completedAt: Date?, evidence: NotikaBuildSessionTerminalEvidence?,
        admitCaptures: Bool = true, allowFixtureCommands: Bool = false, publicationFailures: [String] = []
    ) throws -> NotikaBuildSessionReport {
        let identity = directories.last!.identity
        guard let device = UInt64(exactly: identity.st_dev) else { throw NotikaBuildSessionError.unsafePath(path) }
        return try NotikaBuildSessionReport.make(
            repository: canonicalRepository, runID: runID, ownerUID: geteuid(), directoryDevice: device,
            directoryInode: UInt64(identity.st_ino), request: request, startedAt: startedAt,
            destination: plannedDestination, outerLeaseEvidence: outerLeaseEvidence,
            completedAt: completedAt, timeZone: timeZone, evidence: evidence, admitCaptures: admitCaptures,
            allowFixtureCommands: allowFixtureCommands,
            publicationFailures: publicationFailures
        )
    }

    private func revalidateResult(
        _ summary: NotikaResultSummaryEvidence?, preparation: NotikaResultPreparationFailure?, admitted: Bool
    ) throws {
        guard admitted else { return }
        if let probe = preparation?.probe, probe.rawCapture.captureComplete { try probe.revalidateForPublication() }
        guard let summary else { return }
        // Incomplete probe output can be recorded as diagnostic evidence, but
        // its retained bundle remains bound and cannot silently be replaced.
        try summary.resultBundle.revalidateForPublication()
        if let probe = summary.probe, probe.rawCapture.captureComplete {
            try probe.revalidateForPublication()
        }
    }

    private func revalidateAncillary(
        _ consumer: NotikaResultConsumerEvidence?, performance: NotikaPerformanceEvidence?, preflight: NotikaDevelopmentPreflightEvidence?,
        preparation: CapturedNativePhase?, uiPreparation: CapturedNativePhase?, admitted: Bool
    ) throws {
        guard admitted else { return }
        try consumer?.revalidateForPublication()
        try performance?.revalidateForPublication()
        try preflight?.revalidateForPublication()
        if let preparation, preparation.rawCapture.captureComplete { try preparation.revalidateForPublication() }
        if let uiPreparation, uiPreparation.rawCapture.captureComplete { try uiPreparation.revalidateForPublication() }
    }

    private func validateCapturedCommands(
        _ evidence: NotikaBuildSessionTerminalEvidence, admitCaptures: Bool, allowFixtureCommands: Bool
    ) throws {
        let observations = evidence.outcome?.observations ?? []
        guard observations.count == evidence.capturedPhases.count else {
            throw NotikaBuildSessionError.invalidSchema("capturedPhases")
        }
        guard admitCaptures, !allowFixtureCommands else { return }
        for (observation, capsule) in zip(observations, evidence.capturedPhases) where capsule.rawCapture.captureComplete {
            guard capsule.command.executable.utf8.elementsEqual("/usr/bin/xcodebuild".utf8),
                  capsule.command.arguments.map({ Data($0.utf8) }) == observation.phase.arguments.map({ Data($0.utf8) }),
                  capsule.command.workingDirectory.utf8.elementsEqual(canonicalRepository.utf8) else {
                throw NotikaBuildSessionError.invalidSchema("capturedPhaseCommand")
            }
        }
    }

    private func validateOwnershipAndDirectories() throws {
        guard leases.leases.count == 1, leases.leases[0].mode == .shared,
              leases.leases[0].resource.value.utf8.elementsEqual(writerResource.utf8),
              leases.inheritedDescriptors.count == 1 else { throw NotikaBuildSessionError.expiredOwnership }
        try repository.revalidate()
        for (index, pin) in directories.enumerated() {
            let current = try sessionStat(pin.descriptor.value)
            guard sessionDirectoryEqual(current, pin.identity) else { throw NotikaBuildSessionError.identityChanged(pin.name) }
            if index > 0 {
                let named = try sessionStatAt(directories[index - 1].descriptor.value, pin.name)
                guard sessionDirectoryEqual(named, current) else { throw NotikaBuildSessionError.identityChanged(pin.name) }
            } else {
                guard Int64(current.st_dev) == repository.fingerprint.device,
                      UInt64(current.st_ino) == repository.fingerprint.inode else {
                    throw NotikaBuildSessionError.identityChanged(canonicalRepository)
                }
            }
        }
    }

    private func close() {
        state.withLock { state in
            state.active = false
            state.capsules = []
            state.resultSummary = nil
            state.resultPreparation = nil
            state.resultConsumer = nil
            state.performanceEvidence = nil
            state.preflightEvidence = nil
            state.simulatorPreparation = nil
            state.uiPreparation = nil
            state.terminal = nil
            state.progress = nil
        }
        // Only close references. Never unlock inherited open-file descriptions.
        leases.release()
    }
}

private final class SessionOwnedDescriptor: @unchecked Sendable {
    let value: Int32
    init(_ value: Int32) { self.value = value }
    deinit { _ = Darwin.close(value) }
}

private struct SessionDirectoryPin: Sendable {
    let descriptor: SessionOwnedDescriptor
    let identity: stat
    let name: String
}

private func sessionOpenDirectories(repository: RetainedArtifactDirectory, runID: String) throws -> [SessionDirectoryPin] {
    let descriptor = Darwin.open(repository.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw sessionIO("open repository") }
    let owner = SessionOwnedDescriptor(descriptor)
    let identity = try sessionStat(descriptor)
    guard Int64(identity.st_dev) == repository.fingerprint.device,
          UInt64(identity.st_ino) == repository.fingerprint.inode else {
        throw NotikaBuildSessionError.identityChanged(repository.path)
    }
    var pins = [SessionDirectoryPin(descriptor: owner, identity: identity, name: repository.path)]
    for (name, exclusive) in [("Artifacts", false), ("AgentSessions", false), (runID, true)] {
        let parent = pins.last!.descriptor.value
        let created = name.withCString { mkdirat(parent, $0, 0o700) }
        if created != 0 {
            guard errno == EEXIST, !exclusive else { throw sessionIO("create session directory") }
        }
        let opened = name.withCString { openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard opened >= 0 else { throw sessionIO("open session directory") }
        let owned = SessionOwnedDescriptor(opened)
        let value = try sessionStat(opened)
        guard value.st_mode & S_IFMT == S_IFDIR, value.st_uid == geteuid(),
              value.st_mode & 0o7022 == 0, !exclusive || value.st_mode & 0o777 == 0o700,
              sessionDirectoryEqual(value, try sessionStatAt(parent, name)) else {
            throw NotikaBuildSessionError.unsafePath(name)
        }
        pins.append(.init(descriptor: owned, identity: value, name: name))
        if created == 0, fsync(parent) != 0 { throw sessionIO("sync session parent") }
    }
    try repository.revalidate()
    return pins
}

/// A private hard link and readonly descriptor remain retained alongside the
/// public name. Neither mutable generic manifests nor decoded paths grant this
/// capability. The final descriptor is never exported to native commands.
private final class SessionSealedJSON: @unchecked Sendable {
    let report: NotikaBuildSessionReport
    let descriptor: SessionOwnedDescriptor
    let watch: SessionOwnedDescriptor
    let fingerprint: stat
    let publicName: String
    let privateName: String

    private init(
        report: NotikaBuildSessionReport, descriptor: SessionOwnedDescriptor, watch: SessionOwnedDescriptor,
        fingerprint: stat, publicName: String, privateName: String
    ) {
        self.report = report
        self.descriptor = descriptor
        self.watch = watch
        self.fingerprint = fingerprint
        self.publicName = publicName
        self.privateName = privateName
    }

    static func publish(
        _ report: NotikaBuildSessionReport, filename: String, directory: SessionDirectoryPin,
        validateBeforeLink: () throws -> Void
    ) throws -> SessionSealedJSON {
        let parent = directory.descriptor.value
        let privateName = ".agentbuild-" + filename + "-" + UUID().uuidString + ".sealed"
        var writer = privateName.withCString {
            openat(parent, $0, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        }
        guard writer >= 0 else { throw sessionIO("create private report") }
        // Keep the only locally owned writer inside this scope. Any error
        // quarantines the exact owned inode; foreign public names are preserved.
        var admittedReader: SessionOwnedDescriptor?
        var succeeded = false
        defer {
            if !succeeded {
                let quarantine = writer >= 0 ? writer : admittedReader?.value
                if let quarantine { _ = fchmod(quarantine, 0o000); _ = fsync(quarantine) }
            }
            if writer >= 0 { let retiring = writer; writer = -1; _ = Darwin.close(retiring) }
        }
        let created = try sessionStat(writer)
        guard created.st_mode & S_IFMT == S_IFREG, created.st_uid == geteuid(), created.st_nlink == 1 else {
            throw NotikaBuildSessionError.unsafePath(privateName)
        }
        guard fchmod(writer, 0o600) == 0 else { throw sessionIO("set report permissions") }
        try sessionWriteAll(writer, report.originalData)
        guard fsync(writer) == 0 else { throw sessionIO("sync private report") }
        let reader = privateName.withCString { openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard reader >= 0 else { throw sessionIO("retain readonly report") }
        let readonly = SessionOwnedDescriptor(reader)
        admittedReader = readonly
        guard sessionSameInode(try sessionStat(reader), created) else { throw NotikaBuildSessionError.identityChanged(privateName) }
        guard fchmod(writer, 0o000) == 0 else { throw sessionIO("quarantine report writer") }
        let retiring = writer
        writer = -1
        guard Darwin.close(retiring) == 0 else { throw sessionIO("retire report writer") }
        guard fchmod(reader, 0o400) == 0, fsync(reader) == 0 else { throw sessionIO("seal readonly report") }
        let watch = try sessionOpenWatch(reader)
        try sessionRequireBytes(reader, report.originalData)
        let sealed = try sessionStat(reader)
        guard sealed.st_mode & 0o7777 == 0o400, sealed.st_nlink == 1,
              sessionSameInode(sealed, created),
              sessionFileEqual(sealed, try sessionStatAt(parent, privateName)) else {
            throw NotikaBuildSessionError.identityChanged(privateName)
        }
        try validateBeforeLink()
        try sessionCheckWatch(watch.value)
        try sessionRequireBytes(reader, report.originalData)
        guard sessionFileEqual(sealed, try sessionStat(reader)),
              sessionFileEqual(sealed, try sessionStatAt(parent, privateName)) else {
            throw NotikaBuildSessionError.identityChanged(privateName)
        }
        let linked = privateName.withCString { source in filename.withCString { target in linkat(parent, source, parent, target, 0) } }
        guard linked == 0 else { throw sessionIO("publish report without overwrite") }
        guard fsync(parent) == 0 else { throw sessionIO("sync published report directory") }
        let fingerprint = try sessionStat(reader)
        guard fingerprint.st_nlink == 2, fingerprint.st_mode & 0o7777 == 0o400,
              sessionSameInode(fingerprint, created) else { throw NotikaBuildSessionError.identityChanged(filename) }
        let result = SessionSealedJSON(report: report, descriptor: readonly, watch: watch, fingerprint: fingerprint,
                                      publicName: filename, privateName: privateName)
        try result.revalidate(directory: directory)
        succeeded = true
        return result
    }

    func revalidate(directory: SessionDirectoryPin) throws {
        try sessionCheckWatch(watch.value)
        let current = try sessionStat(descriptor.value)
        guard sessionFileEqual(current, fingerprint), current.st_nlink == 2, current.st_uid == geteuid(),
              current.st_mode & S_IFMT == S_IFREG, current.st_mode & 0o7777 == 0o400,
              sessionFileEqual(current, try sessionStatAt(directory.descriptor.value, publicName)),
              sessionFileEqual(current, try sessionStatAt(directory.descriptor.value, privateName)) else {
            throw NotikaBuildSessionError.identityChanged(publicName)
        }
        try sessionRequireBytes(descriptor.value, report.originalData)
        guard sessionFileEqual(try sessionStat(descriptor.value), fingerprint) else {
            throw NotikaBuildSessionError.identityChanged(publicName)
        }
        try sessionCheckWatch(watch.value)
    }
}

private func sessionIO(_ operation: String) -> NotikaBuildSessionError { .io(operation: operation, code: errno) }
private func sessionStat(_ descriptor: Int32) throws -> stat {
    var value = stat()
    guard fstat(descriptor, &value) == 0 else { throw sessionIO("stat retained session inode") }
    return value
}
private func sessionStatAt(_ parent: Int32, _ name: String) throws -> stat {
    var value = stat()
    guard name.withCString({ fstatat(parent, $0, &value, AT_SYMLINK_NOFOLLOW) }) == 0 else {
        throw sessionIO("stat retained session name")
    }
    return value
}
private func sessionSameInode(_ left: stat, _ right: stat) -> Bool { left.st_dev == right.st_dev && left.st_ino == right.st_ino }
private func sessionDirectoryEqual(_ left: stat, _ right: stat) -> Bool {
    sessionSameInode(left, right) && left.st_mode == right.st_mode && left.st_uid == right.st_uid && left.st_gid == right.st_gid
}
private func sessionFileEqual(_ left: stat, _ right: stat) -> Bool {
    sessionDirectoryEqual(left, right) && left.st_size == right.st_size && left.st_nlink == right.st_nlink
        && left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec && left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec
        && left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec && left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec
}
private func sessionWriteAll(_ descriptor: Int32, _ bytes: Data) throws {
    try bytes.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let count = pwrite(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, off_t(offset))
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw sessionIO("write private report") }
            offset += count
        }
    }
}
private func sessionRequireBytes(_ descriptor: Int32, _ expected: Data) throws {
    let before = try sessionStat(descriptor)
    guard before.st_size == expected.count, expected.count <= StrictJSONLimits.standard.maximumBytes else {
        throw NotikaBuildSessionError.identityChanged("report bytes")
    }
    var actual = Data(count: expected.count + 1)
    let count = try actual.withUnsafeMutableBytes { buffer -> Int in
        var offset = 0
        while offset < buffer.count {
            let count = pread(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, off_t(offset))
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw sessionIO("read retained report") }
            if count == 0 { break }
            offset += count
        }
        return offset
    }
    actual.count = count
    guard actual == expected, sessionFileEqual(before, try sessionStat(descriptor)) else {
        throw NotikaBuildSessionError.identityChanged("report bytes")
    }
}
private func sessionOpenWatch(_ descriptor: Int32) throws -> SessionOwnedDescriptor {
    let queue = kqueue()
    guard queue >= 0 else { throw sessionIO("create report watch") }
    let owned = SessionOwnedDescriptor(queue)
    guard fcntl(queue, F_SETFD, FD_CLOEXEC) == 0 else { throw sessionIO("set report watch close-on-exec") }
    var event = kevent()
    event.ident = UInt(descriptor)
    event.filter = Int16(EVFILT_VNODE)
    event.flags = UInt16(EV_ADD | EV_CLEAR)
    event.fflags = UInt32(NOTE_WRITE | NOTE_EXTEND | NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE | NOTE_ATTRIB)
    guard sessionKevent(queue, &event, 1, nil, 0, nil) == 0 else { throw sessionIO("arm report watch") }
    return owned
}
private func sessionCheckWatch(_ queue: Int32) throws {
    var event = kevent(), timeout = timespec(tv_sec: 0, tv_nsec: 0)
    var count: Int32
    repeat { count = sessionKevent(queue, nil, 0, &event, 1, &timeout) } while count < 0 && errno == EINTR
    guard count >= 0 else { throw sessionIO("poll report watch") }
    guard count == 0 else { throw NotikaBuildSessionError.identityChanged("report vnode mutation") }
}
@_silgen_name("kevent")
private func sessionKevent(
    _ queue: Int32, _ changes: UnsafePointer<kevent>?, _ changeCount: Int32,
    _ events: UnsafeMutablePointer<kevent>?, _ eventCount: Int32,
    _ timeout: UnsafePointer<timespec>?
) -> Int32
