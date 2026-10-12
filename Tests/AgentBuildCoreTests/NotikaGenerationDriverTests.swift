@testable import AgentBuildCore
import AgentLeaseCore
import Darwin
import Foundation
import Synchronization
import Testing

@Suite("Notika supervised generation driver")
struct NotikaGenerationDriverTests {
    @Test(arguments: [false, true])
    func actualToolsRetainRawEvidenceAndWriterGraphOwnership(cached: Bool) async throws {
        let fixture = try GenerationDriverFixture()
        defer { fixture.remove() }
        let steps = Mutex<[String]>([])
        let driver = NotikaGenerationDriver(identityCapture: GenerationDriverIdentityCapture(), captureOperation: { helper, command, descriptors, root, directory in
            #expect(try !fixture.available("notika:sessions:" + fixture.path))
            #expect(try !fixture.available(CacheCompatibilityIdentity.graphResourceName(canonicalWorktree: fixture.path)))
            let generating = command.executable == fixture.path + "/Scripts/tuist"
            let compileAvailable = try fixture.compilationAvailable()
            #expect(compileAvailable)
            #expect(descriptors.count == 2)
            #expect(descriptors.allSatisfy { fcntl($0, F_GETFD) >= 0 })
            #expect(fcntl(directory, F_GETFD) >= 0)
            #expect(command.environment["NOTIKA_ROUTE_AUTHORITY_FD"] == nil)
            #expect(command.environment["PATH"]?.hasPrefix(fixture.path + "/Scripts:") == true)
            if generating {
                #expect(command.arguments == ["generate", "--no-open"])
                #expect(command.environment["USE_CACHED_DEPENDENCIES"] == (cached ? "1" : nil))
            } else { #expect(command.environment["USE_CACHED_DEPENDENCIES"] == nil) }
            steps.withLock { $0.append(URL(fileURLWithPath: command.executable).lastPathComponent) }
            return try await CapturedNativePhaseRunner().run(helperExecutable: helper, command: command,
                retainedLockDescriptors: descriptors, nativeWorkingDirectoryDescriptor: directory, artifactRoot: root)
        })
        let result = try await driver.run(repository: fixture.path, helperExecutable: fixture.helper,
            registryRoot: fixture.registry, environment: fixture.environment, cached: cached)
        #expect(result.exitCode == 0)
        #expect(result.status == "succeeded")
        #expect(result.nativeTermination == RunTermination(kind: .exit, value: 0))
        #expect(!result.cancelled)
        #expect(result.orchestrationFailures.isEmpty)
        #expect(result.publicationFailures.isEmpty)
        #expect(steps.withLock { $0 } == ["prepare-htt-mini.sh", "prepare-onnxruntime.sh", "trash", "trash", "tuist"])
        #expect(result.rawCaptures.count == 5)
        let capturesComplete = result.rawCaptures.allSatisfy(\.captureComplete)
        #expect(capturesComplete)
        let report = try #require(result.report)
        #expect(report.lifecycle == "terminal")
        let root = try StrictJSONDocument(data: report.originalData).root.requireObject()
        #expect(root.value(forKey: "request") == nil)
        #expect(root.value(forKey: "cached") == .bool(cached))
        #expect(root.value(forKey: "executionComplete") == .bool(true))
        #expect(root.value(forKey: "removedWorkspaceScheme") == .bool(true))
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "/Notika.xcworkspace/xcshareddata/xcschemes/Notika-Workspace.xcscheme"))
        #expect(FileManager.default.fileExists(atPath: fixture.path + "/Retired/Notika.xcodeproj/project.pbxproj"))
        #expect(FileManager.default.fileExists(atPath: fixture.path + "/Retired/Notika.xcworkspace/xcshareddata/swiftpm/Package.resolved"))
        for name in ["in-progress.json", "manifest.json"] {
            var metadata = stat()
            #expect(lstat(try #require(result.sessionPath) + "/" + name, &metadata) == 0)
            #expect(metadata.st_mode & 0o7777 == 0o400)
            #expect(metadata.st_nlink == 1)
        }
        #expect(try fixture.available("notika:sessions:" + fixture.path))
        #expect(try fixture.available(CacheCompatibilityIdentity.graphResourceName(canonicalWorktree: fixture.path)))
        #expect(try fixture.compilationAvailable())
        try rejectHostileGenerationReports(report, fixture: fixture)
    }

    @Test func nativeFailureAndBinaryLogsSurviveWithoutRetiringPriorGraph() async throws {
        let fixture = try GenerationDriverFixture()
        defer { fixture.remove() }
        try fixture.script("Scripts/bridges/prepare-htt-mini.sh", #"printf '\000\377\200'; printf 'preparation failed' >&2; exit 27"#)
        let result = try await NotikaGenerationDriver(identityCapture: GenerationDriverIdentityCapture()).run(
            repository: fixture.path, helperExecutable: fixture.helper, registryRoot: fixture.registry, environment: fixture.environment)
        #expect(result.exitCode == 27)
        #expect(result.status == "failed")
        #expect(result.nativeTermination == RunTermination(kind: .exit, value: 27))
        #expect(result.rawCaptures.count == 1)
        #expect(try Data(contentsOf: URL(fileURLWithPath: #require(result.rawCaptures.first).standardOutput.path)) == Data([0, 255, 128]))
        #expect(result.report?.nativeTermination == result.nativeTermination)
        #expect(FileManager.default.fileExists(atPath: fixture.path + "/Notika.xcodeproj/project.pbxproj"))
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "/Retired"))
    }

    @Test func rawRewriteCannotPublishNativeZeroAsGenerationSuccess() async throws {
        let fixture = try GenerationDriverFixture()
        defer { fixture.remove() }
        let first = Mutex(true)
        let driver = NotikaGenerationDriver(identityCapture: GenerationDriverIdentityCapture(), captureOperation: { helper, command, descriptors, root, directory in
            let phase = try await CapturedNativePhaseRunner().run(helperExecutable: helper, command: command,
                retainedLockDescriptors: descriptors, nativeWorkingDirectoryDescriptor: directory, artifactRoot: root)
            if first.withLock({ let value = $0; $0 = false; return value }) {
                try Data("rewritten".utf8).write(to: URL(fileURLWithPath: phase.rawCapture.standardOutput.path))
            }
            return phase
        })
        let result = try await driver.run(repository: fixture.path, helperExecutable: fixture.helper,
            registryRoot: fixture.registry, environment: fixture.environment)
        #expect(result.nativeTermination == RunTermination(kind: .exit, value: 0))
        #expect(result.exitCode == 70)
        #expect(result.status == "inconclusive")
        #expect(!result.publicationFailures.isEmpty)
        #expect(result.report?.status == "inconclusive")
    }

    @Test func cancellationAwaitsNativeRetirementAndRetainsPriorGraph() async throws {
        let fixture = try GenerationDriverFixture()
        defer { fixture.remove() }
        try fixture.script("Scripts/bridges/prepare-htt-mini.sh", "trap '' TERM INT\nprintf 'before cancel'\nsleep 30 & wait")
        let started = Mutex<Int32?>(nil)
        let driver = NotikaGenerationDriver(identityCapture: GenerationDriverIdentityCapture(), captureOperation: { helper, command, descriptors, root, directory in
            try await CapturedNativePhaseRunner().run(helperExecutable: helper, command: command,
                retainedLockDescriptors: descriptors, nativeWorkingDirectoryDescriptor: directory, artifactRoot: root,
                onNativeStart: { pid in started.withLock { $0 = pid } })
        })
        let task = Task { try await driver.run(repository: fixture.path, helperExecutable: fixture.helper,
            registryRoot: fixture.registry, environment: fixture.environment) }
        defer { task.cancel() }
        let deadline = ContinuousClock.now + .seconds(5)
        while started.withLock({ $0 == nil }) {
            guard ContinuousClock.now < deadline else { throw GenerationDriverFixture.Failure.deadline }
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        let result = try await task.value
        #expect(result.cancelled)
        #expect(result.rawCaptures.count == 1)
        let capturesComplete = result.rawCaptures.allSatisfy(\.captureComplete)
        #expect(capturesComplete)
        #expect(result.report?.cancelled == true)
        #expect(result.exitCode != 0)
        #expect(FileManager.default.fileExists(atPath: fixture.path + "/Notika.xcodeproj/project.pbxproj"))
        let pid = try #require(started.withLock { $0 })
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        #expect(try fixture.compilationAvailable())
        #expect(try fixture.available("notika:sessions:" + fixture.path))
    }

    @Test func busySessionWriterStopsBeforeArtifactCreationOrGraphAdmission() async throws {
        let fixture = try GenerationDriverFixture()
        defer { fixture.remove() }
        let paths = try AgentLeasePaths.open(selectedRoot: fixture.registry)
        let held = try FileLock(resource: ResourceName("notika:sessions:" + fixture.path), paths: paths)
        #expect(try held.tryAcquire())
        defer { held.release() }
        await #expect(throws: (any Error).self) {
            _ = try await NotikaGenerationDriver(identityCapture: GenerationDriverIdentityCapture()).run(
                repository: fixture.path, helperExecutable: fixture.helper, registryRoot: fixture.registry,
                environment: fixture.environment, waitSeconds: 0)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "/Artifacts"))
        #expect(try fixture.available(CacheCompatibilityIdentity.graphResourceName(canonicalWorktree: fixture.path)))
    }

    @Test func escapedArtifactNamespaceIsRejectedBeforePreparation() async throws {
        let fixture = try GenerationDriverFixture(), outside = try GenerationDriverFixture()
        defer { fixture.remove(); outside.remove() }
        try FileManager.default.createSymbolicLink(atPath: fixture.path + "/Artifacts", withDestinationPath: outside.path)
        await #expect(throws: (any Error).self) {
            _ = try await NotikaGenerationDriver(identityCapture: GenerationDriverIdentityCapture()).run(
                repository: fixture.path, helperExecutable: fixture.helper, registryRoot: fixture.registry, environment: fixture.environment)
        }
        #expect(!FileManager.default.fileExists(atPath: outside.path + "/AgentSessions"))
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "/Retired"))
        #expect(try fixture.available("notika:sessions:" + fixture.path))
    }
}

