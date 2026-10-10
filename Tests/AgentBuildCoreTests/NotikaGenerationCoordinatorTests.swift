import AgentBuildCore
import AgentLeaseCore
import Darwin
import Foundation
import Synchronization
import Testing

@Suite("Notika native project generation")
struct NotikaGenerationCoordinatorTests {
    @Test(arguments: [false, true])
    func preparesThenRetiresAndGeneratesUnderOrderedOwnership(cached: Bool) async throws {
        let fixture = try GenerationFixture()
        defer { fixture.remove() }
        try fixture.generatedGraph("before")
        let steps = Mutex<[String]>([])
        let report = try await NotikaGenerationCoordinator().run(
            repository: fixture.path, registryRoot: fixture.graphRegistry.path,
            environment: fixture.environment.merging(["USE_CACHED_DEPENDENCIES": "stale", "NOTIKA_ROUTE_AUTHORITY_FD": "900"]) { _, new in new },
            cached: cached, identityCapture: GenerationIdentityCapture(),
            commandOperation: { command, descriptors in
                #expect(try !fixture.graphAvailable())
                #expect(command.workingDirectory == fixture.path)
                #expect(command.environment["SRCROOT"] == fixture.path)
                #expect(command.environment["NOTIKA_ROUTE_AUTHORITY_FD"] == nil)
                #expect(descriptors.allSatisfy { fcntl($0, F_GETFD) >= 0 })
                let name = URL(fileURLWithPath: command.executable).lastPathComponent
                steps.withLock { $0.append(name) }
                if name == "tuist" {
                    #expect(descriptors.count == 2)
                    #expect(try !fixture.compilationAvailable())
                    #expect(command.arguments == ["generate", "--no-open"])
                    #expect(command.environment["USE_CACHED_DEPENDENCIES"] == (cached ? "1" : nil))
                    #expect(!FileManager.default.fileExists(atPath: fixture.path + "/Notika.xcodeproj"))
                    #expect(!FileManager.default.fileExists(atPath: fixture.path + "/Notika.xcworkspace"))
                    try fixture.generatedGraph("after")
                } else {
                    #expect(descriptors.count == 1)
                    #expect(try fixture.compilationAvailable())
                    #expect(command.arguments.isEmpty)
                    #expect(command.environment["USE_CACHED_DEPENDENCIES"] == nil)
                    #expect(FileManager.default.fileExists(atPath: fixture.path + "/Notika.xcworkspace"))
                }
                return generationSuccess
            }, retirementOperation: { entry, descriptors in
                #expect(descriptors.count == 1)
                #expect(try !fixture.graphAvailable())
                #expect(try fixture.compilationAvailable())
                try entry.validate()
                #expect(fcntl(entry.parentDescriptor, F_GETFD) >= 0)
                steps.withLock { $0.append("retire-" + entry.relativeName) }
                try FileManager.default.removeItem(atPath: entry.absolutePath)
                return generationSuccess
            })
        #expect(steps.withLock { $0 } == ["prepare-htt-mini.sh", "prepare-onnxruntime.sh",
                                         "retire-Notika.xcodeproj", "retire-Notika.xcworkspace", "tuist"])
        #expect(report.commands.map(\.step) == ["prepare-htt-mini.sh", "prepare-onnxruntime.sh", "tuist-generate"])
        #expect(report.commands.allSatisfy { $0.outcome.succeeded })
        #expect(report.retiredGraphEntries == ["Notika.xcodeproj", "Notika.xcworkspace"])
        #expect(report.retirementOutcomes.count == 2)
        #expect(report.sourceBefore.generatedGraphDigest != report.sourceAfter.generatedGraphDigest)
        #expect(report.removedWorkspaceScheme)
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "/Notika.xcworkspace/xcshareddata/xcschemes/Notika-Workspace.xcscheme"))
        #expect(try fixture.graphAvailable())
        #expect(try fixture.compilationAvailable())
    }

    @Test(arguments: [GenerationFailureVector.preparation, .unprovenRetirement, .captureFailure, .nativeFailure, .cancelled])
    fileprivate func incompleteCommandOutcomesStopBeforeGraphRetirement(_ vector: GenerationFailureVector) async throws {
        let fixture = try GenerationFixture()
        defer { fixture.remove() }
        try fixture.generatedGraph("unchanged")
        let calls = Mutex(0)
        await #expect(throws: NotikaGenerationError.commandFailed(step: "prepare-htt-mini.sh", outcome: vector.outcome)) {
            _ = try await NotikaGenerationCoordinator().run(
                repository: fixture.path, registryRoot: fixture.graphRegistry.path, environment: fixture.environment,
                identityCapture: GenerationIdentityCapture(),
                commandOperation: { _, _ in calls.withLock { $0 += 1 }; return vector.outcome },
                retirementOperation: { _, _ in Issue.record("failed preparation retired the graph"); return generationSuccess })
        }
        #expect(calls.withLock { $0 } == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.path + "/Notika.xcworkspace"))
        #expect(try fixture.graphAvailable())
        #expect(try fixture.compilationAvailable())
    }

    @Test func noOpRetirementIsRejectedBeforeTuist() async throws {
        let fixture = try GenerationFixture()
        defer { fixture.remove() }
        try fixture.generatedGraph("kept")
        await #expect(throws: NotikaGenerationError.retirementIncomplete(fixture.path + "/Notika.xcodeproj")) {
            _ = try await NotikaGenerationCoordinator().run(
                repository: fixture.path, registryRoot: fixture.graphRegistry.path, environment: fixture.environment,
                identityCapture: GenerationIdentityCapture(),
                commandOperation: { command, _ in
                    #expect(command.executable != fixture.path + "/Scripts/tuist")
                    return generationSuccess
                }, retirementOperation: { _, _ in generationSuccess })
        }
    }

    @Test func generatedSwiftPMConfigurationAllowsItsObservedPermissiveMode() async throws {
        let fixture = try GenerationFixture()
        defer { fixture.remove() }
        let configuration = "Notika.xcworkspace/xcshareddata/swiftpm/configuration"
        try fixture.generatedGraph("before")
        try fixture.directory(configuration)
        try #require((fixture.path + "/" + configuration).withCString { chmod($0, 0o777) } == 0)
        let retired = Mutex<[String]>([])
        let report = try await NotikaGenerationCoordinator().run(
            repository: fixture.path, registryRoot: fixture.graphRegistry.path, environment: fixture.environment,
            identityCapture: GenerationIdentityCapture(),
            commandOperation: { command, _ in
                if command.executable == fixture.path + "/Scripts/tuist" {
                    try fixture.generatedGraph("after")
                    try fixture.directory(configuration)
                    try #require((fixture.path + "/" + configuration).withCString { chmod($0, 0o777) } == 0)
                } else {
                    let attributes = try FileManager.default.attributesOfItem(atPath: fixture.path + "/" + configuration)
                    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o777)
                }
                return generationSuccess
            }, retirementOperation: { entry, _ in
                if entry.relativeName == "Notika.xcworkspace" {
                    let attributes = try FileManager.default.attributesOfItem(atPath: fixture.path + "/" + configuration)
                    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o777)
                }
                retired.withLock { $0.append(entry.relativeName) }
                try FileManager.default.removeItem(atPath: entry.absolutePath)
                return generationSuccess
            })
        #expect(retired.withLock { $0 } == ["Notika.xcodeproj", "Notika.xcworkspace"])
        #expect(report.removedWorkspaceScheme)
        #expect(report.commands.count == 3)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.path + "/" + configuration)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o777)
        #expect(try NotikaGeneratedWorkspace.validate(repository: fixture.path).repository == fixture.path)
    }

    @Test(arguments: ["Notika.xcworkspace/xcshareddata/custom",
                      "Notika.xcworkspace/xcshareddata/swiftpm/configuration/nested"])
    func unsafeLaterGraphCandidatePreservesEveryOldRoot(_ relative: String) async throws {
        let fixture = try GenerationFixture()
        defer { fixture.remove() }
        try fixture.generatedGraph("unchanged")
        try fixture.directory(relative)
        try #require((fixture.path + "/" + relative).withCString { chmod($0, 0o777) } == 0)
        let preparations = Mutex<[String]>([])
        await #expect(throws: NotikaGenerationError.unsafePath(fixture.path + "/" + relative)) {
            _ = try await NotikaGenerationCoordinator().run(
                repository: fixture.path, registryRoot: fixture.graphRegistry.path, environment: fixture.environment,
                identityCapture: GenerationIdentityCapture(),
                commandOperation: { command, _ in
                    preparations.withLock { $0.append(URL(fileURLWithPath: command.executable).lastPathComponent) }
                    return generationSuccess
                }, retirementOperation: { _, _ in
                    Issue.record("unsafe later graph candidate admitted destructive retirement")
                    return generationSuccess
                })
        }
        #expect(preparations.withLock { $0 } == ["prepare-htt-mini.sh", "prepare-onnxruntime.sh"])
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.path + "/Notika.xcodeproj/project.pbxproj")) == Data("unchanged".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.path + "/Notika.xcworkspace/xcshareddata/swiftpm/Package.resolved")) == Data("unchanged".utf8))
        #expect(try fixture.graphAvailable())
        #expect(try fixture.compilationAvailable())
    }

    @Test func graphRootSymlinkEscapeIsRejectedBeforeAnyToolOrRetirement() async throws {
        let fixture = try GenerationFixture()
        let outside = try GenerationFixture()
        defer { fixture.remove(); outside.remove() }
        try fixture.link("Notika.xcworkspace", outside.path)
        await #expect(throws: NotikaGenerationError.unsafePath(fixture.path + "/Notika.xcworkspace")) {
            _ = try await NotikaGenerationCoordinator().run(
                repository: fixture.path, registryRoot: fixture.graphRegistry.path, environment: fixture.environment,
                identityCapture: GenerationIdentityCapture(),
                commandOperation: { _, _ in Issue.record("unsafe graph admitted a tool"); return generationSuccess },
                retirementOperation: { _, _ in Issue.record("unsafe graph admitted retirement"); return generationSuccess })
        }
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func workspaceValidationRejectsResolvedEscapeAndAcceptsContainedFileLink() throws {
        let fixture = try GenerationFixture()
        let outside = try GenerationFixture()
        defer { fixture.remove(); outside.remove() }
        try fixture.generatedGraph("valid")
        #expect(try NotikaGeneratedWorkspace.validate(repository: fixture.path).repository == fixture.path)
        let resolved = "Notika.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        try FileManager.default.removeItem(atPath: fixture.path + "/" + resolved)
        try outside.write("lock", Data("outside".utf8))
        try fixture.link(resolved, outside.path + "/lock")
        #expect(throws: NotikaGenerationError.unsafePath(fixture.path + "/" + resolved)) {
            try NotikaGeneratedWorkspace.validate(repository: fixture.path)
        }
        try FileManager.default.removeItem(atPath: fixture.path + "/" + resolved)
        try fixture.write("contained.lock", Data("inside".utf8))
        try fixture.link(resolved, fixture.path + "/contained.lock")
        #expect(try NotikaGeneratedWorkspace.validate(repository: fixture.path).resolvedDependenciesPath == fixture.path + "/contained.lock")
    }

    @Test func generatedSchemeSymlinkIsNeverFollowedOrRemoved() async throws {
        let fixture = try GenerationFixture()
        let outside = try GenerationFixture()
        defer { fixture.remove(); outside.remove() }
        try outside.write("scheme", Data("untouched".utf8))
        let scheme = "Notika.xcworkspace/xcshareddata/xcschemes/Notika-Workspace.xcscheme"
        await #expect(throws: NotikaGenerationError.unsafePath(fixture.path + "/" + scheme)) {
            _ = try await NotikaGenerationCoordinator().run(
                repository: fixture.path, registryRoot: fixture.graphRegistry.path, environment: fixture.environment,
                identityCapture: GenerationIdentityCapture(),
                commandOperation: { command, _ in
                    if command.executable == fixture.path + "/Scripts/tuist" {
                        try fixture.generatedGraph("output")
                        try FileManager.default.removeItem(atPath: fixture.path + "/" + scheme)
                        try fixture.link(scheme, outside.path + "/scheme")
                    }
                    return generationSuccess
                }, retirementOperation: { _, _ in Issue.record("no prior graph exists"); return generationSuccess })
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: outside.path + "/scheme")) == Data("untouched".utf8))
    }

    @Test func localBuildProductsHideDeclaredSiblingPackageButSkipDirectorySymlinks() async throws {
        let fixture = try GenerationFixture()
        let sibling = try GenerationFixture()
        let outside = try GenerationFixture()
        defer { fixture.remove(); sibling.remove(); outside.remove() }
        try fixture.generatedGraph("graph")
        try fixture.directory("DerivedData")
        try fixture.write("Packages/A/Package.swift", Data("package".utf8))
        try fixture.link("Packages/A/DerivedData", outside.path)
        try sibling.write("Package.swift", Data("package".utf8))
        try sibling.directory("DerivedData")
        let objects: [String: Any] = ["a": ["isa": "XCLocalSwiftPackageReference", "relativePath": "Packages/A"],
                                      "b": ["isa": "XCLocalSwiftPackageReference", "relativePath": sibling.path]]
        let capture = GenerationPlistCapture(data: try JSONSerialization.data(withJSONObject: ["objects": objects]))
        let visibility = try await NotikaGeneratedWorkspace.hideLocalBuildProducts(repository: fixture.path, capture: capture)
        #expect(Set(visibility.hiddenDirectories) == Set([fixture.path + "/DerivedData", sibling.path + "/DerivedData"]))
        #expect(visibility.warnings.isEmpty)
        var untouched = stat()
        #expect(outside.path.withCString { stat($0, &untouched) } == 0)
        #expect(untouched.st_flags & UInt32(UF_HIDDEN) == 0)
        #expect(try await NotikaGeneratedWorkspace.hideLocalBuildProducts(repository: fixture.path, capture: capture).hiddenDirectories.isEmpty)
    }

    @Test func projectFileEscapeIsRejectedBeforePlistCapture() async throws {
        let fixture = try GenerationFixture()
        let outside = try GenerationFixture()
        defer { fixture.remove(); outside.remove() }
        try fixture.generatedGraph("graph")
        try outside.write("project", Data("external".utf8))
        let relative = "Notika.xcodeproj/project.pbxproj"
        try FileManager.default.removeItem(atPath: fixture.path + "/" + relative)
        try fixture.link(relative, outside.path + "/project")
        await #expect(throws: NotikaGenerationError.unsafePath(fixture.path + "/" + relative)) {
            _ = try await NotikaGeneratedWorkspace.hideLocalBuildProducts(repository: fixture.path,
                                                                         capture: GenerationUnexpectedCapture())
        }
    }
}

