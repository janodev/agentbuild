import AgentBuildCore
import Darwin
import Foundation

public enum GunshipProjectAction: String, Codable, Sendable {
    case build, test, package, validate
}

public enum GunshipProjectError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidRequest(String)
    case invalidRepository(String)
    case invalidEngine(String)
    case invalidToolObservation(String)

    public var description: String {
        switch self {
        case .invalidRequest(let detail): "invalid Gunship request: \(detail)"
        case .invalidRepository(let detail): "invalid Gunship repository: \(detail)"
        case .invalidEngine(let detail): "invalid Unreal Engine: \(detail)"
        case .invalidToolObservation(let detail): "invalid Gunship tool observation: \(detail)"
        }
    }
}

/// A closed Gunship workflow request. Values reach Gunship's scripts as literal
/// environment data and are never evaluated as shell text.
public struct GunshipProjectRequest: Encodable, Sendable {
    public let repository: String
    public let action: GunshipProjectAction
    public let target: String?
    public let configuration: String
    public let testFilter: String?
    public let map: String?
    public let archive: String?
    public let scenario: String?

    public init(
        repository: String,
        action: GunshipProjectAction,
        target: String? = nil,
        configuration: String? = nil,
        testFilter: String? = nil,
        map: String? = nil,
        archive: String? = nil,
        scenario: String? = nil
    ) throws {
        guard gunshipValidAbsolutePath(repository) else {
            throw GunshipProjectError.invalidRequest("repository must be an absolute path without control characters")
        }
        let resolvedConfiguration = configuration ?? "Development"
        guard ["Development", "Shipping"].contains(resolvedConfiguration) else {
            throw GunshipProjectError.invalidRequest("configuration must be Development or Shipping")
        }
        let selectedTarget: String?
        switch action {
        case .build:
            selectedTarget = target ?? "GunshipEditor"
            guard ["GunshipEditor", "Gunship"].contains(selectedTarget!) else {
                throw GunshipProjectError.invalidRequest("target must be GunshipEditor or Gunship")
            }
            guard selectedTarget == "Gunship" || resolvedConfiguration == "Development" else {
                throw GunshipProjectError.invalidRequest("the editor target builds Development only")
            }
            guard testFilter == nil, map == nil, archive == nil, scenario == nil else {
                throw GunshipProjectError.invalidRequest("build accepts only a target and configuration")
            }
        case .test:
            selectedTarget = nil
            guard target == nil, map == nil, archive == nil, scenario == nil, resolvedConfiguration == "Development" else {
                throw GunshipProjectError.invalidRequest("test accepts only a test filter")
            }
        case .package:
            selectedTarget = nil
            guard target == nil, testFilter == nil, scenario == nil else {
                throw GunshipProjectError.invalidRequest("package accepts only an archive, map, and configuration")
            }
            guard archive != nil else { throw GunshipProjectError.invalidRequest("package requires an archive directory") }
        case .validate:
            selectedTarget = nil
            guard target == nil, testFilter == nil, resolvedConfiguration == "Development" else {
                throw GunshipProjectError.invalidRequest("validate accepts only a scenario, archive, and map")
            }
            guard scenario != nil, archive != nil else {
                throw GunshipProjectError.invalidRequest("validate requires a scenario and an archive directory")
            }
            guard scenario != "slice" || map == nil else {
                throw GunshipProjectError.invalidRequest("slice validation uses L_Apron and does not accept a map")
            }
        }
        let filter = action == .test ? testFilter ?? "Gunship" : nil
        let testPath = #"[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*"#
        if let filter, !gunshipMatches(filter, testPath + #"(\+"# + testPath + ")*") {
            throw GunshipProjectError.invalidRequest("test filter must be automation test paths joined by +")
        }
        let mapPath = #"/Game(/[A-Za-z0-9_]+)+"#
        if let map {
            let pattern = action == .validate ? mapPath : mapPath + #"(\+"# + mapPath + ")*"
            guard gunshipMatches(map, pattern) else {
                throw GunshipProjectError.invalidRequest(action == .validate
                    ? "validation map must be one /Game package path"
                    : "map must be /Game package paths joined by +")
            }
        }
        if let scenario, !gunshipMatches(scenario, "[a-z][a-z0-9_]*") {
            throw GunshipProjectError.invalidRequest("scenario must name a Scripts/validate_<scenario>_macos.sh workflow")
        }
        if let archive {
            let components = archive.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
            guard gunshipValidAbsolutePath(archive), archive != "/",
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw GunshipProjectError.invalidRequest("archive must be a normalized absolute directory path")
            }
        }
        self.repository = repository
        self.action = action
        self.target = selectedTarget
        self.configuration = resolvedConfiguration
        self.testFilter = filter
        self.map = map
        self.archive = archive
        self.scenario = scenario
    }

    /// Packaged validation opens a game window; every other route is headless.
    public var needsOuterLease: Bool { action == .validate }

    /// Validation runs an existing archive and never enters Unreal's build tools.
    public var usesEngine: Bool { action != .validate }
}

