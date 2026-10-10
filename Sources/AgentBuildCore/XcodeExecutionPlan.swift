import AgentLeaseCore
import Foundation

public enum XcodePlanError: Error, Equatable, Sendable {
    case invalidArgument
    case ambiguousAction
    case invalidResultBundleOption
    case missingOptionValue(String)
    case unsupportedArgument(String)
}

public struct XcodeExecutionPhase: Equatable, Sendable {
    public let arguments: [String]
    public let requiresCompilation: Bool

    public var compilationResource: String? {
        requiresCompilation ? HostCompilationAdmission.resource : nil
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.requiresCompilation == rhs.requiresCompilation && exactArgumentsEqual(lhs.arguments, rhs.arguments)
    }
}

/// Derives physical invocations from one already-authorized logical invocation.
/// This plan is not command authority; the project route still admits exact argv.
public struct XcodeExecutionPlan: Equatable, Sendable {
    public let logicalArguments: [String]
    public let phases: [XcodeExecutionPhase]

    public static func == (lhs: Self, rhs: Self) -> Bool {
        exactArgumentsEqual(lhs.logicalArguments, rhs.logicalArguments) && lhs.phases == rhs.phases
    }

    public init(arguments: [String]) throws {
        guard !arguments.contains(where: { $0.utf8.contains(0) }) else {
            throw XcodePlanError.invalidArgument
        }
        let actions: Set<String> = ["build", "build-for-testing", "docbuild", "test", "test-without-building"]
        // Managed routes use a closed option vocabulary. Values named "test"
        // or "build" must remain values, never become positional actions.
        let valueOptions: Set<String> = [
            "-configuration", "-derivedDataPath", "-destination", "-enableCodeCoverage",
            "-parallel-testing-enabled", "-resultBundlePath", "-scheme", "-testPlan", "-workspace",
        ]
        var positions: [Int] = []
        var resultPositions: [Int] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if valueOptions.contains(argument) {
                guard index + 1 < arguments.count else {
                    if argument == "-resultBundlePath" { throw XcodePlanError.invalidResultBundleOption }
                    throw XcodePlanError.missingOptionValue(argument)
                }
                if argument == "-resultBundlePath" { resultPositions.append(index) }
                index += 2
                continue
            }
            if actions.contains(argument) {
                positions.append(index)
            } else if argument != "-disableAutomaticPackageResolution",
                      !argument.hasPrefix("-only-testing:"),
                      (argument.hasPrefix("-") || !argument.contains("=")) {
                throw XcodePlanError.unsupportedArgument(argument)
            }
            index += 1
        }
        guard positions.count == 1, let position = positions.first else {
            throw XcodePlanError.ambiguousAction
        }
        guard resultPositions.count <= 1,
              resultPositions.allSatisfy({ $0 + 1 < arguments.count && arguments[$0 + 1].hasPrefix("/") }) else {
            throw XcodePlanError.invalidResultBundleOption
        }
        logicalArguments = arguments
        if arguments[position] == "test" {
            var build = arguments
            build[position] = "build-for-testing"
            if let resultPosition = resultPositions.first {
                // Only runtime owns the result path; compilation must not create it.
                build.removeSubrange(resultPosition...(resultPosition + 1))
            }
            var execute = arguments
            execute[position] = "test-without-building"
            phases = [
                XcodeExecutionPhase(arguments: build, requiresCompilation: true),
                XcodeExecutionPhase(arguments: execute, requiresCompilation: false),
            ]
        } else {
            phases = [XcodeExecutionPhase(arguments: arguments,
                                          requiresCompilation: arguments[position] != "test-without-building")]
        }
    }
}

private func exactArgumentsEqual(_ lhs: [String], _ rhs: [String]) -> Bool {
    lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { Data($0.utf8) == Data($1.utf8) }
}

public struct XcodePhaseOutcome: Equatable, Sendable {
    public let phase: XcodeExecutionPhase
    public let termination: RunTermination

    public var exitCode: Int32 {
        termination.kind == .exit ? termination.value : 128 + termination.value
    }
}

/// Executes sequentially beneath the caller's graph/cache ownership. Each
/// operation must await child reaping before returning its native termination.
/// Project artifact custody and authority remain the caller's responsibility.
public struct XcodePhaseRunner: Sendable {
    public init() {}

    public func run(
        _ plan: XcodeExecutionPlan,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        label: String = "agentbuild Xcode compilation",
        waitSeconds: Double? = nil,
        operation: @Sendable (XcodeExecutionPhase, CompilationLease?) async throws -> RunTermination
    ) async throws -> [XcodePhaseOutcome] {
        var outcomes: [XcodePhaseOutcome] = []
        for phase in plan.phases {
            try Task.checkCancellation()
            let termination: RunTermination
            if phase.requiresCompilation {
                termination = try await HostCompilationAdmission().withLease(
                    environment: environment, label: label, waitSeconds: waitSeconds
                ) { lease in
                    try await operation(phase, lease)
                }
            } else {
                termination = try await operation(phase, nil)
            }
            let outcome = XcodePhaseOutcome(phase: phase, termination: termination)
            outcomes.append(outcome)
            if outcome.exitCode != 0 { break }
        }
        return outcomes
    }
}
