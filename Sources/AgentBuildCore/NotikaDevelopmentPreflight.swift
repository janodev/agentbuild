import AgentLeaseCore
import CryptoKit
import Darwin
import Foundation
import Synchronization

public enum NotikaDevelopmentPreflightError: Error, Equatable, Sendable {
    case invalidRepository
    case invalidIdentity(String)
    case invalidEnvironment(String)
    case ownershipMismatch
    case rustExecutorUnavailable
    case identityChanged(String)
    case admittedSourceChanged
    case unavailableExecutable(String)
    case unsafePath(String)
    case io(operation: String, code: Int32)
}

public enum NotikaRustTestFamily: String, CaseIterable, Sendable {
    case liteparse
    case svg
}

public enum NotikaPreflightVersionProbe: String, CaseIterable, Sendable {
    case make, python3, systemPython3, rustc, cargo

    fileprivate var arguments: [String] {
        switch self {
        case .make: ["make", "--version"]
        case .python3: ["python3", "--version"]
        case .systemPython3: ["/usr/bin/python3", "--version"]
        case .rustc: ["mise", "exec", "--", "rustc", "--version", "--verbose"]
        case .cargo: ["mise", "exec", "--", "cargo", "--version"]
        }
    }
}

/// A native result is successful only after the complete supervised workload
/// has retired. A zero exit alone cannot publish a shared passing receipt.
public struct NotikaPreflightCommandOutcome: Equatable, Sendable {
    public let nativeTermination: RunTermination?
    public let retirementProven: Bool
    public let cancelled: Bool
    public let failures: [DarwinWorkloadFailure]

    public init(nativeTermination: RunTermination?, retirementProven: Bool, cancelled: Bool = false,
                failures: [DarwinWorkloadFailure] = []) {
        self.nativeTermination = nativeTermination
        self.retirementProven = retirementProven
        self.cancelled = cancelled
        self.failures = failures
    }

    public var succeeded: Bool {
        nativeTermination == RunTermination(kind: .exit, value: 0) && retirementProven && !cancelled && failures.isEmpty
    }
}

public struct NotikaPreflightIdentity: Equatable, Sendable {
    public let sourceDigest: String
    public let toolchainDigest: String

    public init(sourceDigest: String, toolchainDigest: String) throws {
        guard preflightDigest(sourceDigest) else { throw NotikaDevelopmentPreflightError.invalidIdentity("source") }
        guard preflightDigest(toolchainDigest) else { throw NotikaDevelopmentPreflightError.invalidIdentity("toolchain") }
        self.sourceDigest = sourceDigest
        self.toolchainDigest = toolchainDigest
    }
}

/// Closed equivalents of Make's platform-independent gate. Python commands are
/// explicit repository contract tests; they are not the live Python controller.
public struct NotikaDevelopmentPreflightStep: Equatable, Sendable {
    public enum Operation: Equatable, Sendable {
        case helper(arguments: [String], requiresCompilation: Bool)
        case rust(NotikaRustTestFamily)
    }

    public let name: String
    public let operation: Operation

    fileprivate init(_ name: String, _ operation: Operation) {
        self.name = name
        self.operation = operation
    }

    public var commandMaterial: CanonicalJSONValue {
        switch operation {
        case .helper(let arguments, let compilation):
            .object(["name": .string(name), "arguments": .array(arguments.map { .string($0) }),
                     "requiresCompilation": .bool(compilation)])
        case .rust(let family):
            .object(["name": .string(name), "nativeRustTestFamily": .string(family.rawValue)])
        }
    }
}

/// Borrowed inside the exact-key receipt and project ownership scopes. The Rust
/// executor must acquire its own policy/cache leases before host:compile, retain
/// every supplied descriptor, and await supervised retirement before returning.
/// No default executor exists: incomplete Rust support cannot reuse a receipt.
public struct NotikaPreflightRustContext: Sendable {
    public let repository: String
    public let environment: [String: String]
    public let ownership: ProjectOwnership
    public let retainedLockDescriptors: [Int32]
}

public struct NotikaDevelopmentPreflightReport: Sendable {
    public enum Status: String, Sendable { case passed, reused, failed }
    public struct Execution: Sendable {
        public let step: String
        public let outcome: NotikaPreflightCommandOutcome
    }

    public let status: Status
    public let identity: NotikaPreflightIdentity
    public let commandDigest: String
    public let key: String
    public let receiptPath: String
    public let executions: [Execution]
    public var succeeded: Bool { status != .failed }
}

/// Native exact-source gate controller. It borrows existing graph/cache
/// ownership rather than reacquiring graph after a cache. The caller's trusted
/// execution adapters must wait out quarantined workloads before returning.
/// Observations do not prove an atomic source snapshot or hostile UID isolation.
public struct NotikaDevelopmentPreflight: Sendable {
    public typealias CommandOperation = @Sendable (DarwinWorkloadCommand, [Int32]) async throws -> NotikaPreflightCommandOutcome
    public typealias RustOperation = @Sendable (NotikaRustTestFamily, NotikaPreflightRustContext) async throws -> NotikaPreflightCommandOutcome
    public typealias IdentityOperation = @Sendable () async throws -> NotikaPreflightIdentity

    public init() {}

    /// Literal broad Make prerequisites; fixed replay selects only its closed
    /// semantic workload even though its canonical Xcode family is test-unit.
    public static func requiresPreflight(for request: NotikaActionRequest) -> Bool {
        guard request.makeRoute != .replayFixedSemantic, let route = request.canonicalMakeRoute else { return false }
        return [NotikaMakeRoute.test, .testUnit, .buildAndTest].contains(route)
    }

    public static let steps: [NotikaDevelopmentPreflightStep] = {
        var values: [NotikaDevelopmentPreflightStep] = [
            .init("check-agent-adoption", .helper(arguments: ["Scripts/semantic-operation-adoption", "check"], requiresCompilation: true)),
            .init("check-agent-promotions", .helper(arguments: ["Scripts/agent-failure-diagnostics", "check"], requiresCompilation: false)),
            .init("test-agent-adoption", .helper(arguments: ["Scripts/semantic-operation-adoption", "test"], requiresCompilation: true)),
        ]
        for (interpreter, pattern) in [
            ("python3", "test_development_preflight.py"), ("python3", "test_agent_cache_retention.py"),
            ("/usr/bin/python3", "test_agent_loop_acceptance.py"), ("/usr/bin/python3", "test_bounded_stream_capture.py"),
            ("python3", "test_generated_graph_lock.py"), ("python3", "test_compilation_admission.py"),
            ("python3", "test_fixed_semantic_replay_route.py"), ("python3", "test_notika_dev.py"),
            ("python3", "test_session_concurrency.py"), ("python3", "test_session_retention.py"),
            ("python3", "test_daily_retention.py"), ("python3", "test_daily_maintenance.py"),
            ("/usr/bin/python3", "test_agent_failure_diagnostics.py"), ("/usr/bin/python3", "test_notikactl*.py"),
        ] {
            values.append(.init(pattern, .helper(arguments: [interpreter, "-m", "unittest", "discover", "-s", "Scripts/tests", "-p", pattern], requiresCompilation: false)))
        }
        values.append(.init("test-liteparse-rust", .rust(.liteparse)))
        values.append(.init("test-svg-rust", .rust(.svg)))
        return values
    }()

