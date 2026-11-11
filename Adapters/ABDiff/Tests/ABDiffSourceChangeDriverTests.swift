@testable import ABDiffAdapter
import AgentBuildCore
import AgentBuildTestSupport
import AgentLeaseCore
import CryptoKit
import Darwin
import Foundation
import Testing

@Suite("ABDiff expected source changes through owned execution")
struct ABDiffSourceChangeDriverTests {
    @Test(arguments: ABDiffSourceChangeScenario.allCases)
    func expectedChangesKeepNativeAndVerificationOutcomesSeparate(
        _ scenario: ABDiffSourceChangeScenario
    ) async throws {
        let fixture = try ABDiffSourceChangeDriverFixture(scenario: scenario)
        defer { fixture.remove() }
        try await fixture.initializeGit()
        _ = try RetainedArtifactDirectory(path: fixture.repository)
        let allowedPaths = scenario.allowsVersionChange ? ["BuildNumber.xcconfig"] : []
        let request = try ABDiffProjectRequest(
            repository: fixture.repository,
            route: "build-release",
            allowedSourceChanges: allowedPaths
        )

        let result = try await ABDiffProjectDriver().run(
            request: request,
            helperExecutable: fixture.helper,
            environment: fixture.environment,
            waitSeconds: 30
        )
        let report = try #require(JSONSerialization.jsonObject(with: result.jsonData()) as? [String: Any])
        let diagnostics = Comment(rawValue: String(decoding: try result.jsonData(), as: UTF8.self))

        #expect(result.status == scenario.expectedStatus, diagnostics)
        #expect(result.exitCode == scenario.expectedExitCode, diagnostics)
        #expect(result.nativeTermination == RunTermination(kind: .exit, value: scenario.nativeExitCode))
        #expect(result.orchestrationFailures.isEmpty, diagnostics)
        #expect(result.publicationFailures.isEmpty, diagnostics)
        #expect(result.rawCaptures.count == 2)
        #expect(result.rawCaptures.allSatisfy { $0.captureComplete })
        #expect(report["sourceDrift"] as? Bool == true)
        #expect(report["unexpectedSourceDrift"] as? Bool == scenario.hasUnexpectedChange)
        #expect(report["toolDrift"] as? Bool == false)

        // The allowance changes the verdict, while the raw observations still
        // show that the build changed a tracked input.
        let before = try #require(report["sourceBefore"] as? [String: String])
        let after = try #require(report["sourceAfter"] as? [String: String])
        #expect(before["diff"] != after["diff"])
        let recordedRequest = try #require(report["request"] as? [String: Any])
        #expect(recordedRequest["allowedSourceChanges"] as? [String] == allowedPaths)
        let allowedChanges = try #require(report["allowedSourceChanges"] as? [[String: Any]])
        if scenario.allowsVersionChange {
            let change = try #require(allowedChanges.first)
            #expect(allowedChanges.count == 1)
            #expect(change["path"] as? String == "BuildNumber.xcconfig")
            #expect(change["beforeSHA256"] as? String == fixture.digest(fixture.originalVersion))
            #expect(change["afterSHA256"] as? String == fixture.digest(fixture.updatedVersion))
            #expect(change["changed"] as? Bool == true)
        } else {
            #expect(allowedChanges.isEmpty)
        }

        let session = try #require(result.sessionPath)
        let persisted = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: session + "/manifest.json"))
        ) as? [String: Any])
        #expect(persisted["status"] as? String == scenario.expectedStatus)
        #expect(persisted["sourceDrift"] as? Bool == true)
        #expect(persisted["unexpectedSourceDrift"] as? Bool == scenario.hasUnexpectedChange)
    }
}

enum ABDiffSourceChangeScenario: String, CaseIterable, Sendable {
    case allowedVersionChange
    case versionChangeWithoutAllowance
    case allowedVersionAndUnexpectedSourceChange
    case nativeFailureWithAllowedChange

    var allowsVersionChange: Bool { self != .versionChangeWithoutAllowance }
    var changesOtherSource: Bool { self == .allowedVersionAndUnexpectedSourceChange }
    var nativeExitCode: Int32 { self == .nativeFailureWithAllowedChange ? 23 : 0 }
    var hasUnexpectedChange: Bool { !allowsVersionChange || changesOtherSource }
    var expectedStatus: String {
        nativeExitCode != 0 ? "failed" : hasUnexpectedChange ? "inconclusive" : "succeeded"
    }
    var expectedExitCode: Int32 {
        nativeExitCode != 0 ? nativeExitCode : hasUnexpectedChange ? 70 : 0
    }
}

