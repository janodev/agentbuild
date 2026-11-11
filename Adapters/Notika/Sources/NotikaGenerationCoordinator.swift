import AgentBuildCore
import AgentLeaseCore
import Darwin
import Foundation

/// The adapter supplies authenticated native completion only after its helper,
/// capture and workload are quiescent. Exit zero alone is insufficient.
public struct NotikaGenerationCommandOutcome: Equatable, Sendable {
    public let nativeTermination: RunTermination?
    public let retirementProven: Bool
    public let cancelled: Bool
    public let failures: [DarwinWorkloadFailure]

    public init(nativeTermination: RunTermination?, retirementProven: Bool,
                cancelled: Bool = false, failures: [DarwinWorkloadFailure] = []) {
        self.nativeTermination = nativeTermination
        self.retirementProven = retirementProven
        self.cancelled = cancelled
        self.failures = failures
    }

    public var succeeded: Bool {
        nativeTermination == RunTermination(kind: .exit, value: 0) && retirementProven && !cancelled && failures.isEmpty
    }
}

public enum NotikaGenerationError: Error, Equatable, Sendable {
    case invalidRepository
    case unsafePath(String)
    case fileSystem(operation: String, path: String, code: Int32)
    case commandFailed(step: String, outcome: NotikaGenerationCommandOutcome)
    case retirementIncomplete(String)
    case invalidProject
    case observationBudgetExceeded
}

public struct NotikaGenerationCommandObservation: Sendable {
    public let step: String
    public let command: DarwinWorkloadCommand
    public let outcome: NotikaGenerationCommandOutcome
}

public struct NotikaGenerationReport: Sendable {
    public let repository: String
    public let cached: Bool
    public let sourceBefore: NotikaSourceIdentity
    public let sourceAfter: NotikaSourceIdentity
    public let commands: [NotikaGenerationCommandObservation]
    public let retiredGraphEntries: [String]
    public let retirementOutcomes: [NotikaGenerationCommandOutcome]
    public let removedWorkspaceScheme: Bool
}

/// A fixed graph root entry checked against a pinned repository directory.
/// The descriptor is borrowed while the retirement operation is awaited; it
/// is not an AgentLease descriptor and must not be forwarded as route authority.
public struct NotikaGeneratedGraphEntry: Sendable {
    public let absolutePath: String
    public let relativeName: String
    public let device: UInt64
    public let inode: UInt64
    private let parent: NotikaGraphDirectory

    public var parentDescriptor: Int32 { parent.descriptor }

    fileprivate init(parent: NotikaGraphDirectory, name: String, metadata: stat) {
        self.parent = parent
        relativeName = name
        absolutePath = parent.path + "/" + name
        device = UInt64(metadata.st_dev)
        inode = UInt64(metadata.st_ino)
    }

    public func validate() throws {
        try parent.validate()
        guard let metadata = try parent.metadata(relativeName),
              UInt64(metadata.st_dev) == device, UInt64(metadata.st_ino) == inode,
              metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == geteuid() else {
            throw NotikaGenerationError.unsafePath(absolutePath)
        }
    }
}

/// Generation owns the exclusive graph throughout preparation and Tuist execution.
/// It does not acquire host compilation admission. No freshness receipt is inferred.
/// Both injected operations must await complete child retirement before return.
public struct NotikaGenerationCoordinator: Sendable {
    public typealias CommandOperation = @Sendable (DarwinWorkloadCommand, [Int32]) async throws -> NotikaGenerationCommandOutcome
    public typealias RetirementOperation = @Sendable (NotikaGeneratedGraphEntry, [Int32]) async throws -> NotikaGenerationCommandOutcome

    public init() {}

