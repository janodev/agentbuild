@testable import ABDiffAdapter
@testable import AgentBuildCore
import Darwin
import Foundation
import Testing

struct ABDiffSourceSnapshotTests {
    @Test(arguments: [false, true])
    func trackedFileContentChangesRemainEvidenceWithoutUnexpectedDrift(alreadyDirty: Bool) async throws {
        let fixture = try await SourceSnapshotFixture()
        defer { fixture.remove() }
        if alreadyDirty { try fixture.write("BuildNumber.xcconfig", "CURRENT_PROJECT_VERSION = 113\n") }
        let before = try await fixture.snapshot(allowing: ["BuildNumber.xcconfig"])
        try fixture.write("BuildNumber.xcconfig", "CURRENT_PROJECT_VERSION = 114\n", atomically: true)
        let after = try await fixture.snapshot(allowing: ["BuildNumber.xcconfig"])
        #expect(before.raw != after.raw)
        #expect(before.comparison == after.comparison)
        #expect(before.allowedFileHashes["BuildNumber.xcconfig"] != after.allowedFileHashes["BuildNumber.xcconfig"])
        #expect(after.allowedFileHashes["BuildNumber.xcconfig"]?.count == 64)
    }

    @Test func defaultPolicyStillRejectsTrackedFileChanges() async throws {
        let fixture = try await SourceSnapshotFixture()
        defer { fixture.remove() }
        let before = try await fixture.snapshot()
        try fixture.write("BuildNumber.xcconfig", "CURRENT_PROJECT_VERSION = 114\n")
        let after = try await fixture.snapshot()
        #expect(before.raw == before.comparison)
        #expect(after.raw == after.comparison)
        #expect(before.comparison != after.comparison)
        #expect(after.allowedFileHashes.isEmpty)
    }

    @Test(arguments: ["Main.swift", "Untracked.swift", "BuildNumber.xcconfig.extra"])
    func concurrentChangesOutsideTheExactAllowedFileStayUnexpected(_ path: String) async throws {
        let fixture = try await SourceSnapshotFixture()
        defer { fixture.remove() }
        // Start dirty so an implementation looking only for new status entries
        // cannot mistake a second content change for stable inputs.
        try fixture.write(path, "before\n")
        let before = try await fixture.snapshot(allowing: ["BuildNumber.xcconfig"])
        try fixture.write("BuildNumber.xcconfig", "CURRENT_PROJECT_VERSION = 114\n")
        try fixture.write(path, "after\n")
        let after = try await fixture.snapshot(allowing: ["BuildNumber.xcconfig"])
        #expect(before.raw != after.raw)
        #expect(before.comparison != after.comparison)
    }

    @Test(arguments: ["untracked.cfg", "ignored.cfg", "ABDiff.xcodeproj/project.pbxproj"])
    func allowedUntrackedIgnoredAndGeneratedGraphFilesRetainContentEvidence(_ path: String) async throws {
        let fixture = try await SourceSnapshotFixture()
        defer { fixture.remove() }
        try fixture.write(path, "before\n")
        let before = try await fixture.snapshot(allowing: [path])
        try fixture.write(path, "after\n")
        let after = try await fixture.snapshot(allowing: [path])
        #expect(before.raw != after.raw)
        #expect(before.comparison == after.comparison)
        #expect(before.allowedFileHashes[path] != after.allowedFileHashes[path])
    }

