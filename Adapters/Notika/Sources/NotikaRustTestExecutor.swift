import AgentBuildCore
import AgentLeaseCore
import CryptoKit
import Darwin
import Foundation

public enum NotikaRustTestError: Error, Equatable, Sendable {
    case invalidIdentity(String)
    case invalidBindings
    case ownershipMismatch
    case unsafePath(String)
    case unsafeMetadata
    case unavailableMise
    case invalidToolOutput
    case io(operation: String, code: Int32)
}

/// Exact direct-Rust cache compatibility material. No storage projection is
/// applied: Rust's schema-1 full identity digest supplies its 24-character key.
public struct NotikaRustCacheIdentity: Equatable, Sendable {
    public let repository: String
    public let family: NotikaRustTestFamily
    public let inputs: [String: String]
    public let misePath: String
    public let miseDigest: String
    public let rustc: String
    public let sysroot: String
    public let cargo: String

    public init(repository: String, family: NotikaRustTestFamily, inputs: [String: String], misePath: String,
                miseDigest: String, rustc: String, sysroot: String, cargo: String) throws {
        guard rustLiteralPath(repository), rustLiteralPath(misePath), rustLiteralPath(sysroot) else {
            throw NotikaRustTestError.invalidIdentity("paths")
        }
        guard Set(inputs.keys) == Set(Self.inputPaths(family)), inputs.values.allSatisfy(rustDigest), rustDigest(miseDigest) else {
            throw NotikaRustTestError.invalidIdentity("inputs")
        }
        guard [rustc, sysroot, cargo].allSatisfy({ !$0.isEmpty && $0.count <= 4096 && !$0.utf8.contains(0) }) else {
            throw NotikaRustTestError.invalidIdentity("toolchain")
        }
        self.repository = repository
        self.family = family
        self.inputs = inputs
        self.misePath = misePath
        self.miseDigest = miseDigest
        self.rustc = rustc
        self.sysroot = sysroot
        self.cargo = cargo
    }

    public var keyMaterial: CanonicalJSONValue {
        .object(["schemaVersion": .integer(1), "canonicalWorktree": .string(repository), "family": .string(family.rawValue),
                 "targetKind": .string("host-debug-cargo-test"), "inputs": .object(inputs.mapValues { .string($0) }),
                 "toolchain": .object(["mise": .object(["path": .string(misePath), "sha256": .string(miseDigest)]),
                                       "rustc": .string(rustc), "sysroot": .string(sysroot), "cargo": .string(cargo)])])
    }

    public var compatibilityFamily: CanonicalJSONValue {
        .object(["canonicalWorktree": .string(repository), "family": .string(family.rawValue), "targetKind": .string("host-debug-cargo-test")])
    }

    public func digest() throws -> String { try CanonicalJSONDigest.sha256(keyMaterial) }
    public func cacheKey() throws -> String { String(try digest().prefix(24)) }
    public var policyResource: String { "notika:rust-test-cache-policy:" + CanonicalJSONDigest.digest(Data(repository.utf8)) }
    public func cacheResource() throws -> String {
        "notika:rust-test-cache:" + CanonicalJSONDigest.digest(Data(repository.utf8)) + ":" + (try cacheKey())
    }
    public var crate: String { family == .svg ? "SVGPathImporter" : "LiteParseBridge" }
    public var licenseScript: String { family == .svg ? "svg-path-importer-licenses.sh" : "liteparse-bridge-licenses.sh" }
    public var pins: [String] { family == .liteparse ? ["rust@1.88.0"] : [] }

    public static func inputPaths(_ family: NotikaRustTestFamily) -> [String] {
        let crate = family == .svg ? "SVGPathImporter" : "LiteParseBridge"
        let script = family == .svg ? "svg-path-importer-licenses.sh" : "liteparse-bridge-licenses.sh"
        return [".mise.toml", "Rust/" + crate + "/Cargo.toml", "Rust/" + crate + "/Cargo.lock", "Rust/" + crate + "/about.hbs", "Scripts/bridges/" + script]
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.keyMaterial == rhs.keyMaterial }
}

public struct NotikaRustTestExecutionBindings: Equatable, Sendable {
    public let sessionID: String
    public let temporaryDirectory: String

    public init(sessionID: String, temporaryDirectory: String) throws {
        guard rustSessionID(sessionID), rustLiteralPath(temporaryDirectory) else { throw NotikaRustTestError.invalidBindings }
        self.sessionID = sessionID
        self.temporaryDirectory = temporaryDirectory
    }
}

/// Observed facts only. Pure usage admission does not acquire leases or grant
/// mutation/retention authority over a Rust cache directory.
public struct NotikaRustCacheObservation: Equatable, Sendable {
    public let repository: String
    public let cacheRoot: String
    public let cachePath: String
    public let cacheKey: String
    public private(set) var deviceID: UInt64
    public let inode: UInt64
    public let ownerUID: UInt32