    public func run(
        repository: String, registryRoot: String, environment: [String: String] = ProcessInfo.processInfo.environment,
        cached: Bool = false, waitSeconds: Double? = nil,
        identityCapture: (any RepositoryCommandCapturing)? = nil,
        commandOperation: @escaping CommandOperation,
        retirementOperation: @escaping RetirementOperation
    ) async throws -> NotikaGenerationReport {
        let root = try NotikaGraphDirectory(repository)
        let plan = try NotikaProjectOwnershipPlan(generationFor: root.path)
        let identity = try NotikaRepositoryIdentity(repository: root.path, capture: identityCapture, environment: environment)
        return try await NotikaProjectAdmission().withOwnership(
            plan, registryRoot: registryRoot, label: "Notika project generation", waitSeconds: waitSeconds
        ) { ownership in
            try root.validate()
            // Reject unsafe root substitutions before running preparation tools.
            _ = try root.graphEntries()
            let before = try await identity.sourceIdentity()
            let graphDescriptors = try ownership.inheritedDescriptors()
            var observations: [NotikaGenerationCommandObservation] = []
            var childEnvironment = environment.filter { name, _ in
                !name.hasPrefix("NOTIKA_ROUTE_") && !name.hasPrefix("NOTIKA_INTERACTIVE_") &&
                !name.hasPrefix("NOTIKA_GENERATED_GRAPH_") && !name.hasPrefix("NOTIKA_TEXT_PERFORMANCE_TREE_HANDOFF_") &&
                !["NOTIKA_REPORT_HANDOFF_FD", "NOTIKA_TEXT_INPUT_PERFORMANCE_ROOT_DEVICE_ID",
                  "NOTIKA_TEXT_PERFORMANCE_ROOT_INODE", "NOTIKA_TEXT_INPUT_PERFORMANCE_ROOT_INODE",
                  "AGENTLEASE_LEASE_DESCRIPTORS", "AGENTLEASE_HELD_RESOURCES", "AGENTLEASE_RUN_ID"].contains(name)
            }
            childEnvironment["SRCROOT"] = root.path
            childEnvironment.removeValue(forKey: "USE_CACHED_DEPENDENCIES")
            for name in ["prepare-htt-mini.sh", "prepare-onnxruntime.sh"] {
                try Task.checkCancellation()
                try root.validate()
                let command = try DarwinWorkloadCommand(executable: root.path + "/Scripts/bridges/" + name,
                                                       workingDirectory: root.path, environment: childEnvironment)
                let outcome = try await commandOperation(command, graphDescriptors)
                observations.append(.init(step: name, command: command, outcome: outcome))
                try requireGenerationSuccess(outcome, step: name)
            }
            var retired: [String] = []
            var retirementOutcomes: [NotikaGenerationCommandOutcome] = []
            // Preparations must pass before prior generated output is retired.
            // Admit the entire old graph before the first destructive operation:
            // an unsafe workspace must not leave an already-retired project.
            let graphEntries = try root.graphEntries()
            for entry in graphEntries {
                try entry.validate()
                try root.validateTree(entry.relativeName)
            }
            for entry in graphEntries {
                try Task.checkCancellation()
                try entry.validate()
                try root.validateTree(entry.relativeName)
                let outcome = try await retirementOperation(entry, graphDescriptors)
                try requireGenerationSuccess(outcome, step: "retire-" + entry.relativeName)
                try root.validate()
                guard try root.metadata(entry.relativeName) == nil else {
                    throw NotikaGenerationError.retirementIncomplete(entry.absolutePath)
                }
                retired.append(entry.relativeName)
                retirementOutcomes.append(outcome)
            }
            let tuistEnvironment = childEnvironment.merging(cached ? ["USE_CACHED_DEPENDENCIES": "1"] : [:]) { _, new in new }
            let tuist = try DarwinWorkloadCommand(executable: root.path + "/Scripts/tuist", arguments: ["generate", "--no-open"],
                                                 workingDirectory: root.path, environment: tuistEnvironment)
            try root.validate()
            let outcome = try await commandOperation(tuist, graphDescriptors)
            observations.append(.init(step: "tuist-generate", command: tuist, outcome: outcome))
            try requireGenerationSuccess(outcome, step: "tuist-generate")
            try Task.checkCancellation()
            _ = try NotikaGeneratedWorkspace.validate(repository: root.path)
            let removed = try root.removeWorkspaceScheme()
            let after = try await identity.sourceIdentity()
            try root.validate()
            return NotikaGenerationReport(repository: root.path, cached: cached, sourceBefore: before, sourceAfter: after,
                                          commands: observations, retiredGraphEntries: retired, retirementOutcomes: retirementOutcomes,
                                          removedWorkspaceScheme: removed)
        }
    }
}

