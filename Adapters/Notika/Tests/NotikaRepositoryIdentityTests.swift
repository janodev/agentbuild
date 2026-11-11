import AgentBuildCore
import Darwin
import Foundation
@testable import NotikaAdapter
import Testing

@Suite("Notika repository identity observations")
struct NotikaRepositoryIdentityTests {
    @Test func sourceJSONMatchesStaticPythonOracleIncludingRawBytesAndGraphOrder() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.remove() }
        try fixture.write("Project.swift", Data("P".utf8))
        try fixture.write("Tuist.swift", Data("T".utf8))
        try fixture.write(".mise.toml", Data("M".utf8))
        try fixture.write("Notika.xcodeproj/project.pbxproj", Data("G".utf8))
        try fixture.write("Notika.xcworkspace/xcshareddata/swiftpm/Package.resolved", Data("R".utf8))
        try fixture.write("Notika.xcodeproj/xcuserdata/person/data", Data("ignored".utf8))
        try fixture.write("input.bin", Data([97, 0, 98, 255]))
        try fixture.link("link", "../../external")
        try fixture.link("Notika.xcodeproj/directory-link", "../Notika.xcworkspace")
        let provider = try NotikaRepositoryIdentity(repository: fixture.path, capture: IdentityOracleCapture(),
                                                    environment: ["PATH": "/usr/bin:/bin", "SDKROOT": "retained",
                                                                  "NOTIKA_ROUTE_AUTHORITY_TICKET": "must-be-scrubbed",
                                                                  "NOTIKA_ROUTE_GRAPH_LOCK_FD": "42",
                                                                  "NOTIKA_INTERACTIVE_SIGNAL_RELAY_WRITE_FD": "43"])
        let source = try await provider.sourceIdentity()
        // Python RepositoryIdentityProvider oracle with these exact raw vectors,
        // file bytes and canonical root /REPOSITORY; excludes xcuserdata and the
        // directory symlink and retains graph inputs in their declared order.
        #expect(try source.digest() == "60fad6e79c78bd6c2c0fee629362a2f41f0194ba2d3a22acaa499f0a00e9202b")
        #expect(source.gitlinks.isEmpty)
    }

    @Test func realGitTracksStagedUnstagedAndUntrackedInputsWithReviewExclusions() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.remove() }
        try await fixture.initializeGit()
        try fixture.write("tracked.txt", Data("base\n".utf8))
        try fixture.write("GPT-Pro/reviews/one.md", Data("review\n".utf8))
        try fixture.write("GPT-Pro/reviews/admitted.json", Data("input\n".utf8))
        try fixture.write("DerivedData/tracked.txt", Data("cache\n".utf8))
        try await fixture.git(["add", "."])
        try await fixture.git(["commit", "-qm", "fixture"])
        let provider = try fixture.provider()
        let initial = try await provider.sourceIdentity()
        try fixture.write("GPT-Pro/reviews/one.md", Data("changed review\n".utf8))
        try fixture.write("GPT-Pro/reviews/new.md", Data("new review\n".utf8))
        #expect(try await provider.sourceIdentity().keyMaterial == initial.keyMaterial)
        try fixture.write("tracked.txt", Data("staged\n".utf8))
        try await fixture.git(["add", "tracked.txt"])
        try fixture.write("tracked.txt", Data("unstaged\n".utf8))
        try fixture.write("input space.bin", Data([0, 255, 10]))
        try fixture.link("outside-link", "../../outside-never-hashed")
        try fixture.write("DerivedData/untracked.txt", Data("ignored status\n".utf8))
        try fixture.write("Artifacts/AgentSessions/session/log", Data("ignored status\n".utf8))
        let changed = try await provider.sourceIdentity()
        #expect(changed.statusDigest != initial.statusDigest)
        #expect(changed.stagedDiffDigest != initial.stagedDiffDigest)
        #expect(changed.unstagedDiffDigest != initial.unstagedDiffDigest)
        let rows = try jsonRows(changed, "untrackedInputs")
        #expect(rows.compactMap { $0["path"] as? String } == ["input space.bin", "outside-link"])
        #expect(rows.first?["bytes"] as? Int == 3)
        #expect(rows.last?["linkTarget"] as? String == "../../outside-never-hashed")
        #expect(rows.last?["sha256"] == nil)
        let rawStatus = try await fixture.git(["status", "--porcelain=v2", "-z", "--untracked-files=all", "--", ".",
                                               ":(exclude)Artifacts/AgentSessions/**", ":(exclude)DerivedData/**",
                                               ":(glob,exclude)GPT-Pro/reviews/*.md"])
        #expect(changed.statusDigest == CanonicalJSONDigest.digest(rawStatus))
        // The reference excludes caches from status, but only reviews from diff.
        try fixture.write("DerivedData/tracked.txt", Data("changed tracked cache\n".utf8))
        let cacheChanged = try await provider.sourceIdentity()
        #expect(cacheChanged.statusDigest == changed.statusDigest)
        #expect(cacheChanged.unstagedDiffDigest != changed.unstagedDiffDigest)
        try fixture.write("GPT-Pro/reviews/admitted.json", Data("admitted change\n".utf8))
        #expect(try await provider.sourceIdentity().statusDigest != cacheChanged.statusDigest)
    }

    @Test func graphHashesFollowContainedFilesAndSkipUserDataDirectoryLinksAndLoops() async throws {
        let fixture = try IdentityFixture()
        let outside = try IdentityFixture()
        defer { fixture.remove(); outside.remove() }
        try fixture.write("actual.swift", Data(repeating: 67, count: 192 * 1_024 + 7))
        try fixture.link("Project.swift", "actual.swift")
        try fixture.link("Tuist.swift", "Tuist.swift")
        try fixture.write("Notika.xcodeproj/z-last", Data("last".utf8))
        try fixture.write("Notika.xcodeproj/a-first", Data("first".utf8))
        try fixture.write("Notika.xcodeproj/xcuserdata/user/info", Data("user".utf8))
        try outside.write("file", Data("external".utf8))
        try fixture.link("Notika.xcodeproj/external-directory", outside.path)
        let provider = try fixture.provider(capture: EmptyIdentityCapture())
        let source = try await provider.sourceIdentity()
        let graph = try jsonRows(source, "projectGraphFiles")
        #expect(graph.compactMap { $0["path"] as? String } == ["Project.swift"])
        #expect(graph.first?["sha256"] as? String == CanonicalJSONDigest.digest(Data(repeating: 67, count: 192 * 1_024 + 7)))
        #expect(try jsonRows(source, "generatedGraphFiles").compactMap { $0["path"] as? String } ==
                ["Notika.xcodeproj/a-first", "Notika.xcodeproj/z-last"])
        try fixture.write("Notika.xcodeproj/xcuserdata/user/info", Data("changed".utf8))
        #expect(try await provider.sourceIdentity().generatedGraphDigest == source.generatedGraphDigest)
        try FileManager.default.removeItem(atPath: fixture.path + "/Project.swift")
        try fixture.link("Project.swift", outside.path + "/file")
        await #expect(throws: NotikaRepositoryIdentityError.invalidGraphInput("Project.swift")) {
            _ = try await provider.sourceIdentity()
        }
        try FileManager.default.removeItem(atPath: fixture.path + "/Project.swift")
        try fixture.link("Notika.xcworkspace", outside.path)
        #expect(try await provider.sourceIdentity().generatedGraphDigest == source.generatedGraphDigest)
    }

    @Test func realGitSubmoduleIncludesDirtyWorktreeAndRejectsNestedGitlinks() async throws {
        let fixture = try IdentityFixture()
        let library = try IdentityFixture()
        defer { fixture.remove(); library.remove() }
        try await fixture.initializeGit()
        try await library.initializeGit()
        try library.write("tracked.txt", Data("library\n".utf8))
        try await library.git(["add", "."])
        try await library.git(["commit", "-qm", "library"])
        try await fixture.git(["-c", "protocol.file.allow=always", "submodule", "add", "-q", library.path, "Vendor/Library Space"])
        try await fixture.git(["commit", "-qam", "submodule"])
        let provider = try fixture.provider()
        let original = try await provider.sourceIdentity()
        let link = try #require(original.gitlinks.first)
        #expect(link.path == "Vendor/Library Space")
        let child = fixture.path + "/" + link.path
        try Data("dirty\n".utf8).write(to: URL(fileURLWithPath: child + "/tracked.txt"))
        try Data([255, 0]).write(to: URL(fileURLWithPath: child + "/new.bin"))
        let dirty = try await provider.sourceIdentity()
        #expect(dirty.gitlinks == original.gitlinks)
        #expect(dirty.submoduleWorktreeDigest != original.submoduleWorktreeDigest)
        let records = try jsonRows(dirty, "submoduleWorktrees")
        let untracked = try #require(records.first?["untrackedInputs"] as? [[String: Any]])
        #expect(untracked.first?["path"] as? String == "Vendor/Library Space/new.bin")
        #expect(untracked.first?["bytes"] as? Int == 2)
        try await fixture.git(["config", "-f", ".gitmodules", "submodule.Nested.path", "Nested"], root: child)
        try await fixture.git(["config", "-f", ".gitmodules", "submodule.Nested.url", library.path], root: child)
        try await fixture.git(["update-index", "--add", "--cacheinfo", "160000," + link.commit + ",Nested"], root: child)
        await #expect(throws: NotikaRepositoryIdentityError.nestedSubmodule(link.path)) {
            _ = try await provider.sourceIdentity()
        }
    }

    @Test func missingAndEscapedSubmoduleWorktreesFailClosed() async throws {
        let fixture = try IdentityFixture()
        let outside = try IdentityFixture()
        defer { fixture.remove(); outside.remove() }
        let capture = EmptyIdentityCapture(gitlink: "Vendor/Library")
        let provider = try fixture.provider(capture: capture)
        do {
            _ = try await provider.sourceIdentity()
            Issue.record("missing submodule was accepted")
        } catch let error as NotikaRepositoryIdentityError {
            guard case .unavailableSubmodule(let path, let diagnostic) = error else { throw error }
            #expect(path == "Vendor/Library")
            #expect(diagnostic.contains("No such file or directory"))
        }
        try fixture.link("Vendor/Library", outside.path)
        await #expect(throws: NotikaRepositoryIdentityError.escapedSubmodule("Vendor/Library")) {
            _ = try await provider.sourceIdentity()
        }
    }

    @Test func toolchainSnapshotUsesExactProbesCanonicalBinaryBytesAndFailureDiagnostics() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.remove() }
        let bytes = Data([0, 255, 65, 10])
        try fixture.write("bin/actual-tool", bytes)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.path + "/bin/actual-tool")
        try fixture.link("bin/simslim", "actual-tool")
        let capture = ToolchainOracleCapture(repository: fixture.path)
        let provider = try NotikaRepositoryIdentity(repository: fixture.path, capture: capture,
                                                    environment: ["PATH": fixture.path + "/bin"])
        let toolchain = try await provider.toolchainIdentity()
        let object = try jsonObject(toolchain.keyMaterial)
        let versions = try #require(object["versions"] as? [String: Any])
        #expect(versions["xcode"] as? String == "Xcode 27.0\nBuild version TEST")
        #expect(versions["sdk"] as? String == "27.0")
        #expect(versions["tuist"] as? String == "4.210.0")
        let swift = try #require(versions["swift"] as? [String: String])
        #expect(swift["unavailable"] == "command failed (7): swift: fixture failure")
        let binaries = try #require(object["binaries"] as? [String: [String: Any]])
        #expect(binaries["simslim"]?["path"] as? String == fixture.path + "/bin/actual-tool")
        #expect(binaries["simslim"]?["sha256"] as? String == CanonicalJSONDigest.digest(bytes))
        #expect(binaries["agentlease"]?["unavailable"] as? Bool == true)
        let incomplete = try NotikaRepositoryIdentity(repository: fixture.path, capture: FailingIdentityCapture(error: .outputLimitExceeded))
        await #expect(throws: RepositoryCaptureError.outputLimitExceeded) { _ = try await incomplete.toolchainIdentity() }
        let cancelled = try NotikaRepositoryIdentity(repository: fixture.path, capture: CancelledIdentityCapture())
        await #expect(throws: CancellationError.self) { _ = try await cancelled.toolchainIdentity() }
    }

    @Test func invalidUTF8StatusPathCannotBecomeReplacementHashMaterial() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.remove() }
        let provider = try fixture.provider(capture: EmptyIdentityCapture(status: Data([63, 32, 255, 0])))
        await #expect(throws: NotikaRepositoryIdentityError.invalidUTF8Path) { _ = try await provider.sourceIdentity() }
        #expect(throws: NotikaRepositoryIdentityError.invalidEnvironment) {
            try NotikaRepositoryIdentity(repository: fixture.path, capture: EmptyIdentityCapture(), environment: ["PATH": "/bin\0tail"])
        }
    }

    @Test func executableFIFOIsRejectedWithoutBlockingInOpenOrRead() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(atPath: fixture.path + "/bin", withIntermediateDirectories: true)
        let fifo = fixture.path + "/bin/simslim"
        #expect(fifo.withCString { mkfifo($0, 0o755) } == 0)
        let provider = try NotikaRepositoryIdentity(repository: fixture.path,
                                                    capture: ToolchainOracleCapture(repository: fixture.path),
                                                    environment: ["PATH": fixture.path + "/bin"])
        await #expect(throws: NotikaRepositoryIdentityError.invalidFileType(fifo)) { _ = try await provider.toolchainIdentity() }
    }
}