    /// Matches _preflight_environment after the outer route's admission. This
    /// layer deliberately does not broaden or reapply the parent's allowlist.
    public static func environment(from inherited: [String: String]) throws -> [String: String] {
        let excluded: Set<String> = [
            "CONFIGURATION", "DERIVED_DATA_PATH", "DEVICE_ID", "FILE", "IOS_DESTINATION", "MACOS_DESTINATION",
            "MAKEFLAGS", "MAKELEVEL", "METHOD", "MFLAGS", "OLDPWD", "PLATFORM", "PWD", "RESULT_BUNDLE", "SHLVL",
            "TARGET", "TEST_XCODEBUILD_FLAGS", "UI_TEST_XCODEBUILD_FLAGS", "UNIT_TEST_XCODEBUILD_FLAGS", "XCODEBUILD",
            "XCODEBUILD_FLAGS", "XCODE_DESTINATION", "XCODE_WORKSPACE", "_",
        ]
        var result: [String: String] = [:]
        for (name, value) in inherited {
            guard !value.isEmpty, !excluded.contains(name), !name.hasPrefix("SIMLEASE_"), !name.hasPrefix("SIMULATOR_"),
                  !name.hasPrefix("NOTIKA_") || name == "NOTIKA_AGENTLEASE_INTEGRATION_BINARY" else { continue }
            guard !name.isEmpty, !name.contains("="), !name.utf8.contains(0), !value.utf8.contains(0) else {
                throw NotikaDevelopmentPreflightError.invalidEnvironment(name)
            }
            result[name] = value
        }
        return result
    }

    public func run(
        repository: String, ownership: ProjectOwnership, environment inherited: [String: String],
        admittedSourceDigest: String? = nil, capture: (any RepositoryCommandCapturing)? = nil,
        identityOperation: IdentityOperation? = nil, commandOperation: CommandOperation,
        rustOperation: RustOperation? = nil, waitSeconds: Double? = nil
    ) async throws -> NotikaDevelopmentPreflightReport {
        guard let rustOperation else { throw NotikaDevelopmentPreflightError.rustExecutorUnavailable }
        guard let canonical = try preflightCanonical(repository), preflightSame(canonical, repository) else {
            throw NotikaDevelopmentPreflightError.invalidRepository
        }
        guard preflightSame(ownership.plan.canonicalWorktree, repository),
              ownership.plan.orderedLeases.first?.mode == .shared,
              ownership.plan.orderedLeases.first?.resource.value == (try CacheCompatibilityIdentity.graphResourceName(canonicalWorktree: repository)) else {
            throw NotikaDevelopmentPreflightError.ownershipMismatch
        }
        if let admittedSourceDigest, !preflightDigest(admittedSourceDigest) {
            throw NotikaDevelopmentPreflightError.invalidIdentity("admittedSource")
        }
        if let waitSeconds, !waitSeconds.isFinite || waitSeconds < 0 {
            throw LeaseSetError.invalidWaitSeconds(waitSeconds)
        }
        let child = try Self.environment(from: inherited)
        let commandDigest = try CanonicalJSONDigest.sha256(.array(Self.steps.map(\.commandMaterial)))
        let observer: IdentityOperation
        if let identityOperation { observer = identityOperation }
        else {
            let rawCapture = try capture ?? RepositoryCommandCapture()
            observer = { try await Self.captureIdentity(repository: repository, environment: child, capture: rawCapture) }
        }
        let opening = try await observer()
        try preflightRequireSource(opening, admittedSourceDigest)
        let key = try CanonicalJSONDigest.sha256(.object([
            "schemaVersion": .integer(1), "sourceIdentitySHA256": .string(opening.sourceDigest),
            "toolchainIdentitySHA256": .string(opening.toolchainDigest), "commandSHA256": .string(commandDigest),
        ]))
        let state = try PreflightState(repository: repository)
        let lock = try state.openLock(key: key)
        defer { Darwin.close(lock) }
        try await preflightAcquire(lock, waitSeconds: waitSeconds)
        try state.validateLock(lock, key: key)
        // Close, rather than LOCK_UN: native lock duplicates remain crash fallback.
        let locked = try await observer()
        try preflightRequireSource(locked, admittedSourceDigest)
        guard locked == opening else { throw NotikaDevelopmentPreflightError.identityChanged("lock admission") }
        let receipt = try CanonicalJSONDigest.encode(.object([
            "schemaVersion": .integer(1), "key": .string(key), "sourceIdentitySHA256": .string(opening.sourceDigest),
            "toolchainIdentitySHA256": .string(opening.toolchainDigest), "commandSHA256": .string(commandDigest), "passed": .bool(true),
        ]))
        let receiptPath = state.path + "/" + key + ".json"
        if try state.validReceipt(key: key, expected: receipt) {
            return .init(status: .reused, identity: opening, commandDigest: commandDigest, key: key, receiptPath: receiptPath, executions: [])
        }
        try state.removeReceipt(key: key)
        var executions: [NotikaDevelopmentPreflightReport.Execution] = []
        let descriptors = try ownership.inheritedDescriptors() + [lock]
        let rustContext = NotikaPreflightRustContext(repository: repository, environment: child, ownership: ownership,
                                                   retainedLockDescriptors: descriptors)
        for step in Self.steps {
            try Task.checkCancellation()
            try state.revalidate()
            try state.validateLock(lock, key: key)
            let outcome: NotikaPreflightCommandOutcome
            switch step.operation {
            case .rust(let family):
                outcome = try await rustOperation(family, rustContext)
            case .helper(let arguments, let compilation):
                let executable = try preflightExecutable(arguments[0], repository: repository, environment: child)
                let command = try DarwinWorkloadCommand(executable: executable, arguments: Array(arguments.dropFirst()),
                                                        workingDirectory: repository, environment: child)
                if compilation {
                    outcome = try await HostCompilationAdmission().withLease(environment: inherited, label: "notika-preflight:" + step.name,
                                                                              waitSeconds: waitSeconds) { compile in
                        try await commandOperation(command, descriptors + compile.inheritedDescriptors())
                    }
                } else { outcome = try await commandOperation(command, descriptors) }
            }
            executions.append(.init(step: step.name, outcome: outcome))
            guard outcome.succeeded else {
                return .init(status: .failed, identity: opening, commandDigest: commandDigest, key: key,
                             receiptPath: receiptPath, executions: executions)
            }
        }
        let final = try await observer()
        try preflightRequireSource(final, admittedSourceDigest)
        guard final == opening else { throw NotikaDevelopmentPreflightError.identityChanged("execution") }
        try Task.checkCancellation()
        try state.validateLock(lock, key: key)
        try state.publish(key: key, payload: receipt)
        return .init(status: .passed, identity: opening, commandDigest: commandDigest, key: key,
                     receiptPath: receiptPath, executions: executions)
    }

