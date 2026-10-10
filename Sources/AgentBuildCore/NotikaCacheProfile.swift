import Foundation

/// Notika's closed build family selection, matching the reference driver's
/// _cache_key_material. The profile and identity grant no filesystem custody.
public struct NotikaCacheProfile: Equatable, Sendable, Encodable {
    public let scheme: CacheCompatibilityIdentity.Scheme
    public let configuration: CacheCompatibilityIdentity.Configuration
    public let destinationFamily: CacheCompatibilityIdentity.DestinationFamily
    public let buildFlags: [String]

    public init(request: NotikaActionRequest) {
        destinationFamily = request.platform == .iPadSimulator ? .iOSSimulator : .macOS
        let route = request.canonicalMakeRoute
        let textPerformance = route == .testTextInputHeavyDependencyPerformance
        let canvasPerformance = route == .testCanvasFramePacingPerformance
        if request.isLegacyMake {
            let ui = route.map { [.testUI, .testUIFile, .testUIOnly, .testUIOnlyFile].contains($0) } ?? false
            scheme = if textPerformance {
                .notikaTextPerformance
            } else if canvasPerformance {
                .notikaCanvasPerformance
            } else if request.platform == .iPadSimulator {
                ui ? .notikaiPadUI : .notikaiPad
            } else {
                ui ? .notikaUI : .notika
            }
            configuration = route == .buildRelease || textPerformance ? .release : .debug
        } else if request.isInteractive || request.isDocumentation {
            scheme = .notika
            configuration = .debug
        } else {
            scheme = request.platform == .iPadSimulator ? .notikaiPadUI : .notikaUI
            configuration = .debug
        }
        var flags = ["-disableAutomaticPackageResolution"]
        if textPerformance { flags.append("ENABLE_TESTABILITY=YES") }
        if canvasPerformance { flags += ["SWIFT_OPTIMIZATION_LEVEL=-O", "SWIFT_COMPILATION_MODE=wholemodule"] }
        buildFlags = flags
    }

    public func identity(source: NotikaSourceIdentity, toolchain: NotikaToolchainIdentity) throws -> CacheCompatibilityIdentity {
        try CacheCompatibilityIdentity(
            canonicalWorktree: source.canonicalWorktree,
            toolchainHash: toolchain.digest(),
            gitlinks: source.gitlinks,
            submoduleStatusDigest: source.submoduleStatusDigest,
            submoduleWorktreeDigest: source.submoduleWorktreeDigest,
            projectGraphDigest: source.projectGraphDigest,
            generatedGraphDigest: source.generatedGraphDigest,
            resolvedDependenciesDigest: source.resolvedDependenciesDigest,
            scheme: scheme.rawValue,
            configuration: configuration.rawValue,
            destinationFamily: destinationFamily.rawValue,
            buildFlags: buildFlags,
            expectedRepository: source.canonicalWorktree
        )
    }

    private enum CodingKeys: String, CodingKey {
        case scheme, configuration, destinationFamily, buildFlags
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scheme.rawValue, forKey: .scheme)
        try container.encode(configuration.rawValue, forKey: .configuration)
        try container.encode(destinationFamily.rawValue, forKey: .destinationFamily)
        try container.encode(buildFlags, forKey: .buildFlags)
    }
}
