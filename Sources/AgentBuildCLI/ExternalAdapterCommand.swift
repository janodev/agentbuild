import AgentBuildCLISupport
import Darwin
import Foundation

struct AdapterDispatchError: Error {
    let message: String
    let exitCode: Int32
}

/// Replace the router so the adapter retains the caller's process, terminal,
/// environment, signals, and inherited resource descriptors.
enum ExternalAdapterCommand {
    static func dispatchIfRequested(_ arguments: [String]) throws {
        guard let name = arguments.first, !name.hasPrefix("-"),
              !["doctor", "run", "help", "_native-worker"].contains(name) else { return }
        guard name.range(of: #"^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil else {
            throw AdapterDispatchError(message: "Invalid adapter name. Use lowercase letters, digits, and single hyphens.", exitCode: 64)
        }
        let router = try currentAgentBuildExecutable()
        let variable = "AGENTBUILD_ADAPTER_" + name.uppercased().replacingOccurrences(of: "-", with: "_") + "_EXECUTABLE"
        let executable = ProcessInfo.processInfo.environment[variable]
            ?? URL(fileURLWithPath: router).deletingLastPathComponent().appendingPathComponent("agentbuild-" + name).path
        guard executable.hasPrefix("/"), !executable.utf8.contains(0) else {
            throw AdapterDispatchError(message: "\(variable) must be a nonempty absolute executable path.", exitCode: 64)
        }
        var target = stat()
        guard lstat(executable, &target) == 0 else {
            let code = errno
            throw AdapterDispatchError(message: "Adapter '\(name)' is not installed at \(executable). Install its reviewed executable beside agentbuild or set \(variable).", exitCode: code == ENOENT ? 127 : 126)
        }
        guard target.st_mode & S_IFMT == S_IFREG, access(executable, X_OK) == 0 else {
            throw AdapterDispatchError(message: "Adapter must be an executable regular file: \(executable)", exitCode: 126)
        }
        var own = stat()
        guard stat(router, &own) == 0 else {
            throw AdapterDispatchError(message: "Cannot inspect the current executable.", exitCode: 70)
        }
        guard target.st_dev != own.st_dev || target.st_ino != own.st_ino else {
            throw AdapterDispatchError(message: "Adapter cannot refer to the agentbuild router itself.", exitCode: 64)
        }
        var argv = ([executable] + arguments.dropFirst()).map { strdup($0) }
        defer { argv.forEach { free($0) } }
        guard argv.allSatisfy({ $0 != nil }) else {
            throw AdapterDispatchError(message: "Cannot allocate adapter arguments.", exitCode: 70)
        }
        argv.append(nil)
        execv(executable, &argv)
        let code = errno
        throw AdapterDispatchError(message: "Cannot execute adapter at \(executable): \(String(cString: strerror(code)))", exitCode: code == ENOENT ? 127 : 126)
    }
}
