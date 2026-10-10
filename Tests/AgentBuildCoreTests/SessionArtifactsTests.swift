@testable import AgentBuildCore
import Darwin
import Foundation
import Testing

@Test func artifactsCreatePrivateFilesAndPublishReplaceableManifests() throws {
    let fixture = try ArtifactFixture()
    defer { fixture.remove() }
    let artifacts = try SessionArtifacts(root: fixture.root.path, runID: UUID().uuidString)
    #expect(try permissions(artifacts.directoryPath) == 0o700)
    for path in [artifacts.standardOutputPath, artifacts.standardErrorPath] {
        #expect(try permissions(path) == 0o600)
    }
    for descriptor in [artifacts.stdoutDescriptor, artifacts.stderrDescriptor] {
        #expect(Darwin.fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
    }

    var report = artifactReport(artifacts)
    try artifacts.publish(report)
    let manifest = URL(fileURLWithPath: artifacts.directoryPath).appendingPathComponent("manifest.json")
    #expect(try permissions(manifest.path) == 0o600)
    #expect(try JSONDecoder().decode(ManagedExecutionReport.self, from: Data(contentsOf: manifest)) == report)
    report.state = .completed
    try artifacts.publish(report)
    #expect(try JSONDecoder().decode(ManagedExecutionReport.self, from: Data(contentsOf: manifest)) == report)
    #expect(try FileManager.default.contentsOfDirectory(atPath: artifacts.directoryPath).sorted()
        == ["manifest.json", "stderr.log", "stdout.log"])
}

@Test func binaryLogsKeepEveryByteAndBorrowedDescriptorsRemainOwned() throws {
    let fixture = try ArtifactFixture()
    defer { fixture.remove() }
    var artifacts: SessionArtifacts? = try SessionArtifacts(root: fixture.root.path, runID: UUID().uuidString)
    let outputPath = try #require(artifacts?.standardOutputPath)
    let errorPath = try #require(artifacts?.standardErrorPath)
    let outputDescriptor = try #require(artifacts?.stdoutDescriptor)
    let errorDescriptor = try #require(artifacts?.stderrDescriptor)
    let outputIdentity = try descriptorIdentity(outputDescriptor)
    let errorIdentity = try descriptorIdentity(errorDescriptor)
    let duplicateDescriptor = Darwin.dup(outputDescriptor)
    #expect(duplicateDescriptor >= 0)
    defer { Darwin.close(duplicateDescriptor) }

    let output = Data([0x00, 0xFF, 0x80, 0x0A, 0x41])
    let error = Data([0xFE, 0x00, 0x42])
    try writeArtifactBytes(output, to: outputDescriptor)
    try writeArtifactBytes(error, to: errorDescriptor)
    try artifacts?.synchronizeLogs()
    let sizes = try #require(try artifacts?.logSizes())
    #expect(sizes.standardOutput == output.count)
    #expect(sizes.standardError == error.count)
    #expect(try Data(contentsOf: URL(fileURLWithPath: outputPath)) == output)
    #expect(try Data(contentsOf: URL(fileURLWithPath: errorPath)) == error)
    #expect(Darwin.fcntl(outputDescriptor, F_GETFD) >= 0)
    #expect(Darwin.fcntl(errorDescriptor, F_GETFD) >= 0)

    artifacts = nil
    expectDescriptorReleased(outputDescriptor, identity: outputIdentity)
    expectDescriptorReleased(errorDescriptor, identity: errorIdentity)
    try writeArtifactBytes(Data([0x43]), to: duplicateDescriptor)
    #expect(try Data(contentsOf: URL(fileURLWithPath: outputPath)) == output + Data([0x43]))
}

@Test func artifactRootsAndExistingSessionsCannotFollowSymlinks() throws {
    let fixture = try ArtifactFixture()
    defer { fixture.remove() }
    let target = fixture.directory.appendingPathComponent("target")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: fixture.root, withDestinationURL: target)
    #expect(throws: (any Error).self) {
        _ = try SessionArtifacts(root: fixture.root.path, runID: UUID().uuidString)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)

    try FileManager.default.removeItem(at: fixture.root)
    try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
    let runID = UUID().uuidString
    try FileManager.default.createSymbolicLink(
        at: fixture.root.appendingPathComponent(runID), withDestinationURL: target
    )
    #expect(throws: (any Error).self) {
        _ = try SessionArtifacts(root: fixture.root.path, runID: runID)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
}