private struct ABDiffSourceChangeDriverFixture: Sendable {
    enum Failure: Error { case fileSystem(Int32) }
    let directory: URL
    let helper: String
    let originalVersion = "CURRENT_PROJECT_VERSION = 113\n"
    let updatedVersion = "CURRENT_PROJECT_VERSION = 114\n"

    var repository: String { directory.appendingPathComponent("checkout").path }
    var environment: [String: String] {
        [
            "PATH": directory.appendingPathComponent("tools").path + ":/usr/bin:/bin",
            "AGENTLEASE_HOME": directory.appendingPathComponent("registry").path,
        ]
    }

    init(scenario: ABDiffSourceChangeScenario) throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentbuild-abdiff-source-driver-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        // Foundation can normalize /private/var back to /var. Retained custody
        // requires the physical spelling with no symlink in any ancestor.
        guard let canonical = temporary.path.withCString({ realpath($0, nil) }) else {
            throw Failure.fileSystem(errno)
        }
        directory = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        free(canonical)
        let sourceRoot = AgentBuildTestPaths.packageRoot
        helper = sourceRoot.appendingPathComponent(".build/debug/agentbuild").path
        try write("checkout/.gitignore", "/Artifacts/\n/DerivedData/\n")
        try write("checkout/Project.swift", "// Fixture project\n")
        try write("checkout/Makefile", "# Fixture Makefile\n")
        try write("checkout/ABDiff.xcworkspace/contents.xcworkspacedata", "<Workspace/>\n")
        try write("checkout/BuildNumber.xcconfig", originalVersion)
        try write("checkout/Source.swift", "// Original source\n")
        try script("checkout/Scripts/check-native-dependencies.sh", "printf 'Fixture dependencies ready\\n'")
        try script("tools/xcode-select", #"""
        [ "$#" = 1 ] && [ "$1" = -p ] || exit 97
        printf '%s\n' "${0%/*}/Developer"
        """#)
        try script("tools/xcrun", #"""
        case "$*" in
          '--find xcodebuild') printf '%s\n' "${0%/*}/xcodebuild" ;;
          '--find swift') printf '%s\n' "${0%/*}/swift" ;;
          '--sdk macosx --show-sdk-path') printf '%s\n' "${0%/*}/SDK" ;;
          '--sdk macosx --show-sdk-version') printf '%s\n' '27.0' ;;
          *) exit 97 ;;
        esac
        """#)
        try script("tools/swift", #"""
        [ "$#" = 1 ] && [ "$1" = --version ] || exit 97
        printf '%s\n' 'Apple Swift version 6.4'
        """#)
        let sourceMutation = scenario.changesOtherSource
            ? "printf '%s\\n' '// Unexpected edit' > \"$SRCROOT/Source.swift\"\n" : ""
        try script("tools/xcodebuild", #"""
        if [ "$#" = 1 ] && [ "$1" = -version ]; then
          printf '%s\n' 'Xcode 27.0' 'Build version Fixture'
          exit 0
        fi
        is_build=0
        for argument in "$@"; do
          case "$argument" in build) is_build=1 ;; esac
        done
        [ "$is_build" = 1 ] || exit 97
        printf '%s\n' 'CURRENT_PROJECT_VERSION = 114' > "$SRCROOT/BuildNumber.xcconfig"
        """# + "\n" + sourceMutation + "printf 'Fixture native build finished\\n'\nexit \(scenario.nativeExitCode)")
    }

    func initializeGit() async throws {
        let capture = try RepositoryCommandCapture()
        for arguments in [
            ["git", "init", "-q"],
            ["git", "add", "."],
            ["git", "-c", "user.name=AgentBuild Fixture", "-c", "user.email=fixture@example.invalid",
             "-c", "commit.gpgsign=false", "commit", "-qm", "Initial fixture"],
        ] {
            _ = try await capture.capture(
                arguments: arguments, workingDirectory: repository, environment: ["PATH": "/usr/bin:/bin"]
            )
        }
    }

    func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func write(_ relative: String, _ contents: String) throws {
        let file = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(contents.utf8).write(to: file)
    }

    private func script(_ relative: String, _ body: String) throws {
        try write(relative, "#!/bin/sh\nset -eu\n" + body + "\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.appendingPathComponent(relative).path)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