private func requireGenerationSuccess(_ outcome: NotikaGenerationCommandOutcome, step: String) throws {
    guard outcome.succeeded else { throw NotikaGenerationError.commandFailed(step: step, outcome: outcome) }
    try Task.checkCancellation()
}

/// Pinned directory ownership is limited to the checked root and traversed
/// descriptors; this helper does not claim custody against arbitrary writers.
fileprivate final class NotikaGraphDirectory: Sendable {
    let path: String
    let descriptor: Int32
    private let device: dev_t
    private let inode: ino_t

    init(_ path: String) throws {
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              let resolved = try graphCanonicalPath(path), resolved.utf8.elementsEqual(path.utf8) else {
            throw NotikaGenerationError.invalidRepository
        }
        let descriptor = path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw graphSystemError("open repository", path) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(), status.st_mode & 0o022 == 0 else {
            close(descriptor)
            throw NotikaGenerationError.unsafePath(path)
        }
        var named = stat()
        guard path.withCString({ lstat($0, &named) }) == 0, named.st_mode & S_IFMT == S_IFDIR,
              named.st_dev == status.st_dev, named.st_ino == status.st_ino else {
            close(descriptor)
            throw NotikaGenerationError.unsafePath(path)
        }
        self.path = path
        self.descriptor = descriptor
        device = status.st_dev
        inode = status.st_ino
    }

    deinit { close(descriptor) }

    func validate() throws {
        var status = stat()
        guard path.withCString({ lstat($0, &status) }) == 0,
              status.st_mode & S_IFMT == S_IFDIR, status.st_dev == device, status.st_ino == inode,
              status.st_uid == geteuid(), status.st_mode & 0o022 == 0 else {
            throw NotikaGenerationError.unsafePath(path)
        }
    }

    func metadata(_ name: String) throws -> stat? { try graphMetadata(descriptor, name, path: path + "/" + name) }

    func graphEntries() throws -> [NotikaGeneratedGraphEntry] {
        try validate()
        return try ["Notika.xcodeproj", "Notika.xcworkspace"].compactMap { name in
            guard let status = try metadata(name) else { return nil }
            guard status.st_mode & S_IFMT == S_IFDIR, status.st_uid == geteuid(), status.st_mode & 0o022 == 0 else {
                throw NotikaGenerationError.unsafePath(path + "/" + name)
            }
            return NotikaGeneratedGraphEntry(parent: self, name: name, metadata: status)
        }
    }

    func validateTree(_ name: String) throws {
        var remaining = 100_000
        func visit(_ parent: Int32, _ name: String, _ relative: String, depth: Int) throws {
            try Task.checkCancellation()
            let display = path + "/" + relative
            remaining -= 1
            guard remaining >= 0, depth <= 128 else { throw NotikaGenerationError.observationBudgetExceeded }
            guard let status = try graphMetadata(parent, name, path: display), status.st_uid == geteuid() else {
                throw NotikaGenerationError.unsafePath(display)
            }
            // Moving a symlink to Trash never traverses its target.
            guard status.st_mode & S_IFMT == S_IFDIR else { return }
            // Xcode/Tuist creates this real owned directory with mode 0777.
            // It is supported generated output, not a permission repair target.
            // The exception is one literal directory, never its descendants.
            let swiftPMConfiguration = relative.utf8.elementsEqual(
                "Notika.xcworkspace/xcshareddata/swiftpm/configuration".utf8
            )
            guard status.st_mode & 0o022 == 0 || swiftPMConfiguration else {
                throw NotikaGenerationError.unsafePath(display)
            }
            let child = try graphOpenDirectory(parent, name, path: display)
            defer { close(child) }
            var opened = stat()
            guard fstat(child, &opened) == 0, opened.st_dev == status.st_dev, opened.st_ino == status.st_ino else {
                throw NotikaGenerationError.unsafePath(display)
            }
            for entry in try graphDirectoryNames(child, path: display) { try visit(child, entry, relative + "/" + entry, depth: depth + 1) }
        }
        try visit(descriptor, name, name, depth: 0)
    }

    func removeWorkspaceScheme() throws -> Bool {
        let workspace = try graphOpenDirectory(descriptor, "Notika.xcworkspace", path: path + "/Notika.xcworkspace")
        defer { close(workspace) }
        guard let shared = try graphOptionalDirectory(workspace, "xcshareddata", path: path + "/Notika.xcworkspace/xcshareddata") else { return false }
        defer { close(shared) }
        guard let schemes = try graphOptionalDirectory(shared, "xcschemes", path: path + "/Notika.xcworkspace/xcshareddata/xcschemes") else { return false }
        defer { close(schemes) }
        let name = "Notika-Workspace.xcscheme"
        let display = path + "/Notika.xcworkspace/xcshareddata/xcschemes/" + name
        guard let status = try graphMetadata(schemes, name, path: display) else { return false }
        guard status.st_mode & S_IFMT == S_IFREG, status.st_uid == geteuid(), status.st_nlink == 1 else {
            throw NotikaGenerationError.unsafePath(display)
        }
        guard name.withCString({ unlinkat(schemes, $0, 0) }) == 0 else { throw graphSystemError("unlink workspace scheme", display) }
        return true
    }
}