    public init(identity: NotikaRustCacheIdentity, deviceID: UInt64, inode: UInt64, ownerUID: UInt32) throws {
        repository = identity.repository
        cacheRoot = identity.repository + "/DerivedData/RustTestCaches"
        cacheKey = try identity.cacheKey()
        cachePath = cacheRoot + "/" + cacheKey
        self.deviceID = deviceID
        self.inode = inode
        self.ownerUID = ownerUID
    }

    fileprivate func replacingDeviceID(_ deviceID: UInt64) -> Self {
        var observation = self
        observation.deviceID = deviceID
        return observation
    }
}

/// Reference-compatible Rust usage schema 1; unknown schemas/fields/bindings
/// remain errors rather than evidence that may be overwritten.
public struct NotikaRustCacheUsageRecord: Equatable, Sendable {
    public static let maximumBytes = 32 * 1024
    public let document: StrictJSONDocument
    public let createdAt: String
    public let lastUsedAt: String
    public let lastSessionID: String

    /// Without `boot`, the stored device and inode must equal the observation.
    /// With the current boot, a record last written during an earlier boot is
    /// admitted by its inode alone, because its device number may be stale.
    public init(
        data: Data, identity: NotikaRustCacheIdentity, observation: NotikaRustCacheObservation, boot: DirectoryIdentityBoot? = nil
    ) throws {
        let document = try StrictJSONDocument(data: data, limits: StrictJSONLimits(maximumBytes: Self.maximumBytes))
        let object = try document.root.requireObject()
        func string(_ key: String) throws -> String {
            guard case .string(let value) = try object.requiredValue(forKey: key) else { throw NotikaRustTestError.unsafeMetadata }
            return value
        }
        let created = try string("createdAt"), used = try string("lastUsedAt"), session = try string("lastSessionID")
        guard rustSessionID(session), let first = rustParseTime(created), let last = rustParseTime(used), first <= last,
              observation.ownerUID == geteuid() else { throw NotikaRustTestError.unsafeMetadata }
        // Every publication rewrites the directory identity, so the last use is
        // when the stored device number was observed. Exact material equality
        // below still binds every other field, including the inode.
        var admittedObservation = observation
        if let boot, case .object(let directory)? = object.value(forKey: "directoryIdentity"),
           case .number(let device)? = directory.value(forKey: "deviceID"), let storedDeviceID = try? device.uint64(),
           storedDeviceID != observation.deviceID,
           boot.admits(storedDeviceID: storedDeviceID, storedInode: observation.inode,
                       recordedAtMicrosecondsSince1970: last, observedDeviceID: observation.deviceID,
                       observedInode: observation.inode) {
            admittedObservation = observation.replacingDeviceID(storedDeviceID)
        }
        let expected = try Self.material(
            identity: identity, observation: admittedObservation, sessionID: session, createdAt: created, lastUsedAt: used
        )
        // A parsed positive JSON integer uses the unsigned representation,
        // whereas producer constants may use signed integers. JSON bytes, not
        // that internal enum choice, define exact schema/material equality.
        guard try CanonicalJSONDigest.encode(rustCanonicalJSON(document.root)) == CanonicalJSONDigest.encode(expected) else {
            throw NotikaRustTestError.unsafeMetadata
        }
        self.document = document
        createdAt = created
        lastUsedAt = used
        lastSessionID = session
    }

    public static func make(identity: NotikaRustCacheIdentity, observation: NotikaRustCacheObservation,
                            sessionID: String, usedAt: Date, createdAt: String? = nil) throws -> Self {
        let used = try rustTimestamp(usedAt)
        let created: String
        if let createdAt {
            guard let microseconds = rustParseTime(createdAt) else { throw NotikaRustTestError.unsafeMetadata }
            created = rustFormatMicroseconds(microseconds)
        } else { created = used }
        var data = try CanonicalJSONDigest.encode(material(identity: identity, observation: observation, sessionID: sessionID,
                                                           createdAt: created, lastUsedAt: used))
        data.append(10)
        return try Self(data: data, identity: identity, observation: observation)
    }

    private static func material(identity: NotikaRustCacheIdentity, observation: NotikaRustCacheObservation,
                                 sessionID: String, createdAt: String, lastUsedAt: String) throws -> CanonicalJSONValue {
        guard observation.repository.utf8.elementsEqual(identity.repository.utf8), observation.cacheKey == (try identity.cacheKey()),
              observation.cachePath == identity.repository + "/DerivedData/RustTestCaches/" + observation.cacheKey else {
            throw NotikaRustTestError.unsafeMetadata
        }
        return .object([
            "schemaVersion": .integer(1), "resourceID": .string("notika.rust-test-cache-usage"), "repository": .string(observation.repository),
            "cacheRoot": .string(observation.cacheRoot), "cacheKey": .string(observation.cacheKey), "cachePath": .string(observation.cachePath),
            "directoryIdentity": .object(["deviceID": .unsignedInteger(observation.deviceID), "inode": .unsignedInteger(observation.inode)]),
            "ownerUID": .unsignedInteger(UInt64(observation.ownerUID)), "ownershipAuthority": .string("agentlease-kernel-lock"),
            "agentLeaseResource": .string(try identity.cacheResource()), "compatibilityFamily": identity.compatibilityFamily,
            "compatibilityFamilySHA256": .string(try CanonicalJSONDigest.sha256(identity.compatibilityFamily)),
            "compatibilityKeyMaterial": identity.keyMaterial, "compatibilityIdentitySHA256": .string(try identity.digest()),
            "createdAt": .string(createdAt), "lastUsedAt": .string(lastUsedAt), "lastSessionID": .string(sessionID),
        ])
    }
}

