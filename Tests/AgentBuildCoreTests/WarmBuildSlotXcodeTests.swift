import AgentBuildCore
import AgentBuildTestSupport
import AgentLeaseCore
import Foundation
import Testing

extension WarmBuildSlotTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTBUILD_TEST_XCODE_SLOT"] == "1"))
    func xcodeReusesUnchangedInputsAndBuildsCorrectProductAfterSwitching() async throws {
        let fixture = try Fixture()
        defer { fixture.base.remove() }
        let manifest = """
            // swift-tools-version: 6.4
            import PackageDescription
            let package = Package(name: "SlotProbe", platforms: [.macOS("27.0")], targets: [.executableTarget(name: "SlotProbe")])
            """
        let main = "Sources/SlotProbe/main.swift"
        let fixedDate = Date(timeIntervalSince1970: 1_000_000)
        for root in [fixture.a, fixture.b] {
            try manifest.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/SlotProbe"),
                                                    withIntermediateDirectories: true)
            let file = root.appendingPathComponent(main)
            try Data("print(\"A\")".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: file.path)
        }
        for (index, root) in [fixture.a, fixture.b, fixture.b, fixture.a].enumerated() {
            if index == 2 {
                try Data("print(\"B\")".utf8).write(to: root.appendingPathComponent(main))
            }
            try await fixture.use(root) { slot in
                let phase = try await HostCompilationAdmission().withLease { lease in
                    try await CapturedNativePhaseRunner().run(
                        helperExecutable: AgentBuildTestPaths.packageRoot.appendingPathComponent(".build/debug/agentbuild").path,
                        command: DarwinWorkloadCommand(executable: "/usr/bin/xcodebuild", arguments: [
                            "-scheme", "SlotProbe", "-destination", "platform=macOS", "-configuration", "Debug",
                            "-derivedDataPath", slot.derivedDataDirectory, "build", "CODE_SIGNING_ALLOWED=NO",
                        ], workingDirectory: slot.sourceDirectory),
                        retainedLockDescriptors: slot.leaseDescriptors + lease.inheritedDescriptors(),
                        nativeWorkingDirectoryDescriptor: slot.sourceDirectoryDescriptor,
                        artifactRoot: fixture.base.directory.path + "/logs")
                }
                let log = try String(contentsOfFile: phase.rawCapture.combined.path, encoding: .utf8)
                try #require(phase.observation.termination == RunTermination(kind: .exit, value: 0),
                             Comment(rawValue: String(log.suffix(4000))))
                try #require(phase.observation.failures.isEmpty)
                let compiled = log.split(separator: "\n").contains { $0.hasPrefix("SwiftCompile ") }
                if index == 0 { #expect(compiled) }
                if index == 1 { #expect(!compiled) }
                let product = slot.derivedDataDirectory + "/Build/Products/Debug/SlotProbe"
                let output = try await RepositoryCommandCapture().capture(
                    arguments: [product], workingDirectory: slot.sourceDirectory, environment: [:])
                #expect(String(decoding: output, as: UTF8.self) == (index == 2 ? "B\n" : "A\n"))
            }
        }
    }
}