/// One native step. Compilation phases are the only ones admitted under
/// `host:compile`; cooking, automation, and packaged runs follow its release.
public struct GunshipProjectPhase: Encodable, Equatable, Sendable {
    public let step: String
    public let kind: String
    public let executable: String
    public let arguments: [String]
    /// Literal values added to the inherited child environment.
    public let environment: [String: String]
    public let requiresCompilation: Bool
}

public struct GunshipLeaseRequirement: Encodable, Equatable, Sendable {
    public let resource: String
    public let exclusive: Bool
}

/// Read-only observations and exact native phases. This value establishes no
/// lease, source custody, archive custody, or native outcome.
public struct GunshipProjectPlan: Sendable {
    public let request: GunshipProjectRequest
    public let repository: String
    public let engine: String?
    public let archive: String?
    public let productPath: String?
    public let sessionPath: String
    public let phases: [GunshipProjectPhase]
    public let resources: [GunshipLeaseRequirement]
    public let needsOuterLease: Bool
    public let toolIdentity: [String: String]
    public let identityKey: String

    public var admissionEstablished: Bool { false }

    public func jsonData() throws -> Data {
        struct Report: Encodable {
            let schemaVersion = 1
            let admissionEstablished = false
            let request: GunshipProjectRequest
            let repository: String
            let engine: String?
            let archive: String?
            let productPath: String?
            let sessionPath: String
            let phases: [GunshipProjectPhase]
            let resources: [GunshipLeaseRequirement]
            let needsOuterLease: Bool
            let toolIdentity: [String: String]
            let identityKey: String
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Report(request: request, repository: repository, engine: engine, archive: archive,
            productPath: productPath, sessionPath: sessionPath, phases: phases, resources: resources,
            needsOuterLease: needsOuterLease, toolIdentity: toolIdentity, identityKey: identityKey))
    }
}

public enum GunshipProjectPlanner {
    /// The driver sets this to the owned session before admitting the plan again.
    public static let sessionEnvironmentKey = "AGENTBUILD_GUNSHIP_SESSION"
    public static let engineEnvironmentKey = "GUNSHIP_UNREAL_ENGINE"

