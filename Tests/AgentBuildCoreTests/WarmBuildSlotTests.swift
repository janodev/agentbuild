import AgentBuildCore
import AgentBuildTestSupport
import AgentLeaseCore
import Darwin
import Foundation
import Testing

@Suite struct WarmBuildSlotTests {
    struct Fixture {
        let base: CompilationFixture
        let a: URL
        let b: URL
        let pool: URL

        init() throws {
            base = try CompilationFixture()
            a = base.directory.appendingPathComponent("A")
            b = base.directory.appendingPathComponent("B")
            pool = base.directory.appendingPathComponent("slots")
            for dir in [a, b, pool] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
            }
        }

        func use<T: Sendable>(_ tree: URL, key: String = "repo/profile",
                              symlinks: BuildSlotSymlinkPolicy = .withinSource,
                              _ operation: @Sendable (PreparedBuildSlot) async throws -> T) async throws -> T {
            try await WarmBuildSlot(poolDirectory: pool.path, key: key).withPreparedSlot(
                worktree: tree.path, environment: base.environment,
                waitSeconds: 0, symlinkPolicy: symlinks, including: { $0 != "excluded" }, operation: operation)
        }
    }

    @Test func switchingWorktreesReconcilesContentsModesNamesAndTypes() async throws {
        let f = try Fixture()
        defer { f.base.remove() }
        for root in [f.a, f.b] {
            try Data("same".utf8).write(to: root.appendingPathComponent("common"))
            try Data("hidden".utf8).write(to: root.appendingPathComponent(".git"))
            try Data().write(to: root.appendingPathComponent("excluded"))
            try Data((root == f.a ? "AAAA" : "BBBB").utf8).write(to: root.appendingPathComponent("edit"))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: root.path + "/edit")
            try Data().write(to: root.appendingPathComponent("script"))
            try FileManager.default.setAttributes([.posixPermissions: root == f.a ? 0o600 : 0o700], ofItemAtPath: root.path + "/script")
        }
        try FileManager.default.createSymbolicLink(atPath: f.a.path + "/node", withDestinationPath: "common")
        try FileManager.default.createDirectory(at: f.b.appendingPathComponent("node"), withIntermediateDirectories: false)
        try Data().write(to: f.b.appendingPathComponent("node/new"))
        try Data().write(to: f.a.appendingPathComponent("Old"))
        try Data().write(to: f.b.appendingPathComponent("old"))
        let first = try await f.use(f.a) { slot in
            #expect(slot.syncSummary.unchangedFiles == 0)
            #expect(slot.syncSummary.clonedFiles + slot.syncSummary.copiedFiles == 4)
            try Data("cache".utf8).write(to: URL(fileURLWithPath: slot.derivedDataDirectory + "/sentinel"))
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: slot.sourceDirectory + "/node") == "common")
            return try fileStamp(slot.sourceDirectory + "/common")
        }
        try await f.use(f.b) { slot in
            #expect(slot.syncSummary.unchangedFiles == 1)
            let path = slot.sourceDirectory
            #expect(try fileStamp(path + "/common") == first)
            #expect(try String(contentsOfFile: path + "/edit", encoding: .utf8) == "BBBB")
            #expect(try FileManager.default.attributesOfItem(atPath: path + "/script")[.posixPermissions] as? Int == 0o700)
            #expect(try Set(FileManager.default.contentsOfDirectory(atPath: path)) == ["common", "edit", "node", "old", "script"])
            #expect(FileManager.default.fileExists(atPath: path + "/node/new"))
            #expect(FileManager.default.fileExists(atPath: slot.derivedDataDirectory + "/sentinel"))
            try Data("slot only".utf8).write(to: URL(fileURLWithPath: path + "/edit"))
            #expect(try String(contentsOfFile: f.b.path + "/edit", encoding: .utf8) == "BBBB")
        }
        try await f.use(f.a) { slot async throws -> Void in
            #expect(try String(contentsOfFile: slot.sourceDirectory + "/edit", encoding: .utf8) == "AAAA")
            #expect(try FileManager.default.contentsOfDirectory(atPath: slot.sourceDirectory).contains("Old"))
            #expect(FileManager.default.fileExists(atPath: f.b.path + "/node/new"))
        }
    }

    @Test func failedSyncCanBeRetriedWithoutRunningAgainstPartialTree() async throws {
        let f = try Fixture()
        defer { f.base.remove() }
        try Data().write(to: f.a.appendingPathComponent("stale"))
        try await f.use(f.a) { _ in }
        try #require(mkfifo(f.b.path + "/pipe", 0o600) == 0)
        await #expect(throws: BuildSlotError.unsupportedEntry("pipe")) {
            try await f.use(f.b) { _ in Issue.record("Ran with incomplete inputs") }
        }
        try FileManager.default.removeItem(at: f.b.appendingPathComponent("pipe"))
        try Data().write(to: f.b.appendingPathComponent("new"))
        try await f.use(f.b) { slot async throws -> Void in
            #expect(try FileManager.default.contentsOfDirectory(atPath: slot.sourceDirectory) == ["new"])
        }
    }

    @Test func retainedDescriptorProtectsSlotAfterOperationReturns() async throws {
        let f = try Fixture()
        defer { f.base.remove() }
        let retained = try await f.use(f.a) { slot in
            let descriptor = try #require(slot.leaseDescriptors.first)
            let result = fcntl(descriptor, F_DUPFD_CLOEXEC, 3)
            try #require(result >= 0)
            return result
        }
        do {
            defer { _ = close(retained) }
            await #expect(throws: LeaseSetError.self) {
                try await f.use(f.b) { _ in Issue.record("Previous workload still holds the slot") }
            }
        }
        try await f.use(f.b) { _ in }
    }

    @Test func sharedSlotHasExclusiveCustodyIndependentOfCompilation() async throws {
        let f = try Fixture()
        defer { f.base.remove() }
        let plan = try WarmBuildSlot(poolDirectory: f.pool.path, key: "repo/profile")
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.pool.path).isEmpty)
        try await f.use(f.a) { slot in
            #expect(slot.sourceDirectory == plan.sourceDirectory)
            #expect(slot.derivedDataDirectory == plan.derivedDataDirectory)
            let contender = try FileLock(resource: ResourceName(plan.resource), paths: f.base.paths)
            defer { contender.release() }
            #expect(try !contender.tryAcquire())
            #expect(try f.base.available())
            #expect(slot.leaseDescriptors.count == 1)
            #expect(fcntl(slot.sourceDirectoryDescriptor, F_GETFD) >= 0)
            await #expect(throws: LeaseSetError.self) {
                try await f.use(f.b) { _ in Issue.record("Two simultaneous slot writers") }
            }
            try await f.use(f.b, key: "second slot") { other in
                #expect(other.derivedDataDirectory != slot.derivedDataDirectory)
            }
        }
        try await f.use(f.b) { _ in }
        await #expect(throws: BuildSlotError.overlappingDirectories) {
            try await f.use(f.base.directory) { _ in Issue.record("Pool nested in source") }
        }
    }
}

private func fileStamp(_ path: String) throws -> [UInt64] {
    var info = stat()
    try #require(lstat(path, &info) == 0)
    return [info.st_ino, UInt64(info.st_mtimespec.tv_sec), UInt64(info.st_mtimespec.tv_nsec)]
}
