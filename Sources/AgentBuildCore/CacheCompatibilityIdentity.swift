import Foundation

public enum CacheCompatibilityError: Error, Equatable, Sendable {
    case invalidField(String)
    case invalidSchema
    case incompatibleAdmission
    case unsupportedMetadataSchema(Int)
}

public struct CacheGitlink: Equatable, Sendable {
    public let path: String
    public let commit: String

    public init(path: String, commit: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"),
              !path.split(separator: "/").contains(".."),
              isLowercaseHex(commit, length: 40) else {
            throw CacheCompatibilityError.invalidField("gitlinks")
        }
        self.path = path
        self.commit = commit
    }

    public var keyMaterial: CanonicalJSONValue {
        .object(["path": .string(path), "commit": .string(commit)])
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.path.utf8.elementsEqual(rhs.path.utf8) && lhs.commit == rhs.commit
    }
}

/// Exact execution profiles retain the selected graph and scheme. Storage
/// projections separately preserve Notika's current and historical cache keys.
/// This value does not acquire locks or establish filesystem custody.
public struct CacheCompatibilityIdentity: Equatable, Sendable {
    public enum Scheme: String, CaseIterable, Sendable {
        case notika = "Notika"
        case notikaUI = "NotikaUITestsOnly"
        case notikaTextPerformance = "NotikaTextPerformanceTests"
        case notikaCanvasPerformance = "NotikaCanvasPerformance"
        case notikaiPad = "NotikaiPad"
        case notikaiPadUI = "NotikaiPadUITestsOnly"
    }

    public enum Configuration: String, Sendable {
        case debug = "Debug"
        case release = "Release"
    }

    public enum DestinationFamily: String, Sendable {
        case macOS = "macos-arm64"
        case iOSSimulator = "ios-simulator-arm64"
    }

    public enum Purpose: String, Sendable {
        case agentLoopAcceptance = "agent-loop-composite-acceptance"
    }