public struct NotikaLocalBuildProductVisibility: Sendable {
    public let hiddenDirectories: [String]
    public let warnings: [String]
}

/// Existing generated workspace admission, not proof of generation freshness.
public struct NotikaGeneratedWorkspace: Sendable {
    public let repository: String
    public let resolvedDependenciesPath: String

    public static func validate(repository: String) throws -> NotikaGeneratedWorkspace {
        let root = try NotikaGraphDirectory(repository)
        guard try root.graphEntries().contains(where: { $0.relativeName == "Notika.xcworkspace" }) else {
            throw NotikaGenerationError.unsafePath(repository + "/Notika.xcworkspace")
        }
        let candidate = repository + "/Notika.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        guard let canonical = try graphCanonicalPath(candidate),
              canonical.utf8.starts(with: (repository + "/").utf8) else { throw NotikaGenerationError.unsafePath(candidate) }
        let descriptor = canonical.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { throw NotikaGenerationError.unsafePath(candidate) }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            throw NotikaGenerationError.unsafePath(candidate)
        }
        try root.validate()
        return NotikaGeneratedWorkspace(repository: repository, resolvedDependenciesPath: canonical)
    }

    /// Call while graph/cache ownership is held. Declared local package roots
    /// may be outside the checkout. Their DerivedData leaf must be a real owned
    /// directory; symlink leaves are skipped without changing their targets.
    public static func hideLocalBuildProducts(
        repository: String, capture: any RepositoryCommandCapturing,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> NotikaLocalBuildProductVisibility {
        let root = try NotikaGraphDirectory(repository)
        guard try root.graphEntries().contains(where: { $0.relativeName == "Notika.xcodeproj" }) else {
            throw NotikaGenerationError.unsafePath(repository + "/Notika.xcodeproj")
        }
        let projectPath = repository + "/Notika.xcodeproj/project.pbxproj"
        guard let canonicalProject = try graphCanonicalPath(projectPath),
              canonicalProject.utf8.starts(with: (repository + "/").utf8) else {
            throw NotikaGenerationError.unsafePath(projectPath)
        }
        var projectStatus = stat()
        guard canonicalProject.withCString({ lstat($0, &projectStatus) }) == 0,
              projectStatus.st_mode & S_IFMT == S_IFREG else { throw NotikaGenerationError.unsafePath(projectPath) }
        let data = try await capture.capture(arguments: ["/usr/bin/plutil", "-convert", "json", "-o", "-", "--",
                                                        repository + "/Notika.xcodeproj/project.pbxproj"],
                                             workingDirectory: repository, environment: environment)
        guard let project = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let objects = project["objects"] as? [String: Any] else { throw NotikaGenerationError.invalidProject }
        guard let currentProject = try graphCanonicalPath(projectPath),
              currentProject.utf8.elementsEqual(canonicalProject.utf8) else { throw NotikaGenerationError.unsafePath(projectPath) }
        var packageRoots = [Data(repository.utf8): repository]
        for item in objects.values {
            guard let object = item as? [String: Any], object["isa"] as? String == "XCLocalSwiftPackageReference" else { continue }
            guard let relative = object["relativePath"] as? String, !relative.isEmpty, !relative.utf8.contains(0) else {
                throw NotikaGenerationError.invalidProject
            }
            let candidate = relative.hasPrefix("/") ? relative : repository + "/" + relative
            guard let canonical = try graphCanonicalPath(candidate) else { continue }
            let packageManifest = canonical + "/Package.swift"
            var status = stat()
            if packageManifest.withCString({ stat($0, &status) }) == 0, status.st_mode & S_IFMT == S_IFREG {
                packageRoots[Data(canonical.utf8)] = canonical
            }
        }
        var hidden: [String] = []
        var warnings: [String] = []
        for package in packageRoots.values.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            try Task.checkCancellation()
            let directory = try NotikaGraphDirectory(package)
            let display = package + "/DerivedData"
            guard let status = try directory.metadata("DerivedData"), status.st_mode & S_IFMT == S_IFDIR,
                  status.st_uid == geteuid(), status.st_flags & UInt32(UF_HIDDEN) == 0 else { continue }
            let descriptor = try graphOpenDirectory(directory.descriptor, "DerivedData", path: display)
            defer { close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, opened.st_dev == status.st_dev, opened.st_ino == status.st_ino else {
                throw NotikaGenerationError.unsafePath(display)
            }
            if fchflags(descriptor, opened.st_flags | UInt32(UF_HIDDEN)) == 0 { hidden.append(display) }
            else { warnings.append("⚠️ Could not hide generated build directory \(display): \(String(cString: strerror(errno)))") }
            try directory.validate()
        }
        try root.validate()
        return NotikaLocalBuildProductVisibility(hiddenDirectories: hidden, warnings: warnings)
    }
}

