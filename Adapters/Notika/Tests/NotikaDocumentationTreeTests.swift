@testable import AgentBuildCore
import Darwin
import Foundation
@testable import NotikaAdapter
import Testing

@Suite("Notika documentation tree custody")
struct NotikaDocumentationTreeTests {
    @Test(arguments: [0, 1, 37, 131_071, 131_072, 131_073, 262_161])
    func adaptiveStreamingAndCopiesMatchIndependentBinaryOracle(_ count: Int) throws {
        let fixture = try DocumentationTreeFixture()
        defer { fixture.cleanUp() }
        try fixture.makeDirectory("source")
        try fixture.makeDirectory("snapshot")
        let bytes = Data((0..<count).map { UInt8($0 % 251) })
        try fixture.write("source/blob.bin", bytes: bytes)
        let source = try NotikaDocumentationTree(path: fixture.child("source"))
        let snapshot = try NotikaDocumentationTree(path: fixture.child("snapshot"), privateRoot: true)
        let expected = NotikaDocumentationTreeCommitment(algorithm: "notika.docc-owned-tree.sha256.v1",
            sha256: try #require(documentationStreamingOracle[count]), entries: 1, bytes: Int64(count),
            maximumEntries: 250_000, maximumBytes: 2_147_483_648, maximumDepth: 64)

        #expect(try source.commitment() == expected)
        #expect(try source.copy(into: snapshot, expected: expected) == expected)
        #expect(try snapshot.commitment() == expected)
        #expect(try fixture.read("snapshot/blob.bin") == bytes)
    }

    @Test func canonicalTreeCommitmentMatchesIndependentPythonFixture() throws {
        let fixture = try DocumentationTreeFixture()
        defer { fixture.cleanUp() }
        try fixture.makeSmallTree("source")

        let tree = try NotikaDocumentationTree(path: fixture.child("source"))
        #expect(try tree.commitment() == smallDocumentationTreeCommitment)
    }

    @Test func copyingPreservesCommittedBytesAndMakesDestinationPrivate() throws {
        let fixture = try DocumentationTreeFixture()
        defer { fixture.cleanUp() }
        try fixture.makeSmallTree("source")
        try fixture.makeDirectory("snapshot")
        let source = try NotikaDocumentationTree(path: fixture.child("source"))
        let snapshot = try NotikaDocumentationTree(path: fixture.child("snapshot"), privateRoot: true)

        let copied = try source.copy(into: snapshot, expected: smallDocumentationTreeCommitment)
        #expect(copied == smallDocumentationTreeCommitment)
        #expect(try snapshot.commitment() == smallDocumentationTreeCommitment)
        #expect(try fixture.read("snapshot/index.html") == Data("Hello, DocC!\n".utf8))
        #expect(try fixture.read("snapshot/assets/icon.txt") == Data("Café 🧭\n".utf8))
        for name in ["snapshot", "snapshot/assets", "snapshot/empty"] {
            #expect(try fixture.permissions(name) == 0o700)
        }
        for name in ["snapshot/index.html", "snapshot/assets/icon.txt"] {
            #expect(try fixture.permissions(name) == 0o600)
        }
        #expect(try fixture.permissions("source/assets") == 0o755)
        #expect(try fixture.permissions("source/index.html") == 0o644)
    }