    /// Exact preflight toolchain envelope from the reference. Version probes use
    /// bounded raw capture; no truncated prefix can become compatibility input.
    public static func captureIdentity(repository: String, environment: [String: String],
                                       capture: any RepositoryCommandCapturing) async throws -> NotikaPreflightIdentity {
        let provider = try NotikaRepositoryIdentity(repository: repository, capture: capture, environment: environment)
        let source = try await provider.sourceIdentity()
        guard preflightSame(source.canonicalWorktree, repository) else { throw NotikaDevelopmentPreflightError.invalidRepository }
        var binaries: [String: CanonicalJSONValue] = [:]
        for (name, executable) in [("bash", "/bin/bash"), ("git", "git"), ("make", "make"), ("mise", "mise"),
                                   ("python3", "python3"), ("systemPython3", "/usr/bin/python3"), ("xcrun", "xcrun")] {
            let path = try preflightExecutable(executable, repository: repository, environment: environment, canonical: true)
            binaries[name] = .object(["path": .string(path), "sha256": .string(try preflightFileDigest(path))])
        }
        var versions: [String: CanonicalJSONValue] = [:]
        for probe in NotikaPreflightVersionProbe.allCases {
            versions[probe.rawValue] = .string(try await captureVersion(probe, repository: repository, environment: environment, capture: capture))
        }
        let tools = CanonicalJSONValue.object([
            "schemaVersion": .integer(1), "development": try await provider.toolchainIdentity().keyMaterial,
            "environment": .object(environment.mapValues { .string($0) }), "binaries": .object(binaries), "versions": .object(versions),
        ])
        return try NotikaPreflightIdentity(sourceDigest: source.digest(), toolchainDigest: CanonicalJSONDigest.sha256(tools))
    }

    /// The reference's five additional version probes combine stdout/stderr.
    /// A fixed shell redirects that stream into the raw capture's strict budget.
    /// Arguments remain literal. Shell startup variables are withheld from this
    /// transport shell and restored for the actual version command.
    public static func captureVersion(_ probe: NotikaPreflightVersionProbe, repository: String,
                                      environment: [String: String], capture: any RepositoryCommandCapturing) async throws -> String {
        var transportEnvironment = environment
        var restoration: [String] = []
        for key in ["BASH_ENV", "ENV"] {
            let value = transportEnvironment.removeValue(forKey: key)
            restoration.append(value.map { key + "=" + $0 } ?? "")
        }
        let script = "if [[ -n \"$1\" ]]; then export \"$1\"; fi; if [[ -n \"$2\" ]]; then export \"$2\"; fi; shift 2; exec \"$@\" 2>&1"
        let arguments = ["/bin/bash", "--noprofile", "--norc", "-c", script, "--"] + restoration + probe.arguments
        return repositoryDecodedText(try await capture.capture(arguments: arguments, workingDirectory: repository,
                                                               environment: transportEnvironment))
    }
}

private final class PreflightState: Sendable {
    let path: String
    private let paths: [String]
    private let descriptors: [Int32]
    private let identities: [PreflightInode]

