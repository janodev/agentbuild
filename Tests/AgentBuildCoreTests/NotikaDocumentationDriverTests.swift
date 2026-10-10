@testable import AgentBuildCore
import AgentLeaseCore
import Darwin
import Foundation
import Synchronization
import Testing

@Suite("Notika supervised documentation routes")
struct NotikaDocumentationDriverTests {
    @Test func hardlinkedExecutableToolsRetainExactIdentityWhileArtifactsRemainSingleLinked() async throws {
        let fixture = try DocumentationDriverFixture()
        defer { fixture.remove() }
        let names = ["xcodebuild", "xcrun", "docc"]
        for name in names { try fixture.hardlinkTool(name) }
        let result = try await fixture.driver.run(repository: fixture.path, mode: .rendered, helperExecutable: fixture.helper,
            registryRoot: fixture.registry, environment: fixture.environment, rendererRoot: fixture.renderer)
        #expect(result.status == "succeeded")
        #expect(result.exitCode == 0)
        #expect(result.nativeTermination == RunTermination(kind: .exit, value: 0))
        let report = try #require(result.report), tools = try #require(report.payload.tools)
        for name in names {
            let path = fixture.path + "/tools/" + name
            var physical = stat()
            try #require(lstat(path, &physical) == 0)
            #expect(physical.st_nlink == 16)
            #expect(physical.st_mode & 0o7777 == 0o755)
            let evidence = try #require(tools[name])
            #expect(evidence.path == path)
            #expect(evidence.deviceID == Int64(physical.st_dev) && evidence.inode == physical.st_ino)
            #expect(evidence.sha256 == CanonicalJSONDigest.digest(try Data(contentsOf: URL(fileURLWithPath: path))))
        }
        let session = try #require(result.sessionPath)
        for relative in ["manifest.json", "Notika.doccarchive/data/notika.json", "site/index.html"] {
            var physical = stat()
            try #require(lstat(session + "/" + relative, &physical) == 0)
            #expect(physical.st_nlink == 1)
        }
    }

    @Test(arguments: ["bytes", "link-count", "replacement"])
    func hardlinkedToolMutationPreservesNativeExitButRefusesSuccessfulPublication(kind: String) async throws {
        let fixture = try DocumentationDriverFixture()
        defer { fixture.remove() }
        try fixture.hardlinkTool("xcodebuild")
        let driver = NotikaDocumentationDriver(identityCapture: fixture.capture, captureOperation: { helper, command, descriptors, root, directory in
            let phase = try await CapturedNativePhaseRunner().run(helperExecutable: helper, command: command,
                retainedLockDescriptors: descriptors, nativeWorkingDirectoryDescriptor: directory, artifactRoot: root)
            if command.executable == fixture.path + "/tools/xcodebuild" {
                let alias = URL(fileURLWithPath: fixture.path + "/tools/xcodebuild-alias-0")
                if kind == "bytes" {
                    try Data("changed executable through its hardlink".utf8).write(to: alias)
                } else if kind == "link-count" {
                    try FileManager.default.removeItem(at: alias)
                } else {
                    let path = URL(fileURLWithPath: command.executable)
                    let bytes = try Data(contentsOf: path)
                    try FileManager.default.removeItem(at: path)
                    try bytes.write(to: path)
                    try #require(chmod(path.path, 0o755) == 0)
                }
            }
            return phase
        })
        let result = try await driver.run(repository: fixture.path, mode: .rendered, helperExecutable: fixture.helper,
            registryRoot: fixture.registry, environment: fixture.environment, rendererRoot: fixture.renderer)
        #expect(result.nativeTermination == RunTermination(kind: .exit, value: 0))
        #expect(result.status == "inconclusive")
        #expect(result.exitCode == 70)
        #expect(result.rawCaptures.count == 1)
        #expect(result.ancillaryTerminations.isEmpty)
        #expect(!result.orchestrationFailures.isEmpty)
        #expect(result.report?.payload.executionComplete == false)
    }