private func rejectHostileGenerationReports(_ report: NotikaGenerationSessionReport, fixture: GenerationDriverFixture) throws {
    let object = try #require(JSONSerialization.jsonObject(with: report.originalData) as? [String: Any])
    let mutations: [[String: Any]] = [
        object.merging(["request": ["kind": "make"]]) { _, new in new },
        object.merging(["sessionID": UUID().uuidString]) { _, new in new },
        object.merging(["exitCode": 27]) { _, new in new },
        object.merging(["expiresAt": object["completedAt"]!]) { _, new in new },
    ]
    for mutation in mutations {
        #expect(throws: (any Error).self) {
            _ = try NotikaGenerationSessionReport(data: JSONSerialization.data(withJSONObject: mutation),
                expectedRepository: fixture.path, expectedSessionID: report.sessionID)
        }
    }
    var phases = try #require(object["phases"] as? [[String: Any]])
    phases[0]["rawCapture"] = ["standardOutput": ["retainedBytes": Int64.max], "extra": true]
    let malformed = object.merging(["phases": phases]) { _, new in new }
    #expect(throws: (any Error).self) { _ = try NotikaGenerationSessionReport(data: JSONSerialization.data(withJSONObject: malformed)) }
    let lateCancellation = object.merging(["cancelled": true, "executionComplete": false, "status": "cancelled", "exitCode": 130]) { _, new in new }
    let cancelled = try NotikaGenerationSessionReport(data: JSONSerialization.data(withJSONObject: lateCancellation))
    #expect(cancelled.cancelled)
    #expect(cancelled.nativeTermination == RunTermination(kind: .exit, value: 0))
    #expect(cancelled.exitCode == 130)
    let duplicate = Data((String(decoding: report.originalData.dropLast(), as: UTF8.self) + #", "cached":false}"#).utf8)
    #expect(throws: (any Error).self) { _ = try NotikaGenerationSessionReport(data: duplicate) }
}

private struct GenerationDriverIdentityCapture: RepositoryCommandCapturing {
    func capture(arguments: [String], workingDirectory: String, environment: [String: String]) async throws -> Data {
        if arguments == ["git", "rev-parse", "HEAD"] { return Data(String(repeating: "a", count: 40).utf8) }
        if arguments == ["git", "rev-parse", "--show-toplevel"] { return Data(workingDirectory.utf8) }
        return Data()
    }
}

private struct GenerationDriverFixture: Sendable {
    enum Failure: Error { case deadline; case fileSystem(Int32) }
    let path: String
    let helper: String
    var registry: String { path + "/registry" }
    var compileRegistry: String { path + "/compile-registry" }
    var environment: [String: String] {
        ["PATH": "/usr/bin:/bin", "HOME": path, "AGENTLEASE_COMPILE_HOME": compileRegistry,
         "USE_CACHED_DEPENDENCIES": "stale", "NOTIKA_ROUTE_AUTHORITY_FD": "1234"]
    }
    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentbuild-generation-driver-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard let canonical = directory.path.withCString({ realpath($0, nil) }) else { throw Failure.fileSystem(errno) }
        path = String(cString: canonical); free(canonical)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        helper = repository.appendingPathComponent(".build/debug/agentbuild").path
        try write("Project.swift", "fixture graph")
        try write("Notika.xcodeproj/project.pbxproj", "before")
        try write("Notika.xcworkspace/xcshareddata/swiftpm/Package.resolved", "before")
        try script("Scripts/bridges/prepare-htt-mini.sh", "printf 'htt-mini ready'")
        try script("Scripts/bridges/prepare-onnxruntime.sh", "printf 'onnxruntime ready'")
        try script("Scripts/trash", #"""
        [ "$#" = 1 ] || exit 19
        case "$1" in "$SRCROOT/Notika.xcodeproj"|"$SRCROOT/Notika.xcworkspace") ;; *) exit 20 ;; esac
        /bin/mkdir -p "$SRCROOT/Retired"
        /bin/mv "$1" "$SRCROOT/Retired/"
        printf 'retired %s' "$1"
        """#)
        try script("Scripts/tuist", #"""
        [ "$#" = 2 ] && [ "$1" = generate ] && [ "$2" = --no-open ] || exit 21
        /bin/mkdir -p Notika.xcodeproj Notika.xcworkspace/xcshareddata/swiftpm Notika.xcworkspace/xcshareddata/xcschemes
        printf 'after' > Notika.xcodeproj/project.pbxproj
        printf 'after' > Notika.xcworkspace/xcshareddata/swiftpm/Package.resolved
        printf 'scheme' > Notika.xcworkspace/xcshareddata/xcschemes/Notika-Workspace.xcscheme
        printf 'cached=%s' "${USE_CACHED_DEPENDENCIES-}"
        """#)
    }
    func write(_ relative: String, _ text: String) throws {
        let file = URL(fileURLWithPath: path + "/" + relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
    func script(_ relative: String, _ body: String) throws {
        try write(relative, "#!/bin/sh\nset -eu\n" + body + "\n")
        guard chmod(path + "/" + relative, 0o700) == 0 else { throw Failure.fileSystem(errno) }
    }
    func available(_ resource: String) throws -> Bool {
        let lock = try FileLock(resource: ResourceName(resource), paths: AgentLeasePaths.open(selectedRoot: registry))
        defer { lock.release() }
        return try lock.tryAcquire()
    }
    func compilationAvailable() throws -> Bool {
        let lock = try FileLock(resource: ResourceName(HostCompilationAdmission.resource), paths: AgentLeasePaths.open(selectedRoot: compileRegistry))
        defer { lock.release() }
        return try lock.tryAcquire()
    }
    func remove() { try? FileManager.default.removeItem(atPath: path) }
}
