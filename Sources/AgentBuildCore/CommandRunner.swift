import Darwin
import Foundation
import Subprocess

public enum CommandTermination: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)
}

public struct CommandResult: Equatable, Sendable {
    public let standardOutput: String
    public let standardError: String
    public let termination: CommandTermination
}

public enum CommandRunnerError: Error, Equatable {
    case timedOut
    case missingResult
    case spawnConfiguration(Int32)
}

/// Runs bounded diagnostic commands. Project build admission is a separate layer.
public struct CommandRunner: Sendable {
    public let outputLimit: Int

    public init(outputLimit: Int = 16 * 1_024) {
        self.outputLimit = outputLimit
    }

    public func run(
        executable: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        timeout: Duration = .seconds(10)
    ) async throws -> CommandResult {
        try await withThrowingTaskGroup(of: CommandResult.self) { group in
            group.addTask {
                try await execute(
                    executable: executable,
                    arguments: arguments,
                    workingDirectory: workingDirectory
                )
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CommandRunnerError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CommandRunnerError.missingResult
            }
            return result
        }
    }

    private func execute(
        executable: String,
        arguments: [String],
        workingDirectory: String?
    ) async throws -> CommandResult {
        var options = PlatformOptions()
        // Darwin supports session creation in posix_spawn itself. The package's
        // createSession path forks first, briefly inheriting every live lock in
        // a concurrent coordinator before exec closes unrelated descriptors.
        options.preSpawnProcessConfigurator = { attributes, _ in
            var flags: Int16 = 0
            let read = posix_spawnattr_getflags(&attributes, &flags)
            guard read == 0 else { throw CommandRunnerError.spawnConfiguration(read) }
            let write = posix_spawnattr_setflags(&attributes, flags | Int16(POSIX_SPAWN_SETSID))
            guard write == 0 else { throw CommandRunnerError.spawnConfiguration(write) }
        }
        // A diagnostic probe can be killed immediately. Target its isolated
        // process group so an early parent exit cannot strand descendants.
        options.teardownSequence = [
            .send(signal: .kill, toProcessGroup: true, allowedDurationToNextStep: .zero)
        ]
        let result = try await Subprocess.run(
            .path(.init(executable)),
            arguments: Arguments(arguments),
            workingDirectory: workingDirectory.map { .init($0) },
            platformOptions: options,
            output: .string(limit: outputLimit),
            error: .string(limit: outputLimit)
        )
        let termination: CommandTermination = switch result.terminationStatus {
        case .exited(let code): .exited(code)
        case .signaled(let signal): .signaled(signal)
        }
        return CommandResult(
            standardOutput: result.standardOutput,
            standardError: result.standardError,
            termination: termination
        )
    }
}