    @Test func rendererOverlayReplacesRegularFilesAndPreservesTransformOnlyFiles() throws {
        let fixture = try DocumentationTreeFixture()
        defer { fixture.cleanUp() }
        try fixture.makeDirectory("renderer")
        try fixture.makeDirectory("renderer/assets", permissions: 0o755)
        try fixture.write("renderer/index.html", bytes: Data("renderer page\n".utf8))
        try fixture.write("renderer/assets/app.js", bytes: Data("renderer script\n".utf8))
        try fixture.makeDirectory("site")
        try fixture.makeDirectory("site/assets", permissions: 0o755)
        try fixture.makeDirectory("site/data", permissions: 0o755)
        try fixture.write("site/index.html", bytes: Data("transform page\n".utf8))
        try fixture.write("site/assets/app.js", bytes: Data("transform script\n".utf8))
        let generated = Data(#"{"generated":true}"#.utf8)
        let topic = Data(#"{"title":"Notika"}"#.utf8)
        try fixture.write("site/assets/generated.json", bytes: generated)
        try fixture.write("site/data/topic.json", bytes: topic)
        let renderer = try NotikaDocumentationTree(path: fixture.child("renderer"))
        let site = try NotikaDocumentationTree(path: fixture.child("site"), privateRoot: true)
        let originalRenderer = try renderer.commitment()
        let originalSite = try site.commitment()

        try renderer.merge(into: site)

        #expect(try fixture.read("site/index.html") == Data("renderer page\n".utf8))
        #expect(try fixture.read("site/assets/app.js") == Data("renderer script\n".utf8))
        #expect(try fixture.read("site/assets/generated.json") == generated)
        #expect(try fixture.read("site/data/topic.json") == topic)
        #expect(try renderer.commitment() == originalRenderer)
        #expect(try site.commitment().sha256 != originalSite.sha256)
        for name in ["site", "site/assets", "site/data"] {
            #expect(try fixture.permissions(name) == 0o700)
        }
        for name in ["site/index.html", "site/assets/app.js", "site/assets/generated.json", "site/data/topic.json"] {
            #expect(try fixture.permissions(name) == 0o600)
        }
    }

    @Test(arguments: DocumentationUnsafeTreeEntry.allCases)
    func unsafeEntriesAreRejectedBeforeStreaming(_ entry: DocumentationUnsafeTreeEntry) throws {
        let fixture = try DocumentationTreeFixture()
        defer { fixture.cleanUp() }
        try fixture.makeDirectory("source")
        try fixture.write("source/original", bytes: Data("owned bytes".utf8))
        switch entry {
        case .symbolicLink:
            try fixture.write("outside", bytes: Data("outside bytes".utf8))
            try #require(Darwin.symlink("../outside", fixture.child("source/unsafe")) == 0)
        case .hardLink:
            try #require(Darwin.link(fixture.child("source/original"), fixture.child("source/unsafe")) == 0)
        case .fifo:
            try #require(Darwin.mkfifo(fixture.child("source/unsafe"), 0o600) == 0)
        }
        let tree = try NotikaDocumentationTree(path: fixture.child("source"))

        #expect(throws: NotikaDocumentationDriverError.unsafeArtifact) { try tree.commitment() }
        #expect(throws: NotikaDocumentationDriverError.unsafeArtifact) {
            try tree.openFile(components: ["unsafe"])
        }
    }

    @Test func oversizedSparseFileIsRejectedBeforeReadingItsBytes() throws {
        let fixture = try DocumentationTreeFixture()
        defer { fixture.cleanUp() }
        try fixture.makeDirectory("source")
        // ftruncate creates a sparse fixture; the test does not allocate or write 2 GiB.
        try fixture.makeSparseFile("source/large", bytes: NotikaDocumentationTree.maximumBytes + 1)
        let tree = try NotikaDocumentationTree(path: fixture.child("source"))

        #expect(throws: NotikaDocumentationDriverError.treeBoundExceeded) { try tree.commitment() }
        #expect(throws: NotikaDocumentationDriverError.treeBoundExceeded) {
            try tree.openFile(components: ["large"])
        }
    }

    @Test func replacingRootPathInvalidatesTreeAndRetainedOpenedFile() throws {
        let fixture = try DocumentationTreeFixture()
        defer { fixture.cleanUp() }
        try fixture.makeDirectory("source")
        try fixture.write("source/index.html", bytes: Data("same bytes".utf8))
        let tree = try NotikaDocumentationTree(path: fixture.child("source"))
        let opened = try tree.openFile(components: ["index.html"])
        try tree.revalidate()
        try opened.revalidate()

        try FileManager.default.moveItem(atPath: fixture.child("source"), toPath: fixture.child("retired"))
        try fixture.makeDirectory("source")
        try fixture.write("source/index.html", bytes: Data("same bytes".utf8))

        #expect(throws: RetainedArtifactError.directoryChanged) { try tree.revalidate() }
        #expect(throws: RetainedArtifactError.directoryChanged) { try opened.revalidate() }
    }

    @Test func retainedOpenedFileRejectsSameInodeByteMutation() throws {
        let fixture = try DocumentationTreeFixture()
        defer { fixture.cleanUp() }
        try fixture.makeDirectory("source")
        try fixture.makeDirectory("source/assets", permissions: 0o755)
        try fixture.write("source/assets/app.js", bytes: Data("before".utf8))
        let tree = try NotikaDocumentationTree(path: fixture.child("source"))
        let opened = try tree.openFile(components: ["assets", "app.js"])
        let original = try fixture.status("source/assets/app.js")
        try opened.revalidate()

        try fixture.overwriteSameSizedFile("source/assets/app.js", bytes: Data("after!".utf8))

        let changed = try fixture.status("source/assets/app.js")
        #expect(changed.st_dev == original.st_dev && changed.st_ino == original.st_ino)
        #expect(changed.st_size == original.st_size)
        #expect(try fixture.read("source/assets/app.js") == Data("after!".utf8))
        #expect(throws: NotikaDocumentationDriverError.artifactChanged) { try opened.revalidate() }
    }

