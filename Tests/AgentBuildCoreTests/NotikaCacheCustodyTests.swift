import AgentBuildCore
import AgentLeaseCore
import Darwin
import Foundation
import Testing

@Suite("Notika cache custody")
struct NotikaCacheCustodyTests {
    @Test func createsPrivateFixedNamespaceAndPublishesAdmittedBytes() async throws {
        let fixture = try CacheCustodyFixture()
        defer { fixture.base.remove() }
        try await fixture.withOwnership { ownership in
            let custody = try NotikaCacheCustody(identity: fixture.identity, ownership: ownership)
            #expect(custody.cacheDirectory == fixture.plan.cacheDirectory)
            #expect(custody.environment == ["NOTIKA_DERIVED_DATA": custody.cacheDirectory])
            #expect(try custody.readUsage() == nil)
            let physical = try cacheTestStatus(custody.cacheDirectory)
            #expect(physical.st_mode & 0o7777 == 0o700)
            #expect(physical.st_uid == geteuid())
            #expect(custody.facts.directoryDeviceID == UInt64(physical.st_dev))
            #expect(custody.facts.directoryInode == physical.st_ino)
            for descriptor in try custody.inheritedDirectoryDescriptors() {
                #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
            }
            let record = try custody.publishUsage(sessionID: "native-first", usedAt: fixture.firstUse)
            let bytes = try Data(contentsOf: fixture.usageURL)
            #expect(bytes == record.originalData)
            #expect(bytes.last == 10)
            #expect(try custody.readUsage() == record)
            #expect(record.createdAtMicrosecondsSince1970 == record.lastUsedAtMicrosecondsSince1970)
            #expect(record.lastSessionID == "native-first")
            let file = try cacheTestStatus(fixture.usageURL.path)
            #expect(file.st_mode & 0o7777 == 0o600)
            #expect(file.st_nlink == 1)
            #expect(file.st_dev == physical.st_dev)
            #expect(try FileManager.default.contentsOfDirectory(atPath: custody.cacheDirectory) == [NotikaCacheCustody.metadataFilename])
        }
    }

    @Test(arguments: [1, 2, 3, 4])
    func historicalKeySelectsExactSchemaAndFactoryRoundTrips(_ schema: Int) async throws {
        let fixture = try CacheCustodyFixture(schema: schema)
        defer { fixture.base.remove() }
        try await fixture.withOwnership { ownership in
            let custody = try NotikaCacheCustody(identity: fixture.identity, ownership: ownership)
            let factory = try NotikaCacheUsageFactory.make(
                identity: fixture.identity, directoryObservation: custody.directoryObservation,
                sessionID: "schema-\(schema)", usedAt: fixture.firstUse
            )
            #expect(try custody.readUsage() == nil)
            #expect(factory.schemaVersion == schema)
            #expect(custody.facts.metadataSchemaVersion == schema)
            #expect(try NotikaCacheUsageRecord(data: factory.originalData, directoryObservation: custody.directoryObservation) == factory)
            #expect((factory.storageIdentitySHA256 == nil) == (schema == 1))
            let published = try custody.publishUsage(sessionID: "schema-\(schema)", usedAt: fixture.firstUse)
            #expect(published == factory)
            #expect(published.cacheKey == (try fixture.identity.cacheKey(metadataSchemaVersion: schema)))
        }
    }

    @Test func sharedAppAndUICachePreservesCreationAndUpdatesExecutionMaterial() async throws {
        let fixture = try CacheCustodyFixture()
        defer { fixture.base.remove() }
        let first = try await fixture.withOwnership { ownership in
            try NotikaCacheCustody(identity: fixture.identity, ownership: ownership)
                .publishUsage(sessionID: "app-build", usedAt: fixture.firstUse)
        }
        let firstInode = try cacheTestStatus(fixture.usageURL.path).st_ino
        let ui = try cacheTestIdentity(worktree: fixture.base.directory.path, scheme: "NotikaUITestsOnly")
        #expect(try NotikaProjectOwnershipPlan(identity: ui) == fixture.plan)
        try await fixture.withOwnership { ownership in
            let custody = try NotikaCacheCustody(identity: ui, ownership: ownership)
            #expect(try custody.readUsage() == first)
            let updated = try custody.publishUsage(sessionID: "ui-build", usedAt: fixture.firstUse.addingTimeInterval(3_600.123456))
            #expect(updated.createdAtMicrosecondsSince1970 == first.createdAtMicrosecondsSince1970)
            #expect(try updated.document.root.requireObject().requiredValue(forKey: "createdAt") == first.document.root.requireObject().requiredValue(forKey: "createdAt"))
            #expect(updated.lastUsedAt > first.lastUsedAt)
            #expect(updated.lastSessionID == "ui-build")
            #expect(updated.compatibilityIdentity == ui)
            #expect(updated.compatibilityIdentitySHA256 != first.compatibilityIdentitySHA256)
            #expect(updated.cacheKey == first.cacheKey)
            #expect(try cacheTestStatus(fixture.usageURL.path).st_ino != firstInode)
            #expect(try custody.readUsage() == updated)
        }
    }