public struct NotikaRustTestReport: Sendable {
    public let identity: NotikaRustCacheIdentity
    public let cache: NotikaRustCacheObservation
    public let sourceBeforeDigest: String
    public let sourceAfterDigest: String?
    public let commands: [DarwinWorkloadCommand]
    public let outcomes: [NotikaPreflightCommandOutcome]
    public let outcome: NotikaPreflightCommandOutcome
    public let usage: NotikaRustCacheUsageRecord?
    public let metadataWriteIssues: [MetadataWriteIssue]
}

/// Direct native Rust license/test execution beneath borrowed project ownership.
/// Native adapters must await quiescence before returning, including quarantine
/// cases. Cooperative leases are not hostile-account filesystem isolation.
public struct NotikaRustTestExecutor: Sendable {
    public typealias IdentityOperation = @Sendable () async throws -> NotikaRustCacheIdentity
    public typealias SourceOperation = @Sendable () async throws -> String
    public init() {}

    public static func environment(from inherited: [String: String]) throws -> [String: String] {
        let names: Set<String> = ["AGENTLEASE_HOME", "HOME", "LANG", "LC_ALL", "LC_CTYPE", "LOGNAME", "PATH", "TERM", "USER", "__CF_USER_TEXT_ENCODING"]
        var result: [String: String] = [:]
        for name in names {
            guard let value = inherited[name] else { continue }
            guard !value.utf8.contains(0) else { throw NotikaRustTestError.invalidIdentity("environment:" + name) }
            result[name] = value
        }
        return result
    }

    public static func observeIdentity(repository: String, family: NotikaRustTestFamily, environment: [String: String],
                                       capture: any RepositoryCommandCapturing) async throws -> NotikaRustCacheIdentity {
        let clean = try Self.environment(from: environment)
        guard let canonical = try rustRealPath(repository), canonical.utf8.elementsEqual(repository.utf8) else {
            throw NotikaRustTestError.invalidIdentity("repository")
        }
        var inputs: [String: String] = [:]
        for relative in NotikaRustCacheIdentity.inputPaths(family) {
            let path = repository + "/" + relative
            guard let resolved = try rustRealPath(path), rustWithin(resolved, repository),
                  (try rustNamedStatus(path)?.st_mode ?? 0) & S_IFMT == S_IFREG else { throw NotikaRustTestError.unsafePath(path) }
            inputs[relative] = try rustHashFile(resolved)
        }
        let mise = try rustMise(repository: repository, environment: clean)
        var values: [String] = []
        let pins = family == .liteparse ? ["rust@1.88.0"] : []
        for command in [["rustc", "--version", "--verbose"], ["rustc", "--print", "sysroot"], ["cargo", "--version"]] {
            let bytes = try await capture.capture(arguments: ["mise", "exec"] + pins + ["--"] + command, workingDirectory: repository, environment: clean)
            guard String(data: bytes, encoding: .utf8) != nil else { throw NotikaRustTestError.invalidToolOutput }
            values.append(repositoryDecodedText(bytes))
        }
        return try NotikaRustCacheIdentity(repository: repository, family: family, inputs: inputs, misePath: mise,
                                          miseDigest: rustHashFile(mise), rustc: values[0], sysroot: values[1], cargo: values[2])
    }

