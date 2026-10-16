import AgentLeaseCore
import CryptoKit
import Darwin
import Foundation
import Synchronization

public struct ABDiffProjectResult: Sendable {
    public let runID: String
    public let sessionPath: String?
    public let productPath: String?
    public let status: String
    public let exitCode: Int32
    public let nativeTermination: RunTermination?
    public let rawCaptures: [NativeLogCaptureResult]
    public let orchestrationFailures: [String]
    public let publicationFailures: [String]
    private let data: Data

    fileprivate init(report: ABDiffSessionReport) throws {
        runID = report.runID; sessionPath = report.sessionPath; productPath = report.productPath
        status = report.status; exitCode = report.exitCode ?? 70; nativeTermination = report.nativeTermination
        rawCaptures = report.phases.map(\.rawCapture)
        orchestrationFailures = report.orchestrationFailures; publicationFailures = report.publicationFailures
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        data = try encoder.encode(report)
    }

    public func jsonData() throws -> Data { data }
}

/// Closed ABDiff workflows share execution primitives, not Notika's frozen
/// request/cache/report schemas. Only native compile phases enter host:compile.
public struct ABDiffProjectDriver: Sendable {
    public init() {}

    public func plan(
        request: ABDiffProjectRequest,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> ABDiffProjectPlan {
        try await ABDiffProjectPlanner.plan(request: request, environment: environment)
    }

    public func run(
        request: ABDiffProjectRequest, helperExecutable: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        waitSeconds: Double? = nil
    ) async throws -> ABDiffProjectResult {
        try ABDiffLeaseBoundary.admit(request: request, environment: environment)
        guard helperExecutable.hasPrefix("/"), access(helperExecutable, X_OK) == 0 else {
            throw ABDiffProjectDriverError.invalidArgument("helper executable")
        }
        let initial = try await plan(request: request, environment: environment)
        let runID = UUID().uuidString
        return try await ABDiffProjectOwnership.withOwnership(
            plan: initial, runID: runID, environment: environment, waitSeconds: waitSeconds
        ) { ownership in
            var executionEnvironment = environment
            executionEnvironment["AGENTBUILD_ABDIFF_RESULT_BUNDLE"] = ownership.session.path + "/Tests.xcresult"
            let admitted = try await plan(request: request, environment: executionEnvironment)
            guard admitted.cacheKey == initial.cacheKey,
                  admitted.repository.utf8.elementsEqual(initial.repository.utf8) else {
                throw ABDiffProjectDriverError.changedInput("toolchain/cache changed during admission")
            }
            let state = ABDiffDriverState(plan: admitted, runID: runID, sessionPath: ownership.session.path)
            do {
                let before = try await abdiffSourceSnapshot(admitted.repository, environment: executionEnvironment)
                state.value.withLock { $0.sourceBefore = before }
                try publish(state: state, ownership: ownership, lifecycle: "inProgress", name: "in-progress.json")
                let childEnvironment = abdiffChildEnvironment(executionEnvironment, plan: admitted)
                if request.action == .generate {
                    let tool = try abdiffResolveTool("tuist", environment: executionEnvironment)
                    let observer = try RepositoryCommandCapture(outputLimit: 64 * 1_024)
                    let version = try await observer.capture(arguments: [tool, "version"],
                        workingDirectory: admitted.repository, environment: childEnvironment)
                    state.value.withLock { $0.generationTool = ["path": tool, "versionSHA256": CanonicalJSONDigest.digest(version)] }
                    var generatedEnvironment = childEnvironment
                    generatedEnvironment["USE_CACHED_DEPENDENCIES"] = request.cached ? "1" : nil
                    _ = try await perform("tuist-install", kind: "generation", executable: tool,
                        arguments: ["install"], environment: generatedEnvironment,
                        compilation: true, state: state, ownership: ownership,
                        helper: helperExecutable, admissionEnvironment: executionEnvironment, waitSeconds: waitSeconds)
                    if state.succeededSoFar {
                        _ = try await perform("tuist-generate", kind: "generation", executable: tool,
                            arguments: ["generate", "--no-open"], environment: generatedEnvironment,
                            compilation: true, state: state, ownership: ownership,
                            helper: helperExecutable, admissionEnvironment: executionEnvironment, waitSeconds: waitSeconds)
                    }
                    if state.succeededSoFar {
                        for path in admitted.generatedPaths { _ = try RetainedArtifactDirectory(path: path) }
                    }
                } else {
                    _ = try RetainedArtifactDirectory(path: admitted.workspace)
                    if request.platform == "macos" {
                        _ = try await perform("check-native-dependencies", kind: "preparation", executable: "/bin/bash",
                            arguments: [admitted.repository + "/Scripts/check-native-dependencies.sh"],
                            environment: childEnvironment, compilation: false, state: state, ownership: ownership,
                            helper: helperExecutable, admissionEnvironment: executionEnvironment, waitSeconds: waitSeconds)
                    }
                    if admitted.requiresMacUI, request.isTesting, state.succeededSoFar {
                        let accountRegistry = try HostCompilationAdmission.selectedRoot(environment: [:])
                        let destination = URL(fileURLWithPath: accountRegistry).deletingLastPathComponent().path
                        // Positional paths stay literal; only this fixed script is interpreted.
                        let script = """
                        set -eu
                        target="$2/Library/Application Scripts/dev.jano.apple.abdiff.uitests.xctrunner"
                        /bin/mkdir -p "$target"
                        for source in "$1"/UITests/ABDiffUITests/Resources/AppleScripts/*.applescript; do
                            [ -f "$source" ] || continue
                            /bin/cp "$source" "$target/"
                        done
                        """
                        _ = try await perform("prepare-ui-applescripts", kind: "preparation", executable: "/bin/sh",
                            arguments: ["-c", script, "abdiff-prepare-ui", admitted.repository, destination],
                            environment: childEnvironment, compilation: false, state: state, ownership: ownership,
                            helper: helperExecutable, admissionEnvironment: executionEnvironment, waitSeconds: waitSeconds)
                    }
                    if let phases = admitted.xcodePlan?.phases {
                        for (index, phase) in phases.enumerated() where state.succeededSoFar {
                            _ = try await perform("xcode-\(index)", kind: "xcode",
                                executable: admitted.toolIdentity["xcodebuildPath"] ?? "/usr/bin/xcodebuild",
                                arguments: phase.arguments, environment: childEnvironment,
                                compilation: phase.requiresCompilation, state: state, ownership: ownership,
                                helper: helperExecutable, admissionEnvironment: executionEnvironment, waitSeconds: waitSeconds)
                        }
                    }
                    if request.isTesting, state.succeededSoFar {
                        try await inspectTests(state: state, ownership: ownership, helper: helperExecutable,
                            environment: childEnvironment, admissionEnvironment: executionEnvironment, waitSeconds: waitSeconds)
                    }
                    if request.action == .run, state.succeededSoFar {
                        try await launch(state: state, ownership: ownership, helper: helperExecutable,
                            environment: childEnvironment, admissionEnvironment: executionEnvironment, waitSeconds: waitSeconds)
                    }
                }
                let after = try await abdiffSourceSnapshot(admitted.repository, environment: executionEnvironment)
                let closing = try await plan(request: request, environment: executionEnvironment)
                let complete = state.succeededSoFar
                state.value.withLock {
                    $0.sourceAfter = after
                    $0.sourceDrift = $0.sourceBefore != after
                    $0.toolDrift = admitted.cacheKey != closing.cacheKey
                    $0.executionComplete = complete
                }
            } catch {
                state.value.withLock {
                    $0.cancelled = $0.cancelled || error is CancellationError || Task.isCancelled
                    $0.failures.append(String(describing: error))
                }
            }
            do { try publish(state: state, ownership: ownership, lifecycle: "terminal", name: "manifest.json") }
            catch { state.value.withLock { $0.publicationFailures.append(String(describing: error)) } }
            return try state.result(lifecycle: "terminal")
        }
    }

    private func perform(
        _ step: String, kind: String, executable: String, arguments: [String], environment: [String: String],
        compilation: Bool, state: ABDiffDriverState, ownership: ABDiffProjectOwnership,
        helper: String, admissionEnvironment: [String: String], waitSeconds: Double?,
        directory: String? = nil, directoryDescriptor: Int32? = nil,
        onStart: @escaping @Sendable (Int32) throws -> Void = { _ in }
    ) async throws -> CapturedNativePhase {
        try Task.checkCancellation()
        try ownership.revalidate()
        let command = try DarwinWorkloadCommand(executable: executable, arguments: arguments,
            workingDirectory: directory ?? ownership.plan.repository, environment: environment)
        let execute: @Sendable (CompilationLease?) async throws -> CapturedNativePhase = { lease in
            let descriptors = try ownership.descriptors() + (lease?.inheritedDescriptors() ?? [])
            return try await CapturedNativePhaseRunner().run(helperExecutable: helper, command: command,
                retainedLockDescriptors: descriptors,
                nativeWorkingDirectoryDescriptor: directoryDescriptor ?? ownership.session.repositoryDescriptor,
                artifactRoot: ownership.session.path, onNativeStart: onStart)
        }
        let capture: CapturedNativePhase
        if compilation {
            capture = try await HostCompilationAdmission().withLease(environment: admissionEnvironment,
                label: "ABDiff " + step, waitSeconds: waitSeconds) { try await execute($0) }
        } else { capture = try await execute(nil) }
        state.value.withLock {
            $0.captures.append(capture)
            $0.phases.append(ABDiffPhaseReport(step: step, kind: kind, compilation: compilation, capture: capture))
            $0.cancelled = $0.cancelled || capture.observation.cancelled
            if !capture.rawCapture.captureComplete { $0.failures.append("Incomplete raw evidence: " + step) }
            if capture.observation.termination == nil { $0.failures.append("Missing native outcome: " + step) }
            $0.failures.append(contentsOf: capture.observation.failures.map { "\(step): \($0.operation): \($0.detail ?? String($0.code ?? 0))" })
        }
        return capture
    }

    private func inspectTests(
        state: ABDiffDriverState, ownership: ABDiffProjectOwnership, helper: String,
        environment: [String: String], admissionEnvironment: [String: String], waitSeconds: Double?
    ) async throws {
        let path = ownership.session.path + "/Tests.xcresult"
        let result = try ABDiffResultCustody(session: ownership.session.path)
        let capture = try await perform("xcresult-summary", kind: "result", executable: "/usr/bin/xcrun",
            arguments: ["xcresulttool", "get", "test-results", "summary", "--path", ".", "--compact"],
            environment: environment, compilation: false, state: state, ownership: ownership,
            helper: helper, admissionEnvironment: admissionEnvironment, waitSeconds: waitSeconds,
            directory: path, directoryDescriptor: result.directoryDescriptor)
        guard capture.observation.termination == RunTermination(kind: .exit, value: 0) else {
            throw ABDiffProjectDriverError.evidence("xcresult summary failed")
        }
        try capture.revalidateForPublication()
        let logDirectory = try RetainedArtifactDirectory(path: URL(fileURLWithPath: capture.rawCapture.standardOutput.path).deletingLastPathComponent().path)
        let file = try logDirectory.openFile(named: "stdout.log", policy: ArtifactFilePolicy(maximumBytes: 1_024 * 1_024))
        let tests = try NotikaExecutedTests.parse(file.readBounded())
        try capture.revalidateForPublication()
        try result.finishPreparation()
        state.value.withLock { $0.tests = tests; $0.resultCustody = result; $0.resultCommitment = result.commitment }
        guard tests.satisfiesExpectedRun(focusedMethod: ownership.plan.request.route == "test-ui-file" && ownership.plan.request.method != nil) else {
            throw ABDiffProjectDriverError.evidence("Native test summary does not establish a nonempty passing run")
        }
    }

    private func launch(
        state: ABDiffDriverState, ownership: ABDiffProjectOwnership, helper: String,
        environment: [String: String], admissionEnvironment: [String: String], waitSeconds: Double?
    ) async throws {
        let plan = ownership.plan
        _ = try RetainedArtifactDirectory(path: plan.productPath)
        let executable: String, arguments: [String]
        if plan.request.platform == "ipad-simulator" {
            guard let simulator = environment["SIMULATOR_ID"], UUID(uuidString: simulator) != nil else {
                throw ABDiffProjectDriverError.invalidArgument("leased simulator")
            }
            _ = try await perform("simctl-install", kind: "preparation", executable: "/usr/bin/xcrun",
                arguments: ["simctl", "install", simulator, plan.productPath], environment: environment,
                compilation: false, state: state, ownership: ownership, helper: helper,
                admissionEnvironment: admissionEnvironment, waitSeconds: waitSeconds)
            guard state.succeededSoFar else { return }
            executable = "/usr/bin/xcrun"
            arguments = ["simctl", "launch", "--console", "--terminate-running-process", simulator,
                         "dev.jano.apple.abdiff.ipadhexviewer"]
        } else {
            executable = plan.productPath + "/Contents/MacOS/ABDiff"
            arguments = []
        }
        _ = try await perform("application", kind: "launch", executable: executable,
            arguments: arguments, environment: environment, compilation: false,
            state: state, ownership: ownership, helper: helper,
            admissionEnvironment: admissionEnvironment, waitSeconds: waitSeconds,
            onStart: { pid in
                state.value.withLock { $0.launchedPID = pid }
                try publish(state: state, ownership: ownership, lifecycle: "running", name: "preview-ready.json")
            })
    }

    private func publish(state: ABDiffDriverState, ownership: ABDiffProjectOwnership, lifecycle: String, name: String) throws {
        let result = try state.result(lifecycle: lifecycle)
        try ownership.session.publish(sealedData: result.jsonData(), name: name) {
            try ownership.revalidate()
            try state.revalidateEvidence()
        }
        try state.revalidateEvidence()
        try ownership.revalidate()
    }
}

private struct ABDiffPhaseReport: Encodable, Sendable {
    let step: String
    let kind: String
    let compilation: Bool
    let executable: String
    let arguments: [String]
    let workingDirectory: String
    let environmentSHA256: String
    let processIdentifier: Int32?
    let nativeTermination: RunTermination?
    let retirement: String
    let cancelled: Bool
    let rawCapture: NativeLogCaptureResult