    @Test func changedInputsReuseExistingBuildProductsAndRefreshUsage() async throws {
        let fixture = try CacheCustodyFixture()
        defer { fixture.base.remove() }
        let product = fixture.cacheURL.appendingPathComponent("existing-object.o")
        let first = try await fixture.withOwnership { ownership in
            let custody = try NotikaCacheCustody(identity: fixture.identity, ownership: ownership)
            try Data("retained build product".utf8).write(to: product)
            return try custody.publishUsage(sessionID: "before-input-edit", usedAt: fixture.firstUse)
        }
        let inode = try cacheTestStatus(fixture.cacheURL.path).st_ino
        let changed = try cacheTestIdentity(worktree: fixture.base.directory.path,
                                           inputDigest: String(repeating: "b", count: 64))
        #expect(try NotikaProjectOwnershipPlan(identity: changed) == fixture.plan)
        try await fixture.withOwnership { ownership in
            let custody = try NotikaCacheCustody(identity: changed, ownership: ownership)
            #expect(try custody.readUsage() == first)
            #expect(try cacheTestStatus(fixture.cacheURL.path).st_ino == inode)
            #expect(try Data(contentsOf: product) == Data("retained build product".utf8))
            let updated = try custody.publishUsage(sessionID: "after-input-edit", usedAt: fixture.firstUse.addingTimeInterval(1))
            #expect(updated.schemaVersion == 4)
            #expect(updated.compatibilityIdentity == changed)
            #expect(updated.compatibilityIdentitySHA256 != first.compatibilityIdentitySHA256)
            #expect(updated.createdAtMicrosecondsSince1970 == first.createdAtMicrosecondsSince1970)
            #expect(updated.cacheKey == first.cacheKey)
        }
    }

    @Test func preservesAdmittedCreationLiteralAndMicroseconds() async throws {
        let fixture = try CacheCustodyFixture()
        defer { fixture.base.remove() }
        try await fixture.withOwnership { ownership in
            let custody = try NotikaCacheCustody(identity: fixture.identity, ownership: ownership)
            let created = "1970-01-01T01:00:00.123456+01:00"
            let admitted = try NotikaCacheUsageFactory.make(
                identity: fixture.identity, directoryObservation: custody.directoryObservation,
                sessionID: "python-compatible-prior", usedAt: fixture.firstUse, createdAt: created
            )
            try admitted.originalData.write(to: fixture.usageURL)
            try #require(chmod(fixture.usageURL.path, 0o600) == 0)
            let published = try custody.publishUsage(sessionID: "native-update", usedAt: fixture.firstUse.addingTimeInterval(1))
            #expect(published.createdAtMicrosecondsSince1970 == 123_456)
            #expect(try published.document.root.requireObject().requiredValue(forKey: "createdAt") == .string(created))
        }
    }

    @Test func factoryEmitsProducerSecondsMicrosecondsAndUTCRollover() async throws {
        let fixture = try CacheCustodyFixture()
        defer { fixture.base.remove() }
        try await fixture.withOwnership { ownership in
            let custody = try NotikaCacheCustody(identity: fixture.identity, ownership: ownership)
            for (seconds, expected) in [
                (0.0, "1970-01-01T00:00:00Z"),
                (0.123456, "1970-01-01T00:00:00.123456Z"),
                (-0.000001, "1969-12-31T23:59:59.999999Z"),
            ] {
                let record = try NotikaCacheUsageFactory.make(
                    identity: fixture.identity, directoryObservation: custody.directoryObservation,
                    sessionID: "producer-form", usedAt: Date(timeIntervalSince1970: seconds)
                )
                #expect(try record.document.root.requireObject().requiredValue(forKey: "lastUsedAt") == .string(expected))
                #expect(record.createdAtMicrosecondsSince1970 == record.lastUsedAtMicrosecondsSince1970)
            }
        }
    }