func graphCanonicalPath(_ path: String) throws -> String? {
    guard !path.utf8.contains(0) else { throw NotikaGenerationError.unsafePath(path) }
    guard let canonical = path.withCString({ realpath($0, nil) }) else {
        if errno == ENOENT { return nil }
        throw graphSystemError("resolve path", path)
    }
    defer { free(canonical) }
    guard let value = String(validatingCString: canonical) else { throw NotikaGenerationError.unsafePath(path) }
    return value
}

func graphMetadata(_ parent: Int32, _ name: String, path: String) throws -> stat? {
    var status = stat()
    guard name.withCString({ fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW) }) == 0 else {
        if errno == ENOENT { return nil }
        throw graphSystemError("fstatat", path)
    }
    return status
}

func graphOpenDirectory(_ parent: Int32, _ name: String, path: String) throws -> Int32 {
    let descriptor = name.withCString { openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
    guard descriptor >= 0 else { throw NotikaGenerationError.unsafePath(path) }
    return descriptor
}

private func graphOptionalDirectory(_ parent: Int32, _ name: String, path: String) throws -> Int32? {
    guard let status = try graphMetadata(parent, name, path: path) else { return nil }
    guard status.st_mode & S_IFMT == S_IFDIR, status.st_uid == geteuid() else { throw NotikaGenerationError.unsafePath(path) }
    return try graphOpenDirectory(parent, name, path: path)
}

private func graphDirectoryNames(_ descriptor: Int32, path: String) throws -> [String] {
    let copy = dup(descriptor)
    guard copy >= 0 else { throw graphSystemError("dup", path) }
    guard let directory = fdopendir(copy) else { close(copy); throw graphSystemError("fdopendir", path) }
    defer { closedir(directory) }
    var names: [String] = []
    while true {
        errno = 0
        guard let entry = readdir(directory) else {
            if errno != 0 { throw graphSystemError("readdir", path) }
            return names
        }
        let name = try withUnsafePointer(to: &entry.pointee.d_name) { tuple in
            try tuple.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { pointer in
                guard let text = String(validatingCString: pointer) else { throw NotikaGenerationError.unsafePath(path) }
                return text
            }
        }
        if name != "." && name != ".." { names.append(name) }
    }
}

func graphSystemError(_ operation: String, _ path: String) -> NotikaGenerationError {
    .fileSystem(operation: operation, path: path, code: errno)
}