    @Test func literalMetacharactersCannotExcludeOtherFiles() async throws {
        let fixture = try await SourceSnapshotFixture()
        defer { fixture.remove() }
        let literal = ":(glob)* [x] $(touch sentinel).cfg"
        try fixture.write(literal, "before\n")
        try fixture.write("unrelated.cfg", "before\n")
        try await fixture.git(["add", "--all"])
        try await fixture.git(["commit", "-m", "literal paths"])
        let before = try await fixture.snapshot(allowing: [literal])
        try fixture.write(literal, "after\n")
        let allowed = try await fixture.snapshot(allowing: [literal])
        #expect(before.comparison == allowed.comparison)
        try fixture.write("unrelated.cfg", "after\n")
        let outside = try await fixture.snapshot(allowing: [literal])
        #expect(before.comparison != outside.comparison)
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "/sentinel"))
    }

    @Test func stagingAnAllowedFileIsStillUnexpected() async throws {
        let fixture = try await SourceSnapshotFixture()
        defer { fixture.remove() }
        let before = try await fixture.snapshot(allowing: ["BuildNumber.xcconfig"])
        try fixture.write("BuildNumber.xcconfig", "CURRENT_PROJECT_VERSION = 114\n")
        try await fixture.git(["add", "BuildNumber.xcconfig"])
        let after = try await fixture.snapshot(allowing: ["BuildNumber.xcconfig"])
        #expect(before.comparison["index"] != after.comparison["index"])
        #expect(before.comparison != after.comparison)
    }

    @Test func commitAndModeChangesAreNotCoveredByContentAllowance() async throws {
        let fixture = try await SourceSnapshotFixture()
        defer { fixture.remove() }
        let before = try await fixture.snapshot(allowing: ["BuildNumber.xcconfig"])
        try await fixture.git(["commit", "--allow-empty", "-m", "new HEAD"])
        let committed = try await fixture.snapshot(allowing: ["BuildNumber.xcconfig"])
        #expect(before.comparison["head"] != committed.comparison["head"])
        #expect(chmod(fixture.path + "/BuildNumber.xcconfig", 0o755) == 0)
        let modeChanged = try await fixture.snapshot(allowing: ["BuildNumber.xcconfig"])
        #expect(committed.comparison != modeChanged.comparison)
        #expect(committed.raw != modeChanged.raw)
    }

    @Test(arguments: ["", "/absolute", "../outside", "a/../b", "./file", "a//b", "file/", "a/./b", ".git/config", "a/.git/config", ".GIT/config", "a/.GiT/config", "line\nname", "nul\0name", "delete\u{7f}name"])
    func malformedPathsAreRejectedBeforeFilesystemAccess(_ path: String) {
        #expect(throws: (any Error).self) { try ABDiffSourceSnapshot.validatedAllowedPaths([path]) }
    }

    @Test(arguments: [".gitignore", ".gitattributes", ".gitmodules", ".GITIGNORE", ".GitAttributes", ".GiTmOdUlEs"], ["", "nested/"])
    func gitObservationPolicyCannotBeExemptedInRequestsOrSnapshots(name: String, prefix: String) async throws {
        let fixture = try await SourceSnapshotFixture()
        defer { fixture.remove() }
        let path = prefix + name
        try fixture.write(path, "# Existing observation policy\n")
        #expect(throws: ABDiffProjectError.self) {
            try ABDiffProjectRequest(repository: fixture.path, allowedSourceChanges: [path])
        }
        await #expect(throws: ABDiffProjectError.self) {
            try await fixture.snapshot(allowing: [path])
        }
    }

    @Test func duplicateLiteralPathsAreDeduplicatedAndSorted() throws {
        #expect(try ABDiffSourceSnapshot.validatedAllowedPaths(["z file", "a[1]", "z file"]) == ["a[1]", "z file"])
    }

    @Test(arguments: ["missing", "directory", "symlink", "ancestor-symlink", "fifo"])
    func allowanceRequiresAnExistingRegularFileWithoutSymlinks(_ kind: String) async throws {
        let fixture = try await SourceSnapshotFixture()
        defer { fixture.remove() }
        let path: String
        switch kind {
        case "missing": path = "missing.cfg"
        case "directory":
            path = "directory"
            try FileManager.default.createDirectory(atPath: fixture.path + "/" + path, withIntermediateDirectories: true)
        case "symlink":
            path = "symlink.cfg"
            try FileManager.default.createSymbolicLink(atPath: fixture.path + "/" + path, withDestinationPath: "BuildNumber.xcconfig")
        case "ancestor-symlink":
            try fixture.write("real/file.cfg", "value\n")
            try FileManager.default.createSymbolicLink(atPath: fixture.path + "/alias", withDestinationPath: "real")
            path = "alias/file.cfg"
        default:
            path = "fifo"
            try #require(mkfifo(fixture.path + "/" + path, 0o600) == 0)
        }
        await #expect(throws: (any Error).self) { try await fixture.snapshot(allowing: [path]) }
    }

    @Test(arguments: ["remove", "symlink"])
    func replacingAllowedFileWithMissingOrSymlinkFailsClosingObservation(_ replacement: String) async throws {
        let fixture = try await SourceSnapshotFixture()
        defer { fixture.remove() }
        _ = try await fixture.snapshot(allowing: ["BuildNumber.xcconfig"])
        let path = fixture.path + "/BuildNumber.xcconfig"
        try FileManager.default.removeItem(atPath: path)
        if replacement == "symlink" {
            try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: "Main.swift")
        }
        await #expect(throws: (any Error).self) { try await fixture.snapshot(allowing: ["BuildNumber.xcconfig"]) }
    }
}

private struct SourceSnapshotFixture {
    let path: String
    let environment: [String: String]

    init() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("abdiff-source-snapshot-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.resolvingSymlinksInPath().path
        environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
        do {
            try write("BuildNumber.xcconfig", "CURRENT_PROJECT_VERSION = 112\n")
            try write("Main.swift", "let value = 1\n")
            try write(".gitignore", "ignored.cfg\nABDiff.xcodeproj/\n")
            try await git(["init", "-q"])
            try await git(["config", "user.name", "Source Snapshot Tests"])
            try await git(["config", "user.email", "source-snapshot@example.invalid"])
            try await git(["add", "--all"])
            try await git(["commit", "-q", "-m", "initial"])
        } catch {
            remove()
            throw error
        }
    }

    func snapshot(allowing paths: [String] = []) async throws -> ABDiffSourceSnapshot {
        try await ABDiffSourceSnapshot.capture(repository: path, allowedPaths: paths, environment: environment)
    }

    func git(_ arguments: [String]) async throws {
        _ = try await RepositoryCommandCapture().capture(arguments: ["/usr/bin/git"] + arguments,
            workingDirectory: path, environment: environment)
    }

    func write(_ relativePath: String, _ contents: String, atomically: Bool = false) throws {
        let file = URL(fileURLWithPath: path).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file, options: atomically ? .atomic : [])
    }

    func remove() { try? FileManager.default.removeItem(atPath: path) }
}
