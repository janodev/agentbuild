@testable import AgentBuildCore
import Darwin
import Foundation
import Testing

@Suite("Notika interactive product and host custody")
struct NotikaInteractiveDriverTests {
    @Test func productAdmitsOnlyExactBuiltBundleAndDetectsReplacement() throws {
        let fixture = try InteractiveFixture()
        defer { fixture.remove() }
        try fixture.product()
        let product = try NotikaInteractiveProduct(cacheDirectory: fixture.path + "/cache")
        #expect(product.executable.path == fixture.executable)
        #expect(product.executable.digest.count == 64 && product.infoPlist.digest.count == 64)
        try product.revalidate()
        try FileManager.default.moveItem(atPath: fixture.executable, toPath: fixture.path + "/old-executable")
        try Data("replacement".utf8).write(to: URL(fileURLWithPath: fixture.executable))
        #expect(chmod(fixture.executable, 0o755) == 0)
        #expect(throws: NotikaInteractiveError.productChanged) { try product.revalidate() }
    }

    @Test(arguments: ["bundle-id", "executable-name", "symlink", "hardlink", "writable", "empty"])
    func invalidProductNeverBecomesLaunchAuthority(_ fault: String) throws {
        let fixture = try InteractiveFixture()
        defer { fixture.remove() }
        try fixture.product(identifier: fault == "bundle-id" ? "foreign.app" : "dev.jano.apple.notes",
                            executableName: fault == "executable-name" ? "Foreign" : "Notika")
        switch fault {
        case "symlink":
            try FileManager.default.moveItem(atPath: fixture.executable, toPath: fixture.path + "/target")
            #expect(symlink((fixture.path + "/target"), fixture.executable) == 0)
        case "hardlink": #expect(link(fixture.executable, fixture.path + "/outside") == 0)
        case "writable": #expect(chmod(fixture.executable, 0o777) == 0)
        case "empty": try Data().write(to: URL(fileURLWithPath: fixture.executable))
        default: break
        }
        #expect(throws: (any Error).self) { _ = try NotikaInteractiveProduct(cacheDirectory: fixture.path + "/cache") }
    }

    @Test(arguments: ["unlocked", "shared", "close-on-exec", "partial"])
    func macOSMarkersCannotInventActualExclusiveHostOwnership(_ fault: String) throws {
        let fixture = try InteractiveFixture()
        defer { fixture.remove() }
        let descriptor = try fixture.openHost(mode: fault == "shared" ? LOCK_SH : fault == "unlocked" ? nil : LOCK_EX)
        defer { _ = Darwin.close(descriptor) }
        if fault == "close-on-exec" { #expect(fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0) }
        var environment = fixture.environment
        if fault == "partial" { environment["SIMLEASE_HOST_RESOURCE"] = nil }
        #expect(throws: (any Error).self) { _ = try NotikaInteractiveHostLease.admit(environment: environment) }
        // Admission failure may never change a genuinely held shared lease.
        if fault == "shared" {
            let contender = open(fixture.lockPath, O_RDWR | O_CLOEXEC)
            defer { _ = Darwin.close(contender) }
            #expect(contender >= 0)
            #expect(flock(contender, LOCK_EX | LOCK_NB) != 0)
        }
    }

    @Test func exactHostCustodySurvivesCallerCloseAndRefusesUnlock() throws {
        let fixture = try InteractiveFixture()
        defer { fixture.remove() }
        let inherited = try fixture.openHost(mode: LOCK_EX)
        let lease = try NotikaInteractiveHostLease.admit(environment: fixture.environment)
        #expect(fcntl(lease.descriptor, F_GETFD) & FD_CLOEXEC != 0)
        #expect(Darwin.close(inherited) == 0)
        try lease.revalidate()
        let contender = open(fixture.lockPath, O_RDWR | O_CLOEXEC)
        defer { _ = Darwin.close(contender) }
        #expect(contender >= 0)
        #expect(flock(contender, LOCK_SH | LOCK_NB) != 0)
        #expect(flock(lease.descriptor, LOCK_UN) == 0)
        #expect(throws: NotikaInteractiveError.hostLeaseInvalid) { try lease.revalidate() }
        #expect(throws: NotikaInteractiveError.hostLeaseInvalid) { try lease.revalidate() }
    }

    @Test func hostPathReplacementCannotBorrowRetainedInodeCustody() throws {
        let fixture = try InteractiveFixture()
        defer { fixture.remove() }
        let inherited = try fixture.openHost(mode: LOCK_EX)
        defer { _ = Darwin.close(inherited) }
        let lease = try NotikaInteractiveHostLease.admit(environment: fixture.environment)
        try FileManager.default.moveItem(atPath: fixture.lockPath, toPath: fixture.path + "/old-lock")
        try Data().write(to: URL(fileURLWithPath: fixture.lockPath))
        #expect(chmod(fixture.lockPath, 0o600) == 0)
        #expect(throws: NotikaInteractiveError.hostLeaseInvalid) { try lease.revalidate() }
    }

    @Test func processEvidenceIncludesBirthParentOwnerAndExactKernelExecutable() throws {
        let first = try NotikaInteractiveProcessIdentity.observe(getpid())
        let second = try NotikaInteractiveProcessIdentity.observe(getpid())
        #expect(first == second)
        #expect(first.processID == getpid() && first.parentProcessID == getppid())
        #expect(first.ownerUID == geteuid() && first.startSeconds > 0 && first.startMicroseconds < 1_000_000)
        #expect(first.executable.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: first.executable))
        #expect(throws: NotikaInteractiveError.processIdentityInvalid) { _ = try NotikaInteractiveProcessIdentity.observe(-1) }
    }

    @Test func driverRejectsSpoofedHostBeforeCreatingSessionOrInvokingBuild() async throws {
        let fixture = try InteractiveFixture()
        defer { fixture.remove() }
        var observedFailure = false
        do {
            _ = try await NotikaInteractiveDriver().run(repository: fixture.path, helperExecutable: "/missing-helper",
                                                       environment: fixture.environment)
            Issue.record("An environment claim without actual host custody cannot launch or create a session")
        } catch RetainedArtifactError.systemCall(_, let code) {
            observedFailure = code == ENOENT
        } catch NotikaInteractiveError.hostLeaseInvalid {
            observedFailure = true
        }
        #expect(observedFailure)
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "/Artifacts"))
    }
}

