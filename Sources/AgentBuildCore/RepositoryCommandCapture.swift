import Darwin
import Foundation
import Subprocess

/// Raw observations only: this interface conveys no route authority or custody.
public protocol RepositoryCommandCapturing: Sendable {
    func capture(arguments: [String], workingDirectory: String, environment: [String: String]) async throws -> Data
}

public enum RepositoryCaptureError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidInput
    case outputLimitExceeded
    case timedOut
    case launchFailed(executable: String, diagnostic: String)
    case commandFailed(executable: String, exitCode: Int32, diagnostic: String)

    public var description: String {
        switch self {
        case .invalidInput: "invalid repository capture input"
        case .outputLimitExceeded: "repository command output exceeded its capture budget"
        case .timedOut: "repository command capture timed out"
        case .launchFailed(let executable, let diagnostic): "cannot execute \(executable): \(diagnostic)"
        case .commandFailed(let executable, let exitCode, let diagnostic):
            "command failed (\(exitCode)): \(executable): \(diagnostic)"
        }
    }
}

/// Strict full capture up to fixed budgets. An overflow never returns a prefix.
/// The structured timeout waits for Subprocess's process-group teardown and child
/// reaping before returning. No caller descriptors are handed to the child.
public struct RepositoryCommandCapture: RepositoryCommandCapturing {
    public let outputLimit: Int
    public let diagnosticLimit: Int
    public let timeout: Duration

    public init(outputLimit: Int = 64 * 1_024 * 1_024, diagnosticLimit: Int = 64 * 1_024,
                timeout: Duration = .seconds(30)) throws {
        guard outputLimit >= 0, (outputLimit < Int.max), diagnosticLimit >= 0,
              (diagnosticLimit < Int.max), timeout > .zero else { throw RepositoryCaptureError.invalidInput }
        self.outputLimit = outputLimit
        self.diagnosticLimit = diagnosticLimit
        self.timeout = timeout
    }

    public func capture(arguments: [String], workingDirectory: String,
                        environment: [String: String]) async throws -> Data {
        guard let executable = arguments.first, !executable.isEmpty,
              workingDirectory.hasPrefix("/"), !workingDirectory.utf8.contains(0),
              arguments.allSatisfy({ !$0.utf8.contains(0) }),
              environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") &&
                  !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) }) else {
            throw RepositoryCaptureError.invalidInput
        }
        try Task.checkCancellation()
        do {
            return try await withThrowingTaskGroup(of: Data.self) { group in
                defer { group.cancelAll() }
                group.addTask { try await execute(arguments, workingDirectory: workingDirectory, environment: environment) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw RepositoryCaptureError.timedOut
                }
                return try await group.next()!
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let subprocessError = error as? SubprocessError {
                if subprocessError.code == .outputLimitExceeded { throw RepositoryCaptureError.outputLimitExceeded }
                throw RepositoryCaptureError.launchFailed(executable: executable, diagnostic: subprocessError.description)
            }
            throw error
        }
    }

    private func execute(_ arguments: [String], workingDirectory: String,
                         environment: [String: String]) async throws -> Data {
        var options = PlatformOptions()
        options.teardownSequence = [.send(signal: .kill, toProcessGroup: true, allowedDurationToNextStep: .zero)]
        // Subprocess 1.0's createSession uses its pre-fork path. Configure the
        // Darwin spawn attributes directly, as AgentLease's supervisor does.
        options.preSpawnProcessConfigurator = { attributes, _ in
            var flags: Int16 = 0
            var result = posix_spawnattr_getflags(&attributes, &flags)
            guard result == 0 else { throw captureSpawnError("getflags", result) }
            result = posix_spawnattr_setflags(&attributes, flags | Int16(POSIX_SPAWN_SETSID))
            guard result == 0 else { throw captureSpawnError("setflags", result) }
            var defaults = sigset_t()
            result = posix_spawnattr_getsigdefault(&attributes, &defaults)
            guard result == 0 else { throw captureSpawnError("getsigdefault", result) }
            var mask = sigset_t()
            result = posix_spawnattr_getsigmask(&attributes, &mask)
            guard result == 0 else { throw captureSpawnError("getsigmask", result) }
            for number in [SIGINT, SIGTERM, SIGHUP] {
                guard sigaddset(&defaults, number) == 0, sigdelset(&mask, number) == 0 else {
                    throw captureSpawnError("signal set", errno)
                }
            }
            result = posix_spawnattr_setsigdefault(&attributes, &defaults)
            guard result == 0 else { throw captureSpawnError("setsigdefault", result) }
            result = posix_spawnattr_setsigmask(&attributes, &mask)
            guard result == 0 else { throw captureSpawnError("setsigmask", result) }
        }
        let values = environment.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
            .map { Array("\($0.key)=\($0.value)\0".utf8) }
        let result = try await Subprocess.run(
            .path(.init(try repositoryExecutable(arguments[0], workingDirectory: workingDirectory, environment: environment))),
            arguments: Arguments(executablePathOverride: arguments[0], remainingValues: Array(arguments.dropFirst())),
            environment: .custom(values), workingDirectory: .init(workingDirectory), platformOptions: options,
            input: .none, output: .data(limit: outputLimit), error: .data(limit: diagnosticLimit)
        )
        try Task.checkCancellation()
        let exitCode: Int32 = switch result.terminationStatus {
        case .exited(let code): code
        case .signaled(let signal): -signal
        }
        guard exitCode == 0 else {
            throw RepositoryCaptureError.commandFailed(executable: arguments[0], exitCode: exitCode,
                                                       diagnostic: repositoryDecodedText(result.standardError))
        }
        return result.standardOutput
    }
}

private func repositoryExecutable(_ name: String, workingDirectory: String, environment: [String: String]) throws -> String {
    if name.contains("/") { return name.hasPrefix("/") ? name : workingDirectory + "/" + name }
    for directory in (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":", omittingEmptySubsequences: false) {
        let component = String(directory)
        let absolute = component.hasPrefix("/") ? component : workingDirectory + "/" + component
        let candidate = absolute + "/" + name
        var metadata = stat()
        if candidate.withCString({ access($0, X_OK) == 0 && stat($0, &metadata) == 0 }),
           metadata.st_mode & S_IFMT != S_IFDIR { return candidate }
    }
    throw RepositoryCaptureError.launchFailed(executable: name, diagnostic: "executable not found in PATH")
}

private func captureSpawnError(_ operation: String, _ code: Int32) -> RepositoryCaptureError {
    .launchFailed(executable: "posix_spawn", diagnostic: "\(operation): \(String(cString: strerror(code)))")
}

/// Python UTF-8 replacement decoding and str.strip's whitespace set.
public func repositoryDecodedText(_ data: Data) -> String {
    let scalars = String(decoding: data, as: UTF8.self).unicodeScalars
    func whitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 9...13, 28...32, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028...0x2029, 0x202F, 0x205F, 0x3000: true
        default: false
        }
    }
    let start = scalars.firstIndex { !whitespace($0) } ?? scalars.endIndex
    let end = scalars[start...].lastIndex { !whitespace($0) }.map { scalars.index(after: $0) } ?? start
    return String(scalars[start..<end])
}