private let generationSuccess = NotikaGenerationCommandOutcome(nativeTermination: .init(kind: .exit, value: 0), retirementProven: true)

private enum GenerationFailureVector: Sendable {
    case preparation, unprovenRetirement, captureFailure, nativeFailure, cancelled
    var outcome: NotikaGenerationCommandOutcome {
        switch self {
        case .preparation: .init(nativeTermination: nil, retirementProven: true, failures: [.init(operation: "launch")])
        case .unprovenRetirement: .init(nativeTermination: .init(kind: .exit, value: 0), retirementProven: false)
        case .captureFailure: .init(nativeTermination: .init(kind: .exit, value: 0), retirementProven: true, failures: [.init(operation: "capture")])
        case .nativeFailure: .init(nativeTermination: .init(kind: .exit, value: 7), retirementProven: true)
        case .cancelled: .init(nativeTermination: .init(kind: .signal, value: SIGKILL), retirementProven: true, cancelled: true)
        }
    }
}

private struct GenerationFixture: Sendable {
    let path: String
    let graphRegistry: URL
    let compileRegistry: URL
    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notika-generation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let canonical = try #require(url.path.withCString { realpath($0, nil) })
        defer { free(canonical) }
        path = String(cString: canonical)
        graphRegistry = URL(fileURLWithPath: path + "/graph-registry")
        compileRegistry = URL(fileURLWithPath: path + "/compile-registry")
    }
    var environment: [String: String] { ["PATH": "/usr/bin:/bin", "AGENTLEASE_COMPILE_HOME": compileRegistry.path] }
    func remove() { try? FileManager.default.removeItem(atPath: path) }
    func directory(_ relative: String) throws { try FileManager.default.createDirectory(atPath: path + "/" + relative, withIntermediateDirectories: true) }
    func write(_ relative: String, _ data: Data) throws {
        let url = URL(fileURLWithPath: path + "/" + relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    func link(_ relative: String, _ target: String) throws {
        let url = URL(fileURLWithPath: path + "/" + relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
    }
    func generatedGraph(_ text: String) throws {
        try write("Notika.xcodeproj/project.pbxproj", Data(text.utf8))
        try write("Notika.xcworkspace/xcshareddata/swiftpm/Package.resolved", Data(text.utf8))
        try write("Notika.xcworkspace/xcshareddata/xcschemes/Notika-Workspace.xcscheme", Data(text.utf8))
    }
    func graphAvailable() throws -> Bool {
        let resource = try ResourceName(CacheCompatibilityIdentity.graphResourceName(canonicalWorktree: path))
        let paths = try AgentLeasePaths.open(selectedRoot: graphRegistry.path)
        let lock = try FileLock(resource: resource, paths: paths)
        defer { lock.release() }
        return try lock.tryAcquire()
    }
    func compilationAvailable() throws -> Bool {
        let paths = try AgentLeasePaths.open(selectedRoot: compileRegistry.path)
        let lock = try FileLock(resource: ResourceName(HostCompilationAdmission.resource), paths: paths)
        defer { lock.release() }
        return try lock.tryAcquire()
    }
}

private struct GenerationIdentityCapture: RepositoryCommandCapturing {
    func capture(arguments: [String], workingDirectory: String, environment: [String: String]) async throws -> Data {
        if arguments == ["git", "rev-parse", "HEAD"] { return Data(String(repeating: "a", count: 40).utf8) }
        if arguments == ["git", "rev-parse", "--show-toplevel"] { return Data(workingDirectory.utf8) }
        return Data()
    }
}

private struct GenerationPlistCapture: RepositoryCommandCapturing {
    let data: Data
    func capture(arguments: [String], workingDirectory: String, environment: [String: String]) async throws -> Data {
        #expect(arguments == ["/usr/bin/plutil", "-convert", "json", "-o", "-", "--", workingDirectory + "/Notika.xcodeproj/project.pbxproj"])
        return data
    }
}

private struct GenerationUnexpectedCapture: RepositoryCommandCapturing {
    func capture(arguments: [String], workingDirectory: String, environment: [String: String]) async throws -> Data {
        Issue.record("unsafe project file reached plist capture")
        return Data()
    }
}