    public func run(
        family: NotikaRustTestFamily, context: NotikaPreflightRustContext, bindings: NotikaRustTestExecutionBindings,
        capture: (any RepositoryCommandCapturing)? = nil, identityOperation: IdentityOperation? = nil,
        sourceOperation: SourceOperation? = nil, commandOperation: NotikaDevelopmentPreflight.CommandOperation,
        waitSeconds: Double? = nil, usedAt: Date = Date()
    ) async throws -> NotikaRustTestReport {
        let projectDescriptors = try context.ownership.inheritedDescriptors()
        guard context.repository.utf8.elementsEqual(context.ownership.plan.canonicalWorktree.utf8),
              context.ownership.plan.orderedLeases.first?.mode == .shared,
              context.ownership.plan.orderedLeases.first?.resource.value == (try CacheCompatibilityIdentity.graphResourceName(canonicalWorktree: context.repository)),
              Set(context.retainedLockDescriptors).isSuperset(of: Set(projectDescriptors)),
              context.retainedLockDescriptors.allSatisfy({ fcntl($0, F_GETFD) >= 0 }) else { throw NotikaRustTestError.ownershipMismatch }
        if let waitSeconds, !waitSeconds.isFinite || waitSeconds < 0 { throw LeaseSetError.invalidWaitSeconds(waitSeconds) }
        let clean = try Self.environment(from: context.environment)
        let rawCapture = try capture ?? RepositoryCommandCapture()
        let identity: NotikaRustCacheIdentity
        if let identityOperation { identity = try await identityOperation() }
        else { identity = try await Self.observeIdentity(repository: context.repository, family: family, environment: clean, capture: rawCapture) }
        guard identity.family == family, identity.repository.utf8.elementsEqual(context.repository.utf8) else { throw NotikaRustTestError.ownershipMismatch }
        let source: SourceOperation
        if let sourceOperation { source = sourceOperation }
        else {
            let provider = try NotikaRepositoryIdentity(repository: context.repository, capture: rawCapture, environment: clean)
            source = { try await provider.sourceIdentity().digest() }
        }
        let opening = try await source()
        guard rustDigest(opening) else { throw NotikaRustTestError.invalidIdentity("source") }
        let paths = try AgentLeasePaths.open(selectedRoot: context.ownership.registryRoot)
        let start = ContinuousClock.now
        func remaining() throws -> Double? {
            guard let waitSeconds, waitSeconds > 0 else { return waitSeconds }
            let elapsed = start.duration(to: .now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            guard seconds < waitSeconds else { throw LeaseSetError.timedOut(try identity.cacheResource()) }
            return waitSeconds - seconds
        }
        let policy = try await rustAcquire(identity.policyResource, mode: .shared, paths: paths, sessionID: bindings.sessionID, waitSeconds: remaining())
        defer { policy.release() }
        let cacheLease = try await rustAcquire(identity.cacheResource(), mode: .exclusive, paths: paths, sessionID: bindings.sessionID, waitSeconds: remaining())
        defer { cacheLease.release() }
        let custody = try RustCacheCustody(identity: identity, ownership: context.ownership, policy: policy, cacheLease: cacheLease,
                                          temporaryDirectory: bindings.temporaryDirectory)
        let existing = try custody.readUsage()
        var child = clean
        child["CARGO_TARGET_DIR"] = custody.observation.cachePath + "/target"
        child["CARGO_HOME"] = custody.observation.cachePath + "/cargo-home"
        child["TMPDIR"] = bindings.temporaryDirectory + "/"
        let license = try DarwinWorkloadCommand(executable: context.repository + "/Scripts/bridges/" + identity.licenseScript,
                                               arguments: ["check"], workingDirectory: context.repository, environment: child)
        let cargo = try DarwinWorkloadCommand(executable: identity.misePath,
                                             arguments: ["exec"] + identity.pins + ["--", "cargo", "test", "--locked", "--manifest-path", "Rust/" + identity.crate + "/Cargo.toml"],
                                             workingDirectory: context.repository, environment: child)
        let descriptors = context.retainedLockDescriptors + policy.inheritedDescriptors + cacheLease.inheritedDescriptors
        var commands: [DarwinWorkloadCommand] = [], outcomes: [NotikaPreflightCommandOutcome] = []
        let completed = try await HostCompilationAdmission().withLease(environment: context.environment, label: "notika-rust-test:" + family.rawValue,
                                                                       waitSeconds: remaining()) { compile in
            var executed: [DarwinWorkloadCommand] = [], results: [NotikaPreflightCommandOutcome] = []
            for command in [license, cargo] {
                try Task.checkCancellation()
                try custody.revalidate()
                let result = try await commandOperation(command, descriptors + compile.inheritedDescriptors())
                executed.append(command); results.append(result)
                if !result.succeeded { break }
            }
            return RustCommands(commands: executed, outcomes: results, metadataWriteIssues: compile.metadataWriteIssues)
        }
        commands = completed.commands; outcomes = completed.outcomes
        let native = outcomes.last!
        var failures = native.failures
        var usage: NotikaRustCacheUsageRecord?
        if native.retirementProven, native.nativeTermination != nil {
            do { usage = try custody.publishUsage(sessionID: bindings.sessionID, usedAt: usedAt, expected: existing) }
            catch { failures.append(.init(operation: "rustCacheUsage", detail: String(describing: error))) }
        }
        var final: String?
        do {
            final = try await source()
            if final != opening { failures.append(.init(operation: "rustSourceChanged")) }
        } catch { failures.append(.init(operation: "rustSourceObservation", detail: String(describing: error))) }
        let outcome = NotikaPreflightCommandOutcome(nativeTermination: native.nativeTermination, retirementProven: native.retirementProven,
                                                    cancelled: native.cancelled || Task.isCancelled, failures: failures)
        return .init(identity: identity, cache: custody.observation, sourceBeforeDigest: opening, sourceAfterDigest: final,
                     commands: commands, outcomes: outcomes, outcome: outcome, usage: usage,
                     metadataWriteIssues: policy.metadataWriteIssues + cacheLease.metadataWriteIssues + completed.metadataWriteIssues)
    }
}

private struct RustCommands: Sendable {
    let commands: [DarwinWorkloadCommand]
    let outcomes: [NotikaPreflightCommandOutcome]
    let metadataWriteIssues: [MetadataWriteIssue]
}

private func rustAcquire(_ resource: String, mode: LeaseMode, paths: AgentLeasePaths, sessionID: String, waitSeconds: Double?) async throws -> LeaseSet {
    let resources = try ResourceSet(exclusive: mode == .exclusive ? [resource] : [], shared: mode == .shared ? [resource] : [])
    let timestamp = RunRecord.timestamp(), pid = getpid()
    return try await LeaseSet.acquire(resources, paths: paths, waitSeconds: waitSeconds, initialMetadata: { lease in
        LockMetadata(resourceName: lease.resource.value, leaseMode: lease.mode, runID: sessionID, coordinatorPID: pid,
                     childPID: nil, mode: .run, state: .acquired, label: "notika-rust-test", bead: nil, acquiredAt: timestamp)
    })
}

private final class RustCacheCustody: Sendable {
    static let metadataName = ".notika-cache-usage.json"
    let observation: NotikaRustCacheObservation
    private let identity: NotikaRustCacheIdentity
    private let ownership: ProjectOwnership
    private let policy: LeaseSet
    private let cacheLease: LeaseSet
    private let directories: [RustDirectoryPin]
    private let tempDirectories: [RustDirectoryPin]
    private let boot: DirectoryIdentityBoot

