import AgentBuildCLISupport
import AgentBuildCore
import AgentLeaseCore
import ArgumentParser
import Foundation

package struct NotikaCommand: AsyncParsableCommand {
    package init() {}

    package static let configuration = CommandConfiguration(
        commandName: "notika",
        abstract: "Plan and run explicitly admitted Notika project actions.",
        subcommands: [NotikaPlanCommand.self, NotikaBuildCommand.self, NotikaGenerateCommand.self,
                      NotikaRunCommand.self, NotikaRustTestCommand.self, NotikaPreflightCommand.self,
                      NotikaDocsCommand.self, NotikaCleanupCommand.self]
    )
}

struct NotikaPlanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plan",
        abstract: "Observe inputs and describe an unowned Notika execution plan.",
        discussion: "This read-only command acquires no leases and creates no cache or session. It does not build or launch."
    )

    @Option(help: "Absolute path to the Notika Git worktree root.")
    var repository: String

    @Option(help: "Exact route from Notika's closed Make catalog, such as build or test-unit.")
    var route: String

    @Option(help: "macos-ui or ipad-simulator; defaults to the route's platform or macos-ui.")
    var platform: String?

    @Option(help: "Test file or relative coverage source file, where the route accepts it.")
    var file = ""

    @Option(help: "Test method, where the route accepts it.")
    var method = ""

    @Option(help: "iPad device name; defaults to the existing Notika request default.")
    var device: String?

    @Option(name: .customLong("only-testing"), help: "Focused Swift Testing selector; repeat with test-unit-focused.")
    var onlyTesting: [String] = []

    @Option(name: .customLong("simulator-id"), help: "Explicit simulator identifier required for iPad planning; no simulator is contacted.")
    var simulatorID: String?

    @Flag(help: "Print the typed planning report as JSON.")
    var json = false

    mutating func run() async throws {
        let request: NotikaActionRequest
        let destination: String
        do {
            guard let selectedRoute = NotikaMakeRoute(rawValue: route) else {
                throw ValidationError("Unknown Notika route: \(route)")
            }
            let selectedPlatform: NotikaPlatform?
            if let platform {
                guard let parsed = NotikaPlatform(rawValue: platform) else {
                    throw ValidationError("Platform must be macos-ui or ipad-simulator.")
                }
                selectedPlatform = parsed
            } else {
                selectedPlatform = nil
            }
            request = try NotikaActionRequest(makeRoute: selectedRoute, platform: selectedPlatform,
                                              testFile: file, testMethod: method, device: device,
                                              unitSelectors: onlyTesting)
            if request.platform == .iPadSimulator {
                guard let simulatorID else { throw ValidationError("iPad plans require --simulator-id.") }
                destination = "platform=iOS Simulator,id=" + simulatorID
            } else {
                guard simulatorID == nil else { throw ValidationError("--simulator-id applies only to iPad plans.") }
                destination = "platform=macOS,arch=arm64"
            }
            // Validate the destination and complete closed request before probes.
            _ = try NotikaXcodeInvocationPlan(request: request, destination: destination,
                                               cacheDirectory: "/plan-validation/cache",
                                               resultBundle: "/plan-validation/result.xcresult")
        } catch let error as ValidationError {
            throw error
        } catch {
            throw ValidationError(String(describing: error))
        }

        let observer = try NotikaRepositoryIdentity(repository: repository)
        let source = try await observer.sourceIdentity()
        guard source.canonicalWorktree.utf8.elementsEqual(observer.repository.utf8) else {
            throw ValidationError("--repository must name the Git worktree root.")
        }
        let toolchain = try await observer.toolchainIdentity()
        let cache = try NotikaCacheProfile(request: request).identity(source: source, toolchain: toolchain)
        let ownership = try NotikaProjectOwnershipPlan(identity: cache)
        guard let cachePath = ownership.cacheDirectory else {
            throw ValidationError("The plan did not derive a cache path.")
        }
        let repositoryBase = source.canonicalWorktree == "/" ? "" : source.canonicalWorktree
        let resultBundle = repositoryBase + "/Artifacts/AgentSessions/plan-only/result.xcresult"
        let native = try NotikaXcodeInvocationPlan(request: request, destination: destination,
                                                   cacheDirectory: cachePath, resultBundle: resultBundle)
        let ledger = try NativeInvocationLedger(plan: native)
        let report = try NotikaPlanningReport(
            request: request, source: source, toolchain: toolchain, cache: cache,
            cachePath: cachePath, ownership: ownership, native: native, phases: ledger.phases
        )
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
        } else {
            print("Notika plan: \(route) (\(request.platform.rawValue))")
            print("Unowned planning: inputs are sequential observations; no admission or execution evidence.")
            print("Repository: \(source.canonicalWorktree)")
            print("Source: \(report.sourceObservation.digest)")
            print("Toolchain: \(report.toolchainObservationDigest)")
            print("Cache: \(cachePath)")
            for phase in report.physicalPhases {
                print("Phase \(phase.physicalOrdinal): \(phase.segment) \(phase.phaseOrdinal) — \(phase.requiresCompilation ? "compilation admission required" : "runtime")")
            }
        }
    }
}

