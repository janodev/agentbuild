import AgentBuildCore
import Foundation
import Testing

@Suite("ABDiff public CLI contract")
struct ABDiffCommandTests {
    @Test(arguments: ["plan", "build", "generate", "run", "install"])
    func helpExposesTheSupportedPublicOptions(_ command: String) async throws {
        let result = try await abdiffCLI([command, "--help"])
        #expect(result.termination == .exited(0))
        #expect(result.standardOutput.contains("--repository"))
        #expect(!result.standardOutput.lowercased().contains("simslim"))
        if command == "generate" {
            #expect(result.standardOutput.contains("--cached"))
            #expect(!result.standardOutput.contains("--only-testing"))
        } else {
            for option in ["--route", "--platform", "--configuration", "--file", "--method", "--only-testing", "--device"] {
                #expect(result.standardOutput.contains(option))
            }
        }
    }

    @Test func publicPlanningPreservesRepeatedLiteralSelectorsAndDoesNotAcquireOrBuild() async throws {
        let fixture = try ABDiffPlanFixture()
        defer { fixture.remove() }
        let bin = try abdiffFixtureTools(in: fixture)
        let selectors = ["FeatureTests/run(value:_:)", "WordsTests/`literal $(touch pwn) café`()"]
        let result = try await abdiffCLI([
            "plan", "--repository", fixture.path, "--route", "test-unit-focused",
            "--platform", "macos", "--configuration", "DebugUITests",
            "--only-testing", selectors[0], "--only-testing", selectors[1],
        ], fixtureBin: bin)
        #expect(result.termination == .exited(0), Comment(rawValue: result.standardError))
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8)) as? [String: Any])
        #expect(object["admissionEstablished"] as? Bool == false)
        let arguments = try #require(object["logicalArguments"] as? [String])
        #expect(arguments.filter { $0.hasPrefix("-only-testing:") } == selectors.map { "-only-testing:ABDiffTests/" + $0 })
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "/Artifacts"))
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "/DerivedData"))
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "/pwn"))
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "/unexpected-native-command"))
        #expect(FileManager.default.fileExists(atPath: fixture.path + "/tool-probes"))
    }

    @Test(arguments: [
        ["--route", "unsupported"],
        ["--route", "test-unit-file", "--file", "Suite", "--method", "bad\nmethod"],
        ["--route", "test-unit-file", "--method", "testExample"],
        ["--route", "test-unit-focused", "--only-testing", "Suite//method()"],
        ["--route", "build", "--file", "Suite"],
        ["--configuration", "Unknown"],
        ["--platform", "ipad-device"],
        ["--platform", "ipad-device", "--device", "Alejandro’s iPad"],
    ])
    func invalidNativeOptionsFailBeforeProbingTools(_ options: [String]) async throws {
        let fixture = try ABDiffPlanFixture()
        defer { fixture.remove() }
        let bin = try abdiffFixtureTools(in: fixture)
        let result = try await abdiffCLI(["plan", "--repository", fixture.path] + options, fixtureBin: bin)
        #expect(result.termination != .exited(0))
        #expect(!result.standardError.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "/tool-probes"))
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "/unexpected-native-command"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.path).sorted() == ["Makefile", "Project.swift", "bin"])
    }

    @Test(arguments: ["macos", "ipad-simulator"])
    func nativeUiRequestsEnterOneLiteralOuterLeaseAndPreserveItsExitStatus(_ platform: String) async throws {
        let fixture = try ABDiffPlanFixture()
        defer { fixture.remove() }
        let bin = try abdiffFixtureTools(in: fixture, leaseStatus: 37)
        let method = "`literal $(touch pwn) words`()"
        var arguments = ["build", "--repository", fixture.path, "--platform", platform,
                         "--route", "test-ui-file", "--file", "SomeUITests", "--method", method]
        if platform == "ipad-simulator" { arguments += ["--device", "iPad Air 13-inch (M4)"] }
        let result = try await abdiffCLI(arguments, fixtureBin: bin)
        #expect(result.termination == .exited(37))
        let recorded = try Data(contentsOf: fixture.directory.appendingPathComponent("lease-arguments"))
            .split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        let expectedTail = ["abdiff"] + arguments
        #expect(Array(recorded.suffix(expectedTail.count)) == expectedTail)
        #expect(recorded.first == (platform == "macos" ? "macos-ui" : "run"))
        #expect(recorded.filter { $0 == "--" }.count == 1)
        if platform == "macos" {
            #expect(recorded.contains("/usr/bin/caffeinate"))
            #expect(recorded.contains("-dimsu"))
        } else {
            let index = try #require(recorded.firstIndex(of: "--device"))
            #expect(recorded[index + 1] == "iPad Air 13-inch (M4)")
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "/unexpected-native-command"))
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "/Artifacts"))
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "/pwn"))
    }

    @Test func invalidRepositoryAndWaitOptionsCannotCreateExecutionArtifacts() async throws {
        let relative = try await abdiffCLI(["plan", "--repository", "relative/ABDiff"])
        #expect(relative.termination != .exited(0))
        #expect(relative.standardError.contains("absolute"))
        let fixture = try ABDiffPlanFixture()
        defer { fixture.remove() }
        for command in ["build", "generate", "run"] {
            let result = try await abdiffCLI([command, "--repository", fixture.path, "--wait-seconds=-1"])
            #expect(result.termination != .exited(0))
            #expect(result.standardError.contains("finite and nonnegative"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.path).sorted() == ["Makefile", "Project.swift"])
    }

    @Test(arguments: ["build", "install", "launch", "none"])
    func physicalDeploymentStopsAtTheFailedNativeStep(_ failedStep: String) async throws {
        let fixture = try ABDiffPlanFixture(literalPath: false)
        defer { fixture.remove() }
        let bin = try abdiffFixtureTools(in: fixture)
        try FileManager.default.createDirectory(atPath: fixture.path + "/ABDiff.xcworkspace", withIntermediateDirectories: false)
        try writeABDiffDeploymentTools(bin: bin, failedStep: failedStep)
        let device = "00000000-0000000000000000"
        let result = try await abdiffCLI([
            "install", "--repository", fixture.path, "--platform", "ipad-device", "--device", device,
            "--lease-home", fixture.path + "/leases", "--json",
        ], fixtureBin: bin)
        #expect(result.termination == .exited(failedStep == "none" ? 0 : 37), Comment(rawValue: result.standardError))
        let steps = try String(contentsOfFile: fixture.path + "/native-steps", encoding: .utf8).split(separator: "\n").map(String.init)
        let expected = failedStep == "build" ? ["build"] : failedStep == "install" ? ["build", "install"] : ["build", "install", "launch"]
        #expect(steps == expected)
        let report = try #require(JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8)) as? [String: Any])
        #expect(report["status"] as? String == (failedStep == "none" ? "succeeded" : "failed"))
        let phases = try #require(report["phases"] as? [[String: Any]])
        #expect(phases.count == expected.count)
        for phase in phases.dropFirst() {
            #expect(phase["compilation"] as? Bool == false)
            let arguments = try #require(phase["arguments"] as? [String])
            let target = try #require(arguments.firstIndex(of: "--device"))
            #expect(arguments[target + 1] == device)
            #expect(!arguments.contains("simctl"))
        }
        if phases.count > 1 {
            let arguments = try #require(phases[1]["arguments"] as? [String])
            #expect(arguments.contains(try #require(report["productPath"] as? String)))
        }
        if phases.count > 2 {
            let arguments = try #require(phases[2]["arguments"] as? [String])
            #expect(arguments.contains("fixture.abdiff.from-built-product"))
            #expect(!arguments.contains("--console"))
        }
    }
}