private struct InteractiveFixture {
    let path: String
    var bundle: String { path + "/cache/Build/Products/Debug/Notika.app" }
    var executable: String { bundle + "/Contents/MacOS/Notika" }
    var lockPath: String { path + "/host-locks/macos-ui.lock" }
    var environment: [String: String] {
        ["SIMLEASE_HOME": path, "SIMLEASE_HOST_RESOURCE": "macos-ui", "SIMLEASE_MACOS_UI": "1",
         "SIMLEASE_SESSION_ID": "BC2C843D-0DD2-4ECD-90E6-94893582BD5B", "PATH": "/usr/bin:/bin"]
    }
    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notika-interactive-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        guard let pointer = realpath(url.path, nil) else { throw NotikaInteractiveError.productInvalid }
        defer { free(pointer) }
        path = String(cString: pointer)
        try FileManager.default.createDirectory(atPath: path + "/host-locks", withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }
    func product(identifier: String = "dev.jano.apple.notes", executableName: String = "Notika") throws {
        try FileManager.default.createDirectory(atPath: bundle + "/Contents/MacOS", withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data("fixture executable bytes".utf8).write(to: URL(fileURLWithPath: executable))
        guard chmod(executable, 0o755) == 0 else { throw NotikaInteractiveError.productInvalid }
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier,
            "CFBundleExecutable": executableName], format: .binary, options: 0)
        try plist.write(to: URL(fileURLWithPath: bundle + "/Contents/Info.plist"))
        guard chmod(bundle + "/Contents/Info.plist", 0o644) == 0 else { throw NotikaInteractiveError.productInvalid }
    }
    func openHost(mode: Int32?) throws -> Int32 {
        let descriptor = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw NotikaInteractiveError.hostLeaseInvalid }
        guard fcntl(descriptor, F_SETFD, 0) == 0,
              mode.map({ flock(descriptor, $0 | LOCK_NB) == 0 }) ?? true else {
            _ = Darwin.close(descriptor)
            throw NotikaInteractiveError.hostLeaseInvalid
        }
        return descriptor
    }
    func remove() { try? FileManager.default.removeItem(atPath: path) }
}
