@testable import AgentBuildCore
import Foundation
@testable import GunshipAdapter
import Testing

@Suite("Gunship archive paths and validation maps")
struct GunshipArchivePlanningTests {
    @Test func newArchiveDirectoriesAreAllowedWithoutCreation() async throws {
        let fixture = try await GunshipFixture()
        defer { fixture.remove() }
        let archive = fixture.directory.path + "/New/Archive"
        let plan = try await GunshipProjectPlanner.plan(
            request: GunshipProjectRequest(repository: fixture.repository, action: .package, archive: archive),
            environment: fixture.environment)

        #expect(plan.archive == archive)
        #expect(plan.resources.last?.resource == "gunship:archive:" + archive)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path + "/New"))
        #expect(!FileManager.default.fileExists(atPath: fixture.repository + "/Artifacts"))
    }

    @Test func existingSymlinkAndPhysicalPathsKeepOneArchiveLease() async throws {
        let fixture = try await GunshipFixture()
        defer { fixture.remove() }
        let destination = fixture.directory.path + "/Destination"
        let link = fixture.directory.path + "/Link"
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "Destination")

        let throughLink = try await GunshipProjectPlanner.plan(
            request: GunshipProjectRequest(repository: fixture.repository, action: .package, archive: link + "/New/Archive"),
            environment: fixture.environment)
        let physical = try await GunshipProjectPlanner.plan(
            request: GunshipProjectRequest(repository: fixture.repository, action: .package,
                                           archive: destination + "/New/Archive"),
            environment: fixture.environment)

        #expect(throughLink.archive == destination + "/New/Archive")
        #expect(throughLink.resources.last == physical.resources.last)
        #expect(!FileManager.default.fileExists(atPath: destination + "/New"))
    }

    @Test(arguments: ["", "/Nested/Archive"])
    func danglingSymlinkIsRejectedAtAnyArchiveDepth(_ suffix: String) async throws {
        let fixture = try await GunshipFixture()
        defer { fixture.remove() }
        let link = fixture.directory.path + "/Dangling"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "MissingTarget")
        let request = try GunshipProjectRequest(repository: fixture.repository, action: .package, archive: link + suffix)

        await #expect(throws: GunshipProjectError.invalidRequest("archive contains an unresolved symbolic link")) {
            try await GunshipProjectPlanner.plan(request: request, environment: fixture.environment)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path + "/MissingTarget"))
    }

    @Test(arguments: ["", "/Nested/Archive"])
    func regularFilesCannotBeArchiveDirectoriesOrAncestors(_ suffix: String) async throws {
        let fixture = try await GunshipFixture()
        defer { fixture.remove() }
        let file = fixture.directory.path + "/RegularFile"
        try Data("not a directory".utf8).write(to: URL(fileURLWithPath: file))
        let request = try GunshipProjectRequest(repository: fixture.repository, action: .package, archive: file + suffix)

        await #expect(throws: GunshipProjectError.self) {
            try await GunshipProjectPlanner.plan(request: request, environment: fixture.environment)
        }
    }

    @Test func symbolicLinkLoopsAreRejected() async throws {
        let fixture = try await GunshipFixture()
        defer { fixture.remove() }
        let link = fixture.directory.path + "/Loop"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "Loop")
        let request = try GunshipProjectRequest(repository: fixture.repository, action: .package, archive: link + "/Archive")

        await #expect(throws: GunshipProjectError.invalidRequest("cannot resolve archive directory")) {
            try await GunshipProjectPlanner.plan(request: request, environment: fixture.environment)
        }
    }

    @Test func sliceRejectsMapOverridesThatItsHarnessCannotHonor() throws {
        #expect(throws: GunshipProjectError.invalidRequest("slice validation uses L_Apron and does not accept a map")) {
            try GunshipProjectRequest(repository: "/fixture/Gunship", action: .validate,
                map: "/Game/Gunship/Maps/L_Defense_Blockout", archive: "/fixture/Archive", scenario: "slice")
        }
        let request = try GunshipProjectRequest(repository: "/fixture/Gunship", action: .validate,
            archive: "/fixture/Archive", scenario: "slice")
        #expect(request.map == nil)
    }

    @Test func validationAcceptsOneMapWhilePackagingAcceptsMapLists() throws {
        let map = "/Game/Gunship/Maps/L_Defense_Blockout"
        let maps = map + "+/Game/Gunship/Maps/L_Apron"
        #expect(throws: GunshipProjectError.invalidRequest("validation map must be one /Game package path")) {
            try GunshipProjectRequest(repository: "/fixture/Gunship", action: .validate,
                map: maps, archive: "/fixture/Archive", scenario: "zombies")
        }
        let validation = try GunshipProjectRequest(repository: "/fixture/Gunship", action: .validate,
            map: map, archive: "/fixture/Archive", scenario: "zombies")
        let package = try GunshipProjectRequest(repository: "/fixture/Gunship", action: .package,
            map: maps, archive: "/fixture/Archive")
        #expect(validation.map == map)
        #expect(package.map == maps)
    }
}