private func abdiffCLI(_ arguments: [String], fixtureBin: String? = nil) async throws -> CommandResult {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let executable = repository.appendingPathComponent(".build/debug/agentbuild").path
    let fixtureRoot = fixtureBin.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
    var environmentArguments = ["-i", "PATH=" + (fixtureBin.map { $0 + ":/usr/bin:/bin" } ?? "/__agentbuild_abdiff_no_tools__"), "DEVELOPER_DIR=/Fixture/Xcode/Developer"]
    if let fixtureBin {
        environmentArguments += ["ABDIFF_FIXTURE_BIN=" + fixtureBin, "ABDIFF_FIXTURE_ROOT=" + URL(fileURLWithPath: fixtureBin).deletingLastPathComponent().path,
                                 "AGENTLEASE_COMPILE_HOME=" + URL(fileURLWithPath: fixtureBin).deletingLastPathComponent().path + "/compile-leases"]
    }
    return try await CommandRunner(outputLimit: 128 * 1_024).run(
        executable: "/usr/bin/env", arguments: environmentArguments + [executable, "abdiff"] + arguments,
        workingDirectory: fixtureRoot ?? repository.path, timeout: .seconds(10))
}

private func abdiffFixtureTools(in fixture: ABDiffPlanFixture, leaseStatus: Int32? = nil) throws -> String {
    let directory = fixture.directory.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    var tools = [
        "xcrun": #"""
        #!/bin/sh
        printf '%s\n' xcrun >> "$ABDIFF_FIXTURE_ROOT/tool-probes"
        case "$1|$2|$3|$4" in
          '--find|xcodebuild||') printf '%s\n' "$ABDIFF_FIXTURE_BIN/xcodebuild" ;;
          '--find|swift||') printf '%s\n' "$ABDIFF_FIXTURE_BIN/swift" ;;
          '--sdk|macosx|--show-sdk-path|') printf '%s\n' '/Fixture/Xcode/Developer/SDKs/MacOSX27.sdk' ;;
          '--sdk|macosx|--show-sdk-version|') printf '%s\n' '27.0' ;;
          '--sdk|iphoneos|--show-sdk-path|') printf '%s\n' '/Fixture/Xcode/Developer/SDKs/iPhoneOS27.sdk' ;;
          '--sdk|iphoneos|--show-sdk-version|') printf '%s\n' '27.0' ;;
          *) printf '%s\n' unexpected > "$ABDIFF_FIXTURE_ROOT/unexpected-native-command"; exit 98 ;;
        esac
        """#,
        "xcodebuild": #"""
        #!/bin/sh
        printf '%s\n' xcodebuild >> "$ABDIFF_FIXTURE_ROOT/tool-probes"
        if [ "$#" -eq 1 ] && [ "$1" = '-version' ]; then
          printf '%s\n' 'Xcode 27.0' 'Build version 18A123'
        else
          printf '%s\n' unexpected > "$ABDIFF_FIXTURE_ROOT/unexpected-native-command"; exit 98
        fi
        """#,
        "swift": #"""
        #!/bin/sh
        printf '%s\n' swift >> "$ABDIFF_FIXTURE_ROOT/tool-probes"
        if [ "$#" -eq 1 ] && [ "$1" = '--version' ]; then
          printf '%s\n' 'Apple Swift version 6.4'
        else
          printf '%s\n' unexpected > "$ABDIFF_FIXTURE_ROOT/unexpected-native-command"; exit 98
        fi
        """#,
        "simlease": #"""
        #!/bin/sh
        printf '%s\n' unexpected > "$ABDIFF_FIXTURE_ROOT/unexpected-native-command"
        exit 98
        """#,
        "simslim": #"""
        #!/bin/sh
        printf '%s\n' unexpected > "$ABDIFF_FIXTURE_ROOT/unexpected-native-command"
        exit 98
        """#,
    ]
    if let leaseStatus {
        tools["simlease"] = "#!/bin/sh\nprintf '%s\\0' \"$@\" > \"$ABDIFF_FIXTURE_ROOT/lease-arguments\"\nexit \(leaseStatus)\n"
    }
    for (name, script) in tools {
        let url = directory.appendingPathComponent(name)
        try Data((script + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    return directory.path
}

private func writeABDiffDeploymentTools(bin: String, failedStep: String) throws {
    let tools = [
        "git": "#!/bin/sh\nexit 0\n",
        "xcodebuild": #"""
        #!/bin/sh
        if [ "$1" = '-version' ]; then printf '%s\n' 'Xcode 27.0' 'Build version 18A123'; exit 0; fi
        printf '%s\n' build >> "$ABDIFF_FIXTURE_ROOT/native-steps"
        if [ '__FAILED_STEP__' = build ]; then exit 37; fi
        while [ "$#" -gt 0 ]; do
          if [ "$1" = '-derivedDataPath' ]; then cache="$2"; break; fi
          shift
        done
        product="$cache/Build/Products/Debug-iphoneos/ABDiffIPad.app"
        mkdir -p "$product"
        printf '%s\n' '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>fixture.abdiff.from-built-product</string></dict></plist>' > "$product/Info.plist"
        """#,
    ]
    for (name, script) in tools {
        let path = bin + "/" + name
        try Data((script.replacingOccurrences(of: "__FAILED_STEP__", with: failedStep) + "\n").utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    }
    let xcrunPath = bin + "/xcrun"
    let original = try String(contentsOfFile: xcrunPath, encoding: .utf8)
    let devicePrefix = #"""
    #!/bin/sh
    if [ "$1" = devicectl ]; then
      if [ "$3" = install ]; then step=install; else step=launch; fi
      printf '%s\n' "$step" >> "$ABDIFF_FIXTURE_ROOT/native-steps"
      if [ '__FAILED_STEP__' = "$step" ]; then exit 37; fi
      exit 0
    fi
    """#.replacingOccurrences(of: "__FAILED_STEP__", with: failedStep)
    try Data((devicePrefix + "\n" + original).utf8).write(to: URL(fileURLWithPath: xcrunPath))
}