    @Test(arguments: [NotikaDocumentationMode.archive, .rendered])
    func fixedToolsHoldOwnershipAndPublishHonestBoundedArtifacts(mode: NotikaDocumentationMode) async throws {
        let fixture = try DocumentationDriverFixture()
        defer { fixture.remove() }
        let steps = Mutex<[String]>([])
        let driver = NotikaDocumentationDriver(identityCapture: fixture.capture, captureOperation: { helper, command, descriptors, root, directory in
            #expect(try !fixture.available("notika:sessions:" + fixture.path))
            #expect(try !fixture.available(CacheCompatibilityIdentity.graphResourceName(canonicalWorktree: fixture.path)))
            #expect(try !fixture.available(CacheCompatibilityIdentity.cachePolicyResourceName(canonicalWorktree: fixture.path)))
            let compiling = command.executable == fixture.path + "/tools/xcodebuild"
            if compiling {
                let cache = try #require(command.environment["NOTIKA_DERIVED_DATA"])
                #expect(command.arguments == ["-derivedDataPath", cache, "-disableAutomaticPackageResolution", "docbuild",
                    "-workspace", "Notika.xcworkspace", "-scheme", "Notika", "-destination", "platform=macOS,arch=arm64"])
            }
            #expect(try fixture.compilationAvailable() == !compiling)
            #expect(command.environment["NOTIKA_DERIVED_DATA"]?.hasPrefix(fixture.path + "/DerivedData/AgentCaches/") == true)
            #expect(command.environment["NOTIKA_ROUTE_AUTHORITY_FD"] == nil)
            #expect(descriptors.allSatisfy { fcntl($0, F_GETFD) >= 0 })
            #expect(fcntl(directory, F_GETFD) >= 0)
            steps.withLock { $0.append(URL(fileURLWithPath: command.executable).lastPathComponent) }
            return try await CapturedNativePhaseRunner().run(helperExecutable: helper, command: command,
                retainedLockDescriptors: descriptors, nativeWorkingDirectoryDescriptor: directory, artifactRoot: root)
        })
        let result = try await driver.run(repository: fixture.path, mode: mode, helperExecutable: fixture.helper,
            registryRoot: fixture.registry, environment: fixture.environment, rendererRoot: fixture.renderer)
        #expect(result.status == "succeeded")
        #expect(result.exitCode == 0)
        #expect(result.nativeTermination == RunTermination(kind: .exit, value: 0))
        #expect(result.orchestrationFailures.isEmpty)
        #expect(result.publicationFailures.isEmpty)
        #expect(steps.withLock { $0 } == (mode == .archive ? ["xcodebuild"] : ["xcodebuild", "docc"]))
        let report = try #require(result.report), session = try #require(result.sessionPath)
        #expect(report.lifecycle == "terminal")
        #expect(report.archivePath == session + "/Notika.doccarchive")
        #expect(try Data(contentsOf: URL(fileURLWithPath: session + "/Notika.doccarchive/data/notika.json")) == Data("archive".utf8))
        if mode == .rendered {
            #expect(report.sitePath == session + "/site")
            #expect(try Data(contentsOf: URL(fileURLWithPath: session + "/site/index.html")) == Data("renderer".utf8))
            #expect(try Data(contentsOf: URL(fileURLWithPath: session + "/site/data/notika.json")) == Data("transformed".utf8))
            var siteFile = stat()
            #expect(lstat(session + "/site/index.html", &siteFile) == 0)
            #expect(siteFile.st_mode & 0o7777 == 0o600)
        }
        for name in ["in-progress.json", "manifest.json"] {
            var observed = stat()
            #expect(lstat(session + "/" + name, &observed) == 0)
            #expect(observed.st_mode & 0o7777 == 0o400)
            #expect(observed.st_nlink == 1)
        }
        #expect(try fixture.available("notika:sessions:" + fixture.path))
        #expect(try fixture.available(CacheCompatibilityIdentity.graphResourceName(canonicalWorktree: fixture.path)))
        #expect(try fixture.compilationAvailable())
        try documentationRejectTamperedReports(report)
    }

    @Test func nativeFailureRetainsExactBinaryLogsAndSkipsRendering() async throws {
        let fixture = try DocumentationDriverFixture()
        defer { fixture.remove() }
        try fixture.script("tools/xcodebuild", #"printf '\000\377\200'; printf 'native failure' >&2; exit 27"#)
        let result = try await fixture.driver.run(repository: fixture.path, mode: .rendered, helperExecutable: fixture.helper,
            registryRoot: fixture.registry, environment: fixture.environment, rendererRoot: fixture.renderer)
        #expect(result.nativeTermination == RunTermination(kind: .exit, value: 27))
        #expect(result.exitCode == 27)
        #expect(result.status == "failed")
        #expect(result.rawCaptures.count == 1)
        #expect(result.ancillaryTerminations.isEmpty)
        #expect(result.report?.archivePath == nil)
        #expect(try Data(contentsOf: URL(fileURLWithPath: #require(result.rawCaptures.first).standardOutput.path)) == Data([0, 255, 128]))
        // Previously recorded generic-destination failures remain readable for
        // retention, preserving their actual nonzero native outcome.
        let report = try #require(result.report)
        var legacy = try #require(JSONSerialization.jsonObject(with: report.originalData) as? [String: Any])
        var phases = try #require(legacy["phases"] as? [[String: Any]])
        var command = try #require(phases[0]["command"] as? [String: Any])
        var arguments = try #require(command["arguments"] as? [String])
        arguments[arguments.count - 1] = "generic/platform=macOS"
        command["arguments"] = arguments; phases[0]["command"] = command; legacy["phases"] = phases
        let retained = try NotikaDocumentationSessionReport(data: JSONSerialization.data(withJSONObject: legacy))
        #expect(retained.nativeTermination == RunTermination(kind: .exit, value: 27))
        #expect(retained.status == "failed" && retained.exitCode == 27)
    }

    @Test func renderFailureKeepsSuccessfulDocbuildStatusSeparate() async throws {
        let fixture = try DocumentationDriverFixture()
        defer { fixture.remove() }
        try fixture.script("tools/docc", "printf 'render failed' >&2; exit 19")
        let result = try await fixture.driver.run(repository: fixture.path, mode: .rendered, helperExecutable: fixture.helper,
            registryRoot: fixture.registry, environment: fixture.environment, rendererRoot: fixture.renderer)
        #expect(result.nativeTermination == RunTermination(kind: .exit, value: 0))
        #expect(result.ancillaryTerminations == [RunTermination(kind: .exit, value: 19)])
        #expect(result.exitCode == 19)
        #expect(result.status == "failed")
        #expect(result.report?.archivePath != nil)
        #expect(result.report?.sitePath == nil)
    }

    @Test func missingFixedArchiveIsInconclusiveAfterNativeZero() async throws {
        let fixture = try DocumentationDriverFixture()
        defer { fixture.remove() }
        try fixture.script("tools/xcodebuild", "printf 'no archive'; exit 0")
        let result = try await fixture.driver.run(repository: fixture.path, mode: .archive, helperExecutable: fixture.helper,
            registryRoot: fixture.registry, environment: fixture.environment)
        #expect(result.nativeTermination == RunTermination(kind: .exit, value: 0))
        #expect(result.status == "inconclusive")
        #expect(result.exitCode == 70)
        #expect(result.report?.archivePath == nil)
    }

    @Test(arguments: ["renderer", "raw", "source"])
    func observedMutationCannotBecomeSuccessfulDocumentation(kind: String) async throws {
        let fixture = try DocumentationDriverFixture()
        defer { fixture.remove() }
        let driver = NotikaDocumentationDriver(identityCapture: fixture.capture, captureOperation: { helper, command, descriptors, root, directory in
            let phase = try await CapturedNativePhaseRunner().run(helperExecutable: helper, command: command,
                retainedLockDescriptors: descriptors, nativeWorkingDirectoryDescriptor: directory, artifactRoot: root)
            if command.executable.hasSuffix("/xcodebuild") {
                let path = kind == "renderer" ? fixture.renderer + "/index.html"
                    : kind == "source" ? fixture.path + "/Project.swift" : phase.rawCapture.standardOutput.path
                try Data("changed after admission".utf8).write(to: URL(fileURLWithPath: path))
            }
            return phase
        })
        let result = try await driver.run(repository: fixture.path, mode: .rendered, helperExecutable: fixture.helper,
            registryRoot: fixture.registry, environment: fixture.environment, rendererRoot: fixture.renderer)
        #expect(result.nativeTermination == RunTermination(kind: .exit, value: 0))
        #expect(result.exitCode == 70)
        #expect(result.status == "inconclusive")
        if kind == "renderer" { #expect(result.rawCaptures.count == 1) }
        if kind == "raw" { #expect(!result.publicationFailures.isEmpty) }
        if kind == "source" { #expect(result.report?.payload.sourceChanged == true) }
    }

    @Test(arguments: [false, true])
    func previewServesLoopbackAndRetainsOwnershipUntilNativeRetirement(delayedStartup: Bool) async throws {
        let fixture = try DocumentationDriverFixture()
        defer { fixture.remove() }
        let ready = Mutex<NotikaDocumentationPreviewEvidence?>(nil)
        let previewStarted = Mutex<ContinuousClock.Instant?>(nil)
        let driver = NotikaDocumentationDriver(identityCapture: fixture.capture,
            captureOperation: { helper, command, descriptors, root, directory in
                if command.arguments.first == "_notika-doc-preview" {
                    previewStarted.withLock { $0 = ContinuousClock.now }
                    // Allowed validation work must not expire the former 15s
                    // readiness timer while the admitted helper is starting.
                    if delayedStartup { try await Task.sleep(for: .seconds(16)) }
                }
                return try await CapturedNativePhaseRunner().run(helperExecutable: helper, command: command,
                    retainedLockDescriptors: descriptors, nativeWorkingDirectoryDescriptor: directory, artifactRoot: root)
            })
        let port = try documentationUnusedLoopbackPort()
        let task = Task { try await driver.run(repository: fixture.path, mode: .preview, helperExecutable: fixture.helper,
            registryRoot: fixture.registry, environment: fixture.environment, rendererRoot: fixture.renderer, previewPort: port,
            onPreviewReady: { evidence in ready.withLock { $0 = evidence } }) }
        defer { task.cancel() }
        let deadline = ContinuousClock.now + .seconds(30)
        while ready.withLock({ $0 == nil }) {
            guard ContinuousClock.now < deadline else { task.cancel(); _ = try await task.value; throw DocumentationDriverFixture.Failure.deadline }
            try await Task.sleep(for: .milliseconds(10))
        }
        let evidence = try #require(ready.withLock { $0 })
        if delayedStartup {
            let started = try #require(previewStarted.withLock { $0 })
            #expect(started.duration(to: ContinuousClock.now) >= .seconds(16))
        }
        #expect(evidence.host == "127.0.0.1")
        #expect(try !fixture.available("notika:sessions:" + fixture.path))
        #expect(try !fixture.available(CacheCompatibilityIdentity.graphResourceName(canonicalWorktree: fixture.path)))
        #expect(try !fixture.available(CacheCompatibilityIdentity.cachePolicyResourceName(canonicalWorktree: fixture.path)))
        #expect(try fixture.compilationAvailable())
        let (data, response) = try await URLSession.shared.data(from: #require(URL(string: evidence.url)))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect((response as? HTTPURLResponse)?.mimeType == "text/html")
        #expect(data == Data("renderer".utf8))
        let (_, outside) = try await URLSession.shared.data(from: #require(URL(string: "http://127.0.0.1:\(port)/outside.txt")))
        #expect((outside as? HTTPURLResponse)?.statusCode == 404)
        task.cancel()
        let result = try await task.value
        #expect(result.nativeTermination == RunTermination(kind: .exit, value: 0))
        #expect(result.cancelled)
        #expect(result.status == "cancelled")
        #expect(result.exitCode == 130)
        #expect(result.rawCaptures.count == 3)
        let capturesComplete = result.rawCaptures.allSatisfy(\.captureComplete)
        #expect(capturesComplete)
        let previewPhase = try #require(result.report?.payload.phases.last)
        #expect(previewPhase.step == .preview)
        #expect(previewPhase.processID == evidence.processID)
        #expect(previewPhase.retirement == "workerReaped")
        #expect(previewPhase.cancelled)
        #expect(kill(evidence.processID, 0) == -1 && errno == ESRCH)
        #expect(try fixture.available("notika:sessions:" + fixture.path))
        #expect(try fixture.available(CacheCompatibilityIdentity.graphResourceName(canonicalWorktree: fixture.path)))
    }

    @Test func busyWriterAndPartialLeaseEnvironmentHaveNoSessionEffects() async throws {
        let fixture = try DocumentationDriverFixture()
        defer { fixture.remove() }
        let held = try FileLock(resource: ResourceName("notika:sessions:" + fixture.path), paths: AgentLeasePaths.open(selectedRoot: fixture.registry))
        #expect(try held.tryAcquire())
        await #expect(throws: (any Error).self) {
            _ = try await fixture.driver.run(repository: fixture.path, mode: .archive, helperExecutable: fixture.helper,
                registryRoot: fixture.registry, environment: fixture.environment, waitSeconds: 0)
        }
        held.release()
        var environment = fixture.environment
        environment["SIMLEASE_MACOS_UI"] = "1"
        await #expect(throws: (any Error).self) {
            _ = try await fixture.driver.run(repository: fixture.path, mode: .archive, helperExecutable: fixture.helper,
                registryRoot: fixture.registry, environment: environment)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "/Artifacts"))
    }
}

private func documentationRejectTamperedReports(_ report: NotikaDocumentationSessionReport) throws {
    let object = try #require(JSONSerialization.jsonObject(with: report.originalData) as? [String: Any])
    var mutations = [object.merging(["foreign": true]) { _, new in new },
                     object.merging(["schemaVersion": true]) { _, new in new },
                     object.merging(["executionComplete": true, "phases": []]) { _, new in new }]
    var noIdentity = object
    noIdentity.removeValue(forKey: "compatibilityIdentityJSON"); noIdentity.removeValue(forKey: "cachePath")
    mutations.append(noIdentity)
    var tools = try #require(object["tools"] as? [String: Any])
    tools["unknown"] = tools["docc"]
    mutations.append(object.merging(["tools": tools]) { _, new in new })
    var phases = try #require(object["phases"] as? [[String: Any]])
    var wrongDestination = phases
    var command = try #require(wrongDestination[0]["command"] as? [String: Any])
    var arguments = try #require(command["arguments"] as? [String])
    arguments[arguments.count - 1] = "generic/platform=macOS"
    command["arguments"] = arguments; wrongDestination[0]["command"] = command
    mutations.append(object.merging(["phases": wrongDestination]) { _, new in new })
    phases[0]["nativeTermination"] = ["kind": "signal", "value": Int32.max]
    mutations.append(object.merging(["phases": phases, "buildNativeTermination": ["kind": "signal", "value": Int32.max]]) { _, new in new })
    if report.mode == .rendered { mutations.append(object.merging(["phases": Array((try #require(object["phases"] as? [[String: Any]])).prefix(1))]) { _, new in new }) }
    for mutation in mutations {
        #expect(throws: (any Error).self) { _ = try NotikaDocumentationSessionReport(data: JSONSerialization.data(withJSONObject: mutation)) }
    }
    let literalFloat = Data(String(decoding: report.originalData, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1.0").utf8)
    #expect(throws: (any Error).self) { _ = try NotikaDocumentationSessionReport(data: literalFloat) }
}

private struct DocumentationDriverCapture: RepositoryCommandCapturing {
    let docc: String
    func capture(arguments: [String], workingDirectory: String, environment: [String: String]) async throws -> Data {
        if arguments == ["git", "rev-parse", "HEAD"] { return Data(String(repeating: "a", count: 40).utf8) }
        if arguments == ["git", "rev-parse", "--show-toplevel"] { return Data(workingDirectory.utf8) }
        if arguments == [workingDirectory + "/tools/xcrun", "--find", "docc"] { return Data(docc.utf8) }
        return Data()
    }
}
private struct DocumentationDriverFixture: Sendable {
    enum Failure: Error { case deadline, fileSystem(Int32) }
    let path: String
    let helper: String
    var registry: String { path + "/registry" }
    var compileRegistry: String { path + "/compile-registry" }
    var renderer: String { path + "/renderer-source" }
    var capture: DocumentationDriverCapture { .init(docc: path + "/tools/docc") }
    var driver: NotikaDocumentationDriver { .init(identityCapture: capture) }
    var environment: [String: String] {
        ["PATH": path + "/tools:/usr/bin:/bin", "HOME": path, "AGENTLEASE_COMPILE_HOME": compileRegistry,
         "NOTIKA_ROUTE_AUTHORITY_FD": "1234"]
    }
    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentbuild-docc-driver-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard let canonical = directory.path.withCString({ realpath($0, nil) }) else { throw Failure.fileSystem(errno) }
        path = String(cString: canonical); free(canonical)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        helper = repository.appendingPathComponent(".build/debug/agentbuild").path
        try write("Project.swift", "fixture graph")
        try write("Notika.xcodeproj/project.pbxproj", "fixture project")
        try write("Notika.xcworkspace/xcshareddata/swiftpm/Package.resolved", "fixture dependencies")
        try write("renderer-source/index.html", "renderer")
        try write("renderer-source/assets/theme.css", "body {}")
        try script("tools/xcrun", "exit 0")
        try script("tools/xcodebuild", #"""
        [ "$#" = 10 ] && [ "$1" = -derivedDataPath ] && [ "$2" = "$NOTIKA_DERIVED_DATA" ] || exit 21
        [ "$3" = -disableAutomaticPackageResolution ] && [ "$4" = docbuild ] || exit 22
        [ "$5" = -workspace ] && [ "$6" = Notika.xcworkspace ] && [ "$7" = -scheme ] && [ "$8" = Notika ] || exit 25
        [ "$9" = -destination ] && [ "${10}" = platform=macOS,arch=arm64 ] || exit 26
        /bin/mkdir -p "$2/Build/Products/Debug/Notika.doccarchive/data"
        printf 'archive' > "$2/Build/Products/Debug/Notika.doccarchive/data/notika.json"
        printf 'native docbuild'
        """#)
        try script("tools/docc", #"""
        [ "$#" = 7 ] && [ "$1" = process-archive ] && [ "$2" = transform-for-static-hosting ] || exit 23
        [ "$4" = --output-path ] && [ "$6" = --hosting-base-path ] && [ "$7" = / ] || exit 24
        /bin/mkdir -p "$5/data"
        printf 'transformed' > "$5/data/notika.json"
        printf 'placeholder' > "$5/index.html"
        /bin/chmod 644 "$5/index.html" "$5/data/notika.json"
        /bin/chmod 755 "$5/data"
        printf 'native transform'
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
    func hardlinkTool(_ name: String) throws {
        let executable = path + "/tools/" + name
        guard chmod(executable, 0o755) == 0 else { throw Failure.fileSystem(errno) }
        for index in 0..<15 {
            guard link(executable, executable + "-alias-\(index)") == 0 else { throw Failure.fileSystem(errno) }
        }
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
private func documentationUnusedLoopbackPort() throws -> Int {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw DocumentationDriverFixture.Failure.fileSystem(errno) }
    defer { _ = close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0 else { throw DocumentationDriverFixture.Failure.fileSystem(errno) }
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let observed = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
    }
    guard observed == 0 else { throw DocumentationDriverFixture.Failure.fileSystem(errno) }
    return Int(UInt16(bigEndian: address.sin_port))
}
