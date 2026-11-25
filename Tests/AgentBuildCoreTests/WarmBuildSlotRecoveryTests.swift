import AgentBuildCore
import Darwin
import Foundation
import Testing

extension WarmBuildSlotTests {
    @Test func nextOwnerRepairsReadOnlySourceRootAndSubdirectories() async throws {
        let f = try Fixture()
        defer { f.base.remove() }
        try FileManager.default.createDirectory(at: f.b.appendingPathComponent("keep"), withIntermediateDirectories: false)
        try Data().write(to: f.b.appendingPathComponent("keep/new"))
        try await f.use(f.a) { slot in
            for name in ["keep", "remove"] {
                let dir = slot.sourceDirectory + "/" + name
                try #require(mkdir(dir, 0o700) == 0)
                try Data().write(to: URL(fileURLWithPath: dir + "/old"))
                try #require(chmod(dir, name == "keep" ? 0 : 0o555) == 0)
            }
            try #require(chmod(slot.sourceDirectory, 0o500) == 0)
        }
        try await f.use(f.b) { slot async throws -> Void in
            #expect(try FileManager.default.contentsOfDirectory(atPath: slot.sourceDirectory) == ["keep"])
            #expect(try FileManager.default.contentsOfDirectory(atPath: slot.sourceDirectory + "/keep") == ["new"])
        }
    }

    @Test func lockedInputAndLegacyLockedTemporaryFileLeaveOriginIntact() async throws {
        let f = try Fixture()
        defer { f.base.remove() }
        let original = f.a.appendingPathComponent("locked")
        try Data("original".utf8).write(to: original)
        try #require(chflags(original.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(original.path, 0) }
        try await f.use(f.a) { slot in
            let mirrored = URL(fileURLWithPath: slot.sourceDirectory + "/locked")
            try Data("modified".utf8).write(to: mirrored)
            // Model the debris left by the previous implementation.
            let temp = URL(fileURLWithPath: slot.sourceDirectory + "/.agentbuild-old")
            try Data().write(to: temp)
            try #require(chflags(temp.path, UInt32(UF_IMMUTABLE)) == 0)
        }
        try await f.use(f.b) { slot async throws -> Void in
            #expect(try FileManager.default.contentsOfDirectory(atPath: slot.sourceDirectory).isEmpty)
        }
        var info = stat()
        try #require(lstat(original.path, &info) == 0)
        #expect(info.st_flags & UInt32(UF_IMMUTABLE) != 0)
        #expect(try Data(contentsOf: original) == Data("original".utf8))
    }

    @Test func cleanupPreservesFlagsOnHardLinkedFiles() async throws {
        let f = try Fixture()
        defer { f.base.remove() }
        let original = f.a.appendingPathComponent("value")
        try Data("origin".utf8).write(to: original)
        try await f.use(f.a) { slot in
            try #require(link(original.path, slot.sourceDirectory + "/shared") == 0)
        }
        try #require(chflags(original.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(original.path, 0) }
        await #expect(throws: BuildSlotError.unsupportedEntry("shared")) {
            try await f.use(f.b) { _ in Issue.record("Unexpected handoff with locked hard link") }
        }
        var info = stat()
        try #require(lstat(original.path, &info) == 0)
        #expect(info.st_flags & UInt32(UF_IMMUTABLE) != 0)
    }

    @Test func internalAbsoluteAndChainedLinksResolveInSlot() async throws {
        let f = try Fixture()
        defer { f.base.remove() }
        let file = f.a.appendingPathComponent("value")
        try Data("origin".utf8).write(to: file)
        let dir = f.a.appendingPathComponent("links")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: dir.path + "/absolute", withDestinationPath: file.path)
        try FileManager.default.createSymbolicLink(atPath: f.a.path + "/chain", withDestinationPath: "links/absolute")
        try await f.use(f.a) { slot in
            try Data("slot".utf8).write(to: URL(fileURLWithPath: slot.sourceDirectory + "/chain"))
            #expect(try String(contentsOfFile: slot.sourceDirectory + "/value", encoding: .utf8) == "slot")
            #expect(try String(contentsOf: file, encoding: .utf8) == "origin")
        }
    }

    @Test(arguments: ["absolute", "relative", "chain", "dangling", "cycle"])
    func unresolvedLinksPreventHandoffUnlessLiteralPolicyIsSelected(_ kind: String) async throws {
        let f = try Fixture()
        defer { f.base.remove() }
        let target: String
        switch kind {
        case "absolute": target = f.b.path
        case "relative": target = "../B"
        case "chain":
            try FileManager.default.createDirectory(at: f.a.appendingPathComponent("nested"), withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(atPath: f.a.path + "/nested/up", withDestinationPath: "..")
            target = "nested/up/.."
        case "cycle": target = "link"
        default: target = "missing"
        }
        try FileManager.default.createSymbolicLink(atPath: f.a.path + "/link", withDestinationPath: target)
        await #expect(throws: BuildSlotError.unresolvedSlotLink("link")) {
            try await f.use(f.a) { _ in Issue.record("Build launched with unresolved or external link") }
        }
        try await f.use(f.a, symlinks: .preserveLiteral) { slot async throws -> Void in
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: slot.sourceDirectory + "/link") == target)
        }
    }

    @Test func timestampBasedProductUpdatesAfterClockRegression() async throws {
        let f = try Fixture()
        defer { f.base.remove() }
        let rule = "../DerivedData/result: input\n\t/bin/cp -p input ../DerivedData/result\n"
        for root in [f.a, f.b] {
            try Data(rule.utf8).write(to: root.appendingPathComponent("Makefile"))
            try Data(root.lastPathComponent.utf8).write(to: root.appendingPathComponent("input"))
        }
        for (index, root) in [f.a, f.b, f.a].enumerated() {
            try await f.use(root) { slot in
                if index == 0 {
                    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(30)],
                                                          ofItemAtPath: slot.sourceDirectory + "/input")
                }
                _ = try await RepositoryCommandCapture().capture(arguments: ["/usr/bin/make"], workingDirectory: slot.sourceDirectory,
                                                                 environment: ["PATH": "/usr/bin:/bin"])
                let result = try String(contentsOfFile: slot.derivedDataDirectory + "/result", encoding: .utf8)
                #expect(result == root.lastPathComponent)
            }
        }
    }
}
