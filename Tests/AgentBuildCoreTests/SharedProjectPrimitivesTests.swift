@testable import AgentBuildCore
import Darwin
import Foundation
import Testing

struct SharedProjectPrimitivesTests {
    @Test func dottedSessionDirectoriesRequireAnExactCallerPolicy() throws {
        let repository = try temporaryRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let session = try ControllerSessionArtifacts(repository: repository.path, runID: UUID().uuidString)
        let name = "Reference.doccarchive"
        #expect(throws: ControllerSessionArtifactError.invalidArgument) {
            try session.createPrivateDirectory(named: name)
        }
        let archive = try session.createPrivateDirectory(named: name, additionalAllowedNames: [name])
        try archive.revalidate()
        #expect(archive.path == session.path + "/" + name)
        for unsafe in ["../outside", "nested/child", ".hidden", "truncated\0name"] {
            #expect(throws: ControllerSessionArtifactError.invalidArgument) {
                try session.createPrivateDirectory(named: unsafe, additionalAllowedNames: [unsafe])
            }
        }
    }

    @Test func sharedSessionsRetainPublicationAndBorrowedDirectoryIdentity() throws {
        let repository = try temporaryRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let session = try ControllerSessionArtifacts(repository: repository.path, runID: UUID().uuidString)
        let borrowed = try ControllerSessionArtifacts(borrowingSessionPath: session.path, repository: repository.path)
        let manifest = Data("{\"status\":\"fixture\"}".utf8)
        try session.publish(sealedData: manifest, name: "manifest.json", validating: {})
        try borrowed.revalidate()
        #expect(try Data(contentsOf: URL(fileURLWithPath: borrowed.path).appendingPathComponent("manifest.json")) == manifest)
        try #require(chmod(session.path + "/manifest.json", 0o600) == 0)
        #expect(throws: (any Error).self) { try session.revalidate() }
    }

    @Test func sharedSourceSnapshotsObserveOnlyExplicitIgnoredProjectInputs() async throws {
        let repository = try temporaryRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
        try Data("ABDiff.xcodeproj/\n".utf8).write(to: repository.appendingPathComponent(".gitignore"))
        let capture = try RepositoryCommandCapture()
        for arguments in [["init", "-q"], ["config", "user.name", "Shared Snapshot Tests"],
                          ["config", "user.email", "snapshot@example.invalid"], ["add", ".gitignore"],
                          ["commit", "-q", "-m", "fixture"]] {
            _ = try await capture.capture(arguments: ["/usr/bin/git"] + arguments,
                workingDirectory: repository.path, environment: environment)
        }
        let input = "ABDiff.xcodeproj/project.pbxproj"
        let graph = repository.appendingPathComponent(input)
        try FileManager.default.createDirectory(at: graph.deletingLastPathComponent(), withIntermediateDirectories: false)
        try Data("before".utf8).write(to: graph)
        let genericBefore = try await RepositorySourceSnapshot.capture(repository: repository.path,
            allowedPaths: [], environment: environment)
        let explicitBefore = try await RepositorySourceSnapshot.capture(repository: repository.path,
            allowedPaths: [], environment: environment, projectFiles: [input])
        try Data("after".utf8).write(to: graph)
        let genericAfter = try await RepositorySourceSnapshot.capture(repository: repository.path,
            allowedPaths: [], environment: environment)
        let explicitAfter = try await RepositorySourceSnapshot.capture(repository: repository.path,
            allowedPaths: [], environment: environment, projectFiles: [input])
        #expect(genericBefore.comparison == genericAfter.comparison)
        #expect(explicitBefore.comparison != explicitAfter.comparison)
        #expect(genericBefore.raw[input] == nil)
        #expect(explicitBefore.raw[input] != explicitAfter.raw[input])
    }

    private func temporaryRepository() throws -> URL {
        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentbuild-shared-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        // Retained descriptors require the physical /private spelling, not /var.
        guard let physical = realpath(repository.path, nil) else { throw POSIXError(.EIO) }
        defer { free(physical) }
        return URL(fileURLWithPath: String(cString: physical), isDirectory: true)
    }
}