private struct IdentityFixture: Sendable {
    let path: String
    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notika-identity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let canonical = try #require(url.path.withCString { realpath($0, nil) })
        defer { free(canonical) }
        path = String(cString: canonical)
    }
    func remove() { try? FileManager.default.removeItem(atPath: path) }
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
    var environment: [String: String] {
        ["PATH": "/usr/bin:/bin", "HOME": path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
         "GIT_AUTHOR_DATE": "2000-01-01T00:00:00+0000", "GIT_COMMITTER_DATE": "2000-01-01T00:00:00+0000"]
    }
    func provider(capture: (any RepositoryCommandCapturing)? = nil) throws -> NotikaRepositoryIdentity {
        try NotikaRepositoryIdentity(repository: path, capture: capture, environment: environment)
    }
    @discardableResult func git(_ arguments: [String], root: String? = nil) async throws -> Data {
        try await RepositoryCommandCapture().capture(arguments: ["/usr/bin/git"] + arguments,
                                                    workingDirectory: root ?? path, environment: environment)
    }
    func initializeGit() async throws {
        try await git(["init", "-q"])
        try await git(["config", "user.email", "identity-fixture@example.invalid"])
        try await git(["config", "user.name", "Identity Fixture"])
        try await git(["config", "core.autocrlf", "false"])
    }
}

