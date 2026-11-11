import AgentBuildCore
import AgentLeaseCore
import Darwin
import Dispatch
import Foundation

public enum ABDiffProjectDriverError: Error, Sendable {
    case invalidArgument(String)
    case ownershipExpired
    case changedInput(String)
    case unavailableTool(String)
    case nativeObservationMissing
    case evidence(String)
    case io(String, Int32)
}

/// ABDiff has its own namespaces; historical Notika cache identities stay intact.
internal final class ABDiffProjectOwnership: Sendable {
    let plan: ABDiffProjectPlan
    let runID: String
    let registry: String
    let session: ControllerSessionArtifacts
    let repository: RetainedArtifactDirectory
    private let held: [LeaseSet]
    private let cache: RetainedArtifactDirectory?

    private init(plan: ABDiffProjectPlan, runID: String, registry: String,
                 held: [LeaseSet], session: ControllerSessionArtifacts,
                 repository: RetainedArtifactDirectory, cache: RetainedArtifactDirectory?) {
        self.plan = plan; self.runID = runID; self.registry = registry
        self.held = held; self.session = session; self.repository = repository; self.cache = cache
    }

    static func withOwnership<T: Sendable>(
        plan: ABDiffProjectPlan, runID: String, environment: [String: String], waitSeconds: Double?,
        operation: @Sendable (ABDiffProjectOwnership) async throws -> T
    ) async throws -> T {
        if let waitSeconds, !waitSeconds.isFinite || waitSeconds < 0 {
            throw ABDiffProjectDriverError.invalidArgument("waitSeconds")
        }
        let registry = try environment["AGENTLEASE_HOME"] ?? HostCompilationAdmission.selectedRoot(environment: [:])
        guard registry.hasPrefix("/"), !registry.utf8.contains(0) else {
            throw ABDiffProjectDriverError.invalidArgument("AGENTLEASE_HOME")
        }
        let paths = try AgentLeasePaths.open(selectedRoot: registry)
        let started = DispatchTime.now().uptimeNanoseconds
        let timestamp = RunRecord.timestamp(), pid = getpid()
        let resourceSpecs: [(String, LeaseMode)] = [
            ("abdiff:sessions:" + plan.repository, .shared),
            ("abdiff:graph:" + plan.repository, plan.request.action == .generate ? .exclusive : .shared),
        ] + (plan.request.action == .generate ? [] : [
            ("abdiff:cache-policy:" + plan.repository, .shared),
            ("abdiff:cache:" + plan.cacheDirectory, .exclusive),
        ]) + (plan.request.platform == "ipad-device" ? [
            ("device:ios:" + plan.request.device!, .exclusive),
        ] : [])
        var held: [LeaseSet] = []
        defer { for item in held.reversed() { item.release() } }
        for (resource, mode) in resourceSpecs {
            try Task.checkCancellation()
            let remaining: Double?
            if let waitSeconds, waitSeconds > 0 {
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
                guard elapsed < waitSeconds else { throw LeaseSetError.timedOut(resource) }
                remaining = waitSeconds - elapsed
            } else { remaining = waitSeconds }
            let set = try ResourceSet(exclusive: mode == .exclusive ? [resource] : [], shared: mode == .shared ? [resource] : [])
            held.append(try await LeaseSet.acquire(set, paths: paths, waitSeconds: remaining, initialMetadata: { lease in
                LockMetadata(resourceName: lease.resource.value, leaseMode: lease.mode, runID: runID,
                    coordinatorPID: pid, childPID: nil, mode: .run, state: .acquired,
                    label: "ABDiff " + plan.request.route, bead: nil, acquiredAt: timestamp)
            }))
        }
        let repository = try RetainedArtifactDirectory(path: plan.repository)
        let session = try ControllerSessionArtifacts(repository: plan.repository, runID: runID)
        let cache: RetainedArtifactDirectory?
        if plan.request.action != .generate {
            guard plan.cacheDirectory.hasPrefix(plan.repository + "/DerivedData/AgentCaches/abdiff-") else {
                throw ABDiffProjectDriverError.invalidArgument("cache directory")
            }
            try abdiffCreateDirectories(
                repositoryDescriptor: session.repositoryDescriptor,
                components: ["DerivedData", "AgentCaches", URL(fileURLWithPath: plan.cacheDirectory).lastPathComponent]
            )
            cache = try RetainedArtifactDirectory(path: plan.cacheDirectory)
        } else { cache = nil }
        let ownership = ABDiffProjectOwnership(plan: plan, runID: runID, registry: registry,
            held: held, session: session, repository: repository, cache: cache)
        try ownership.revalidate()
        return try await operation(ownership)
    }

    func descriptors() throws -> [Int32] {
        let values = held.flatMap(\.inheritedDescriptors)
        guard values.count == held.count else { throw ABDiffProjectDriverError.ownershipExpired }
        return values
    }

    func revalidate() throws {
        _ = try descriptors()
        try repository.revalidate(); try cache?.revalidate(); try session.revalidate()
    }
}

private func abdiffCreateDirectories(repositoryDescriptor: Int32, components: [String]) throws {
    var parent = fcntl(repositoryDescriptor, F_DUPFD_CLOEXEC, 3)
    guard parent >= 3 else { throw ABDiffProjectDriverError.io("retain repository", errno) }
    defer { _ = close(parent) }
    for component in components {
        guard !component.isEmpty, component != ".", component != "..", !component.contains("/") else {
            throw ABDiffProjectDriverError.invalidArgument("directory component")
        }
        if mkdirat(parent, component, 0o700) != 0, errno != EEXIST {
            throw ABDiffProjectDriverError.io("create project cache", errno)
        }
        let child = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 3 else { throw ABDiffProjectDriverError.io("open project cache", errno) }
        var identity = stat()
        guard fstat(child, &identity) == 0, identity.st_uid == geteuid(), identity.st_mode & 0o7022 == 0 else {
            _ = close(child)
            throw ABDiffProjectDriverError.evidence("unsafe project cache")
        }
        _ = close(parent); parent = child
    }
}