    public let canonicalWorktree: String
    public let toolchainHash: String
    public let gitlinks: [CacheGitlink]
    public let submoduleStatusDigest: String
    public let submoduleWorktreeDigest: String
    public let projectGraphDigest: String
    public let generatedGraphDigest: String
    public let resolvedDependenciesDigest: String
    public let scheme: Scheme
    public let configuration: Configuration
    public let destinationFamily: DestinationFamily
    public let buildFlags: [String]
    public let purpose: Purpose?

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.canonicalWorktree.utf8.elementsEqual(rhs.canonicalWorktree.utf8)
            && lhs.toolchainHash == rhs.toolchainHash
            && lhs.gitlinks == rhs.gitlinks
            && lhs.submoduleStatusDigest == rhs.submoduleStatusDigest
            && lhs.submoduleWorktreeDigest == rhs.submoduleWorktreeDigest
            && lhs.projectGraphDigest == rhs.projectGraphDigest
            && lhs.generatedGraphDigest == rhs.generatedGraphDigest
            && lhs.resolvedDependenciesDigest == rhs.resolvedDependenciesDigest
            && lhs.scheme == rhs.scheme
            && lhs.configuration == rhs.configuration
            && lhs.destinationFamily == rhs.destinationFamily
            && lhs.buildFlags == rhs.buildFlags
            && lhs.purpose == rhs.purpose
    }

    public init(
        canonicalWorktree: String,
        toolchainHash: String,
        gitlinks: [CacheGitlink],
        submoduleStatusDigest: String,
        submoduleWorktreeDigest: String,
        projectGraphDigest: String,
        generatedGraphDigest: String,
        resolvedDependenciesDigest: String,
        scheme: String,
        configuration: String,
        destinationFamily: String,
        buildFlags: [String],
        purpose: String? = nil,
        expectedRepository: String? = nil
    ) throws {
        guard isAbsolutePath(canonicalWorktree),
              expectedRepository.map({ Data($0.utf8) == Data(canonicalWorktree.utf8) }) ?? true else {
            throw CacheCompatibilityError.invalidField("canonicalWorktree")
        }
        let digests = [
            ("toolchainHash", toolchainHash),
            ("submoduleStatusDigest", submoduleStatusDigest),
            ("submoduleWorktreeDigest", submoduleWorktreeDigest),
            ("projectGraphDigest", projectGraphDigest),
            ("generatedGraphDigest", generatedGraphDigest),
            ("resolvedDependenciesDigest", resolvedDependenciesDigest),
        ]
        for (name, digest) in digests where !isLowercaseHex(digest, length: 64) {
            throw CacheCompatibilityError.invalidField(name)
        }
        guard gitlinks.count <= 128 else { throw CacheCompatibilityError.invalidField("gitlinks") }
        guard let selectedScheme = Scheme(rawValue: scheme),
              let selectedConfiguration = Configuration(rawValue: configuration),
              let selectedDestination = DestinationFamily(rawValue: destinationFamily) else {
            throw CacheCompatibilityError.invalidField("buildFamily")
        }
        let expectedDestination: DestinationFamily = switch selectedScheme {
        case .notikaiPad, .notikaiPadUI: .iOSSimulator
        default: .macOS
        }
        var expectedFlags = ["-disableAutomaticPackageResolution"]
        switch selectedScheme {
        case .notikaTextPerformance:
            guard selectedConfiguration == .release else {
                throw CacheCompatibilityError.invalidField("buildFamily")
            }
            expectedFlags.append("ENABLE_TESTABILITY=YES")
        case .notikaCanvasPerformance:
            guard selectedConfiguration == .debug else {
                throw CacheCompatibilityError.invalidField("buildFamily")
            }
            expectedFlags += ["SWIFT_OPTIMIZATION_LEVEL=-O", "SWIFT_COMPILATION_MODE=wholemodule"]
        case .notikaUI, .notikaiPadUI:
            guard selectedConfiguration == .debug else {
                throw CacheCompatibilityError.invalidField("buildFamily")
            }
        default: break
        }
        guard selectedDestination == expectedDestination, buildFlags == expectedFlags else {
            throw CacheCompatibilityError.invalidField("buildFamily")
        }
        let selectedPurpose: Purpose?
        if let purpose {
            guard let value = Purpose(rawValue: purpose), selectedScheme == .notika,
                  selectedConfiguration == .debug, selectedDestination == .macOS else {
                throw CacheCompatibilityError.invalidField("purpose")
            }
            selectedPurpose = value
        } else {
            selectedPurpose = nil
        }
        self.canonicalWorktree = canonicalWorktree
        self.toolchainHash = toolchainHash
        self.gitlinks = gitlinks
        self.submoduleStatusDigest = submoduleStatusDigest
        self.submoduleWorktreeDigest = submoduleWorktreeDigest
        self.projectGraphDigest = projectGraphDigest
        self.generatedGraphDigest = generatedGraphDigest
        self.resolvedDependenciesDigest = resolvedDependenciesDigest
        self.scheme = selectedScheme
        self.configuration = selectedConfiguration
        self.destinationFamily = selectedDestination
        self.buildFlags = buildFlags
        self.purpose = selectedPurpose
    }

    /// Rejects incomplete/extra keys and wrong value types before hashing input
    /// from a previously decoded manifest. Purpose is absent rather than null.
    public init(keyMaterial: CanonicalJSONValue, expectedRepository: String? = nil) throws {
        let values = try materialObject(keyMaterial)
        let required = Set([
            "canonicalWorktree", "toolchainHash", "gitlinks", "submoduleStatusDigest",
            "submoduleWorktreeDigest", "projectGraphDigest", "generatedGraphDigest",
            "resolvedDependenciesDigest", "scheme", "configuration", "destinationFamily", "buildFlags",
        ])
        let names = Set(values.keys)
        guard names == required || names == required.union(["purpose"]) else {
            throw CacheCompatibilityError.invalidSchema
        }
        guard case .array(let rawGitlinks) = values["gitlinks"],
              case .array(let rawFlags) = values["buildFlags"] else {
            throw CacheCompatibilityError.invalidSchema
        }
        let gitlinks = try rawGitlinks.map { raw in
            let value = try materialObject(raw)
            guard Set(value.keys) == Set(["path", "commit"]) else {
                throw CacheCompatibilityError.invalidField("gitlinks")
            }
            return try CacheGitlink(path: materialString("path", in: value),
                                   commit: materialString("commit", in: value))
        }
        let flags = try rawFlags.map { value in
            guard case .string(let flag) = value else { throw CacheCompatibilityError.invalidField("buildFlags") }
            return flag
        }
        try self.init(
            canonicalWorktree: materialString("canonicalWorktree", in: values),
            toolchainHash: materialString("toolchainHash", in: values),
            gitlinks: gitlinks,
            submoduleStatusDigest: materialString("submoduleStatusDigest", in: values),
            submoduleWorktreeDigest: materialString("submoduleWorktreeDigest", in: values),
            projectGraphDigest: materialString("projectGraphDigest", in: values),
            generatedGraphDigest: materialString("generatedGraphDigest", in: values),
            resolvedDependenciesDigest: materialString("resolvedDependenciesDigest", in: values),
            scheme: materialString("scheme", in: values),
            configuration: materialString("configuration", in: values),
            destinationFamily: materialString("destinationFamily", in: values),
            buildFlags: flags,
            purpose: values["purpose"] == nil ? nil : materialString("purpose", in: values),
            expectedRepository: expectedRepository
        )
    }

    public var keyMaterial: CanonicalJSONValue { .object(materialValues) }

    public func executionDigest() throws -> String {
        try CanonicalJSONDigest.sha256(keyMaterial)
    }

    public func currentStorageDigest() throws -> String {
        try storageDigest(version: 3, normalizeDebugScheme: true)
    }

    public func schema3StorageDigest() throws -> String {
        try storageDigest(version: 2, normalizeDebugScheme: true)
    }

    public func legacyStorageDigest() throws -> String {
        try storageDigest(version: 1, normalizeDebugScheme: false)
    }

    /// Metadata v1 used the complete material; v2 used version-1 projected
    /// storage; v3 used version-2 storage; v4 lets Xcode invalidate changed inputs.
    public func cacheKey(metadataSchemaVersion: Int = 4) throws -> String {
        let digest: String
        switch metadataSchemaVersion {
        case 1: digest = try executionDigest()
        case 2: digest = try legacyStorageDigest()
        case 3: digest = try schema3StorageDigest()
        case 4: digest = try currentStorageDigest()
        default: throw CacheCompatibilityError.unsupportedMetadataSchema(metadataSchemaVersion)
        }
        return String(digest.prefix(24))
    }

    public func compatibilityFamily(metadataSchemaVersion: Int = 4) throws -> CanonicalJSONValue {
        guard (1...4).contains(metadataSchemaVersion) else {
            throw CacheCompatibilityError.unsupportedMetadataSchema(metadataSchemaVersion)
        }
        var values = materialValues
        if metadataSchemaVersion >= 3 { normalizeOrdinaryDebugScheme(in: &values) }
        let names = Set(["canonicalWorktree", "scheme", "configuration", "destinationFamily", "purpose", "buildFlags"])
        return .object(values.filter { names.contains($0.key) })
    }

    /// A historical key never grants another execution profile's authority,
    /// even when both profiles share a current storage directory.
    public func validateAdmission(admittedExecutionDigest: String, cacheKey: String) throws {
        guard isLowercaseHex(admittedExecutionDigest, length: 64),
              isLowercaseHex(cacheKey, length: 24),
              admittedExecutionDigest == (try executionDigest()) else {
            throw CacheCompatibilityError.incompatibleAdmission
        }
        let acceptedKeys = try (1...4).map { try self.cacheKey(metadataSchemaVersion: $0) }
        guard acceptedKeys.contains(cacheKey) else { throw CacheCompatibilityError.incompatibleAdmission }
    }

    /// Inputs are already canonical filesystem paths supplied by the repository
    /// identity owner. These pure helpers do not resolve symlinks or create paths.
    public static func graphResourceName(canonicalWorktree: String) throws -> String {
        try requireCanonicalPath(canonicalWorktree)
        return "notika:generated-xcode-graph:" + CanonicalJSONDigest.digest(Data(canonicalWorktree.utf8))
    }

    public static func cacheResourceName(canonicalWorktree: String, canonicalCachePath: String) throws -> String {
        try requireCanonicalPath(canonicalWorktree)
        try requireCanonicalPath(canonicalCachePath)
        return "notika:derived-data:" + CanonicalJSONDigest.digest(Data(canonicalWorktree.utf8))
            + ":" + CanonicalJSONDigest.digest(Data(canonicalCachePath.utf8))
    }

    public static func cachePolicyResourceName(canonicalWorktree: String) throws -> String {
        try requireCanonicalPath(canonicalWorktree)
        return "notika:derived-data-policy:" + CanonicalJSONDigest.digest(Data(canonicalWorktree.utf8))
    }

    private var materialValues: [String: CanonicalJSONValue] {
        var values: [String: CanonicalJSONValue] = [
            "canonicalWorktree": .string(canonicalWorktree),
            "toolchainHash": .string(toolchainHash),
            "gitlinks": .array(gitlinks.map(\.keyMaterial)),
            "submoduleStatusDigest": .string(submoduleStatusDigest),
            "submoduleWorktreeDigest": .string(submoduleWorktreeDigest),
            "projectGraphDigest": .string(projectGraphDigest),
            "generatedGraphDigest": .string(generatedGraphDigest),
            "resolvedDependenciesDigest": .string(resolvedDependenciesDigest),
            "scheme": .string(scheme.rawValue),
            "configuration": .string(configuration.rawValue),
            "destinationFamily": .string(destinationFamily.rawValue),
            "buildFlags": .array(buildFlags.map(CanonicalJSONValue.string)),
        ]
        if let purpose { values["purpose"] = .string(purpose.rawValue) }
        return values
    }

    private func storageDigest(version: Int64, normalizeDebugScheme: Bool) throws -> String {
        var projected = materialValues
        projected.removeValue(forKey: "generatedGraphDigest")
        if version >= 3 {
            for name in ["gitlinks", "submoduleStatusDigest", "submoduleWorktreeDigest",
                         "projectGraphDigest", "resolvedDependenciesDigest"] {
                projected.removeValue(forKey: name)
            }
        }
        if normalizeDebugScheme { normalizeOrdinaryDebugScheme(in: &projected) }
        return try CanonicalJSONDigest.sha256(.object([
            "schemaVersion": .integer(version),
            "resourceID": .string("notika.xcode-cache-storage"),
            "compatibilityKeyMaterial": .object(projected),
        ]))
    }

    private func normalizeOrdinaryDebugScheme(in values: inout [String: CanonicalJSONValue]) {
        guard configuration == .debug, purpose == nil else { return }
        switch scheme {
        case .notikaUI: values["scheme"] = .string(Scheme.notika.rawValue)
        case .notikaiPadUI: values["scheme"] = .string(Scheme.notikaiPad.rawValue)
        default: break
        }
    }
}

private func materialObject(_ value: CanonicalJSONValue) throws -> [String: CanonicalJSONValue] {
    guard case .object(let members) = value else { throw CacheCompatibilityError.invalidSchema }
    var values: [String: CanonicalJSONValue] = [:]
    for member in members {
        guard values.updateValue(member.value, forKey: member.key) == nil else {
            throw CacheCompatibilityError.invalidSchema
        }
    }
    return values
}

private func materialString(_ name: String, in values: [String: CanonicalJSONValue]) throws -> String {
    guard case .string(let value) = values[name] else { throw CacheCompatibilityError.invalidField(name) }
    return value
}

private func isLowercaseHex(_ value: String, length: Int) -> Bool {
    value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}

private func isAbsolutePath(_ value: String) -> Bool {
    value.hasPrefix("/")
}

private func requireCanonicalPath(_ value: String) throws {
    let components = value.split(separator: "/", omittingEmptySubsequences: false)
    guard isAbsolutePath(value), !value.utf8.contains(0), value == "/" ||
            (!value.hasSuffix("/") && !components.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })) else {
        throw CacheCompatibilityError.invalidField("canonicalPath")
    }
}