    init(identity: NotikaRustCacheIdentity, ownership: ProjectOwnership, policy: LeaseSet, cacheLease: LeaseSet, temporaryDirectory: String) throws {
        self.identity = identity; self.ownership = ownership; self.policy = policy; self.cacheLease = cacheLease
        guard let canonical = try rustRealPath(identity.repository), canonical.utf8.elementsEqual(identity.repository.utf8),
              rustWithin(temporaryDirectory, identity.repository), temporaryDirectory != identity.repository else { throw NotikaRustTestError.unsafePath(temporaryDirectory) }
        let key = try identity.cacheKey()
        directories = try RustDirectoryPin.chain(root: identity.repository, components: ["DerivedData", "RustTestCaches", key, "target", "cargo-home"], cacheBranches: true)
        let cache = directories[3]
        guard let device = UInt64(exactly: cache.status.st_dev), cache.status.st_dev == directories[2].status.st_dev else {
            throw NotikaRustTestError.unsafePath(cache.path)
        }
        observation = try NotikaRustCacheObservation(identity: identity, deviceID: device, inode: UInt64(cache.status.st_ino), ownerUID: cache.status.st_uid)
        boot = try DirectoryIdentityBoot.current()
        let components = String(temporaryDirectory.dropFirst(identity.repository.count + 1)).split(separator: "/").map(String.init)
        tempDirectories = try RustDirectoryPin.chain(root: identity.repository, components: components, create: false)
        guard tempDirectories.last!.status.st_mode & 0o077 == 0 else { throw NotikaRustTestError.unsafePath(temporaryDirectory) }
        try revalidate()
    }

    func revalidate() throws {
        _ = try ownership.inheritedDescriptors()
        guard policy.inheritedLeaseDescriptors.count == 1, policy.inheritedLeaseDescriptors[0].resource == identity.policyResource,
              policy.inheritedLeaseDescriptors[0].mode == .shared,
              cacheLease.inheritedLeaseDescriptors.count == 1, cacheLease.inheritedLeaseDescriptors[0].resource == (try identity.cacheResource()),
              cacheLease.inheritedLeaseDescriptors[0].mode == .exclusive else { throw NotikaRustTestError.ownershipMismatch }
        for pin in directories + tempDirectories { try pin.revalidate() }
    }

    func readUsage() throws -> NotikaRustCacheUsageRecord? {
        try revalidate()
        let directory = directories[3].descriptor
        guard let admitted = try rustStatus(at: Self.metadataName, directory: directory) else { return nil }
        guard rustMetadataSafe(admitted) else { throw NotikaRustTestError.unsafeMetadata }
        let descriptor = openat(directory, Self.metadataName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw NotikaRustTestError.unsafeMetadata }
        defer { Darwin.close(descriptor) }
        guard RustFileFingerprint(try rustStatus(descriptor)) == RustFileFingerprint(admitted) else { throw NotikaRustTestError.unsafeMetadata }
        let bytes = try rustRead(descriptor, size: Int(admitted.st_size))
        guard RustFileFingerprint(try rustStatus(descriptor)) == RustFileFingerprint(admitted),
              try rustStatus(at: Self.metadataName, directory: directory).map(RustFileFingerprint.init) == RustFileFingerprint(admitted) else {
            throw NotikaRustTestError.unsafeMetadata
        }
        let record: NotikaRustCacheUsageRecord
        do { record = try NotikaRustCacheUsageRecord(data: bytes, identity: identity, observation: observation, boot: boot) }
        catch { throw NotikaRustTestError.unsafeMetadata }
        try revalidate()
        return record
    }