private enum IdentityFixtureError: Error { case unexpectedProbe, capabilityInherited }

private struct IdentityOracleCapture: RepositoryCommandCapturing {
    func capture(arguments: [String], workingDirectory: String, environment: [String: String]) async throws -> Data {
        guard !environment.keys.contains(where: { $0.hasPrefix("NOTIKA_") }) else { throw IdentityFixtureError.capabilityInherited }
        let review = ":(glob,exclude)GPT-Pro/reviews/*.md"
        switch arguments {
        case ["git", "rev-parse", "HEAD"]: return Data("\u{001C}abc\u{001D}\n".utf8)
        case ["git", "rev-parse", "--show-toplevel"]: return Data("/REPOSITORY\n".utf8)
        case ["git", "status", "--porcelain=v2", "-z", "--untracked-files=all", "--", ".",
              ":(exclude)Artifacts/AgentSessions/**", ":(exclude)DerivedData/**", review]: return Data("? input.bin\0? link\0".utf8)
        case ["git", "diff", "--cached", "--binary", "--no-ext-diff", "--", ".", review]: return Data("staged\0".utf8) + Data([255, 10])
        case ["git", "diff", "--binary", "--no-ext-diff", "--", ".", review]: return Data("unstaged\n\0".utf8)
        case ["git", "ls-files", "--stage", "-z", "--", ".", review]:
            return Data(("100644 " + String(repeating: "1", count: 40) + " 0\ttracked\0").utf8)
        case ["git", "submodule", "status", "--recursive"]: return Data()
        default: throw IdentityFixtureError.unexpectedProbe
        }
    }
}

