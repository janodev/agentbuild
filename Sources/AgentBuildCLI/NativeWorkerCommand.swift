import AgentBuildCore
import ArgumentParser
import Darwin

/// A private descriptor-only entry; it grants no project route authority.
struct NativeWorkerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "_native-worker", shouldDisplay: false)

    @Option(name: .customLong("request-fd")) var requestDescriptor: Int32
    @Option(name: .customLong("report-fd")) var reportDescriptor: Int32
    @Option(name: .customLong("owner-fd")) var ownerDescriptor: Int32
    @Option var nonce: String

    mutating func run() async throws {
        // This private worker is a process boundary, so its native outputs can
        // be private without changing a reusable coordinator's global umask.
        _ = umask(0o077)
        let status = await NativeWorkerEntry().run(requestDescriptor: requestDescriptor,
                                                  reportDescriptor: reportDescriptor,
                                                  ownerDescriptor: ownerDescriptor, nonce: nonce)
        if status != 0 { throw ExitCode(status) }
    }
}