    @Test func malformedExistingEvidenceBlocksConstructorAndPublicationWithoutOverwrite() async throws {
        let fixture = try CacheCustodyFixture()
        defer { fixture.base.remove() }
        try await fixture.withOwnership { ownership in
            let custody = try NotikaCacheCustody(identity: fixture.identity, ownership: ownership)
            try custody.publishUsage(sessionID: "valid-first", usedAt: fixture.firstUse)
            let invalid = Data("{\"schemaVersion\":3,\"schemaVersion\":3}\n".utf8)
            try invalid.write(to: fixture.usageURL)
            #expect(throws: (any Error).self) { try custody.readUsage() }
            #expect(throws: (any Error).self) { try custody.publishUsage(sessionID: "must-not-write", usedAt: fixture.firstUse) }
            #expect(throws: (any Error).self) { try NotikaCacheCustody(identity: fixture.identity, ownership: ownership) }
            #expect(try Data(contentsOf: fixture.usageURL) == invalid)
            #expect(try FileManager.default.contentsOfDirectory(atPath: custody.cacheDirectory) == [NotikaCacheCustody.metadataFilename])
        }
    }

    @Test(arguments: UnsafeCacheUsage.allCases)
    func unsafeMetadataIsProtectedBeforeAnyPublication(_ unsafe: UnsafeCacheUsage) async throws {
        let fixture = try CacheCustodyFixture()
        defer { fixture.base.remove() }
        try await fixture.withOwnership { ownership in
            let custody = try NotikaCacheCustody(identity: fixture.identity, ownership: ownership)
            let valid = try custody.publishUsage(sessionID: "protected", usedAt: fixture.firstUse)
            let outside = fixture.base.directory.appendingPathComponent("outside-usage")
            switch unsafe {
            case .permissions:
                try #require(chmod(fixture.usageURL.path, 0o644) == 0)
            case .hardlink:
                try #require(link(fixture.usageURL.path, outside.path) == 0)
            case .symlink:
                try FileManager.default.moveItem(at: fixture.usageURL, to: outside)
                try #require(symlink(outside.path, fixture.usageURL.path) == 0)
            case .fifo:
                try FileManager.default.moveItem(at: fixture.usageURL, to: outside)
                try #require(mkfifo(fixture.usageURL.path, 0o600) == 0)
            case .directory:
                try FileManager.default.moveItem(at: fixture.usageURL, to: outside)
                try FileManager.default.createDirectory(at: fixture.usageURL, withIntermediateDirectories: false)
            }
            #expect(throws: NotikaCacheCustodyError.unsafeEntry(NotikaCacheCustody.metadataFilename)) {
                try custody.publishUsage(sessionID: "must-not-replace", usedAt: fixture.firstUse)
            }
            #expect(throws: NotikaCacheCustodyError.unsafeEntry(NotikaCacheCustody.metadataFilename)) {
                try NotikaCacheCustody(identity: fixture.identity, ownership: ownership)
            }
            let preserved = unsafe == .permissions ? fixture.usageURL : outside
            #expect(try Data(contentsOf: preserved) == valid.originalData)
            #expect(try FileManager.default.contentsOfDirectory(atPath: custody.cacheDirectory) == [NotikaCacheCustody.metadataFilename])
        }
    }

    @Test(arguments: ["DerivedData", "AgentCaches", "entry"])
    func namespaceSymlinksAreRejectedWithoutFollowingTargets(_ component: String) async throws {
        let fixture = try CacheCustodyFixture()
        defer { fixture.base.remove() }
        let target = fixture.base.directory.appendingPathComponent("foreign-target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try #require(chmod(target.path, 0o700) == 0)
        let linkURL = component == "DerivedData" ? fixture.derivedDataURL : component == "AgentCaches" ? fixture.cacheRootURL : fixture.cacheURL
        try FileManager.default.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if component != "DerivedData" { try #require(chmod(fixture.derivedDataURL.path, 0o700) == 0) }
        if component == "entry" { try #require(chmod(fixture.cacheRootURL.path, 0o700) == 0) }
        try #require(symlink(target.path, linkURL.path) == 0)
        _ = try await fixture.withOwnership { ownership in
            #expect(throws: (any Error).self) { try NotikaCacheCustody(identity: fixture.identity, ownership: ownership) }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        #expect(try cacheTestStatus(linkURL.path).st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK))
    }

    @Test(arguments: ["DerivedData", "AgentCaches", "entry"])
    func namespacePermissionsAreNeverSilentlyRepaired(_ component: String) async throws {
        let fixture = try CacheCustodyFixture()
        defer { fixture.base.remove() }
        try FileManager.default.createDirectory(at: fixture.cacheURL, withIntermediateDirectories: true)
        for url in [fixture.derivedDataURL, fixture.cacheRootURL, fixture.cacheURL] { try #require(chmod(url.path, 0o700) == 0) }
        let unsafeURL = component == "DerivedData" ? fixture.derivedDataURL : component == "AgentCaches" ? fixture.cacheRootURL : fixture.cacheURL
        let mode: mode_t = component == "DerivedData" ? 0o777 : 0o755
        try #require(chmod(unsafeURL.path, mode) == 0)
        _ = try await fixture.withOwnership { ownership in
            #expect(throws: (any Error).self) { try NotikaCacheCustody(identity: fixture.identity, ownership: ownership) }
        }
        #expect(try cacheTestStatus(unsafeURL.path).st_mode & 0o7777 == mode)
        #expect(!FileManager.default.fileExists(atPath: fixture.usageURL.path))
    }

    @Test(arguments: ["AgentCaches", "entry"])
    func replacedNamespaceFailsEvenWhileOriginalDescriptorsRemainLive(_ component: String) async throws {
        let fixture = try CacheCustodyFixture()
        defer { fixture.base.remove() }
        try await fixture.withOwnership { ownership in
            let custody = try NotikaCacheCustody(identity: fixture.identity, ownership: ownership)
            let initial = try custody.publishUsage(sessionID: "before-replacement", usedAt: fixture.firstUse)
            let replaced = component == "AgentCaches" ? fixture.cacheRootURL : fixture.cacheURL
            let retired = replaced.appendingPathExtension("retired")
            try FileManager.default.moveItem(at: replaced, to: retired)
            try FileManager.default.createDirectory(at: replaced, withIntermediateDirectories: false)
            try #require(chmod(replaced.path, 0o700) == 0)
            #expect(throws: (any Error).self) { try custody.revalidateBeforeOperation() }
            #expect(throws: (any Error).self) { try custody.publishUsage(sessionID: "after-replacement", usedAt: fixture.firstUse) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: replaced.path).isEmpty)
            let oldUsage = component == "AgentCaches"
                ? retired.appendingPathComponent(fixture.cacheURL.lastPathComponent).appendingPathComponent(NotikaCacheCustody.metadataFilename)
                : retired.appendingPathComponent(NotikaCacheCustody.metadataFilename)
            #expect(try Data(contentsOf: oldUsage) == initial.originalData)
        }
    }

    @Test func borrowedOwnershipExpiresAndGenerationCannotAuthorizeCacheCreation() async throws {
        let fixture = try CacheCustodyFixture()
        defer { fixture.base.remove() }
        let escaped = try await fixture.withOwnership { ownership in
            try NotikaCacheCustody(identity: fixture.identity, ownership: ownership)
        }
        #expect(throws: ProjectAdmissionError.expiredOwnership) { try escaped.revalidateBeforeOperation() }
        #expect(throws: ProjectAdmissionError.expiredOwnership) { try escaped.publishUsage(sessionID: "escaped", usedAt: fixture.firstUse) }
        #expect(throws: ProjectAdmissionError.expiredOwnership) { try escaped.inheritedDirectoryDescriptors() }
        #expect(!FileManager.default.fileExists(atPath: fixture.usageURL.path))
        let generation = try NotikaProjectOwnershipPlan(generationFor: fixture.base.directory.path)
        _ = try await NotikaProjectAdmission().withOwnership(generation, registryRoot: fixture.base.registry.path, label: "generation cannot publish") { ownership in
            #expect(throws: NotikaCacheCustodyError.ownershipMismatch) {
                try NotikaCacheCustody(identity: fixture.identity, ownership: ownership)
            }
        }
    }

    @Test func foreignRepositoryOwnerCannotAuthorizeNamespaceCreation() async throws {
        // The filesystem root supplies a real foreign owner without privileged
        // chown or touching another user's files. Root-run tests have no such fixture.
        guard geteuid() != 0 else { return }
        let fixture = try CacheCustodyFixture()
        defer { fixture.base.remove() }
        let identity = try cacheTestIdentity(worktree: "/")
        let plan = try NotikaProjectOwnershipPlan(identity: identity)
        _ = try await NotikaProjectAdmission().withOwnership(plan, registryRoot: fixture.base.registry.path, label: "foreign owner refusal") { ownership in
            #expect(throws: NotikaCacheCustodyError.unsafeEntry("repository")) {
                try NotikaCacheCustody(identity: identity, ownership: ownership)
            }
        }
    }

    @Test func retiringCustodyClosesOnlyItsDescriptorsAndPreservesProjectLock() async throws {
        let fixture = try CacheCustodyFixture()
        defer { fixture.base.remove() }
        try await fixture.withOwnership { ownership in
            var custody: NotikaCacheCustody? = try NotikaCacheCustody(identity: fixture.identity, ownership: ownership)
            let descriptors = try #require(custody).inheritedDirectoryDescriptors()
            custody = nil
            for descriptor in descriptors { #expect(fcntl(descriptor, F_GETFD) == -1 && errno == EBADF) }
            let contender = try FileLock(resource: fixture.plan.orderedLeases[2].resource, paths: fixture.base.paths)
            defer { contender.release() }
            #expect(try !contender.tryAcquire())
            #expect(try ownership.inheritedDescriptors().count == 3)
        }
    }

    @Test func invalidSessionAndBackwardsUsagePreservePriorBytes() async throws {
        let fixture = try CacheCustodyFixture()
        defer { fixture.base.remove() }
        try await fixture.withOwnership { ownership in
            let custody = try NotikaCacheCustody(identity: fixture.identity, ownership: ownership)
            let prior = try custody.publishUsage(sessionID: "valid", usedAt: fixture.firstUse)
            #expect(throws: (any Error).self) { try custody.publishUsage(sessionID: "../escape", usedAt: fixture.firstUse) }
            #expect(throws: NotikaCacheUsageError.invalidTimeRange) {
                try custody.publishUsage(sessionID: "older", usedAt: fixture.firstUse.addingTimeInterval(-1))
            }
            #expect(throws: NotikaCacheCustodyError.invalidTimestamp) {
                try custody.publishUsage(sessionID: "invalid-time", usedAt: Date(timeIntervalSince1970: .infinity))
            }
            #expect(try Data(contentsOf: fixture.usageURL) == prior.originalData)
            #expect(try FileManager.default.contentsOfDirectory(atPath: custody.cacheDirectory) == [NotikaCacheCustody.metadataFilename])
        }
    }
}

enum UnsafeCacheUsage: CaseIterable, Sendable { case permissions, hardlink, symlink, fifo, directory }

private struct CacheCustodyFixture: Sendable {
    let base: CompilationFixture
    let identity: CacheCompatibilityIdentity
    let plan: NotikaProjectOwnershipPlan
    let firstUse = Date(timeIntervalSince1970: 1_788_256_800)
    var derivedDataURL: URL { base.directory.appendingPathComponent("DerivedData") }
    var cacheRootURL: URL { derivedDataURL.appendingPathComponent("AgentCaches") }
    var cacheURL: URL { URL(fileURLWithPath: plan.cacheDirectory!) }
    var usageURL: URL { cacheURL.appendingPathComponent(NotikaCacheCustody.metadataFilename) }

    init(schema: Int = 4) throws {
        base = try CompilationFixture()
        identity = try cacheTestIdentity(worktree: base.directory.path)
        plan = try NotikaProjectOwnershipPlan(identity: identity, admittedCacheKey: identity.cacheKey(metadataSchemaVersion: schema))
    }

    func withOwnership<Result: Sendable>(_ operation: @Sendable (ProjectOwnership) async throws -> Result) async throws -> Result {
        try await NotikaProjectAdmission().withOwnership(plan, registryRoot: base.registry.path, label: "cache custody fixture", operation: operation)
    }
}

private func cacheTestIdentity(worktree: String, scheme: String = "Notika",
                               inputDigest: String = String(repeating: "a", count: 64)) throws -> CacheCompatibilityIdentity {
    let digest = String(repeating: "a", count: 64)
    return try CacheCompatibilityIdentity(
        canonicalWorktree: worktree, toolchainHash: digest, gitlinks: [],
        submoduleStatusDigest: inputDigest, submoduleWorktreeDigest: inputDigest,
        projectGraphDigest: inputDigest, generatedGraphDigest: inputDigest, resolvedDependenciesDigest: inputDigest,
        scheme: scheme, configuration: "Debug", destinationFamily: "macos-arm64",
        buildFlags: ["-disableAutomaticPackageResolution"]
    )
}

private func cacheTestStatus(_ path: String) throws -> stat {
    var result = stat()
    guard lstat(path, &result) == 0 else { throw CompilationFixture.Failure.expected }
    return result
}