    public static func plan(
        request: GunshipProjectRequest,
        environment: [String: String],
        capture: (any RepositoryCommandCapturing)? = nil
    ) async throws -> GunshipProjectPlan {
        let repository = try canonicalRepository(request.repository)
        let observer: any RepositoryCommandCapturing
        if let capture { observer = capture }
        else {
            observer = try RepositoryCommandCapture(outputLimit: 64 * 1_024, diagnosticLimit: 16 * 1_024,
                                                     timeout: .seconds(10))
        }
        // Sessions live in the project; unignored session files would read as source drift.
        do {
            _ = try await observer.capture(arguments: ["git", "check-ignore", "-q", "Artifacts/AgentSessions/probe"],
                                           workingDirectory: repository, environment: environment)
        } catch {
            throw GunshipProjectError.invalidRepository("Git must ignore /Artifacts so sessions are not source changes")
        }
        let session = environment[sessionEnvironmentKey] ?? repository + "/Artifacts/AgentSessions/PLAN"
        guard gunshipValidAbsolutePath(session) else {
            throw GunshipProjectError.invalidRequest("session must be an absolute path")
        }
        let engine = request.usesEngine ? try canonicalEngine(environment[engineEnvironmentKey]) : nil
        let archive = try request.archive.map { try canonicalArchive($0, repository: repository) }
        var identity: [String: String] = [:]
        if let engine {
            identity = try await toolIdentity(engine: engine, repository: repository, environment: environment, capture: observer)
        }
        let identityKey = try CanonicalJSONDigest.sha256(.object([
            "schemaVersion": .integer(1), "repository": .string(repository),
            "toolchain": .object(identity.mapValues { .string($0) }),
        ]))

        let scripts = repository + "/Scripts/"
        let engineValues = engine.map { [engineEnvironmentKey: $0] } ?? [:]
        func compile(_ target: String) -> GunshipProjectPhase {
            GunshipProjectPhase(step: "build-" + target, kind: "compilation", executable: "/bin/zsh",
                arguments: ["-f", scripts + "build_macos.sh", target],
                environment: engineValues.merging(target == "Gunship" ? ["GUNSHIP_CONFIGURATION": request.configuration] : [:]) { $1 },
                requiresCompilation: true)
        }
        let mapValues = request.map.map { ["GUNSHIP_MAP": $0] } ?? [:]
        let phases: [GunshipProjectPhase]
        var product: String?
        switch request.action {
        case .build:
            phases = [compile(request.target!)]
        case .test:
            phases = [compile("GunshipEditor"), GunshipProjectPhase(step: "automation", kind: "test",
                executable: "/bin/zsh", arguments: ["-f", try regularScript(scripts + "test_macos.sh")],
                environment: engineValues.merging([
                    "GUNSHIP_TEST_REPORT_DIR": session + "/Automation", "GUNSHIP_TEST_FILTER": request.testFilter!,
                ]) { $1 }, requiresCompilation: false)]
        case .package:
            // The script's own build is skipped: both targets compiled above under host:compile.
            phases = [compile("GunshipEditor"), compile("Gunship"), GunshipProjectPhase(step: "package", kind: "package",
                executable: "/bin/zsh", arguments: ["-f", try regularScript(scripts + "package_macos.sh")],
                environment: engineValues.merging([
                    "GUNSHIP_SKIP_BUILD": "1", "GUNSHIP_ARCHIVE_DIR": archive!, "GUNSHIP_CONFIGURATION": request.configuration,
                ].merging(mapValues) { $1 }) { $1 }, requiresCompilation: false)]
            let app = request.configuration == "Shipping" ? "Gunship-Mac-Shipping" : "Gunship"
            product = archive! + "/Mac/" + app + ".app"
        case .validate:
            let scenario = request.scenario!
            let name = scenario == "slice" ? "validate_macos.sh" : "validate_" + scenario + "_macos.sh"
            phases = [GunshipProjectPhase(step: "validate-" + scenario, kind: "validation",
                executable: "/bin/zsh", arguments: ["-f", try regularScript(scripts + name)],
                environment: ["GUNSHIP_ARCHIVE_DIR": archive!, "GUNSHIP_RUN_DIR": session + "/Evidence"].merging(mapValues) { $1 },
                requiresCompilation: false)]
            product = archive! + "/Mac/Gunship.app"
            guard access(product! + "/Contents/MacOS/Gunship", X_OK) == 0 else {
                throw GunshipProjectError.invalidRequest("archive has no packaged Mac/Gunship.app; package it first")
            }
        }
        if request.action != .validate { _ = try regularScript(scripts + "build_macos.sh") }

        var resources = [GunshipLeaseRequirement(resource: "gunship:sessions:" + repository, exclusive: false)]
        // Binaries, Intermediate, cooked content, and the editor's DDC are one project build tree.
        if request.usesEngine {
            resources.append(GunshipLeaseRequirement(resource: "gunship:workspace:" + repository, exclusive: true))
        }
        if let archive { resources.append(GunshipLeaseRequirement(resource: "gunship:archive:" + archive, exclusive: true)) }
        return GunshipProjectPlan(request: request, repository: repository, engine: engine, archive: archive,
            productPath: product, sessionPath: session, phases: phases, resources: resources,
            needsOuterLease: request.needsOuterLease, toolIdentity: identity, identityKey: identityKey)
    }