    @Test func previewSealRejectsContentMutationBetweenRequests() throws {
        let fixture = try DocumentationTreeFixture()
        defer { fixture.cleanUp() }
        try fixture.makeDirectory("site")
        try fixture.write("site/index.html", bytes: Data("before".utf8))
        let site = try NotikaDocumentationTree(path: fixture.child("site"), privateRoot: true)
        _ = try site.commitment(retainingEntries: true)
        try site.openFile(components: ["index.html"]).revalidate()
        try fixture.overwriteSameSizedFile("site/index.html", bytes: Data("after!".utf8))
        #expect(throws: NotikaDocumentationDriverError.artifactChanged) { try site.openFile(components: ["index.html"]) }
    }

    @Test func changedSourceCommitmentRejectsCopyBeforeDestinationPublication() throws {
        let fixture = try DocumentationTreeFixture()
        defer { fixture.cleanUp() }
        try fixture.makeSmallTree("source")
        try fixture.makeDirectory("snapshot")
        let source = try NotikaDocumentationTree(path: fixture.child("source"))
        let snapshot = try NotikaDocumentationTree(path: fixture.child("snapshot"), privateRoot: true)
        #expect(try source.commitment() == smallDocumentationTreeCommitment)
        try fixture.overwriteSameSizedFile("source/index.html", bytes: Data("Other, DocC!\n".utf8))

        #expect(throws: NotikaDocumentationDriverError.artifactChanged) {
            try source.copy(into: snapshot, expected: smallDocumentationTreeCommitment)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.child("snapshot")).isEmpty)
    }

    @Test func growingSmallFileInvalidatesRetainedFileAndPreviouslyAdmittedCopy() throws {
        let fixture = try DocumentationTreeFixture()
        defer { fixture.cleanUp() }
        try fixture.makeDirectory("source")
        try fixture.makeDirectory("snapshot")
        try fixture.write("source/blob.bin", bytes: Data([1]))
        let source = try NotikaDocumentationTree(path: fixture.child("source"))
        let snapshot = try NotikaDocumentationTree(path: fixture.child("snapshot"), privateRoot: true)
        let admitted = try source.commitment()
        let opened = try source.openFile(components: ["blob.bin"])
        let before = try fixture.status("source/blob.bin")
        let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: fixture.child("source/blob.bin")))
        defer { try? writer.close() }
        try writer.seekToEnd()
        try writer.write(contentsOf: Data(repeating: 2, count: 131_073))
        let after = try fixture.status("source/blob.bin")
        #expect(after.st_dev == before.st_dev && after.st_ino == before.st_ino)
        #expect(after.st_size == 131_074)

        #expect(throws: NotikaDocumentationDriverError.artifactChanged) { try opened.revalidate() }
        #expect(throws: NotikaDocumentationDriverError.artifactChanged) { try source.copy(into: snapshot, expected: admitted) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.child("snapshot")).isEmpty)
    }
}

enum DocumentationUnsafeTreeEntry: CaseIterable, Sendable {
    case symbolicLink, hardLink, fifo
}

// Python independently hashed the canonical JSON record list using
// json.dumps(records, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
// without a final LF. Four entries contain 11 + 13 bytes. The record sequence is
// assets/, assets/icon.txt, empty/, index.html, independent of creation order.
private let smallDocumentationTreeCommitment = NotikaDocumentationTreeCommitment(
    algorithm: "notika.docc-owned-tree.sha256.v1",
    sha256: "90c3ecb4d603771a78d84f95c0375c250fcca9cce22c4e472289c26ccf58f2b5",
    entries: 4, bytes: 24, maximumEntries: 250_000, maximumBytes: 2_147_483_648, maximumDepth: 64
)