    func publishUsage(sessionID: String, usedAt: Date, expected: NotikaRustCacheUsageRecord?) throws -> NotikaRustCacheUsageRecord {
        try revalidate()
        guard try readUsage() == expected else { throw NotikaRustTestError.unsafeMetadata }
        let record = try NotikaRustCacheUsageRecord.make(identity: identity, observation: observation, sessionID: sessionID,
                                                       usedAt: usedAt, createdAt: expected?.createdAt)
        let directory = directories[3].descriptor
        let name = "." + Self.metadataName + "." + UUID().uuidString + ".tmp"
        let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw rustIO("create usage stage") }
        defer { Darwin.close(descriptor); unlinkat(directory, name, 0) }
        try rustWrite(record.document.originalData, descriptor: descriptor)
        guard fsync(descriptor) == 0 else { throw rustIO("sync usage stage") }
        guard try readUsage() == expected else { throw NotikaRustTestError.unsafeMetadata }
        try revalidate()
        if expected == nil {
            guard linkat(directory, name, directory, Self.metadataName, 0) == 0 else { throw rustIO("publish initial usage") }
            guard unlinkat(directory, name, 0) == 0 else { throw rustIO("retire usage stage") }
        } else {
            guard renameat(directory, name, directory, Self.metadataName) == 0 else { throw rustIO("replace admitted usage") }
        }
        guard fsync(directory) == 0 else { throw rustIO("sync cache directory") }
        try revalidate()
        guard try readUsage() == record else { throw NotikaRustTestError.unsafeMetadata }
        return record
    }
}

private final class RustDirectoryPin: Sendable {
    let path: String
    let descriptor: Int32
    let status: stat
    private let parent: RustDirectoryPin?
    private let name: String?

    private init(path: String, descriptor: Int32, status: stat, parent: RustDirectoryPin?, name: String?) {
        self.path = path; self.descriptor = descriptor; self.status = status; self.parent = parent; self.name = name
    }
    deinit { Darwin.close(descriptor) }