    private static func canonicalRepository(_ path: String) throws -> String {
        guard let canonical = gunshipRealPath(path) else {
            throw GunshipProjectError.invalidRepository("cannot resolve repository directory")
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical, isDirectory: &directory), directory.boolValue else {
            throw GunshipProjectError.invalidRepository("repository directory does not exist")
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: canonical + "/Gunship.uproject")
        guard attributes?[.type] as? FileAttributeType == .typeRegular else {
            throw GunshipProjectError.invalidRepository("missing regular Gunship.uproject")
        }
        return canonical
    }

    private static func canonicalEngine(_ path: String?) throws -> String {
        guard let path, !path.isEmpty else {
            throw GunshipProjectError.invalidEngine("pass --engine or set \(engineEnvironmentKey)")
        }
        guard gunshipValidAbsolutePath(path), let canonical = gunshipRealPath(path) else {
            throw GunshipProjectError.invalidEngine("cannot resolve engine directory")
        }
        for name in ["Engine/Build/Build.version", "Engine/Build/BatchFiles/Mac/Build.sh"] {
            let attributes = try? FileManager.default.attributesOfItem(atPath: canonical + "/" + name)
            guard attributes?[.type] as? FileAttributeType == .typeRegular else {
                throw GunshipProjectError.invalidEngine("missing regular \(name)")
            }
        }
        return canonical
    }

