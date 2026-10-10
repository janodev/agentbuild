import AgentBuildCore
import Darwin
import Foundation
import Testing

@Suite("Retained artifact file custody")
struct RetainedArtifactFileTests {
    @Test func readsExactBytesRepeatedlyAndSeparatelyAdmitsJSON() throws {
        let fixture = try ArtifactDiskFixture()
        defer { fixture.cleanUp() }
        let bytes = Data(#"{"cache":"stable","count":3}"#.utf8)
        try fixture.write("usage.json", bytes: bytes)
        let directory = try RetainedArtifactDirectory(path: fixture.path, requiredPermissions: 0o700)
        defer { try? directory.close() }
        let file = try directory.openFile(named: "usage.json")
        defer { try? file.close() }
        #expect(try file.readBounded() == bytes)
        #expect(try file.readBounded() == bytes)
        let json = try file.readJSON()
        #expect(json.originalData == bytes)
        #expect(json.digest == CanonicalJSONDigest.digest(bytes))
        #expect(file.fingerprint.owner == UInt32(geteuid()))
        #expect(file.fingerprint.mode & 0o7777 == 0o600)
        #expect(file.fingerprint.linkCount == 1)
        #expect(file.fingerprint.size == bytes.count)
        try file.revalidate()
        try file.revalidateBeforeMutation()
    }

    @Test func boundedReadAcceptsEmptyFilesAndExactByteLimit() throws {
        let fixture = try ArtifactDiskFixture()
        defer { fixture.cleanUp() }
        try fixture.write("empty", bytes: Data())
        try fixture.write("exact", bytes: Data([0x00, 0x80, 0xFF, 0x0A]))
        let empty = try RetainedArtifactFile(path: fixture.child("empty"))
        defer { try? empty.close() }
        #expect(try empty.readBounded().isEmpty)
        #expect(throws: StrictJSONError.self) { try empty.readJSON() }
        #expect(throws: RetainedArtifactError.unsafeFile) {
            try RetainedArtifactFile(path: fixture.child("empty"), policy: ArtifactFilePolicy(minimumBytes: 1))
        }
        let exact = try RetainedArtifactFile(path: fixture.child("exact"),
                                            policy: ArtifactFilePolicy(maximumBytes: 4))
        defer { try? exact.close() }
        #expect(try exact.readBounded() == Data([0x00, 0x80, 0xFF, 0x0A]))
        #expect(throws: RetainedArtifactError.unsafeFile) {
            try RetainedArtifactFile(path: fixture.child("exact"), policy: ArtifactFilePolicy(maximumBytes: 3))
        }
    }

    @Test func strictJSONRejectionDoesNotDeleteOrReplaceEvidence() throws {
        let fixture = try ArtifactDiskFixture()
        defer { fixture.cleanUp() }
        let bytes = Data(#"{"x":1,"x":2}"#.utf8)
        try fixture.write("duplicate.json", bytes: bytes)
        let file = try RetainedArtifactFile(path: fixture.child("duplicate.json"))
        defer { try? file.close() }
        #expect(throws: StrictJSONError.self) { try file.readJSON() }
        #expect(try file.readBounded() == bytes)
        try file.close()
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.child("duplicate.json"))) == bytes)
    }

    @Test func linksDirectoriesAndFIFOAreRejectedWithoutOpeningAProducer() throws {
        let fixture = try ArtifactDiskFixture()
        defer { fixture.cleanUp() }
        try fixture.write("original", bytes: Data("original".utf8))
        #expect(Darwin.symlink("original", fixture.child("symbolic")) == 0)
        #expect(throws: RetainedArtifactError.unsafeFile) {
            try RetainedArtifactFile(path: fixture.child("symbolic"))
        }
        #expect(Darwin.link(fixture.child("original"), fixture.child("hardlink")) == 0)
        #expect(throws: RetainedArtifactError.unsafeFile) {
            try RetainedArtifactFile(path: fixture.child("original"))
        }
        #expect(Darwin.mkfifo(fixture.child("pipe"), 0o600) == 0)
        #expect(throws: RetainedArtifactError.unsafeFile) {
            try RetainedArtifactFile(path: fixture.child("pipe"))
        }
        try fixture.makeDirectory("directory")
        #expect(throws: RetainedArtifactError.unsafeFile) {
            try RetainedArtifactFile(path: fixture.child("directory"))
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.child("original"))) == Data("original".utf8))
    }

    @Test func aReplacedEntryNeverRedirectsTheRetainedReaderOrCleanup() throws {
        let fixture = try ArtifactDiskFixture()
        defer { fixture.cleanUp() }
        let original = Data("owned".utf8)
        let replacement = Data("foreign replacement".utf8)
        try fixture.write("evidence", bytes: original)
        let file = try RetainedArtifactFile(path: fixture.child("evidence"))
        #expect(Darwin.rename(fixture.child("evidence"), fixture.child("old-inode")) == 0)
        try fixture.write("evidence", bytes: replacement)
        #expect(throws: RetainedArtifactError.self) { try file.readBounded() }
        #expect(throws: RetainedArtifactError.self) { try file.revalidateBeforeMutation() }
        try file.close()
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.child("evidence"))) == replacement)
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.child("old-inode"))) == original)
    }

    @Test func lateSymlinkReplacementIsNotFollowed() throws {
        let fixture = try ArtifactDiskFixture()
        defer { fixture.cleanUp() }
        try fixture.write("evidence", bytes: Data("owned".utf8))
        try fixture.write("target", bytes: Data("target stays unchanged".utf8))
        let file = try RetainedArtifactFile(path: fixture.child("evidence"))
        defer { try? file.close() }
        #expect(Darwin.rename(fixture.child("evidence"), fixture.child("old-inode")) == 0)
        #expect(Darwin.symlink("target", fixture.child("evidence")) == 0)
        #expect(throws: RetainedArtifactError.self) { try file.readBounded() }
        try file.close()
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.child("target"))) == Data("target stays unchanged".utf8))
        var metadata = stat()
        #expect(Darwin.lstat(fixture.child("evidence"), &metadata) == 0)
        #expect(metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK))
    }

    @Test func growthAndTruncationInvalidateTheOriginallyAdmittedSize() throws {
        let fixture = try ArtifactDiskFixture()
        defer { fixture.cleanUp() }
        try fixture.write("grown", bytes: Data("first".utf8))
        try fixture.write("truncated", bytes: Data("first".utf8))
        let grown = try RetainedArtifactFile(path: fixture.child("grown"))
        let truncated = try RetainedArtifactFile(path: fixture.child("truncated"))
        defer {
            try? grown.close()
            try? truncated.close()
        }
        try fixture.write("grown", bytes: Data("first and more".utf8))
        try fixture.write("truncated", bytes: Data())
        #expect(throws: RetainedArtifactError.self) { try grown.readBounded() }
        #expect(throws: RetainedArtifactError.self) { try truncated.readBounded() }
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.child("grown"))) == Data("first and more".utf8))
    }

    @Test func sameSizeRewriteAndNanosecondTimestampChangesFailRevalidation() throws {
        let fixture = try ArtifactDiskFixture()
        defer { fixture.cleanUp() }
        try fixture.write("same-size", bytes: Data("first".utf8))
        try fixture.write("timestamp", bytes: Data("fixed".utf8))
        let rewritten = try RetainedArtifactFile(path: fixture.child("same-size"))
        let timestamp = try RetainedArtifactFile(path: fixture.child("timestamp"))
        defer {
            try? rewritten.close()
            try? timestamp.close()
        }
        try fixture.write("same-size", bytes: Data("other".utf8))
        #expect(throws: RetainedArtifactError.fileChanged) { try rewritten.revalidate() }
        let admitted = timestamp.fingerprint
        let nanos: Int64 = admitted.modificationNanoseconds == 123_456_789 ? 987_654_321 : 123_456_789
        try fixture.setModificationTime("timestamp", seconds: admitted.modificationSeconds, nanoseconds: nanos)
        var observed = stat()
        #expect(Darwin.lstat(fixture.child("timestamp"), &observed) == 0)
        #expect(Int64(observed.st_mtimespec.tv_sec) == admitted.modificationSeconds)
        #expect(Int64(observed.st_mtimespec.tv_nsec) == nanos)
        #expect(throws: RetainedArtifactError.fileChanged) { try timestamp.revalidate() }
    }

    @Test func permissionAndLinkCountPoliciesRemainSealedAfterAdmission() throws {
        let fixture = try ArtifactDiskFixture()
        defer { fixture.cleanUp() }
        try fixture.write("permissions", bytes: Data("mode".utf8))
        try fixture.write("links", bytes: Data("link".utf8))
        let mode = try RetainedArtifactFile(path: fixture.child("permissions"))
        let links = try RetainedArtifactFile(path: fixture.child("links"))
        defer {
            try? mode.close()
            try? links.close()
        }
        #expect(Darwin.chmod(fixture.child("permissions"), 0o640) == 0)
        #expect(throws: RetainedArtifactError.unsafeFile) { try mode.revalidate() }
        #expect(Darwin.link(fixture.child("links"), fixture.child("new-link")) == 0)
        #expect(throws: RetainedArtifactError.unsafeFile) { try links.readBounded() }
        #expect(FileManager.default.fileExists(atPath: fixture.child("links")))
        #expect(FileManager.default.fileExists(atPath: fixture.child("new-link")))
    }

    @Test func immutablePermissionsAreExplicitAndStillRequireOneLink() throws {
        let fixture = try ArtifactDiskFixture()
        defer { fixture.cleanUp() }
        let bytes = Data(#"{"sealed":true}"#.utf8)
        try fixture.write("sealed.json", bytes: bytes, permissions: 0o400)
        #expect(throws: RetainedArtifactError.unsafeFile) {
            try RetainedArtifactFile(path: fixture.child("sealed.json"))
        }
        let file = try RetainedArtifactFile(path: fixture.child("sealed.json"),
                                           policy: ArtifactFilePolicy(requiredPermissions: 0o400))
        defer { try? file.close() }
        #expect(try file.readJSON().originalData == bytes)
        #expect(Darwin.link(fixture.child("sealed.json"), fixture.child("stage")) == 0)
        #expect(throws: RetainedArtifactError.unsafeFile) { try file.revalidate() }
    }

    @Test func retainedDirectoryRenameRejectsTheReplacementPath() throws {
        let fixture = try ArtifactDiskFixture()
        defer { fixture.cleanUp() }
        try fixture.makeDirectory("session")
        try fixture.write("session/evidence", bytes: Data("owned".utf8))
        let directory = try RetainedArtifactDirectory(path: fixture.child("session"), requiredPermissions: 0o700)
        let file = try directory.openFile(named: "evidence")
        defer {
            try? file.close()
            try? directory.close()
        }
        #expect(Darwin.rename(fixture.child("session"), fixture.child("moved")) == 0)
        try fixture.makeDirectory("session")
        try fixture.write("session/evidence", bytes: Data("replacement".utf8))
        #expect(throws: RetainedArtifactError.directoryChanged) { try directory.revalidate() }
        #expect(throws: RetainedArtifactError.directoryChanged) { try file.readBounded() }
        try file.close()
        try directory.close()
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.child("session/evidence"))) == Data("replacement".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.child("moved/evidence"))) == Data("owned".utf8))
    }

    @Test func retainedAncestryAndDirectoryPermissionsAreChecked() throws {
        let fixture = try ArtifactDiskFixture()
        defer { fixture.cleanUp() }
        try fixture.makeDirectory("parent/child")
        try fixture.write("parent/child/evidence", bytes: Data("owned".utf8))
        let directory = try RetainedArtifactDirectory(path: fixture.child("parent/child"))
        defer { try? directory.close() }
        #expect(Darwin.rename(fixture.child("parent"), fixture.child("moved")) == 0)
        try fixture.makeDirectory("parent/child")
        #expect(throws: RetainedArtifactError.directoryChanged) { try directory.revalidate() }
        let replacement = try RetainedArtifactDirectory(path: fixture.child("parent/child"))
        defer { try? replacement.close() }
        #expect(Darwin.chmod(fixture.child("parent/child"), 0o500) == 0)
        #expect(throws: RetainedArtifactError.directoryChanged) { try replacement.revalidate() }
    }

    @Test func unrelatedDirectoryEntriesDoNotInvalidateAStableArtifact() throws {
        let fixture = try ArtifactDiskFixture()
        defer { fixture.cleanUp() }
        try fixture.write("evidence", bytes: Data("stable".utf8))
        let directory = try RetainedArtifactDirectory(path: fixture.path)
        let file = try directory.openFile(named: "evidence")
        defer {
            try? file.close()
            try? directory.close()
        }
        try fixture.write("unrelated", bytes: Data("new file".utf8))
        try directory.revalidate()
        #expect(try file.readBounded() == Data("stable".utf8))
    }

    @Test func symbolicDirectoryComponentsAndUnsafeDirectoryModesAreRejected() throws {
        let fixture = try ArtifactDiskFixture()
        defer { fixture.cleanUp() }
        try fixture.makeDirectory("real/child")
        #expect(Darwin.symlink("real", fixture.child("alias")) == 0)
        #expect(throws: RetainedArtifactError.unsafeDirectory) {
            try RetainedArtifactDirectory(path: fixture.child("alias/child"))
        }
        #expect(Darwin.chmod(fixture.child("real"), 0o777) == 0)
        #expect(throws: RetainedArtifactError.unsafeDirectory) {
            try RetainedArtifactDirectory(path: fixture.child("real"))
        }
    }

    @Test func closeRetiresOwnershipOnceAndLeavesFilesInPlace() throws {
        let fixture = try ArtifactDiskFixture()
        defer { fixture.cleanUp() }
        try fixture.write("evidence", bytes: Data("stable".utf8))
        try fixture.write("other", bytes: Data("other".utf8))
        let directory = try RetainedArtifactDirectory(path: fixture.path)
        let file = try directory.openFile(named: "evidence")
        try file.close()
        let reused = Darwin.open(fixture.child("other"), O_RDONLY | O_CLOEXEC)
        #expect(reused >= 0)
        defer { if reused >= 0 { _ = Darwin.close(reused) } }
        try file.close()
        var byte: UInt8 = 0
        #expect(Darwin.pread(reused, &byte, 1, 0) == 1)
        #expect(byte == 0x6F)
        #expect(throws: RetainedArtifactError.closed) { try file.readBounded() }
        #expect(throws: RetainedArtifactError.closed) { try file.revalidateBeforeMutation() }
        try directory.close()
        try directory.close()
        #expect(throws: RetainedArtifactError.closed) { try directory.revalidate() }
        #expect(throws: RetainedArtifactError.closed) { try directory.openFile(named: "evidence") }
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.child("evidence"))) == Data("stable".utf8))
    }

    @Test func closingTheParentFailsClosedForItsLiveFileCapabilities() throws {
        let fixture = try ArtifactDiskFixture()
        defer { fixture.cleanUp() }
        try fixture.write("evidence", bytes: Data("stable".utf8))
        let directory = try RetainedArtifactDirectory(path: fixture.path)
        let file = try directory.openFile(named: "evidence")
        defer { try? file.close() }
        try directory.close()
        #expect(throws: RetainedArtifactError.closed) { try file.readBounded() }
        #expect(throws: RetainedArtifactError.closed) { try file.revalidate() }
    }

    @Test func invalidPathsNamesAndPolicyBoundsAreRejected() throws {
        let fixture = try ArtifactDiskFixture()
        defer { fixture.cleanUp() }
        let directory = try RetainedArtifactDirectory(path: fixture.path)
        defer { try? directory.close() }
        for name in ["", ".", "..", "nested/file", "nul\u{00}"] {
            #expect(throws: RetainedArtifactError.invalidPath) { try directory.openFile(named: name) }
        }
        for path in ["relative", fixture.path + "/", fixture.path + "/.", fixture.path + "/../other",
                     fixture.path + "//other", fixture.path + "\u{00}"] {
            #expect(throws: RetainedArtifactError.invalidPath) { try RetainedArtifactDirectory(path: path) }
        }
        for maximum in [-1, 0, Int.max] {
            #expect(throws: RetainedArtifactError.invalidPolicy) { try ArtifactFilePolicy(maximumBytes: maximum) }
        }
        #expect(throws: RetainedArtifactError.invalidPolicy) { try ArtifactFilePolicy(minimumBytes: -1) }
        #expect(throws: RetainedArtifactError.invalidPolicy) { try ArtifactFilePolicy(minimumBytes: 5, maximumBytes: 4) }
        #expect(throws: RetainedArtifactError.invalidPolicy) { try ArtifactFilePolicy(requiredPermissions: 0o666) }
        #expect(throws: RetainedArtifactError.invalidPolicy) { try ArtifactFilePolicy(requiredPermissions: 0o200) }
        #expect(throws: RetainedArtifactError.invalidPolicy) {
            try RetainedArtifactDirectory(path: fixture.path, requiredPermissions: 0o777)
        }
    }
}