private struct EmptyIdentityCapture: RepositoryCommandCapturing {
    var gitlink: String? = nil
    var status: Data = Data()
    func capture(arguments: [String], workingDirectory: String, environment: [String: String]) async throws -> Data {
        if arguments == ["git", "rev-parse", "HEAD"] { return Data(String(repeating: "a", count: 40).utf8) }
        if arguments == ["git", "rev-parse", "--show-toplevel"] { return Data(workingDirectory.utf8) }
        if arguments.contains("status"), arguments.contains("--porcelain=v2") { return status }
        if arguments.contains("ls-files"), let gitlink {
            return Data(("160000 " + String(repeating: "a", count: 40) + " 0\t" + gitlink + "\0").utf8)
        }
        return Data()
    }
}

private struct ToolchainOracleCapture: RepositoryCommandCapturing {
    let repository: String
    func capture(arguments: [String], workingDirectory: String, environment: [String: String]) async throws -> Data {
        switch arguments {
        case ["xcodebuild", "-version"]: return Data("\u{001C}Xcode 27.0\nBuild version TEST\u{001D}\n".utf8)
        case ["swift", "--version"]: throw RepositoryCaptureError.commandFailed(executable: "swift", exitCode: 7, diagnostic: "fixture failure")
        case ["xcrun", "--sdk", "macosx", "--show-sdk-version"]: return Data("27.0\n".utf8)
        case [repository + "/Scripts/tuist", "version"]: return Data("4.210.0\n".utf8)
        default: throw IdentityFixtureError.unexpectedProbe
        }
    }
}

private struct FailingIdentityCapture: RepositoryCommandCapturing {
    let error: RepositoryCaptureError
    func capture(arguments: [String], workingDirectory: String, environment: [String: String]) async throws -> Data { throw error }
}

private struct CancelledIdentityCapture: RepositoryCommandCapturing {
    func capture(arguments: [String], workingDirectory: String, environment: [String: String]) async throws -> Data { throw CancellationError() }
}

private func jsonObject(_ material: CanonicalJSONValue) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: CanonicalJSONDigest.encode(material)) as? [String: Any])
}

private func jsonRows(_ source: NotikaSourceIdentity, _ key: String) throws -> [[String: Any]] {
    try #require(jsonObject(source.keyMaterial)[key] as? [[String: Any]])
}