    /// Resolves the existing part of the path, so a symlinked spelling owns
    /// the same archive lease as the physical directory.
    private static func canonicalArchive(_ path: String, repository: String) throws -> String {
        var existing = path
        var missing: [String] = []
        var resolved: String?
        while resolved == nil {
            // Capture errno at the syscall: Swift string conversion and cleanup
            // must not change which failures permit a missing output suffix.
            let observation: (path: String?, error: Int32) = existing.withCString { path in
                guard let value = realpath(path, nil) else {
                    let code = errno
                    return (nil, code)
                }
                defer { free(value) }
                return (String(validatingCString: value), 0)
            }
            resolved = observation.path
            if resolved != nil { break }
            guard observation.error == ENOENT, existing != "/" else {
                throw GunshipProjectError.invalidRequest("cannot resolve archive directory")
            }
            // ENOENT can mean a dangling symlink rather than an absent directory.
            // Stripping that link would assign a lexical alias its own lease.
            var metadata = stat()
            let status = lstat(existing, &metadata)
            let metadataError = errno
            if status == 0 {
                guard metadata.st_mode & S_IFMT != S_IFLNK else {
                    throw GunshipProjectError.invalidRequest("archive contains an unresolved symbolic link")
                }
                throw GunshipProjectError.invalidRequest("cannot resolve archive directory")
            }
            guard metadataError == ENOENT, let slash = existing.utf8.lastIndex(of: UInt8(ascii: "/")) else {
                throw GunshipProjectError.invalidRequest("cannot resolve archive directory")
            }
            missing.append(String(existing[existing.index(after: slash)...]))
            existing = slash == existing.startIndex ? "/" : String(existing[..<slash])
        }
        var canonical = resolved!
        for component in missing.reversed() { canonical += (canonical == "/" ? "" : "/") + component }
        if missing.isEmpty {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: canonical, isDirectory: &directory), directory.boolValue else {
                throw GunshipProjectError.invalidRequest("archive exists but is not a directory")
            }
        }
        guard canonical != "/", canonical != repository, !repository.hasPrefix(canonical + "/") else {
            throw GunshipProjectError.invalidRequest("archive cannot contain the repository")
        }
        return canonical
    }

    private static func regularScript(_ path: String) throws -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        guard attributes?[.type] as? FileAttributeType == .typeRegular else {
            throw GunshipProjectError.invalidRepository("missing regular script " + URL(fileURLWithPath: path).lastPathComponent)
        }
        return path
    }

    private static func toolIdentity(
        engine: String, repository: String, environment: [String: String], capture: any RepositoryCommandCapturing
    ) async throws -> [String: String] {
        func observe(_ arguments: [String], path: Bool = false) async throws -> String {
            let data = try await capture.capture(arguments: arguments, workingDirectory: repository, environment: environment)
            guard let text = String(data: data, encoding: .utf8) else {
                throw GunshipProjectError.invalidToolObservation("non-UTF-8 response from \(arguments[0])")
            }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !value.utf8.contains(0), !path || gunshipValidAbsolutePath(value) else {
                throw GunshipProjectError.invalidToolObservation("empty or invalid response from \(arguments[0])")
            }
            return value
        }
        let versionData: Data
        do { versionData = try Data(contentsOf: URL(fileURLWithPath: engine + "/Engine/Build/Build.version")) }
        catch { throw GunshipProjectError.invalidEngine("unreadable Build.version") }
        guard versionData.count <= 64 * 1_024,
              let version = try? JSONSerialization.jsonObject(with: versionData) as? [String: Any],
              let major = version["MajorVersion"] as? Int, let minor = version["MinorVersion"] as? Int,
              let patch = version["PatchVersion"] as? Int, let changelist = version["Changelist"] as? Int else {
            throw GunshipProjectError.invalidEngine("Build.version has no engine version")
        }
        let developerDirectory: String
        if let selected = environment["DEVELOPER_DIR"], !selected.isEmpty {
            guard gunshipValidAbsolutePath(selected) else {
                throw GunshipProjectError.invalidRequest("DEVELOPER_DIR must be an absolute path")
            }
            developerDirectory = selected
        } else {
            developerDirectory = try await observe(["xcode-select", "-p"], path: true)
        }
        let xcodebuild = try await observe(["xcrun", "--find", "xcodebuild"], path: true)
        var identity = [
            "engineRoot": engine,
            "engineVersion": "\(major).\(minor).\(patch)-\(changelist)",
            "engineBuildVersionSHA256": CanonicalJSONDigest.digest(versionData),
            "developerDirectory": developerDirectory,
            "xcodebuildPath": xcodebuild,
            "xcodeVersion": try await observe([xcodebuild, "-version"]),
        ]
        for name in ["TOOLCHAINS", "SDKROOT", "CC", "CXX", "LD"] {
            if let value = environment[name] { identity["environment." + name] = value }
        }
        return identity
    }
}

func gunshipValidAbsolutePath(_ value: String) -> Bool {
    value.hasPrefix("/") && !value.utf8.contains(where: { $0 < 32 || $0 == 127 })
}

func gunshipRealPath(_ path: String) -> String? {
    guard gunshipValidAbsolutePath(path), let resolved = path.withCString({ realpath($0, nil) }) else { return nil }
    defer { free(resolved) }
    return String(validatingCString: resolved)
}

private func gunshipMatches(_ value: String, _ pattern: String) -> Bool {
    value.range(of: "^(?:" + pattern + ")$", options: .regularExpression) != nil
}