private struct NotikaPlanningReport: Encodable {
    let schemaVersion = 1
    let toolVersion = AgentBuild.version
    let stage = "unowned-planning"
    let admissionEstablished = false
    let observationsAreAtomic = false
    let request: NotikaActionRequest
    let sourceObservation: SourceObservation
    let toolchainObservationDigest: String
    let cacheIdentity: CacheIdentity
    let cacheExecutionDigest: String
    let cacheStorageDigest: String
    let cacheStorageKey: String
    let cachePath: String
    let requestedResources: [ResourceLease]
    let logicalInvocations: NotikaXcodeInvocationPlan
    let physicalPhases: [PhysicalPhase]

    init(request: NotikaActionRequest, source: NotikaSourceIdentity, toolchain: NotikaToolchainIdentity,
         cache: CacheCompatibilityIdentity, cachePath: String, ownership: NotikaProjectOwnershipPlan,
         native: NotikaXcodeInvocationPlan, phases: [NativeInvocationPhase]) throws {
        self.request = request
        sourceObservation = try SourceObservation(source)
        toolchainObservationDigest = try toolchain.digest()
        cacheIdentity = CacheIdentity(cache)
        cacheExecutionDigest = try cache.executionDigest()
        cacheStorageDigest = try cache.currentStorageDigest()
        cacheStorageKey = try cache.cacheKey()
        self.cachePath = cachePath
        requestedResources = ownership.orderedLeases
        logicalInvocations = native
        physicalPhases = phases.map(PhysicalPhase.init)
    }

    struct SourceObservation: Encodable {
        let digest: String
        let canonicalWorktree: String
        let head: String
        let statusDigest: String
        let stagedDiffDigest: String
        let unstagedDiffDigest: String
        let submoduleStatusDigest: String
        let submoduleWorktreeDigest: String
        let projectGraphDigest: String
        let generatedGraphDigest: String
        let resolvedDependenciesDigest: String

        init(_ source: NotikaSourceIdentity) throws {
            digest = try source.digest()
            canonicalWorktree = source.canonicalWorktree
            head = source.head
            statusDigest = source.statusDigest
            stagedDiffDigest = source.stagedDiffDigest
            unstagedDiffDigest = source.unstagedDiffDigest
            submoduleStatusDigest = source.submoduleStatusDigest
            submoduleWorktreeDigest = source.submoduleWorktreeDigest
            projectGraphDigest = source.projectGraphDigest
            generatedGraphDigest = source.generatedGraphDigest
            resolvedDependenciesDigest = source.resolvedDependenciesDigest
        }
    }

    struct CacheIdentity: Encodable {
        let canonicalWorktree: String
        let toolchainHash: String
        let gitlinks: [Gitlink]
        let submoduleStatusDigest: String
        let submoduleWorktreeDigest: String
        let projectGraphDigest: String
        let generatedGraphDigest: String
        let resolvedDependenciesDigest: String
        let scheme: String
        let configuration: String
        let destinationFamily: String
        let buildFlags: [String]

        init(_ identity: CacheCompatibilityIdentity) {
            canonicalWorktree = identity.canonicalWorktree
            toolchainHash = identity.toolchainHash
            gitlinks = identity.gitlinks.map { Gitlink(path: $0.path, commit: $0.commit) }
            submoduleStatusDigest = identity.submoduleStatusDigest
            submoduleWorktreeDigest = identity.submoduleWorktreeDigest
            projectGraphDigest = identity.projectGraphDigest
            generatedGraphDigest = identity.generatedGraphDigest
            resolvedDependenciesDigest = identity.resolvedDependenciesDigest
            scheme = identity.scheme.rawValue
            configuration = identity.configuration.rawValue
            destinationFamily = identity.destinationFamily.rawValue
            buildFlags = identity.buildFlags
        }
    }

    struct Gitlink: Encodable { let path: String; let commit: String }

    struct PhysicalPhase: Encodable {
        let ordinal: Int
        let phaseOrdinal: Int
        let physicalOrdinal: Int
        let segment: String
        let arguments: [String]
        let requiresCompilation: Bool
        let argumentCommitment: String

        init(_ phase: NativeInvocationPhase) {
            ordinal = phase.ordinal
            phaseOrdinal = phase.phaseOrdinal
            physicalOrdinal = phase.physicalOrdinal
            segment = phase.segment
            arguments = phase.arguments
            requiresCompilation = phase.requiresCompilation
            argumentCommitment = phase.argumentCommitment
        }
    }
}