    static func chain(root: String, components: [String], create: Bool = true, cacheBranches: Bool = false) throws -> [RustDirectoryPin] {
        var pins: [RustDirectoryPin] = []
        func open(_ name: String?, parent: RustDirectoryPin?, privateMode: Bool) throws -> RustDirectoryPin {
            let path = parent.map { $0.path + "/" + name! } ?? root
            let descriptor: Int32
            if let parent, let name {
                if create, mkdirat(parent.descriptor, name, 0o700) != 0, errno != EEXIST { throw rustIO("create cache directory") }
                descriptor = openat(parent.descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            } else { descriptor = Darwin.open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard descriptor >= 0 else { throw NotikaRustTestError.unsafePath(path) }
            do {
                let status = try rustStatus(descriptor)
                guard status.st_mode & S_IFMT == S_IFDIR, status.st_uid == geteuid(), status.st_mode & (privateMode ? 0o077 : 0o022) == 0 else {
                    throw NotikaRustTestError.unsafePath(path)
                }
                return RustDirectoryPin(path: path, descriptor: descriptor, status: status, parent: parent, name: name)
            } catch { Darwin.close(descriptor); throw error }
        }
        pins.append(try open(nil, parent: nil, privateMode: false))
        for (index, component) in components.enumerated() {
            // target and cargo-home are siblings below the exact cache directory.
            let parent = cacheBranches && index == 4 ? pins[3] : pins.last!
            pins.append(try open(component, parent: parent, privateMode: cacheBranches && index >= 1))
        }
        return pins
    }

    func revalidate() throws {
        let named: stat?
        if let parent { named = try rustStatus(at: name!, directory: parent.descriptor) }
        else { named = try rustNamedStatus(path) }
        guard let named, named.st_mode & S_IFMT == S_IFDIR, rustSameInode(named, status),
              rustSameInode(try rustStatus(descriptor), status), named.st_uid == status.st_uid, named.st_mode == status.st_mode else {
            throw NotikaRustTestError.unsafePath(path)
        }
    }
}

private struct RustFileFingerprint: Equatable {
    let device: dev_t, inode: ino_t, owner: uid_t, mode: mode_t, links: nlink_t, size: off_t
    let modifiedSeconds: Int, modifiedNanoseconds: Int, changedSeconds: Int, changedNanoseconds: Int
    init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; owner = value.st_uid; mode = value.st_mode; links = value.st_nlink; size = value.st_size
        modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanoseconds = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec; changedNanoseconds = value.st_ctimespec.tv_nsec
    }
}

private func rustMetadataSafe(_ value: stat) -> Bool {
    value.st_mode & S_IFMT == S_IFREG && value.st_uid == geteuid() && value.st_mode & 0o7777 == 0o600 && value.st_nlink == 1 &&
        value.st_size > 0 && value.st_size <= NotikaRustCacheUsageRecord.maximumBytes
}
private func rustSameInode(_ lhs: stat, _ rhs: stat) -> Bool { lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino }
private func rustWithin(_ path: String, _ root: String) -> Bool {
    path.utf8.elementsEqual(root.utf8) || path.utf8.starts(with: (root == "/" ? "/" : root + "/").utf8)
}
private func rustDigest(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
private func rustLiteralPath(_ value: String) -> Bool {
    value.hasPrefix("/") && value.count <= 4096 && (value == "/" || !value.hasSuffix("/")) && !value.contains("//") &&
        !value.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) && !value.utf8.contains(0)
}
private func rustSessionID(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    func alpha(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) }
    return (1...128).contains(bytes.count) && alpha(bytes[0]) && bytes.dropFirst().allSatisfy { alpha($0) || [45, 46, 95].contains($0) }
}
private func rustRealPath(_ path: String) throws -> String? {
    guard path.hasPrefix("/"), path.count <= 4096, !path.utf8.contains(0) else { throw NotikaRustTestError.unsafePath(path) }
    guard let resolved = realpath(path, nil) else { if errno == ENOENT { return nil }; throw rustIO("resolve path") }
    defer { free(resolved) }
    guard let value = String(validatingCString: resolved) else { throw NotikaRustTestError.unsafePath(path) }
    return value
}
private func rustMise(repository: String, environment: [String: String]) throws -> String {
    for component in (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":", omittingEmptySubsequences: false) {
        let base = component.isEmpty ? repository : (component.hasPrefix("/") ? String(component) : repository + "/" + component)
        let path = base + "/mise"
        if access(path, X_OK) == 0, let resolved = try rustRealPath(path) { return resolved }
    }
    throw NotikaRustTestError.unavailableMise
}
private func rustHashFile(_ path: String) throws -> String {
    let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw rustIO("open identity file") }
    defer { Darwin.close(descriptor) }
    guard try rustStatus(descriptor).st_mode & S_IFMT == S_IFREG else { throw NotikaRustTestError.unsafePath(path) }
    var digest = SHA256(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        try Task.checkCancellation()
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count < 0, errno == EINTR { continue }
        guard count >= 0 else { throw rustIO("read identity file") }
        if count == 0 { break }
        digest.update(data: Data(buffer.prefix(count)))
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}
private func rustStatus(_ descriptor: Int32) throws -> stat { var value = stat(); guard fstat(descriptor, &value) == 0 else { throw rustIO("stat descriptor") }; return value }
private func rustNamedStatus(_ path: String) throws -> stat? { var value = stat(); if lstat(path, &value) == 0 { return value }; if errno == ENOENT { return nil }; throw rustIO("stat path") }
private func rustStatus(at name: String, directory: Int32) throws -> stat? { var value = stat(); if fstatat(directory, name, &value, AT_SYMLINK_NOFOLLOW) == 0 { return value }; if errno == ENOENT { return nil }; throw rustIO("stat entry") }
private func rustIO(_ operation: String, code: Int32 = errno) -> NotikaRustTestError { .io(operation: operation, code: code) }
private func rustRead(_ descriptor: Int32, size: Int) throws -> Data {
    var buffer = [UInt8](repeating: 0, count: size), offset = 0
    while offset < size {
        let count = buffer.withUnsafeMutableBytes { Darwin.pread(descriptor, $0.baseAddress!.advanced(by: offset), size - offset, off_t(offset)) }
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw NotikaRustTestError.unsafeMetadata }
        offset += count
    }
    var tail: UInt8 = 0
    guard pread(descriptor, &tail, 1, off_t(size)) == 0 else { throw NotikaRustTestError.unsafeMetadata }
    return Data(buffer)
}
private func rustWrite(_ data: Data, descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw rustIO("write usage") }
            offset += count
        }
    }
}
private func rustCanonicalJSON(_ value: StrictJSONValue) throws -> CanonicalJSONValue {
    switch value {
    case .array(let values): .array(try values.map(rustCanonicalJSON))
    case .bool(let value): .bool(value)
    case .null: .null
    case .number(let value): value.lexicalValue.hasPrefix("-") ? .integer(try value.int64()) : .unsignedInteger(try value.uint64())
    case .object(let object): .object(try object.members.map { CanonicalJSONMember(key: $0.key, value: try rustCanonicalJSON($0.value)) })
    case .string(let value): .string(value)
    }
}
private func rustParseTime(_ value: String) -> Int64? { try? rustExactTime(value) }
private func rustExactTime(_ value: String) throws -> Int64 {
    let bytes = Array(value.utf8)
    func invalid() -> NotikaRustTestError { .unsafeMetadata }
    guard (20...32).contains(bytes.count), bytes[4] == 45, bytes[7] == 45,
          bytes[10] == 84, bytes[13] == 58, bytes[16] == 58 else { throw invalid() }
    func number(_ start: Int, _ count: Int) throws -> Int {
        guard start + count <= bytes.count else { throw invalid() }
        var value = 0
        for byte in bytes[start..<(start + count)] {
            guard (48...57).contains(byte) else { throw invalid() }
            value = value * 10 + Int(byte - 48)
        }
        return value
    }
    let year = try number(0, 4)
    let month = try number(5, 2)
    let day = try number(8, 2)
    let hour = try number(11, 2)
    let minute = try number(14, 2)
    let second = try number(17, 2)
    guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
          (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { throw invalid() }
    var index = 19
    var microseconds = 0
    if bytes[index] == 46 {
        index += 1
        let start = index
        while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
        let digits = index - start
        guard (1...6).contains(digits) else { throw invalid() }
        microseconds = try number(start, digits)
        for _ in digits..<6 { microseconds *= 10 }
    }
    guard index < bytes.count else { throw invalid() }
    let offsetSeconds: Int
    if bytes[index] == 90, index + 1 == bytes.count {
        offsetSeconds = 0
    } else {
        guard (bytes[index] == 43 || bytes[index] == 45), index + 6 == bytes.count,
              bytes[index + 3] == 58 else { throw invalid() }
        let offsetHour = try number(index + 1, 2)
        let offsetMinute = try number(index + 4, 2)
        guard (0...23).contains(offsetHour), (0...59).contains(offsetMinute) else { throw invalid() }
        offsetSeconds = (offsetHour * 3600 + offsetMinute * 60) * (bytes[index] == 43 ? 1 : -1)
    }
    // Python datetime uses proleptic Gregorian dates. Foundation's Gregorian
    // calendar has a historical Julian cutover, so civil-date arithmetic is
    // explicit here. All admitted years fit exact signed 64-bit microseconds.
    let leap = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
    let monthDays = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    guard day <= monthDays[month - 1] else { throw invalid() }
    func daysBeforeYear(_ value: Int) -> Int {
        let previous = value - 1
        return previous * 365 + previous / 4 - previous / 100 + previous / 400
    }
    let epochDays = daysBeforeYear(1970)
    let dayNumber = daysBeforeYear(year) + monthDays.prefix(month - 1).reduce(0, +) + day - 1
    let utcSeconds = Int64(dayNumber - epochDays) * 86_400
        + Int64(hour * 3600 + minute * 60 + second - offsetSeconds)
    let minimumUTC = -Int64(epochDays) * 86_400
    let maximumUTC = Int64(daysBeforeYear(10_000) - epochDays) * 86_400 - 1
    guard (minimumUTC...maximumUTC).contains(utcSeconds) else { throw invalid() }
    let exactMicroseconds = utcSeconds * 1_000_000 + Int64(microseconds)
    return exactMicroseconds
}

private func rustTimestamp(_ date: Date) throws -> String {
    let scaled = (date.timeIntervalSince1970 * 1_000_000).rounded()
    guard scaled.isFinite, scaled >= -62_135_596_800_000_000, scaled < 253_402_300_800_000_000 else {
        throw NotikaRustTestError.invalidBindings
    }
    return rustFormatMicroseconds(Int64(scaled))
}

private func rustFormatMicroseconds(_ microseconds: Int64) -> String {
    func floorDivide(_ value: Int64, by divisor: Int64) -> Int64 {
        let quotient = value / divisor
        return value % divisor < 0 ? quotient - 1 : quotient
    }
    let seconds = floorDivide(microseconds, by: 1_000_000)
    let fraction = microseconds - seconds * 1_000_000
    let days = floorDivide(seconds, by: 86_400)
    let withinDay = seconds - days * 86_400
    let absoluteDay = Int(days) + 719_162
    func daysBeforeYear(_ year: Int) -> Int { let previous = year - 1; return previous * 365 + previous / 4 - previous / 100 + previous / 400 }
    var low = 1
    var high = 10_000
    while low + 1 < high {
        let middle = (low + high) / 2
        if daysBeforeYear(middle) <= absoluteDay { low = middle } else { high = middle }
    }
    let leap = low.isMultiple(of: 4) && (!low.isMultiple(of: 100) || low.isMultiple(of: 400))
    let monthDays = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    var month = 1
    var day = absoluteDay - daysBeforeYear(low)
    while day >= monthDays[month - 1] { day -= monthDays[month - 1]; month += 1 }
    var result = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", low, month, day + 1,
                        Int(withinDay / 3600), Int(withinDay % 3600 / 60), Int(withinDay % 60))
    if fraction != 0 { result += String(format: ".%06d", Int(fraction)) }
    return result + "Z"
}
