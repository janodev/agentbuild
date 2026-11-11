import ABDiffAdapter
import AgentBuildCore
import ArgumentParser
import Foundation
import GunshipAdapter
import NotikaAdapter

@main
struct AgentBuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agentbuild",
        abstract: "Coordinate owned commands and preserve their native results and logs.",
        discussion: "The Notika, ABDiff, and Gunship adapters run owned development workflows; run executes generic explicitly leased commands.",
        version: AgentBuild.version,
        subcommands: [DoctorCommand.self, RunCommand.self, NotikaCommand.self, ABDiffCommand.self, GunshipCommand.self, NativeWorkerCommand.self,
                      NotikaDocPreviewCommand.self]
    )
}

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Inspect local tooling with read-only version probes."
    )

    @Flag(help: "Print a JSON report.")
    var json = false

    mutating func run() async throws {
        let report = await ToolchainDoctor().inspect()
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
        } else {
            print("agentbuild \(report.toolVersion) (\(report.stage))")
            for tool in report.tools {
                let requirement = tool.required ? "required" : "optional"
                print("\(tool.name): \(tool.status.rawValue) (\(requirement))\(tool.path.map { " — \($0)" } ?? "")")
                if let detail = tool.detail { print("  \(detail)") }
            }
            print("Bootstrap prerequisites: \(report.ready ? "ready" : "incomplete")")
        }
        if !report.ready { throw ExitCode.failure }
    }
}
