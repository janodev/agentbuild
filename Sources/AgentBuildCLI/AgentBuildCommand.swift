import AgentBuildCLISupport
import AgentBuildCore
import ArgumentParser
import Darwin
import Foundation

@main
enum AgentBuildEntry {
    static func main() async {
        do {
            try ExternalAdapterCommand.dispatchIfRequested(Array(CommandLine.arguments.dropFirst()))
        } catch let error as AdapterDispatchError {
            FileHandle.standardError.write(Data("agentbuild: \(error.message)\n".utf8))
            exit(error.exitCode)
        } catch {
            FileHandle.standardError.write(Data("agentbuild: \(error)\n".utf8))
            exit(70)
        }
        await AgentBuildCommand.main()
    }
}

struct AgentBuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agentbuild",
        abstract: "Coordinate owned commands and preserve their native results and logs.",
        discussion: "Run explicitly leased commands, or use agentbuild <adapter> to delegate to an installed sibling agentbuild-<adapter> executable. Adapters are installed separately by their owning projects.",
        version: AgentBuild.version,
        subcommands: [DoctorCommand.self, RunCommand.self, NativeWorkerCommand.self]
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