    init(step: String, kind: String, compilation: Bool, capture: CapturedNativePhase) {
        self.step = step; self.kind = kind; self.compilation = compilation
        executable = capture.command.executable; arguments = capture.command.arguments
        workingDirectory = capture.command.workingDirectory
        environmentSHA256 = (try? CanonicalJSONDigest.sha256(.object(capture.command.environment.mapValues { .string($0) }))) ?? "unavailable"
        processIdentifier = capture.observation.processIdentifier
        nativeTermination = capture.observation.termination
        retirement = capture.observation.retirement.rawValue
        cancelled = capture.observation.cancelled; rawCapture = capture.rawCapture
    }
}

private struct ABDiffSessionReport: Encodable, Sendable {
    let namespace = "agentbuild.abdiff"
    let schemaVersion = 1
    let toolVersion = AgentBuild.version
    let admissionEstablished = true
    let runID: String
    let repository: String
    let request: ABDiffProjectRequest
    let sessionPath: String
    let productPath: String?
    let cacheDirectory: String
    let cacheKey: String
    let lifecycle: String
    let status: String
    let exitCode: Int32?
    let nativeTermination: RunTermination?
    let cancelled: Bool
    let executionComplete: Bool
    let sourceBefore: [String: String]?
    let sourceAfter: [String: String]?
    let sourceDrift: Bool
    let toolIdentity: [String: String]
    let generationTool: [String: String]?
    let toolDrift: Bool
    let startedAt: String
    let completedAt: String?
    let phases: [ABDiffPhaseReport]
    let tests: NotikaExecutedTests?
    let resultBundleSHA256: String?
    let launchedPID: Int32?
    let orchestrationFailures: [String]
    let publicationFailures: [String]
    let retention = "Manual retention; no automatic deletion. Retire only inactive ABDiff sessions/caches while owning their exclusive namespace leases."
}

private final class ABDiffDriverState: Sendable {
    struct State {
        var captures: [CapturedNativePhase] = []
        var phases: [ABDiffPhaseReport] = []
        var sourceBefore: [String: String]?
        var sourceAfter: [String: String]?
        var sourceDrift = false
        var toolDrift = false
        var generationTool: [String: String]?
        var executionComplete = false
        var cancelled = false
        var failures: [String] = []
        var publicationFailures: [String] = []
        var tests: NotikaExecutedTests?
        var resultCustody: ABDiffResultCustody?
        var resultCommitment: String?
        var launchedPID: Int32?
    }
    let value = Mutex(State())
    let plan: ABDiffProjectPlan
    let runID: String
    let sessionPath: String
    let startedAt = RunRecord.timestamp()
    init(plan: ABDiffProjectPlan, runID: String, sessionPath: String) {
        self.plan = plan; self.runID = runID; self.sessionPath = sessionPath
    }
    var succeededSoFar: Bool {
        value.withLock { state in
            !state.cancelled && state.failures.isEmpty
                && state.phases.allSatisfy { $0.nativeTermination == RunTermination(kind: .exit, value: 0) }
        }
    }
    func revalidateEvidence() throws {
        try value.withLock { state in
            for capture in state.captures { try capture.revalidateForPublication() }
            try state.resultCustody?.revalidate()
        }
    }
    func result(lifecycle: String) throws -> ABDiffProjectResult {
        try value.withLock { state in
            let primary = state.phases.filter { $0.kind != "result" }
            let failure = primary.compactMap(\.nativeTermination).first { abdiffNativeCode($0) != 0 }
            let native = failure ?? primary.compactMap(\.nativeTermination).last
            let status: String, code: Int32?
            if lifecycle != "terminal" { status = lifecycle == "running" ? "running" : "preparing"; code = nil }
            else if let failure { status = "failed"; code = abdiffNativeCode(failure) }
            else if state.cancelled { status = "cancelled"; code = 130 }
            else if !state.failures.isEmpty || !state.publicationFailures.isEmpty
                || (state.sourceDrift && plan.request.action != .generate) || state.toolDrift || !state.executionComplete {
                status = "inconclusive"; code = 70
            } else { status = "succeeded"; code = 0 }
            return try ABDiffProjectResult(report: ABDiffSessionReport(
                runID: runID, repository: plan.repository, request: plan.request, sessionPath: sessionPath,
                productPath: plan.request.action == .generate ? nil : plan.productPath,
                cacheDirectory: plan.cacheDirectory, cacheKey: plan.cacheKey,
                lifecycle: lifecycle, status: status, exitCode: code, nativeTermination: native,
                cancelled: state.cancelled, executionComplete: state.executionComplete,
                sourceBefore: state.sourceBefore, sourceAfter: state.sourceAfter, sourceDrift: state.sourceDrift,
                toolIdentity: plan.toolIdentity, generationTool: state.generationTool, toolDrift: state.toolDrift,
                startedAt: startedAt, completedAt: lifecycle == "terminal" ? RunRecord.timestamp() : nil,
                phases: state.phases, tests: state.tests, resultBundleSHA256: state.resultCommitment,
                launchedPID: state.launchedPID, orchestrationFailures: state.failures, publicationFailures: state.publicationFailures
            ))
        }
    }
}

/// The shared bounded result-tree implementation is independent of Notika route
/// admission. Access is serialized by the single driver until publication.
private final class ABDiffResultCustody: @unchecked Sendable {
    private let parent: Int32
    private var tree: NotikaResultBundleTree
    private var prepared = false
    var directoryDescriptor: Int32 { tree.root }
    var commitment: String { tree.commitment }
    init(session: String) throws {
        try NotikaResultBundleTree.ensureDescriptorBudget()
        let descriptor = open(session, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 3 else { throw ABDiffProjectDriverError.io("open result session", errno) }
        do {
            tree = try NotikaResultBundleTree(parent: descriptor, name: "Tests.xcresult", allowsRootSQLitePreparation: true)
        } catch { _ = close(descriptor); throw error }
        parent = descriptor
    }
    deinit { _ = close(parent) }
    func finishPreparation() throws {
        try tree.validateSQLitePreparation()
        tree = try NotikaResultBundleTree(parent: parent, name: "Tests.xcresult")
        prepared = true
    }
    func revalidate() throws {
        guard prepared else { throw ABDiffProjectDriverError.evidence("result index preparation incomplete") }
        try tree.revalidate()
    }
}

private func abdiffNativeCode(_ result: RunTermination) -> Int32 {
    result.kind == .exit ? result.value : 128 + result.value
}

private func abdiffChildEnvironment(_ environment: [String: String], plan: ABDiffProjectPlan) -> [String: String] {
    let retained = NotikaChildEnvironmentPolicy.inheritedNames.union([
        "JAVA_HOME", "TEST_RUNNER_JAVA_HOME", "UITEST_FILE_LOGGING", "TEXT_LOG_FILE",
        "CARGO_HOME", "RUSTUP_HOME", "MISE_DATA_DIR", "MISE_CONFIG_DIR", "SSH_AUTH_SOCK",
    ])
    var child = environment.filter { key, _ in
        retained.contains(key) || key.hasPrefix("ABDIFF_") || key.hasPrefix("TEST_RUNNER_ABDIFF_")
            || key.hasPrefix("SIMCTL_CHILD_ABDIFF_")
    }
    child["SRCROOT"] = plan.repository
    child["DEVELOPER_DIR"] = plan.toolIdentity["developerDirectory"]
    child["ABDIFF_DERIVED_DATA"] = plan.cacheDirectory
    if plan.request.route == "test-ui-safe" {
        child["ABDIFF_UITEST_SAFE_MODE"] = "1"
        child["TEST_RUNNER_ABDIFF_UITEST_SAFE_MODE"] = "1"
    }
    return child
}

private func abdiffSourceSnapshot(_ repository: String, environment: [String: String]) async throws -> [String: String] {
    let capture = try RepositoryCommandCapture()
    var snapshot: [String: String] = [:]
    for (name, arguments) in [
        ("head", ["git", "rev-parse", "HEAD"]),
        ("status", ["git", "status", "--porcelain=v1", "-z", "--untracked-files=all"]),
        ("diff", ["git", "diff", "--binary", "--no-ext-diff", "HEAD"]),
        ("submodules", ["git", "submodule", "status", "--recursive"]),
    ] {
        snapshot[name] = CanonicalJSONDigest.digest(try await capture.capture(
            arguments: arguments, workingDirectory: repository, environment: environment))
    }
    let untracked = try await capture.capture(arguments: ["git", "ls-files", "--others", "--exclude-standard", "-z"],
        workingDirectory: repository, environment: environment)
    var files: [CanonicalJSONValue] = []
    for raw in untracked.split(separator: 0) {
        guard let name = String(bytes: raw, encoding: .utf8), !name.hasPrefix("/"),
              !name.split(separator: "/").contains("..") else { throw ABDiffProjectDriverError.evidence("invalid Git path") }
        files.append(.object(["path": .string(name), "sha256": .string(try abdiffFileDigest(repository + "/" + name))]))
    }
    snapshot["untracked"] = try CanonicalJSONDigest.sha256(.array(files))
    for name in ["ABDiff.xcodeproj/project.pbxproj", "ABDiff.xcworkspace/contents.xcworkspacedata", "Project.swift", "Tuist/Package.resolved", ".package.resolved"] {
        if FileManager.default.fileExists(atPath: repository + "/" + name) {
            snapshot[name] = try abdiffFileDigest(repository + "/" + name)
        }
    }
    return snapshot
}

private func abdiffFileDigest(_ path: String) throws -> String {
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 3 else { throw ABDiffProjectDriverError.io("open source input", errno) }
    defer { _ = close(descriptor) }
    var before = stat()
    guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
          before.st_size >= 0 else { throw ABDiffProjectDriverError.evidence("nonregular source input: " + path) }
    var digest = SHA256(), buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
        let count = read(descriptor, &buffer, buffer.count)
        if count < 0, errno == EINTR { continue }
        guard count >= 0 else { throw ABDiffProjectDriverError.io("read source input", errno) }
        if count == 0 { break }
        digest.update(data: Data(buffer.prefix(count)))
    }
    var after = stat(), named = stat()
    guard fstat(descriptor, &after) == 0, lstat(path, &named) == 0,
          before.st_dev == after.st_dev, before.st_ino == after.st_ino,
          after.st_dev == named.st_dev, after.st_ino == named.st_ino,
          before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
          before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
          before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
          before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
        throw ABDiffProjectDriverError.changedInput(path)
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}