    init(repository: String) throws {
        let names = [repository, repository + "/Untracked", repository + "/Untracked/DevelopmentPreflight"]
        var opened: [Int32] = []
        var observed: [PreflightInode] = []
        do {
            for (index, name) in names.enumerated() {
                let descriptor: Int32
                if index == 0 { descriptor = Darwin.open(name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
                else {
                    let leaf = index == 1 ? "Untracked" : "DevelopmentPreflight"
                    if mkdirat(opened.last!, leaf, 0o700) != 0, errno != EEXIST { throw preflightIO("create state directory") }
                    descriptor = openat(opened.last!, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard descriptor >= 0 else { throw NotikaDevelopmentPreflightError.unsafePath(name) }
                opened.append(descriptor)
                let status = try preflightStatus(descriptor)
                guard status.st_mode & S_IFMT == S_IFDIR, status.st_uid == geteuid(), status.st_mode & 0o022 == 0 else {
                    throw NotikaDevelopmentPreflightError.unsafePath(name)
                }
                observed.append(PreflightInode(status))
            }
        } catch { for descriptor in opened.reversed() { Darwin.close(descriptor) }; throw error }
        path = names.last!
        paths = names
        descriptors = opened
        identities = observed
        try revalidate()
    }

    deinit { for descriptor in descriptors.reversed() { Darwin.close(descriptor) } }

    func revalidate() throws {
        for index in paths.indices {
            var named = stat()
            guard lstat(paths[index], &named) == 0, named.st_mode & S_IFMT == S_IFDIR,
                  PreflightInode(named) == identities[index],
                  PreflightInode(try preflightStatus(descriptors[index])) == identities[index] else {
                throw NotikaDevelopmentPreflightError.unsafePath(paths[index])
            }
        }
    }

    func openLock(key: String) throws -> Int32 {
        try revalidate()
        let descriptor = openat(descriptors.last!, key + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw NotikaDevelopmentPreflightError.unsafePath(path + "/" + key + ".lock") }
        do {
            let status = try preflightStatus(descriptor)
            guard status.st_mode & S_IFMT == S_IFREG, status.st_uid == geteuid(), status.st_mode & 0o7777 == 0o600, status.st_nlink == 1 else {
                throw NotikaDevelopmentPreflightError.unsafePath(path + "/" + key + ".lock")
            }
            try validateLock(descriptor, key: key)
            return descriptor
        } catch { Darwin.close(descriptor); throw error }
    }

    func validateLock(_ descriptor: Int32, key: String) throws {
        try revalidate()
        let opened = try preflightStatus(descriptor)
        var named = stat()
        guard opened.st_mode & S_IFMT == S_IFREG, opened.st_uid == geteuid(), opened.st_mode & 0o7777 == 0o600,
              opened.st_nlink == 1, fstatat(descriptors.last!, key + ".lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
              PreflightInode(named) == PreflightInode(opened) else {
            throw NotikaDevelopmentPreflightError.unsafePath(path + "/" + key + ".lock")
        }
    }

    func validReceipt(key: String, expected: Data) throws -> Bool {
        try revalidate()
        let descriptor = openat(descriptors.last!, key + ".json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0 { return false }
        defer { Darwin.close(descriptor) }
        let status = try preflightStatus(descriptor)
        guard status.st_mode & S_IFMT == S_IFREG, status.st_uid == geteuid(), status.st_mode & 0o7777 == 0o400,
              status.st_nlink == 1, status.st_size <= 4096, status.st_size >= 0 else { return false }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 4097)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return false }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
            if bytes.count > 4096 { return false }
        }
        guard let actual = try? StrictJSONDocument(data: bytes), let required = try? StrictJSONDocument(data: expected),
              actual.root == required.root else { return false }
        var named = stat()
        guard fstatat(descriptors.last!, key + ".json", &named, AT_SYMLINK_NOFOLLOW) == 0,
              PreflightInode(named) == PreflightInode(status) else { return false }
        try revalidate()
        return true
    }

    func removeReceipt(key: String) throws {
        try revalidate()
        if unlinkat(descriptors.last!, key + ".json", 0) != 0, errno != ENOENT { throw preflightIO("remove invalid receipt") }
    }

    func publish(key: String, payload: Data) throws {
        try revalidate()
        let stage = "." + key + "." + UUID().uuidString + ".tmp"
        let descriptor = openat(descriptors.last!, stage, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw preflightIO("create receipt stage") }
        defer { Darwin.close(descriptor); unlinkat(descriptors.last!, stage, 0) }
        var data = payload
        data.append(10)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw preflightIO("write receipt stage") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0, fchmod(descriptor, 0o400) == 0 else { throw preflightIO("seal receipt stage") }
        try revalidate()
        guard renameat(descriptors.last!, stage, descriptors.last!, key + ".json") == 0,
              fsync(descriptors.last!) == 0 else { throw preflightIO("publish receipt") }
    }
}

private struct PreflightInode: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let owner: uid_t
    let mode: mode_t
    init(_ status: stat) { device = status.st_dev; inode = status.st_ino; owner = status.st_uid; mode = status.st_mode }
}

private func preflightAcquire(_ descriptor: Int32, waitSeconds: Double?) async throws {
    let start = ContinuousClock.now
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
        let code = errno
        guard code == EWOULDBLOCK || code == EAGAIN || code == EINTR else { throw preflightIO("acquire preflight lock", code: code) }
        try Task.checkCancellation()
        if let waitSeconds, waitSeconds == 0 || start.duration(to: .now) >= .seconds(waitSeconds) {
            throw LeaseSetError.timedOut("notika development preflight")
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    try Task.checkCancellation()
}

private func preflightRequireSource(_ identity: NotikaPreflightIdentity, _ admitted: String?) throws {
    if let admitted, identity.sourceDigest != admitted { throw NotikaDevelopmentPreflightError.admittedSourceChanged }
}

private func preflightDigest(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}

private func preflightSame(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }

private func preflightCanonical(_ path: String) throws -> String? {
    guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
    guard let resolved = realpath(path, nil) else {
        if errno == ENOENT { return nil }
        throw preflightIO("resolve path")
    }
    defer { free(resolved) }
    return String(validatingCString: resolved)
}

private func preflightExecutable(_ name: String, repository: String, environment: [String: String], canonical: Bool = false) throws -> String {
    let candidates: [String]
    if name.hasPrefix("/") { candidates = [name] }
    else if name.contains("/") { candidates = [repository + "/" + name] }
    else {
        candidates = (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":", omittingEmptySubsequences: false).map {
            let base = $0.isEmpty ? repository : ($0.hasPrefix("/") ? String($0) : repository + "/" + $0)
            return base + "/" + name
        }
    }
    for candidate in candidates where access(candidate, X_OK) == 0 {
        guard let resolved = try preflightCanonical(candidate) else { continue }
        let descriptor = Darwin.open(resolved, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { continue }
        let status = try? preflightStatus(descriptor)
        Darwin.close(descriptor)
        if (status?.st_mode ?? 0) & S_IFMT == S_IFREG { return canonical ? resolved : candidate }
    }
    throw NotikaDevelopmentPreflightError.unavailableExecutable(name)
}

private func preflightFileDigest(_ path: String) throws -> String {
    let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw preflightIO("open identity input") }
    defer { Darwin.close(descriptor) }
    guard try preflightStatus(descriptor).st_mode & S_IFMT == S_IFREG else { throw NotikaDevelopmentPreflightError.unsafePath(path) }
    var digest = SHA256()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        try Task.checkCancellation()
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count < 0, errno == EINTR { continue }
        guard count >= 0 else { throw preflightIO("hash identity input") }
        if count == 0 { break }
        digest.update(data: Data(buffer.prefix(count)))
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}

private func preflightStatus(_ descriptor: Int32) throws -> stat {
    var status = stat()
    guard fstat(descriptor, &status) == 0 else { throw preflightIO("inspect descriptor") }
    return status
}

private func preflightIO(_ operation: String, code: Int32 = errno) -> NotikaDevelopmentPreflightError { .io(operation: operation, code: code) }

/// Retains the actual raw descriptors until the enclosing build report is sealed.
/// A reusable exact-source receipt legitimately has no physical phases.
public struct NotikaDevelopmentPreflightEvidence: Sendable {
    public let report: NotikaDevelopmentPreflightReport?
    public let capturedPhases: [CapturedNativePhase]
    public let rustReports: [NotikaRustTestReport]
    public let orchestrationFailures: [String]
    public let cancelled: Bool
    public var nativeFailure: RunTermination? {
        capturedPhases.compactMap { $0.observation.termination }.first { controllerExitCode($0) != 0 }
    }
    public var succeeded: Bool {
        report?.succeeded == true && !cancelled && orchestrationFailures.isEmpty &&
        capturedPhases.allSatisfy { controllerOutcome($0).succeeded } && rustReports.allSatisfy { $0.outcome.succeeded }
    }
    public func revalidateForPublication() throws {
        for phase in capturedPhases { try phase.revalidateForPublication() }
    }
    public var canonicalValue: CanonicalJSONValue {
        get throws {
            .object([
                "namespace": .string("agentbuild.notika-development-preflight"), "schemaVersion": .integer(1),
                "report": try report.map { report in
                    .object(["status": .string(report.status.rawValue), "sourceSHA256": .string(report.identity.sourceDigest),
                        "toolchainSHA256": .string(report.identity.toolchainDigest), "commandSHA256": .string(report.commandDigest),
                        "key": .string(report.key), "receiptPath": .string(report.receiptPath),
                        "executions": .array(try report.executions.map { .object(["step": .string($0.step), "outcome": try controllerOutcomeValue($0.outcome)]) })])
                } ?? .null,
                "phases": .array(try capturedPhases.map(controllerPhaseValue)),
                "rustReports": .array(try rustReports.map(controllerRustReportValue)),
                "orchestrationFailures": .array(orchestrationFailures.map(CanonicalJSONValue.string)),
                "cancelled": .bool(cancelled), "succeeded": .bool(succeeded), "nativeFailure": try controllerEncoded(nativeFailure),
            ])
        }
    }

    /// This admits metadata only. It does not grant live project/cache authority
    /// or replace revalidation of the retained producer capsules before sealing.
    public static func validateCanonicalValue(
        _ value: CanonicalJSONValue, request: NotikaActionRequest, sourceBeforeSHA256: String,
        sessionPath: String, allowFixtureAdmission: Bool = false
    ) throws -> (succeeded: Bool, nativeFailure: RunTermination?, cancelled: Bool) {
        guard NotikaDevelopmentPreflight.requiresPreflight(for: request) else { throw StrictJSONError.invalidSchema }
        return try validateSnapshot(value, sourceBeforeSHA256: sourceBeforeSHA256, sessionPath: sessionPath, allowFixtureAdmission: allowFixtureAdmission)
    }

    internal static func validateSnapshot(_ value: CanonicalJSONValue, sourceBeforeSHA256: String, sessionPath: String,
                                          allowFixtureAdmission: Bool = false) throws -> (succeeded: Bool, nativeFailure: RunTermination?, cancelled: Bool) {
        guard preflightDigest(sourceBeforeSHA256) else { throw StrictJSONError.invalidSchema }
        let marker = "/Artifacts/AgentSessions/"
        guard let range = sessionPath.range(of: marker, options: .backwards),
              UUID(uuidString: String(sessionPath[range.upperBound...]))?.uuidString == String(sessionPath[range.upperBound...]) else {
            throw StrictJSONError.invalidSchema
        }
        let repository = String(sessionPath[..<range.lowerBound])
        _ = try CacheCompatibilityIdentity.graphResourceName(canonicalWorktree: repository)
        let root = try StrictJSONDocument(data: CanonicalJSONDigest.encode(value)).root.requireObject().project(requiredKeys: [
            "namespace", "schemaVersion", "report", "phases", "rustReports", "orchestrationFailures", "cancelled", "succeeded", "nativeFailure",
        ])
        guard try controllerString(root, "namespace") == "agentbuild.notika-development-preflight",
              try controllerInteger(root, "schemaVersion") == 1 else { throw StrictJSONError.invalidSchema }
        let phaseValues = try controllerArray(root, "phases", maximum: 21)
        let phases = try phaseValues.map { try controllerValidatePhase($0, repository: repository, sessionPath: sessionPath) }
        let rustValues = try controllerArray(root, "rustReports", maximum: 2)
        let rust = try rustValues.map { try controllerValidateRustReport($0, repository: repository, sessionPath: sessionPath) }
        let failures = try controllerStrings(root, "orchestrationFailures", maximum: 128)
        let cancelled = try controllerBool(root, "cancelled")
        guard !phases.contains(where: { $0.cancelled }) || cancelled else { throw StrictJSONError.invalidSchema }
        let nativeFailure = phases.compactMap(\.termination).first { controllerExitCode($0) != 0 }
        guard try controllerTermination(root.requiredValue(forKey: "nativeFailure")) == nativeFailure else { throw StrictJSONError.invalidSchema }
        var passed = false
        if let report = root.value(forKey: "report"), report != .null {
            let object = try report.requireObject().project(requiredKeys: ["status", "sourceSHA256", "toolchainSHA256", "commandSHA256", "key", "receiptPath", "executions"])
            let source = try controllerString(object, "sourceSHA256"), toolchain = try controllerString(object, "toolchainSHA256")
            let command = try CanonicalJSONDigest.sha256(.array(NotikaDevelopmentPreflight.steps.map(\.commandMaterial)))
            let key = try CanonicalJSONDigest.sha256(.object(["schemaVersion": .integer(1), "sourceIdentitySHA256": .string(source),
                "toolchainIdentitySHA256": .string(toolchain), "commandSHA256": .string(command)]))
            guard source == sourceBeforeSHA256, preflightDigest(toolchain), try controllerString(object, "commandSHA256") == command,
                  try controllerString(object, "key") == key,
                  controllerSame(try controllerString(object, "receiptPath"), repository + "/Untracked/DevelopmentPreflight/" + key + ".json") else {
                throw StrictJSONError.invalidSchema
            }
            let executions = try controllerArray(object, "executions", maximum: 19)
            let status = try controllerString(object, "status")
            if status == "reused" {
                guard executions.isEmpty, phases.isEmpty, rust.isEmpty else { throw StrictJSONError.invalidSchema }
                passed = true
            } else {
                guard status == "passed" || status == "failed", !executions.isEmpty else { throw StrictJSONError.invalidSchema }
                var cursor = 0, rustCursor = 0, outcomes: [NotikaPreflightCommandOutcome] = []
                for (index, execution) in executions.enumerated() {
                    let item = try execution.requireObject().project(requiredKeys: ["step", "outcome"])
                    let step = NotikaDevelopmentPreflight.steps[index]
                    guard try controllerString(item, "step") == step.name, outcomes.allSatisfy(\.succeeded) else { throw StrictJSONError.invalidSchema }
                    let outcome = try controllerValidateOutcome(item.requiredValue(forKey: "outcome"))
                    switch step.operation {
                    case .helper(let arguments, _):
                        guard cursor < phases.count else { throw StrictJSONError.invalidSchema }
                        let phase = phases[cursor]
                        try controllerRequireCommand(phase.command, arguments: arguments, repository: repository, fixture: allowFixtureAdmission)
                        guard outcome == phase.outcome else { throw StrictJSONError.invalidSchema }
                        cursor += 1
                    case .rust(let family):
                        guard rustCursor < rust.count, rust[rustCursor].identity.family == family,
                              outcome == rust[rustCursor].outcome else { throw StrictJSONError.invalidSchema }
                        let count = rust[rustCursor].commands.count
                        guard cursor + count <= phases.count else { throw StrictJSONError.invalidSchema }
                        for offset in 0..<count {
                            let phase = phases[cursor + offset]
                            guard try CanonicalJSONDigest.encode(phase.command) == CanonicalJSONDigest.encode(rust[rustCursor].commands[offset]),
                                  phase.outcome == rust[rustCursor].outcomes[offset] else { throw StrictJSONError.invalidSchema }
                        }
                        cursor += count; rustCursor += 1
                    }
                    outcomes.append(outcome)
                }
                guard cursor == phases.count, rustCursor == rust.count else { throw StrictJSONError.invalidSchema }
                passed = executions.count == NotikaDevelopmentPreflight.steps.count && outcomes.allSatisfy(\.succeeded)
                guard (status == "passed") == passed else { throw StrictJSONError.invalidSchema }
            }
        } else {
            // Setup/identity failures may follow real phases. Never invent a
            // passing receipt or discard an observed native failure.
            guard !failures.isEmpty || cancelled else { throw StrictJSONError.invalidSchema }
        }
        let success = passed && !cancelled && failures.isEmpty && phases.allSatisfy(\.succeeded) && rust.allSatisfy { $0.outcome.succeeded }
        guard try controllerBool(root, "succeeded") == success else { throw StrictJSONError.invalidSchema }
        return (success, nativeFailure, cancelled)
    }
}

extension NotikaDevelopmentPreflight {
    /// Live adapter. Session ownership and the compatible Xcode cache are
    /// borrowed; Rust acquires its independent policy/cache before host:compile.
    public func runCaptured(helperExecutable: String, session: NotikaBuildSession, ownership: ProjectOwnership,
                            custody: NotikaCacheCustody, admittedSourceDigest: String,
                            environment: [String: String], additionalRetainedDescriptors: [Int32] = [],
                            waitSeconds: Double? = nil) async -> NotikaDevelopmentPreflightEvidence {
        do {
            let writer = try session.inheritedDescriptors() + additionalRetainedDescriptors
            try custody.revalidateBeforeOperation()
            guard let directory = try custody.inheritedDirectoryDescriptors().dropLast(3).last else { throw NotikaDevelopmentPreflightError.ownershipMismatch }
            let artifacts = try NotikaControllerSessionArtifacts(borrowingSessionPath: session.path, repository: session.canonicalRepository)
            return await runCapturedBorrowingArtifacts(helperExecutable: helperExecutable, artifacts: artifacts, ownership: ownership,
                retainedWriterDescriptors: writer, nativeDirectoryDescriptor: directory, admittedSourceDigest: admittedSourceDigest,
                environment: environment, waitSeconds: waitSeconds, validate: {
                    _ = try session.inheritedDescriptors(); try custody.revalidateBeforeOperation()
                })
        } catch {
            let state = PreflightCapturedState(); state.failure(error)
            return state.evidence(report: nil, cancelled: Task.isCancelled)
        }
    }

    internal typealias CapturedOperation = @Sendable (String, DarwinWorkloadCommand, [Int32], String, Int32) async throws -> CapturedNativePhase
    /// Shared adapter below actual writer/project scopes. Standalone preflight
    /// borrows graph-only ownership; broad Xcode routes additionally validate
    /// their admitted cache without creating a second graph or compile lease.
    internal func runCapturedBorrowingArtifacts(
        helperExecutable: String, artifacts: NotikaControllerSessionArtifacts, ownership: ProjectOwnership,
        retainedWriterDescriptors: [Int32], nativeDirectoryDescriptor: Int32, admittedSourceDigest: String? = nil,
        environment: [String: String], waitSeconds: Double? = nil, identityOperation: IdentityOperation? = nil,
        captureOperation: CapturedOperation? = nil, validate: @escaping @Sendable () throws -> Void = {}
    ) async -> NotikaDevelopmentPreflightEvidence {
        let state = PreflightCapturedState()
        var report: NotikaDevelopmentPreflightReport?
        do {
            try validate(); try artifacts.revalidate()
            let temporary = try artifacts.createPrivateDirectory(named: "tmp")
            let runID = URL(fileURLWithPath: artifacts.path).lastPathComponent, repository = ownership.plan.canonicalWorktree
            let bindings = try NotikaRustTestExecutionBindings(sessionID: runID, temporaryDirectory: artifacts.path + "/tmp")
            let capture: CapturedOperation = captureOperation ?? { helper, command, descriptors, root, directory in
                try await CapturedNativePhaseRunner().run(helperExecutable: helper, command: command,
                    retainedLockDescriptors: descriptors, nativeWorkingDirectoryDescriptor: directory, artifactRoot: root)
            }
            let operation: CommandOperation = { command, descriptors in
                try validate(); try artifacts.revalidate(); try temporary.revalidate()
                let phase = try await capture(helperExecutable, command, descriptors, artifacts.path, nativeDirectoryDescriptor)
                state.retain(phase)
                guard try CanonicalJSONDigest.encode(controllerCommandValue(phase.command)) == CanonicalJSONDigest.encode(controllerCommandValue(command)) else {
                    throw StrictJSONError.invalidSchema
                }
                try artifacts.revalidate(); try temporary.revalidate(); try validate()
                return controllerOutcome(phase)
            }
            report = try await run(repository: repository, ownership: ownership, environment: environment,
                admittedSourceDigest: admittedSourceDigest, identityOperation: identityOperation,
                commandOperation: { command, descriptors in try await operation(command, retainedWriterDescriptors + descriptors) },
                rustOperation: { family, context in
                    let bound = NotikaPreflightRustContext(repository: context.repository, environment: context.environment,
                        ownership: context.ownership, retainedLockDescriptors: retainedWriterDescriptors + context.retainedLockDescriptors)
                    let value = try await NotikaRustTestExecutor().run(family: family, context: bound, bindings: bindings,
                        commandOperation: operation, waitSeconds: waitSeconds)
                    state.retain(value)
                    return value.outcome
                }, waitSeconds: waitSeconds)
        } catch { state.failure(error) }
        return state.evidence(report: report, cancelled: Task.isCancelled)
    }
}

private final class PreflightCapturedState: Sendable {
    private struct State: Sendable { var phases: [CapturedNativePhase] = []; var rust: [NotikaRustTestReport] = []; var failures: [String] = []; var cancelled = false }
    private let state = Mutex(State())
    func retain(_ phase: CapturedNativePhase) { state.withLock { $0.phases.append(phase) } }
    func retain(_ report: NotikaRustTestReport) { state.withLock { $0.rust.append(report) } }
    func failure(_ error: Error) { state.withLock { $0.failures.append(String(describing: error)); $0.cancelled = $0.cancelled || error is CancellationError } }
    func evidence(report: NotikaDevelopmentPreflightReport?, cancelled: Bool) -> NotikaDevelopmentPreflightEvidence {
        state.withLock { .init(report: report, capturedPhases: $0.phases, rustReports: $0.rust, orchestrationFailures: $0.failures,
            cancelled: cancelled || $0.cancelled || $0.phases.contains { $0.observation.cancelled }) }
    }
}

internal func controllerOutcome(_ phase: CapturedNativePhase) -> NotikaPreflightCommandOutcome {
    .init(nativeTermination: phase.observation.termination,
        retirementProven: phase.observation.retirement == .workerReaped || phase.observation.retirement == .notStarted,
        cancelled: phase.observation.cancelled, failures: phase.observation.failures)
}
internal func controllerExitCode(_ value: RunTermination) -> Int32 { value.kind == .exit ? value.value : 128 + value.value }
internal func controllerEncoded<T: Encodable>(_ value: T) throws -> CanonicalJSONValue {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try controllerCanonical(StrictJSONDocument(data: encoder.encode(value)).root)
}
internal func controllerCanonical(_ value: StrictJSONValue) throws -> CanonicalJSONValue {
    switch value {
    case .null: .null
    case .bool(let value): .bool(value)
    case .string(let value): .string(value)
    case .number(let value): value.lexicalValue.hasPrefix("-") ? .integer(try value.int64()) : .unsignedInteger(try value.uint64())
    case .array(let values): .array(try values.map(controllerCanonical))
    case .object(let object): .object(try object.members.map { CanonicalJSONMember(key: $0.key, value: try controllerCanonical($0.value)) })
    }
}
internal func controllerCommandValue(_ command: DarwinWorkloadCommand) throws -> CanonicalJSONValue {
    .object(["executable": .string(command.executable), "arguments": .array(command.arguments.map(CanonicalJSONValue.string)),
        "workingDirectory": .string(command.workingDirectory),
        "environmentSHA256": .string(try CanonicalJSONDigest.sha256(.object(command.environment.mapValues(CanonicalJSONValue.string))))])
}
internal func controllerOutcomeValue(_ value: NotikaPreflightCommandOutcome) throws -> CanonicalJSONValue {
    .object(["nativeTermination": try controllerEncoded(value.nativeTermination), "retirementProven": .bool(value.retirementProven),
        "cancelled": .bool(value.cancelled), "failures": try controllerEncoded(value.failures)])
}
internal func controllerPhaseValue(_ phase: CapturedNativePhase) throws -> CanonicalJSONValue {
    .object(["command": try controllerCommandValue(phase.command), "nativeTermination": try controllerEncoded(phase.observation.termination),
        "retirement": .string(phase.observation.retirement.rawValue), "cancelled": .bool(phase.observation.cancelled),
        "failures": try controllerEncoded(phase.observation.failures), "rawCapture": try controllerEncoded(phase.rawCapture)])
}
internal struct ControllerParsedPhase {
    let command: CanonicalJSONValue; let outcome: NotikaPreflightCommandOutcome
    var termination: RunTermination? { outcome.nativeTermination }; var cancelled: Bool { outcome.cancelled }; var succeeded: Bool { outcome.succeeded }
}
internal func controllerValidatePhase(_ value: StrictJSONValue, repository: String, sessionPath: String) throws -> ControllerParsedPhase {
    let phase = try value.requireObject().project(requiredKeys: ["command", "nativeTermination", "retirement", "cancelled", "failures", "rawCapture"])
    let command = try controllerValidateCommand(phase.requiredValue(forKey: "command"), repository: repository)
    let native = try controllerTermination(phase.requiredValue(forKey: "nativeTermination"))
    let retirement = try controllerString(phase, "retirement")
    guard NotikaNativeRetirementEvidence(rawValue: retirement) != nil,
          (retirement == "workerReaped") == (native != nil) else { throw StrictJSONError.invalidSchema }
    let failures = try controllerFailures(phase.requiredValue(forKey: "failures"), capture: false)
    let rawObject = try phase.requiredValue(forKey: "rawCapture").requireObject().project(requiredKeys: ["standardOutput", "standardError", "maximumBytes", "captureComplete", "failures"])
    for name in ["standardOutput", "standardError"] {
        let stream = try rawObject.requiredValue(forKey: name).requireObject().project(requiredKeys: ["path", "observedBytes", "retainedBytes", "sha256", "reachedEOF"])
        let path = try controllerString(stream, "path"), prefix = sessionPath + "/"
        let relative = path.utf8.starts(with: prefix.utf8) ? String(path.dropFirst(prefix.count)) : ""
        let pieces = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2, UUID(uuidString: String(pieces[0])) != nil,
              pieces[1] == (name == "standardOutput" ? "stdout.log" : "stderr.log"),
              preflightDigest(try controllerString(stream, "sha256")),
              try controllerUnsigned(stream, "retainedBytes") <= controllerUnsigned(stream, "observedBytes") else { throw StrictJSONError.invalidSchema }
        _ = try controllerBool(stream, "reachedEOF")
    }
    _ = try controllerFailures(rawObject.requiredValue(forKey: "failures"), capture: true)
    let raw = try JSONDecoder().decode(NativeLogCaptureResult.self, from: CanonicalJSONDigest.encode(controllerCanonical(.object(rawObject))))
    guard (0...NativeLogCapture.maximumRawBytes).contains(raw.maximumBytes),
          (0...raw.maximumBytes).contains(raw.standardOutput.retainedBytes), (0...raw.maximumBytes).contains(raw.standardError.retainedBytes),
          raw.standardOutput.retainedBytes + raw.standardError.retainedBytes <= raw.maximumBytes else { throw StrictJSONError.invalidSchema }
    if raw.captureComplete {
        guard raw.failures.isEmpty, raw.standardOutput.reachedEOF, raw.standardError.reachedEOF,
              raw.standardOutput.observedBytes == raw.standardOutput.retainedBytes,
              raw.standardError.observedBytes == raw.standardError.retainedBytes else { throw StrictJSONError.invalidSchema }
    } else { guard !failures.isEmpty else { throw StrictJSONError.invalidSchema } }
    return .init(command: command, outcome: .init(nativeTermination: native, retirementProven: retirement == "workerReaped" || retirement == "notStarted",
        cancelled: try controllerBool(phase, "cancelled"), failures: failures))
}
internal func controllerValidateCommand(_ value: StrictJSONValue, repository: String) throws -> CanonicalJSONValue {
    let command = try value.requireObject().project(requiredKeys: ["executable", "arguments", "workingDirectory", "environmentSHA256"])
    let path = try controllerString(command, "executable")
    guard path.hasPrefix("/"), !path.utf8.contains(0), try controllerString(command, "workingDirectory").utf8.elementsEqual(repository.utf8),
          preflightDigest(try controllerString(command, "environmentSHA256")) else { throw StrictJSONError.invalidSchema }
    _ = try controllerStrings(command, "arguments", maximum: 128)
    return try controllerCanonical(.object(command))
}
private func controllerRequireCommand(_ value: CanonicalJSONValue, arguments: [String], repository: String, fixture: Bool) throws {
    let command = try StrictJSONDocument(data: CanonicalJSONDigest.encode(value)).root.requireObject()
    guard controllerSameArguments(try controllerStrings(command, "arguments", maximum: 128), Array(arguments.dropFirst())) else { throw StrictJSONError.invalidSchema }
    let executable = try controllerString(command, "executable"), name = arguments[0]
    if name.hasPrefix("/") { guard controllerSame(executable, name) else { throw StrictJSONError.invalidSchema } }
    else if name.contains("/") { guard controllerSame(executable, repository + "/" + name) else { throw StrictJSONError.invalidSchema } }
    else { guard URL(fileURLWithPath: executable).lastPathComponent == name || fixture else { throw StrictJSONError.invalidSchema } }
}
internal func controllerValidateOutcome(_ value: StrictJSONValue) throws -> NotikaPreflightCommandOutcome {
    let object = try value.requireObject().project(requiredKeys: ["nativeTermination", "retirementProven", "cancelled", "failures"])
    return .init(nativeTermination: try controllerTermination(object.requiredValue(forKey: "nativeTermination")),
        retirementProven: try controllerBool(object, "retirementProven"), cancelled: try controllerBool(object, "cancelled"),
        failures: try controllerFailures(object.requiredValue(forKey: "failures"), capture: false))
}
internal func controllerTermination(_ value: StrictJSONValue) throws -> RunTermination? {
    if value == .null { return nil }
    let object = try value.requireObject().project(requiredKeys: ["kind", "value"])
    let kind = try controllerString(object, "kind"), number = try controllerInteger(object, "value")
    guard let int = Int32(exactly: number), (kind == "exit" && (0...255).contains(int)) || (kind == "signal" && (1...127).contains(int)) else { throw StrictJSONError.invalidSchema }
    return .init(kind: kind == "exit" ? .exit : .signal, value: int)
}
internal func controllerFailures(_ value: StrictJSONValue, capture: Bool) throws -> [DarwinWorkloadFailure] {
    guard case .array(let values) = value, values.count <= 128 else { throw StrictJSONError.invalidSchema }
    for value in values {
        let item = try value.requireObject().project(requiredKeys: ["operation"], optionalKeys: capture ? ["code", "detail", "stream"] : ["code", "detail"])
        guard !(try controllerString(item, "operation")).isEmpty else { throw StrictJSONError.invalidSchema }
        if let value = item.value(forKey: "code"), value != .null { guard case .number(let number) = value, Int32(exactly: try number.int64()) != nil else { throw StrictJSONError.invalidSchema } }
        if let value = item.value(forKey: "detail"), value != .null { guard case .string = value else { throw StrictJSONError.invalidSchema } }
        if let value = item.value(forKey: "stream"), value != .null { guard case .string(let name) = value, NativeLogStream(rawValue: name) != nil else { throw StrictJSONError.invalidSchema } }
    }
    if capture { return [] }
    return try JSONDecoder().decode([DarwinWorkloadFailure].self, from: CanonicalJSONDigest.encode(controllerCanonical(value)))
}
internal func controllerString(_ object: StrictJSONObject, _ key: String) throws -> String {
    guard case .string(let value) = try object.requiredValue(forKey: key), !value.utf8.contains(0) else { throw StrictJSONError.invalidSchema }; return value
}
internal func controllerBool(_ object: StrictJSONObject, _ key: String) throws -> Bool {
    guard case .bool(let value) = try object.requiredValue(forKey: key) else { throw StrictJSONError.invalidSchema }; return value
}
internal func controllerInteger(_ object: StrictJSONObject, _ key: String) throws -> Int64 {
    guard case .number(let value) = try object.requiredValue(forKey: key) else { throw StrictJSONError.invalidSchema }; return try value.int64()
}
internal func controllerUnsigned(_ object: StrictJSONObject, _ key: String) throws -> UInt64 {
    guard case .number(let value) = try object.requiredValue(forKey: key) else { throw StrictJSONError.invalidSchema }; return try value.uint64()
}
internal func controllerArray(_ object: StrictJSONObject, _ key: String, maximum: Int) throws -> [StrictJSONValue] {
    guard case .array(let values) = try object.requiredValue(forKey: key), values.count <= maximum else { throw StrictJSONError.invalidSchema }; return values
}
internal func controllerStrings(_ object: StrictJSONObject, _ key: String, maximum: Int) throws -> [String] {
    try controllerArray(object, key, maximum: maximum).map { guard case .string(let value) = $0, !value.utf8.contains(0) else { throw StrictJSONError.invalidSchema }; return value }
}

internal func controllerRustReportValue(_ report: NotikaRustTestReport) throws -> CanonicalJSONValue {
    .object(["identity": report.identity.keyMaterial,
        "cache": .object(["deviceID": .unsignedInteger(report.cache.deviceID), "inode": .unsignedInteger(report.cache.inode), "ownerUID": .unsignedInteger(UInt64(report.cache.ownerUID))]),
        "sourceBeforeSHA256": .string(report.sourceBeforeDigest), "sourceAfterSHA256": report.sourceAfterDigest.map(CanonicalJSONValue.string) ?? .null,
        "commands": .array(try report.commands.map(controllerCommandValue)), "outcomes": .array(try report.outcomes.map(controllerOutcomeValue)),
        "outcome": try controllerOutcomeValue(report.outcome),
        "usage": try report.usage.map { try controllerCanonical($0.document.root) } ?? .null,
        "metadataWriteIssues": .array(report.metadataWriteIssues.map { .string(String(describing: $0)) })])
}
internal struct ControllerParsedRustReport {
    let identity: NotikaRustCacheIdentity
    let commands: [CanonicalJSONValue]
    let outcomes: [NotikaPreflightCommandOutcome]
    let outcome: NotikaPreflightCommandOutcome
    let sourceBefore: String
    let sourceAfter: String?
}
internal func controllerValidateRustReport(_ value: StrictJSONValue, repository: String, sessionPath: String) throws -> ControllerParsedRustReport {
    let root = try value.requireObject().project(requiredKeys: ["identity", "cache", "sourceBeforeSHA256", "sourceAfterSHA256", "commands", "outcomes", "outcome", "usage", "metadataWriteIssues"])
    let material = try root.requiredValue(forKey: "identity").requireObject().project(requiredKeys: ["schemaVersion", "canonicalWorktree", "family", "targetKind", "inputs", "toolchain"])
    guard try controllerInteger(material, "schemaVersion") == 1, controllerSame(try controllerString(material, "canonicalWorktree"), repository),
          try controllerString(material, "targetKind") == "host-debug-cargo-test",
          let family = NotikaRustTestFamily(rawValue: try controllerString(material, "family")) else { throw StrictJSONError.invalidSchema }
    let inputObject = try material.requiredValue(forKey: "inputs").requireObject().project(requiredKeys: NotikaRustCacheIdentity.inputPaths(family))
    var inputs: [String: String] = [:]
    for name in NotikaRustCacheIdentity.inputPaths(family) { inputs[name] = try controllerString(inputObject, name) }
    let toolchain = try material.requiredValue(forKey: "toolchain").requireObject().project(requiredKeys: ["mise", "rustc", "sysroot", "cargo"])
    let mise = try toolchain.requiredValue(forKey: "mise").requireObject().project(requiredKeys: ["path", "sha256"])
    let identity = try NotikaRustCacheIdentity(repository: repository, family: family, inputs: inputs,
        misePath: controllerString(mise, "path"), miseDigest: controllerString(mise, "sha256"), rustc: controllerString(toolchain, "rustc"),
        sysroot: controllerString(toolchain, "sysroot"), cargo: controllerString(toolchain, "cargo"))
    guard try CanonicalJSONDigest.encode(identity.keyMaterial) == CanonicalJSONDigest.encode(controllerCanonical(.object(material))) else { throw StrictJSONError.invalidSchema }
    let cache = try root.requiredValue(forKey: "cache").requireObject().project(requiredKeys: ["deviceID", "inode", "ownerUID"])
    guard let owner = UInt32(exactly: try controllerUnsigned(cache, "ownerUID")), try controllerUnsigned(cache, "inode") > 0 else { throw StrictJSONError.invalidSchema }
    let observation = try NotikaRustCacheObservation(identity: identity, deviceID: controllerUnsigned(cache, "deviceID"), inode: controllerUnsigned(cache, "inode"), ownerUID: owner)
    let sourceBefore = try controllerString(root, "sourceBeforeSHA256")
    let sourceValue = try root.requiredValue(forKey: "sourceAfterSHA256")
    let sourceAfter: String?
    if sourceValue == .null { sourceAfter = nil }
    else { sourceAfter = try controllerString(root, "sourceAfterSHA256") }
    guard preflightDigest(sourceBefore), sourceAfter.map(preflightDigest) ?? true else { throw StrictJSONError.invalidSchema }
    let commands = try controllerArray(root, "commands", maximum: 2).map { try controllerValidateCommand($0, repository: repository) }
    let outcomes = try controllerArray(root, "outcomes", maximum: 2).map(controllerValidateOutcome)
    guard !commands.isEmpty, commands.count == outcomes.count else { throw StrictJSONError.invalidSchema }
    for (index, command) in commands.enumerated() {
        let object = try StrictJSONDocument(data: CanonicalJSONDigest.encode(command)).root.requireObject()
        let executable = index == 0 ? repository + "/Scripts/bridges/" + identity.licenseScript : identity.misePath
        let arguments = index == 0 ? ["check"] : ["exec"] + identity.pins + ["--", "cargo", "test", "--locked", "--manifest-path", "Rust/" + identity.crate + "/Cargo.toml"]
        guard controllerSame(try controllerString(object, "executable"), executable), controllerSameArguments(try controllerStrings(object, "arguments", maximum: 128), arguments),
              index == 0 || outcomes[index - 1].succeeded else { throw StrictJSONError.invalidSchema }
    }
    let outcome = try controllerValidateOutcome(root.requiredValue(forKey: "outcome"))
    let last = outcomes.last!
    guard outcome.nativeTermination == last.nativeTermination, outcome.retirementProven == last.retirementProven,
          !last.cancelled || outcome.cancelled, outcome.failures.starts(with: last.failures) else { throw StrictJSONError.invalidSchema }
    if outcome.succeeded {
        guard commands.count == 2, outcomes.allSatisfy(\.succeeded), sourceAfter == sourceBefore else { throw StrictJSONError.invalidSchema }
    }
    if let usage = root.value(forKey: "usage"), usage != .null {
        let admitted = try NotikaRustCacheUsageRecord(data: CanonicalJSONDigest.encode(controllerCanonical(usage)), identity: identity, observation: observation)
        guard admitted.lastSessionID == URL(fileURLWithPath: sessionPath).lastPathComponent,
              last.retirementProven, last.nativeTermination != nil else { throw StrictJSONError.invalidSchema }
    } else if outcome.succeeded { throw StrictJSONError.invalidSchema }
    _ = try controllerStrings(root, "metadataWriteIssues", maximum: 128)
    return .init(identity: identity, commands: commands, outcomes: outcomes, outcome: outcome, sourceBefore: sourceBefore, sourceAfter: sourceAfter)
}

internal func controllerSame(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }
internal func controllerSameArguments(_ lhs: [String], _ rhs: [String]) -> Bool { lhs.map { Data($0.utf8) } == rhs.map { Data($0.utf8) } }