private struct ArtifactDiskFixture {
    let path: String

    init() throws {
        let requested = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentbuild-artifact-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: requested, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        guard let resolved = Darwin.realpath(requested, nil) else {
            throw RetainedArtifactError.systemCall("fixture realpath", errno)
        }
        defer { Darwin.free(resolved) }
        path = String(cString: resolved)
    }

    func child(_ name: String) -> String { path + "/" + name }

    func makeDirectory(_ name: String) throws {
        try FileManager.default.createDirectory(atPath: child(name), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
    }

    func write(_ name: String, bytes: Data, permissions: mode_t = 0o600) throws {
        let descriptor = Darwin.open(child(name), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, permissions)
        guard descriptor >= 0 else { throw RetainedArtifactError.systemCall("fixture open", errno) }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, permissions) == 0 else {
            throw RetainedArtifactError.systemCall("fixture chmod", errno)
        }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, buffer.baseAddress?.advanced(by: offset), bytes.count - offset)
                guard written > 0 else { throw RetainedArtifactError.systemCall("fixture write", errno) }
                offset += written
            }
        }
    }

    func setModificationTime(_ name: String, seconds: Int64, nanoseconds: Int64) throws {
        var metadata = stat()
        guard Darwin.lstat(child(name), &metadata) == 0 else {
            throw RetainedArtifactError.systemCall("fixture stat", errno)
        }
        let times = [metadata.st_atimespec, timespec(tv_sec: Int(seconds), tv_nsec: Int(nanoseconds))]
        let result = times.withUnsafeBufferPointer { Darwin.utimensat(AT_FDCWD, child(name), $0.baseAddress, 0) }
        guard result == 0 else { throw RetainedArtifactError.systemCall("fixture timestamp", errno) }
    }

    func cleanUp() {
        _ = Darwin.chmod(path, 0o700)
        if let entries = FileManager.default.enumerator(atPath: path) {
            while let name = entries.nextObject() as? String {
                var metadata = stat()
                let entry = child(name)
                if Darwin.lstat(entry, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                    _ = Darwin.chmod(entry, 0o700)
                }
            }
        }
        try? FileManager.default.removeItem(atPath: path)
    }
}
