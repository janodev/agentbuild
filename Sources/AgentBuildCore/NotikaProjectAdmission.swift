import AgentLeaseCore
import Darwin
import Dispatch
import Foundation

public enum ProjectAdmissionError: Error, Equatable, Sendable {
    case invalidLabel
    case invalidRunID
    case expiredOwnership
}

/// The ordered project resources are separate from account compilation admission.
/// Paths are canonical identity inputs; this model grants no filesystem custody.
public struct NotikaProjectOwnershipPlan: Equatable, Sendable {
    public let canonicalWorktree: String
    public let cacheDirectory: String?
    public let orderedLeases: [ResourceLease]

    public init(generationFor canonicalWorktree: String) throws {
        self.canonicalWorktree = canonicalWorktree
        cacheDirectory = nil
        orderedLeases = [try Self.lease(
            CacheCompatibilityIdentity.graphResourceName(canonicalWorktree: canonicalWorktree), .exclusive
        )]
    }

    /// Rust helpers share the authored/generated graph but select their own
    /// isolated cache through the Rust executor. They never borrow a fabricated
    /// Xcode cache identity or its namespace policy.
    public init(rustTestFor canonicalWorktree: String) throws {
        self.canonicalWorktree = canonicalWorktree
        cacheDirectory = nil
        orderedLeases = [try Self.lease(
            CacheCompatibilityIdentity.graphResourceName(canonicalWorktree: canonicalWorktree), .shared
        )]
    }

    public init(identity: CacheCompatibilityIdentity, admittedCacheKey: String? = nil) throws {
        let key = try admittedCacheKey ?? identity.cacheKey()
        try identity.validateAdmission(admittedExecutionDigest: identity.executionDigest(), cacheKey: key)
        canonicalWorktree = identity.canonicalWorktree
        let base = canonicalWorktree == "/" ? "" : canonicalWorktree
        let cache = base + "/DerivedData/AgentCaches/" + key
        cacheDirectory = cache
        orderedLeases = [
            try Self.lease(CacheCompatibilityIdentity.graphResourceName(canonicalWorktree: canonicalWorktree), .shared),
            try Self.lease(CacheCompatibilityIdentity.cachePolicyResourceName(canonicalWorktree: canonicalWorktree), .shared),
            try Self.lease(CacheCompatibilityIdentity.cacheResourceName(
                canonicalWorktree: canonicalWorktree, canonicalCachePath: cache
            ), .exclusive),
        ]
    }

    private static func lease(_ resource: String, _ mode: LeaseMode) throws -> ResourceLease {
        ResourceLease(resource: try ResourceName(resource), mode: mode)
    }
}

/// Acquires graph, then namespace policy, then the compatible cache. Never sort
/// these different layers together: their order is shared with Notika cleanup.
public struct NotikaProjectAdmission: Sendable {
    public init() {}

    public func withOwnership<Result: Sendable>(
        _ plan: NotikaProjectOwnershipPlan,
        registryRoot: String,
        label: String,
        runID: String = UUID().uuidString,
        waitSeconds: Double? = nil,
        onContention: @Sendable (ResourceLease, BoundedMetadataRead) -> Void = { _, _ in },
        operation: @Sendable (ProjectOwnership) async throws -> Result
    ) async throws -> Result {
        guard (1...256).contains(label.utf8.count),
              !label.unicodeScalars.contains(where: { $0.value <= 0x1f || (0x7f...0x9f).contains($0.value) }) else {
            throw ProjectAdmissionError.invalidLabel
        }
        guard let identifier = UUID(uuidString: runID), identifier.uuidString == runID else {
            throw ProjectAdmissionError.invalidRunID
        }
        if let waitSeconds, !waitSeconds.isFinite || waitSeconds < 0 {
            throw LeaseSetError.invalidWaitSeconds(waitSeconds)
        }
        let paths = try AgentLeasePaths.open(selectedRoot: registryRoot)
        let started = DispatchTime.now().uptimeNanoseconds
        let acquiredAt = RunRecord.timestamp()
        let coordinatorPID = getpid()
        var held: [LeaseSet] = []
        defer { for ownership in held.reversed() { ownership.release() } }
        for lease in plan.orderedLeases {
            try Task.checkCancellation()
            let resources = try ResourceSet(
                exclusive: lease.mode == .exclusive ? [lease.resource.value] : [],
                shared: lease.mode == .shared ? [lease.resource.value] : []
            )
            let remaining: Double?
            if let waitSeconds, waitSeconds > 0 {
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
                guard elapsed < waitSeconds else { throw LeaseSetError.timedOut(lease.resource.value) }
                remaining = waitSeconds - elapsed
            } else {
                remaining = waitSeconds
            }
            held.append(try await LeaseSet.acquire(
                resources, paths: paths, waitSeconds: remaining,
                initialMetadata: { resource in
                    LockMetadata(resourceName: resource.resource.value, leaseMode: resource.mode,
                                 runID: runID, coordinatorPID: coordinatorPID, childPID: nil,
                                 mode: .run, state: .acquired, label: label, bead: nil,
                                 acquiredAt: acquiredAt)
                },
                onContention: onContention
            ))
        }
        try Task.checkCancellation()
        if let waitSeconds, waitSeconds > 0,
           Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000 >= waitSeconds {
            throw LeaseSetError.timedOut(plan.orderedLeases.last!.resource.value)
        }
        return try await operation(ProjectOwnership(plan: plan, paths: paths, leases: held, runID: runID))
    }
}

/// Borrowed inside the admission scope. Children must finish and be reaped
/// before returning. Owner-death supervision is a separate execution layer.
public final class ProjectOwnership: Sendable {
    private let held: [LeaseSet]
    private let paths: AgentLeasePaths
    public let plan: NotikaProjectOwnershipPlan
    public let runID: String

    fileprivate init(plan: NotikaProjectOwnershipPlan, paths: AgentLeasePaths, leases: [LeaseSet], runID: String) {
        self.plan = plan
        self.paths = paths
        held = leases
        self.runID = runID
    }

    public var registryRoot: String { paths.rootPath }
    public var metadataWriteIssues: [MetadataWriteIssue] { held.flatMap(\.metadataWriteIssues) }

    public func inheritedDescriptors() throws -> [Int32] {
        let descriptors = held.flatMap(\.inheritedDescriptors)
        guard descriptors.count == plan.orderedLeases.count else { throw ProjectAdmissionError.expiredOwnership }
        return descriptors
    }

    public func inheritedLeaseDescriptors() throws -> [InheritedLeaseDescriptor] {
        let descriptors = held.flatMap(\.inheritedLeaseDescriptors)
        guard descriptors.count == plan.orderedLeases.count else { throw ProjectAdmissionError.expiredOwnership }
        return descriptors
    }
}