@Test func artifactRootsRejectWritablePermissionsAndRelativeSessionNames() throws {
    let fixture = try ArtifactFixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: fixture.root.path)
    #expect(throws: (any Error).self) {
        _ = try SessionArtifacts(root: fixture.root.path, runID: UUID().uuidString)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
    #expect(throws: (any Error).self) {
        _ = try SessionArtifacts(root: fixture.root.path, runID: "../escaped")
    }
}

@Test func manifestPublicationFailureLeavesLogsAndNoTemporaryManifest() throws {
    let fixture = try ArtifactFixture()
    defer { fixture.remove() }
    let artifacts = try SessionArtifacts(root: fixture.root.path, runID: UUID().uuidString)
    let manifest = URL(fileURLWithPath: artifacts.directoryPath).appendingPathComponent("manifest.json")
    try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
    do {
        try artifacts.publish(artifactReport(artifacts))
        Issue.record("Publishing over a directory must fail")
    } catch ManagedExecutionError.artifactIO(let operation, let code) {
        #expect(operation == "publish session manifest")
        #expect(code == EISDIR)
    }
    try writeArtifactBytes(Data([0xFF]), to: artifacts.stdoutDescriptor)
    #expect(try artifacts.logSizes().standardOutput == 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: artifacts.directoryPath).sorted()
        == ["manifest.json", "stderr.log", "stdout.log"])
}

@Test func publicationReplacesManifestSymlinksWithoutWritingTheirTarget() throws {
    let fixture = try ArtifactFixture()
    defer { fixture.remove() }
    let artifacts = try SessionArtifacts(root: fixture.root.path, runID: UUID().uuidString)
    let target = fixture.directory.appendingPathComponent("unrelated.json")
    let sentinel = Data("unrelated evidence".utf8)
    try sentinel.write(to: target)
    let manifest = URL(fileURLWithPath: artifacts.directoryPath).appendingPathComponent("manifest.json")
    try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: target)
    let report = artifactReport(artifacts)
    try artifacts.publish(report)
    #expect(try Data(contentsOf: target) == sentinel)
    #expect(try JSONDecoder().decode(ManagedExecutionReport.self, from: Data(contentsOf: manifest)) == report)
}

private struct ArtifactFixture {
    let directory: URL
    let root: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = directory.appendingPathComponent("artifacts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func artifactReport(_ artifacts: SessionArtifacts) -> ManagedExecutionReport {
    ManagedExecutionReport(
        schemaVersion: 1, toolVersion: AgentBuild.version,
        runID: URL(fileURLWithPath: artifacts.directoryPath).lastPathComponent,
        state: .running, executable: "/bin/sh", argumentCommitment: "fixture",
        workingDirectory: "/private/tmp", resources: [], label: "artifact fixture",
        coordinatorPID: getpid(), childPID: nil, startedAt: "2026-10-10T00:00:00Z",
        finishedAt: nil, receivedSignal: nil, termination: nil, failure: nil, metadataFailures: [],
        standardOutputPath: artifacts.standardOutputPath,
        standardErrorPath: artifacts.standardErrorPath,
        standardOutputBytes: 0, standardErrorBytes: 0
    )
}

private func permissions(_ path: String) throws -> Int {
    try #require(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber).intValue
}

private func writeArtifactBytes(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { buffer in
        let count = Darwin.write(descriptor, buffer.baseAddress, buffer.count)
        #expect(count == buffer.count)
        try #require(count >= 0)
    }
}

private func descriptorIdentity(_ descriptor: Int32) throws -> (device: dev_t, inode: ino_t) {
    var attributes = stat()
    try #require(Darwin.fstat(descriptor, &attributes) == 0)
    return (attributes.st_dev, attributes.st_ino)
}

private func expectDescriptorReleased(_ descriptor: Int32, identity: (device: dev_t, inode: ino_t)) {
    var attributes = stat()
    let status = Darwin.fstat(descriptor, &attributes)
    // Other parallel tests can reuse a closed descriptor number immediately.
    #expect(status == -1 || attributes.st_dev != identity.device || attributes.st_ino != identity.inode)
    if status == -1 { #expect(errno == EBADF) }
}