// Independent Python hashlib + json.dumps oracle for one blob.bin record.
// Byte i is i % 251; JSON uses sorted keys and compact separators with no LF.
private let documentationStreamingOracle: [Int: String] = [
    0: "048b75739760c20a03d66bc6e3a577771c646914182804b7f47e72067c892834",
    1: "74f6bf7f76e5fc251df532957d35ef40a3a3e1548fee338b1c1fdc020d7e6279",
    37: "939874e730af61bce47041b76e837082d88c6defcd33b22cf464427b562fb947",
    131_071: "7b12338b04604f4ba1cf6d57f064c29f248c4c54c23aaddbf6acc610c40901df",
    131_072: "a3eb56e22fa40c096e89c220a7a94937639cfe0d2a9f22fd4177c37e40be4e4a",
    131_073: "6705c09db42b99255a1705bd03ee34612109c65bdc9a4306317f77f0ed9bdfac",
    262_161: "bc631e5fd4e79dfd8a2ce17f2a0fc4f3d9d2aeede388545ae4af6e302af223f9",
]

private enum DocumentationTreeFixtureError: Error {
    case systemCall(String, Int32)
}

private struct DocumentationTreeFixture {
    let path: String

    init() throws {
        let requested = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentbuild-docc-tree-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: requested, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        guard Darwin.chmod(requested, 0o700) == 0 else {
            throw DocumentationTreeFixtureError.systemCall("make fixture private", errno)
        }
        guard let resolved = Darwin.realpath(requested, nil) else {
            throw DocumentationTreeFixtureError.systemCall("resolve fixture path", errno)
        }
        defer { Darwin.free(resolved) }
        path = String(cString: resolved)
    }

    func child(_ name: String) -> String { path + "/" + name }

    func makeDirectory(_ name: String, permissions: mode_t = 0o700) throws {
        try FileManager.default.createDirectory(atPath: child(name), withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: permissions])
        guard Darwin.chmod(child(name), permissions) == 0 else {
            throw DocumentationTreeFixtureError.systemCall("set fixture directory permissions", errno)
        }
    }

    func makeSmallTree(_ name: String) throws {
        try makeDirectory(name)
        // Deliberately create entries in a different order from the commitment.
        try write(name + "/index.html", bytes: Data("Hello, DocC!\n".utf8))
        try makeDirectory(name + "/empty", permissions: 0o755)
        try makeDirectory(name + "/assets", permissions: 0o755)
        try write(name + "/assets/icon.txt", bytes: Data("Café 🧭\n".utf8))
    }

    func write(_ name: String, bytes: Data) throws {
        let descriptor = Darwin.open(child(name), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o644)
        guard descriptor >= 0 else { throw DocumentationTreeFixtureError.systemCall("create fixture file", errno) }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, 0o644) == 0 else {
            throw DocumentationTreeFixtureError.systemCall("set fixture file permissions", errno)
        }
        try writeAll(bytes, descriptor: descriptor)
    }

    func makeSparseFile(_ name: String, bytes: Int64) throws {
        let descriptor = Darwin.open(child(name), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o644)
        guard descriptor >= 0 else { throw DocumentationTreeFixtureError.systemCall("create sparse fixture", errno) }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, 0o644) == 0, Darwin.ftruncate(descriptor, off_t(bytes)) == 0 else {
            throw DocumentationTreeFixtureError.systemCall("size sparse fixture", errno)
        }
    }

    func overwriteSameSizedFile(_ name: String, bytes: Data) throws {
        let original = try status(name)
        try #require(original.st_size == Int64(bytes.count))
        let descriptor = Darwin.open(child(name), O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw DocumentationTreeFixtureError.systemCall("open mutable fixture", errno) }
        defer { _ = Darwin.close(descriptor) }
        try writeAll(bytes, descriptor: descriptor)
        // Make fingerprint drift deterministic even on coarse timestamp filesystems.
        let times = [original.st_atimespec, timespec(tv_sec: original.st_mtimespec.tv_sec + 1,
                                                   tv_nsec: original.st_mtimespec.tv_nsec)]
        let result = times.withUnsafeBufferPointer { Darwin.futimens(descriptor, $0.baseAddress) }
        guard result == 0 else { throw DocumentationTreeFixtureError.systemCall("mark fixture byte mutation", errno) }
    }

    func read(_ name: String) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: child(name))) }

    func status(_ name: String) throws -> stat {
        var metadata = stat()
        guard Darwin.lstat(child(name), &metadata) == 0 else {
            throw DocumentationTreeFixtureError.systemCall("stat fixture", errno)
        }
        return metadata
    }

    func permissions(_ name: String) throws -> mode_t { try status(name).st_mode & 0o7777 }

    func cleanUp() { try? FileManager.default.removeItem(atPath: path) }

    private func writeAll(_ bytes: Data, descriptor: Int32) throws {
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw DocumentationTreeFixtureError.systemCall("write fixture bytes", errno) }
                offset += count
            }
        }
    }
}
