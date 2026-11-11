import AgentBuildCore
import AgentBuildTestSupport
import AgentLeaseCore
import Darwin
import Foundation
import Testing

@Suite("Xcode compilation phases")
struct XcodeExecutionPlanTests {
    @Test func splitTestPreservesLiteralSelectorsAndRuntimeResultPath() throws {
        let arguments = ["-derivedDataPath", "/tmp/cache", "test", "-resultBundlePath", "/tmp/test.xcresult",
                         "-workspace", "/tmp/project.xcworkspace", "-destination", "platform=macOS",
                         "-only-testing:Tests/Foo/`words and spaces`()", "ENABLE_TESTABILITY=YES"]
        let plan = try XcodeExecutionPlan(arguments: arguments)
        #expect(plan.logicalArguments == arguments)
        #expect(plan.phases[0].arguments == Array(arguments.prefix(2)) + ["build-for-testing"] + Array(arguments.dropFirst(5)))
        #expect(plan.phases[1].arguments == arguments.map { $0 == "test" ? "test-without-building" : $0 })
        #expect(plan.phases.map(\.compilationResource) == ["host:compile", nil])
    }

    @Test(arguments: ["build", "docbuild", "build-for-testing", "test-without-building"])
    func explicitActionsKeepTheirArguments(_ action: String) throws {
        let arguments = ["-scheme", "Fixture", action]
        let plan = try XcodeExecutionPlan(arguments: arguments)
        #expect(plan.phases.count == 1)
        #expect(plan.phases[0].arguments == arguments)
        #expect(plan.phases[0].requiresCompilation == (action != "test-without-building"))
    }

    @Test(arguments: [[], ["build", "test"], ["test", "test"], ["-scheme", "test"]])
    func ambiguousActionsFailBeforeExecution(_ arguments: [String]) {
        #expect(throws: XcodePlanError.ambiguousAction) { try XcodeExecutionPlan(arguments: arguments) }
    }

    @Test(arguments: [["test", "-resultBundlePath"], ["test", "-resultBundlePath", "relative"],
                      ["test", "-resultBundlePath", "/one", "-resultBundlePath", "/two"]])
    func malformedResultOptionsFailBeforeExecution(_ arguments: [String]) {
        #expect(throws: XcodePlanError.invalidResultBundleOption) { try XcodeExecutionPlan(arguments: arguments) }
    }

    @Test func nulArgumentIsRefused() {
        #expect(throws: XcodePlanError.invalidArgument) {
            try XcodeExecutionPlan(arguments: ["test", "SETTING=invalid\0value"])
        }
    }

    @Test func keywordOptionValuesArePreservedAndUnknownOptionArityFailsClosed() throws {
        let arguments = ["-scheme", "test", "test", "-configuration", "build", "-testPlan", "docbuild"]
        let plan = try XcodeExecutionPlan(arguments: arguments)
        #expect(plan.phases[0].arguments == ["-scheme", "test", "build-for-testing", "-configuration", "build", "-testPlan", "docbuild"])
        #expect(plan.phases[1].arguments == ["-scheme", "test", "test-without-building", "-configuration", "build", "-testPlan", "docbuild"])
        #expect(throws: XcodePlanError.unsupportedArgument("-future-option")) {
            try XcodeExecutionPlan(arguments: ["-future-option", "test", "build"])
        }
        #expect(throws: XcodePlanError.unsupportedArgument("-future-option=test")) {
            try XcodeExecutionPlan(arguments: ["-future-option=test", "build"])
        }
        #expect(throws: XcodePlanError.missingOptionValue("-scheme")) {
            try XcodeExecutionPlan(arguments: ["build", "-scheme"])
        }
    }

    @Test func planEqualityPreservesExactArgumentBytes() throws {
        let composed = try XcodeExecutionPlan(arguments: ["build", "-workspace", "/tmp/Caf\u{00E9}.xcworkspace"])
        let decomposed = try XcodeExecutionPlan(arguments: ["build", "-workspace", "/tmp/Cafe\u{0301}.xcworkspace"])
        #expect(composed != decomposed)
        #expect(composed.phases[0] != decomposed.phases[0])
    }

    @Test func compilationReleasesBeforeRuntimeAndEachPhaseObservesNativeExit() async throws {
        let fixture = try CompilationFixture()
        defer { fixture.remove() }
        let plan = try XcodeExecutionPlan(arguments: ["test", "-resultBundlePath", "/tmp/fixture.xcresult"])
        let outcomes = try await XcodePhaseRunner().run(plan, environment: fixture.environment) { phase, lease in
            #expect(try fixture.available() == !phase.requiresCompilation)
            #expect((lease != nil) == phase.requiresCompilation)
            let descriptors = try lease?.inheritedDescriptors() ?? []
            let result = try await SupervisedSubprocess.run(
                executablePath: "/bin/sh", arguments: ["/bin/sh", "-c", "exit 0"],
                inheritedDescriptors: descriptors, workingDirectory: fixture.directory.path,
                onStart: { _ in
                    do { #expect(try fixture.available() == !phase.requiresCompilation) }
                    catch { Issue.record(error) }
                }
            )
            return switch result.termination {
            case .exited(let code): RunTermination(kind: .exit, value: code)
            case .signaled(let signal): RunTermination(kind: .signal, value: signal)
            }
        }
        #expect(outcomes.map(\.phase) == plan.phases)
        #expect(outcomes.map(\.exitCode) == [0, 0])
        #expect(try fixture.available())
    }

    @Test(arguments: [RunTermination(kind: .exit, value: 17), RunTermination(kind: .signal, value: SIGTERM)])
    func nativeBuildFailureSkipsRuntimeAndReleasesAdmission(_ termination: RunTermination) async throws {
        let fixture = try CompilationFixture()
        defer { fixture.remove() }
        let plan = try XcodeExecutionPlan(arguments: ["test"])
        let outcomes = try await XcodePhaseRunner().run(plan, environment: fixture.environment) { phase, lease in
            #expect(phase.requiresCompilation)
            #expect(lease != nil)
            return termination
        }
        #expect(outcomes.count == 1)
        #expect(outcomes[0].termination == termination)
        #expect(outcomes[0].exitCode == (termination.kind == .exit ? 17 : 143))
        #expect(try fixture.available())
    }
}
