@testable import AgentBuildCore
import AgentBuildTestSupport
import AgentLeaseCore
import Darwin
import Foundation
@testable import NotikaAdapter
import Testing

@Suite("Notika retained build sessions")
struct NotikaBuildSessionTests {
    @Test func scopeUsesPythonWriterResourceAndSealsIndependentLifecycleFiles() async throws {
        let fixture = try BuildSessionFixture()
        defer { fixture.remove() }
        let leasePath = try await fixture.withSession { session -> String in
            #expect(session.writerResource == "notika:sessions:" + fixture.path)
            let manifest = try session.inheritedLeaseDescriptors()
            let lease = try #require(manifest.first)
            #expect(lease.mode == .shared)
            #expect(try session.inheritedDescriptors() == [lease.descriptor])
            #expect(fcntl(lease.descriptor, F_GETFD) & FD_CLOEXEC != 0)
            #expect(try !buildSessionLockAvailable(lease.path))
            let progressURL = URL(fileURLWithPath: session.path).appendingPathComponent("in-progress.json")
            let progress = try NotikaBuildSessionReport(data: Data(contentsOf: progressURL),
                                                       expectedRepository: fixture.path, expectedSessionID: session.runID)
            #expect(progress.lifecycle == "inProgress")
            #expect(progress.exitCode == nil)
            let report = try session.publishTerminal(.init(orchestrationFailures: ["fixture setup failure"]),
                                                     completedAt: fixture.completedAt)
            #expect(report.status == "inconclusive")
            #expect(report.exitCode == 70)
            #expect(report.nativeTermination == nil)
            let terminalURL = URL(fileURLWithPath: session.path).appendingPathComponent("manifest.json")
            #expect(try Data(contentsOf: terminalURL) == report.originalData)
            #expect(try Data(contentsOf: progressURL) == progress.originalData)
            var status = stat()
            #expect(lstat(terminalURL.path, &status) == 0)
            #expect(status.st_mode & 0o7777 == 0o400)
            #expect(status.st_nlink == 2)
            #expect(status.st_uid == geteuid())
            #expect(try FileManager.default.attributesOfItem(atPath: session.path)[.posixPermissions] as? Int == 0o700)
            var retainedReaders = 0
            for descriptor in try buildSessionProcessFileDescriptors() {
                var candidate = stat()
                if fstat(descriptor, &candidate) == 0, candidate.st_dev == status.st_dev, candidate.st_ino == status.st_ino {
                    retainedReaders += 1
                    #expect(fcntl(descriptor, F_GETFL) & O_ACCMODE == O_RDONLY)
                    #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
                }
            }
            #expect(retainedReaders >= 1)
            try session.revalidateTerminal()
            #expect(throws: NotikaBuildSessionError.invalidLifecycle) {
                try session.publishTerminal(.init(), completedAt: fixture.completedAt)
            }
            return lease.path
        }
        #expect(try await buildSessionLockEventuallyAvailable(leasePath))
    }

    @Test func missingTerminalCannotReturnSuccessAndHasDriverFailureEvidence() async throws {
        let fixture = try BuildSessionFixture()
        defer { fixture.remove() }
        await #expect(throws: NotikaBuildSessionError.invalidLifecycle) {
            try await fixture.withSession { _ in true }
        }
        let report = try NotikaBuildSessionReport(data: Data(contentsOf: fixture.terminalURL))
        #expect(report.lifecycle == "terminal")
        #expect(report.exitCode == 70)
        #expect(report.nativeTermination == nil)
    }

    @Test func existingTerminalIsNeverOverwritten() async throws {
        let fixture = try BuildSessionFixture()
        defer { fixture.remove() }
        let foreign = Data("foreign retained content".utf8)
        await #expect(throws: (any Error).self) {
            try await fixture.withSession { session in
                try foreign.write(to: fixture.terminalURL)
                try session.publishTerminal(.init(orchestrationFailures: ["setup"]), completedAt: fixture.completedAt)
            }
        }
        #expect(try Data(contentsOf: fixture.terminalURL) == foreign)
    }

    @Test func publicPathReplacementDoesNotBecomeAuthorityOrChangeForeignBytes() async throws {
        let fixture = try BuildSessionFixture()
        defer { fixture.remove() }
        let foreign = Data("foreign replacement".utf8)
        await #expect(throws: (any Error).self) {
            try await fixture.withSession { session in
                try session.publishTerminal(.init(orchestrationFailures: ["setup"]), completedAt: fixture.completedAt)
                try FileManager.default.moveItem(at: fixture.terminalURL, to: fixture.root.appendingPathComponent("owned-manifest"))
                try foreign.write(to: fixture.terminalURL)
                try session.revalidateTerminal()
            }
        }
        #expect(try Data(contentsOf: fixture.terminalURL) == foreign)
    }

    @Test func sessionDirectoryRenameCannotPublishIntoReplacement() async throws {
        let fixture = try BuildSessionFixture()
        defer { fixture.remove() }
        await #expect(throws: (any Error).self) {
            try await fixture.withSession { session in
                let moved = fixture.root.appendingPathComponent("owned-session")
                try FileManager.default.moveItem(atPath: session.path, toPath: moved.path)
                try FileManager.default.createDirectory(atPath: session.path, withIntermediateDirectories: false,
                                                       attributes: [.posixPermissions: 0o700])
                let foreign = URL(fileURLWithPath: session.path).appendingPathComponent("preserve")
                try Data("replacement".utf8).write(to: foreign)
                try session.publishTerminal(.init(orchestrationFailures: ["setup"]), completedAt: fixture.completedAt)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.terminalURL.path))
        #expect(try Data(contentsOf: fixture.terminalURL.deletingLastPathComponent().appendingPathComponent("preserve"))
            == Data("replacement".utf8))
    }

    @Test func sameInodeRewriteAndRestoreRemainsRejected() async throws {
        let fixture = try BuildSessionFixture()
        defer { fixture.remove() }
        await #expect(throws: (any Error).self) {
            try await fixture.withSession { session in
                let report = try session.publishTerminal(.init(orchestrationFailures: ["setup"]), completedAt: fixture.completedAt)
                #expect(chmod(fixture.terminalURL.path, 0o600) == 0)
                let writer = open(fixture.terminalURL.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
                #expect(writer >= 0)
                defer { _ = Darwin.close(writer) }
                #expect("!".withCString { pwrite(writer, $0, 1, 0) } == 1)
                let restored = report.originalData.withUnsafeBytes { pwrite(writer, $0.baseAddress!, $0.count, 0) }
                #expect(restored == report.originalData.count)
                #expect(fsync(writer) == 0)
                #expect(fchmod(writer, 0o400) == 0)
                try session.revalidateTerminal()
            }
        }
        let report = try NotikaBuildSessionReport(data: Data(contentsOf: fixture.terminalURL))
        #expect(report.exitCode == 70) // Valid bytes alone did not restore live custody.
    }

    @Test func retainedDescriptorReplacementIsRejected() async throws {
        let fixture = try BuildSessionFixture()
        defer { fixture.remove() }
        let foreignURL = fixture.root.appendingPathComponent("foreign")
        let foreign = Data("foreign descriptor data".utf8)
        try foreign.write(to: foreignURL)
        await #expect(throws: (any Error).self) {
            try await fixture.withSession { session in
                try session.publishTerminal(.init(orchestrationFailures: ["setup"]), completedAt: fixture.completedAt)
                var original = stat()
                #expect(lstat(fixture.terminalURL.path, &original) == 0)
                let descriptors = try buildSessionProcessFileDescriptors()
                let retained = try #require(descriptors.first { descriptor in
                    var value = stat()
                    return fstat(descriptor, &value) == 0 && value.st_dev == original.st_dev && value.st_ino == original.st_ino
                })
                let replacement = open(foreignURL.path, O_RDONLY | O_CLOEXEC)
                #expect(replacement >= 0)
                defer { _ = Darwin.close(replacement) }
                #expect(dup2(replacement, retained) == retained)
                try session.revalidateTerminal()
            }
        }
        #expect(try Data(contentsOf: foreignURL) == foreign)
    }

    @Test func strictReportRejectsDuplicateUnknownForgedAndChangedCommitments() async throws {
        let fixture = try BuildSessionFixture()
        defer { fixture.remove() }
        let report = try await fixture.withSession { session in
            try session.publishTerminal(.init(orchestrationFailures: ["fixture"]), completedAt: fixture.completedAt)
        }
        let corruptions: [(String, CanonicalJSONValue)] = [
            ("exitCode", .integer(0)), ("status", .string("succeeded")),
            ("namespace", .string("notika.agent-session")), ("schemaVersion", .integer(2)),
            ("ownerUID", .integer(-1)), ("completedAt", .string("tomorrow")), ("expiresAt", .string("2026-01-02T00:00:00.000Z")),
            ("nativeTermination", .object(["kind": .string("exit"), "value": .integer(0)])),
            ("cancelled", .integer(1)), ("extra", .string("unrecognized")),
            ("commitments", .object(["requestSHA256": .string(String(repeating: "0", count: 64)),
                "physicalPlanSHA256": .string(String(repeating: "0", count: 64)),
                "rawLogReportsSHA256": .string(String(repeating: "0", count: 64))])),
        ]
        for (field, value) in corruptions {
            let bytes = try buildSessionReplacing(report.canonicalValue, field: field, value: value)
            #expect(throws: (any Error).self) { try NotikaBuildSessionReport(data: bytes) }
        }
        var duplicate = Data("{\"schemaVersion\":1,".utf8)
        duplicate.append(report.originalData.dropFirst())
        #expect(throws: (any Error).self) { try NotikaBuildSessionReport(data: duplicate) }
        #expect(throws: (any Error).self) {
            try NotikaBuildSessionReport(data: report.originalData, expectedRepository: fixture.path + "-foreign")
        }
    }

    @Test func sharedWriterDoesNotWaitForAnotherWriterButExcludesCollector() async throws {
        let fixture = try BuildSessionFixture()
        defer { fixture.remove() }
        try await fixture.withSession { session in
            let other = try AgentLeasePaths.open(selectedRoot: fixture.registry)
            let resource = session.writerResource
            let set = try ResourceSet(exclusive: [], shared: [resource])
            let lease = try await LeaseSet.acquire(set, paths: other, waitSeconds: 0, initialMetadata: { value in
                LockMetadata(resourceName: value.resource.value, leaseMode: value.mode, runID: UUID().uuidString,
                             coordinatorPID: getpid(), childPID: nil, mode: .run, state: .acquired,
                             label: "second writer", bead: nil, acquiredAt: RunRecord.timestamp())
            })
            defer { lease.release() }
            #expect(lease.inheritedDescriptors.count == 1)
            #expect(try !buildSessionLockAvailable(session.inheritedLeaseDescriptors()[0].path))
            try session.publishTerminal(.init(orchestrationFailures: ["fixture"]), completedAt: fixture.completedAt)
        }
    }

    @Test func rawBinarySuccessAndInputDriftPreserveNativeExitSeparately() async throws {
        for changed in [false, true] {
            let fixture = try BuildSessionFixture()
            defer { fixture.remove() }
            let report = try await fixture.withSession { session in
                let evidence = try await fixture.nativeEvidence(session, shell: #"printf '\000\377\200'; printf warning >&2"#,
                                                                changed: changed)
                // This observes an explicit shell fixture, not an Xcode build.
                return try session.publishTerminalForTrustedFixture(evidence, completedAt: fixture.completedAt)
            }
            #expect(report.nativeTermination == RunTermination(kind: .exit, value: 0))
            #expect(report.status == (changed ? "inconclusive" : "succeeded"))
            #expect(report.exitCode == (changed ? 3 : 0))
            let root = try StrictJSONDocument(data: report.originalData).root.requireObject()
            guard case .array(let logs) = try root.requiredValue(forKey: "rawLogReports") else { throw BuildSessionFixtureError.invalid }
            let capture = try logs[0].requireObject().requiredValue(forKey: "capture").requireObject()
            #expect(try logs[0].requireObject().value(forKey: "commandAdmission") == .string("trustedPackageFixture"))
            let actual = try logs[0].requireObject().requiredValue(forKey: "command").requireObject()
            #expect(actual.value(forKey: "executable") == .string("/bin/sh"))
            #expect(capture.value(forKey: "captureComplete") == .bool(true))
            let output = try capture.requiredValue(forKey: "standardOutput").requireObject()
            guard case .string(let path) = output.value(forKey: "path") else { throw BuildSessionFixtureError.invalid }
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data([0, 255, 128]))
        }
    }

    @Test func nativeFailureRemainsAuthoritativeOverDriverFailureAndCancellation() async throws {
        let fixture = try BuildSessionFixture()
        defer { fixture.remove() }
        let report = try await fixture.withSession { session in
            let observed = try await fixture.nativeEvidence(session, shell: "exit 29")
            let evidence = NotikaBuildSessionTerminalEvidence(
                sourceBefore: observed.sourceBefore, sourceAfter: observed.sourceAfter,
                toolchainBefore: observed.toolchainBefore, toolchainAfter: observed.toolchainAfter,
                compatibilityIdentity: observed.compatibilityIdentity, plan: observed.plan, outcome: observed.outcome,
                capturedPhases: observed.capturedPhases, orchestrationFailures: ["cleanup diagnostic"], cancelled: true)
            return try session.publishTerminalForTrustedFixture(evidence, completedAt: fixture.completedAt)
        }
        #expect(report.status == "failed")
        #expect(report.exitCode == 29)
        #expect(report.cancelled)
        #expect(report.nativeTermination == RunTermination(kind: .exit, value: 29))
    }

    @Test func changedRawEvidenceRefusesSuccessPublication() async throws {
        let fixture = try BuildSessionFixture()
        defer { fixture.remove() }
        await #expect(throws: (any Error).self) {
            try await fixture.withSession { session in
                let evidence = try await fixture.nativeEvidence(session, shell: "printf original")
                let capsule = try #require(evidence.capturedPhases.first)
                let file = open(capsule.rawCapture.standardOutput.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
                #expect(file >= 0)
                defer { _ = Darwin.close(file) }
                #expect("changed!".withCString { pwrite(file, $0, 8, 0) } == 8)
                #expect(fsync(file) == 0)
                try session.publishTerminalForTrustedFixture(evidence, completedAt: fixture.completedAt)
            }
        }
        if FileManager.default.fileExists(atPath: fixture.terminalURL.path) {
            #expect(try NotikaBuildSessionReport(data: Data(contentsOf: fixture.terminalURL)).status != "succeeded")
        }
    }

    @Test func diagnosticFallbackPreservesNativeFailureWithoutBlessingChangedLogs() async throws {
        let fixture = try BuildSessionFixture()
        defer { fixture.remove() }
        let report = try await fixture.withSession { session in
            let evidence = try await fixture.nativeEvidence(session, shell: "printf original; exit 29")
            let capsule = try #require(evidence.capturedPhases.first)
            let file = open(capsule.rawCapture.standardOutput.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
            #expect(file >= 0)
            defer { _ = Darwin.close(file) }
            #expect("changed!".withCString { pwrite(file, $0, 8, 0) } == 8)
            #expect(fsync(file) == 0)
            #expect(throws: (any Error).self) {
                try session.publishTerminalForTrustedFixture(evidence, completedAt: fixture.completedAt)
            }
            return try session.publishDiagnosticTerminal(evidence, publicationFailure: "raw evidence admission failed",
                                                         completedAt: fixture.completedAt)
        }
        #expect(report.exitCode == 29)
        #expect(report.nativeTermination == RunTermination(kind: .exit, value: 29))
        let root = try StrictJSONDocument(data: report.originalData).root.requireObject()
        guard case .array(let logs) = try root.requiredValue(forKey: "rawLogReports") else { throw BuildSessionFixtureError.invalid }
        #expect(try logs[0].requireObject().value(forKey: "publicationAdmitted") == .bool(false))
    }

    @Test func publicPublicationRejectsActualCommandSubstitution() async throws {
        let fixture = try BuildSessionFixture()
        defer { fixture.remove() }
        let report = try await fixture.withSession { session in
            let evidence = try await fixture.nativeEvidence(session, shell: "printf wrong-command")
            #expect(throws: NotikaBuildSessionError.invalidSchema("capturedPhaseCommand")) {
                try session.publishTerminal(evidence, completedAt: fixture.completedAt)
            }
            return try session.publishDiagnosticTerminal(evidence, publicationFailure: "actual native command did not match plan",
                                                         completedAt: fixture.completedAt)
        }
        #expect(report.nativeTermination == RunTermination(kind: .exit, value: 0))
        #expect(report.status == "inconclusive")
        #expect(report.exitCode == 70)
        let root = try StrictJSONDocument(data: report.originalData).root.requireObject()
        guard case .array(let logs) = try root.requiredValue(forKey: "rawLogReports") else { throw BuildSessionFixtureError.invalid }
        let raw = try logs[0].requireObject()
        #expect(raw.value(forKey: "publicationAdmitted") == .bool(false))
        #expect(raw.value(forKey: "commandAdmission") == .string("diagnostic"))
        #expect(try raw.requiredValue(forKey: "command").requireObject().value(forKey: "executable") == .string("/bin/sh"))
    }

    @Test func actualCommandCannotBeEditedOrRelabelledAsProductionEvidence() async throws {
        let fixture = try BuildSessionFixture()
        defer { fixture.remove() }
        let report = try await fixture.withSession { session in
            let evidence = try await fixture.nativeEvidence(session, shell: "printf fixture")
            return try session.publishTerminalForTrustedFixture(evidence, completedAt: fixture.completedAt)
        }
        let value = try #require(buildSessionMember(report.canonicalValue, "rawLogReports"))
        guard case .array(let logs) = value else { throw BuildSessionFixtureError.invalid }
        let first = try #require(logs.first)
        let command = try #require(buildSessionMember(first, "command"))
        let corruptions = [
            buildSessionUpdated(first, "commandAdmission", .string("production")),
            buildSessionUpdated(first, "command", buildSessionUpdated(command, "arguments", .array([.string("foreign")]))),
            buildSessionUpdated(first, "command", buildSessionUpdated(command, "workingDirectory", .string("/foreign"))),
            buildSessionUpdated(first, "command", buildSessionUpdated(command, "environmentSHA256", .string(String(repeating: "0", count: 64)))),
        ]
        for corrupt in corruptions {
            let raw = CanonicalJSONValue.array([corrupt])
            let commitments = try #require(buildSessionMember(report.canonicalValue, "commitments"))
            let updatedCommitments = buildSessionUpdated(commitments, "rawLogReportsSHA256", .string(try CanonicalJSONDigest.sha256(raw)))
            let changed = buildSessionUpdated(buildSessionUpdated(report.canonicalValue, "rawLogReports", raw),
                                              "commitments", updatedCommitments)
            #expect(throws: (any Error).self) { try NotikaBuildSessionReport(data: CanonicalJSONDigest.encode(changed)) }
        }
    }

    @Test func parameterizedUnitSelectionKeepsNonemptyCountsAndSeparateProbe() async throws {
        let fixture = try BuildSessionFixture()
        defer { fixture.remove() }
        let request = try NotikaActionRequest(makeRoute: .testUnitFocused, unitSelectors: ["FixtureTests/parameterized()"])
        let report = try await fixture.withSession(request: request) { session in
            let evidence = try await fixture.unitEvidence(session)
            let summary = try #require(evidence.resultSummary)
            #expect(summary.tests?.passed == 3)
            #expect(!summary.focusedMethod)
            #expect(summary.provesPassingRun)
            let report = try session.publishTerminalForTrustedFixture(evidence, completedAt: fixture.completedAt)
            try session.revalidateTerminal()
            return report
        }
        #expect(report.status == "succeeded")
        #expect(report.nativeTermination == RunTermination(kind: .exit, value: 0))
        let root = try StrictJSONDocument(data: report.originalData).root.requireObject()
        guard case .array(let observations) = try root.requiredValue(forKey: "phaseObservations"),
              case .array(let logs) = try root.requiredValue(forKey: "rawLogReports") else { throw BuildSessionFixtureError.invalid }
        #expect(observations.count == 2)
        #expect(logs.count == 2)
        let result = try root.requiredValue(forKey: "resultEvidence").requireObject()
        let probe = try result.requiredValue(forKey: "probe").requireObject()
        #expect(probe.value(forKey: "commandAdmission") == .string("trustedPackageFixture"))
        #expect(result.value(forKey: "provesPassingRun") == .bool(true))
        let custody = try result.requiredValue(forKey: "custody").requireObject()
        guard case .number(let ordinal) = try custody.requiredValue(forKey: "physicalOrdinal") else { throw BuildSessionFixtureError.invalid }
        #expect(try ordinal.int64() == 1)
    }

    @Test func unitNativeZeroWithoutResultCannotBecomeSuccess() async throws {
        let fixture = try BuildSessionFixture()
        defer { fixture.remove() }
        let request = try NotikaActionRequest(makeRoute: .testUnitFocused, unitSelectors: ["FixtureTests"])
        let report = try await fixture.withSession(request: request) { session in
            let evidence = try await fixture.unitEvidence(session, omitSummary: true)
            return try session.publishTerminalForTrustedFixture(evidence, completedAt: fixture.completedAt)
        }
        #expect(report.status == "inconclusive")
        #expect(report.exitCode == 3)
        #expect(report.nativeTermination == RunTermination(kind: .exit, value: 0))
        #expect(buildSessionMember(report.canonicalValue, "resultEvidence") == .null)
    }

    @Test func unitNativeFailureOutranksPassingSummaryCounts() async throws {
        let fixture = try BuildSessionFixture()
        defer { fixture.remove() }
        let request = try NotikaActionRequest(makeRoute: .testUnitFile, testFile: "FixtureTests")
        let report = try await fixture.withSession(request: request) { session in
            let evidence = try await fixture.unitEvidence(session, nativeExit: 29)
            #expect(evidence.resultSummary?.tests?.passed == 3)
            #expect(evidence.resultSummary?.provesPassingRun == false)
            return try session.publishTerminalForTrustedFixture(evidence, completedAt: fixture.completedAt)
        }
        #expect(report.status == "failed")
        #expect(report.exitCode == 29)
        #expect(report.nativeTermination == RunTermination(kind: .exit, value: 29))
    }

    @Test func failedSummaryProbeKeepsNativeExitAndDiagnosticCountsSeparate() async throws {
        let fixture = try BuildSessionFixture()
        defer { fixture.remove() }
        let request = try NotikaActionRequest(makeRoute: .testUnitFile, testFile: "FixtureTests")
        let report = try await fixture.withSession(request: request) { session in
            let evidence = try await fixture.unitEvidence(session, probeExit: 41)
            #expect(evidence.resultSummary?.tests == nil)
            #expect(evidence.resultSummary?.probe?.observation.termination == RunTermination(kind: .exit, value: 41))
            return try session.publishTerminalForTrustedFixture(evidence, completedAt: fixture.completedAt)
        }
        #expect(report.exitCode == 3)
        #expect(report.nativeTermination == RunTermination(kind: .exit, value: 0))
        let result = try #require(buildSessionMember(report.canonicalValue, "resultEvidence"))
        #expect(buildSessionMember(result, "provesPassingRun") == .bool(false))
    }

    @Test func resultTreeAndProbeAreRetainedThroughTerminalScopeExit() async throws {
        for mutateProbe in [false, true] {
            let fixture = try BuildSessionFixture()
            defer { fixture.remove() }
            let request = try NotikaActionRequest(makeRoute: .testUnitFile, testFile: "FixtureTests")
            await #expect(throws: (any Error).self) {
                try await fixture.withSession(request: request) { session in
                    let evidence = try await fixture.unitEvidence(session)
                    let summary = try #require(evidence.resultSummary)
                    _ = try session.publishTerminalForTrustedFixture(evidence, completedAt: fixture.completedAt)
                    let path = mutateProbe ? try #require(summary.probe).rawCapture.standardOutput.path
                        : summary.resultBundle.custody.resultPath + "/Data/evidence"
                    try Data("foreign".utf8).write(to: URL(fileURLWithPath: path))
                }
            }
        }
    }

    @Test func resultReportRejectsRecommittedCrossBindingsAndForgedCounts() async throws {
        let fixture = try BuildSessionFixture()
        defer { fixture.remove() }
        let request = try NotikaActionRequest(makeRoute: .testUnitFile, testFile: "FixtureTests")
        let report = try await fixture.withSession(request: request) { session in
            try session.publishTerminalForTrustedFixture(await fixture.unitEvidence(session), completedAt: fixture.completedAt)
        }
        let result = try #require(buildSessionMember(report.canonicalValue, "resultEvidence"))
        let custody = try #require(buildSessionMember(result, "custody"))
        let tests = try #require(buildSessionMember(result, "tests"))
        let probe = try #require(buildSessionMember(result, "probe"))
        let corruptedCustodies = [
            buildSessionUpdated(custody, "sourceBeforeHash", .string(String(repeating: "f", count: 64))),
            buildSessionUpdated(custody, "physicalOrdinal", .integer(0)),
            buildSessionUpdated(custody, "resultPath", .string(fixture.path + "/foreign.xcresult")),
        ]
        var corruptedResults = try corruptedCustodies.map { changed in
            buildSessionUpdated(buildSessionUpdated(result, "custody", changed), "custodySHA256",
                .string(try CanonicalJSONDigest.sha256(changed)))
        }
        corruptedResults += [
            buildSessionUpdated(result, "tests", buildSessionUpdated(tests, "executed", .integer(4))),
            buildSessionUpdated(result, "probe", buildSessionUpdated(probe, "commandAdmission", .string("production"))),
            buildSessionUpdated(result, "focusedMethod", .bool(true)),
            buildSessionUpdated(result, "provesPassingRun", .bool(false)),
        ]
        for changed in corruptedResults {
            let commitments = try #require(buildSessionMember(report.canonicalValue, "commitments"))
            let commitment = buildSessionUpdated(commitments, "resultEvidenceSHA256", .string(try CanonicalJSONDigest.sha256(changed)))
            let corrupt = buildSessionUpdated(buildSessionUpdated(report.canonicalValue, "resultEvidence", changed), "commitments", commitment)
            #expect(throws: (any Error).self) { try NotikaBuildSessionReport(data: CanonicalJSONDigest.encode(corrupt)) }
        }
    }

    @Test func diagnosticUnitFallbackMarksResultAndProbeUnadmitted() async throws {
        let fixture = try BuildSessionFixture()
        defer { fixture.remove() }
        let request = try NotikaActionRequest(makeRoute: .testUnitFile, testFile: "FixtureTests")
        let report = try await fixture.withSession(request: request) { session in
            let evidence = try await fixture.unitEvidence(session, nativeExit: 29)
            #expect(throws: (any Error).self) { try session.publishTerminal(evidence, completedAt: fixture.completedAt) }
            return try session.publishDiagnosticTerminal(evidence, publicationFailure: "production rejected shell fixture",
                completedAt: fixture.completedAt)
        }
        #expect(report.exitCode == 29)
        let result = try #require(buildSessionMember(report.canonicalValue, "resultEvidence"))
        let probe = try #require(buildSessionMember(result, "probe"))
        #expect(buildSessionMember(result, "publicationAdmitted") == .bool(false))
        #expect(buildSessionMember(result, "provesPassingRun") == .bool(false))
        #expect(buildSessionMember(probe, "publicationAdmitted") == .bool(false))
        #expect(buildSessionMember(probe, "commandAdmission") == .string("diagnostic"))
    }

    @Test func broadTestBindsResultToLaterLogicalRuntimeInvocation() async throws {
        let fixture = try BuildSessionFixture()
        defer { fixture.remove() }
        let request = try NotikaActionRequest(makeRoute: .testShowOnlyErrors)
        let outer = try buildSessionOuter(.macOS)
        let report = try await fixture.withSession(request: request, outerLeaseEvidence: outer) { session in
            try session.publishTerminalForTrustedFixture(await fixture.unitEvidence(session), completedAt: fixture.completedAt)
        }
        #expect(report.status == "succeeded")
        let root = try StrictJSONDocument(data: report.originalData).root.requireObject()
        guard case .array(let phases) = try root.requiredValue(forKey: "phaseObservations") else { throw BuildSessionFixtureError.invalid }
        #expect(phases.count == 3)
        let result = try root.requiredValue(forKey: "resultEvidence").requireObject()
        let custody = try result.requiredValue(forKey: "custody").requireObject()
        guard case .number(let logical) = try custody.requiredValue(forKey: "invocationOrdinal"),
              case .number(let physical) = try custody.requiredValue(forKey: "physicalOrdinal") else { throw BuildSessionFixtureError.invalid }
        #expect(try logical.int64() == 1)
        #expect(try physical.int64() == 2)
        let value = try #require(buildSessionMember(report.canonicalValue, "resultEvidence"))
        let changedCustody = buildSessionUpdated(try #require(buildSessionMember(value, "custody")), "invocationOrdinal", .integer(0))
        let changedResult = buildSessionUpdated(buildSessionUpdated(value, "custody", changedCustody),
            "custodySHA256", .string(try CanonicalJSONDigest.sha256(changedCustody)))
        let commitments = try #require(buildSessionMember(report.canonicalValue, "commitments"))
        let changed = buildSessionUpdated(buildSessionUpdated(report.canonicalValue, "resultEvidence", changedResult),
            "commitments", buildSessionUpdated(commitments, "resultEvidenceSHA256", .string(try CanonicalJSONDigest.sha256(changedResult))))
        #expect(throws: (any Error).self) { try NotikaBuildSessionReport(data: CanonicalJSONDigest.encode(changed)) }
    }

    @Test func leasedIPadSessionBindsDestinationAndRejectsContextForgery() async throws {
        let fixture = try BuildSessionFixture()
        defer { fixture.remove() }
        let request = try NotikaActionRequest(makeRoute: .testUnitFile, platform: .iPadSimulator, testFile: "FixtureTests")
        let outer = try buildSessionOuter(.iPadSimulator, simulatorID: "SIM-LEASE-123")
        let destination = "platform=iOS Simulator,id=SIM-LEASE-123"
        let report = try await fixture.withSession(request: request, destination: destination, outerLeaseEvidence: outer) { session in
            #expect(session.plannedDestination == destination)
            return try session.publishTerminalForTrustedFixture(await fixture.unitEvidence(session), completedAt: fixture.completedAt)
        }
        #expect(report.status == "succeeded")
        #expect(report.destination == destination)
        let wrong = "platform=iOS Simulator,id=DIFFERENT-ID"
        let outerValue = try #require(buildSessionMember(report.canonicalValue, "outerLeaseEvidence"))
        let changedOuter = buildSessionUpdated(outerValue, "simulatorID", .string("DIFFERENT-ID"))
        let context = CanonicalJSONValue.object(["destination": .string(wrong), "outerLeaseEvidence": changedOuter])
        let commitments = try #require(buildSessionMember(report.canonicalValue, "commitments"))
        let changed = buildSessionUpdated(buildSessionUpdated(buildSessionUpdated(report.canonicalValue, "destination", .string(wrong)),
            "outerLeaseEvidence", changedOuter), "commitments",
            buildSessionUpdated(commitments, "executionContextSHA256", .string(try CanonicalJSONDigest.sha256(context))))
        #expect(throws: (any Error).self) { try NotikaBuildSessionReport(data: CanonicalJSONDigest.encode(changed)) }
    }

    @Test func requiredOuterFactsFailBeforeCreatingSession() async throws {
        for request in [
            try NotikaActionRequest(makeRoute: .testUIFile, testFile: "FixtureUITests"),
            try NotikaActionRequest(makeRoute: .buildIOS),
        ] {
            let fixture = try BuildSessionFixture()
            defer { fixture.remove() }
            await #expect(throws: (any Error).self) {
                try await fixture.withSession(request: request, destination: request.platform == .macOS
                    ? "platform=macOS,arch=arm64" : "platform=iOS Simulator,id=SIM-LEASE-123") { _ in
                    Issue.record("missing outer facts reached session callback")
                }
            }
            #expect(!FileManager.default.fileExists(atPath: fixture.path + "/Artifacts"))
        }
    }

    @Test func focusedUIRequiresExactlyOneWhileUnitSelectionAllowsSeveral() async throws {
        for count in [1, 3] {
            let fixture = try BuildSessionFixture()
            defer { fixture.remove() }
            let request = try NotikaActionRequest(makeRoute: .testUIOnlyFile, testFile: "FixtureUITests", testMethod: "testFocused")
            let outer = try buildSessionOuter(.macOS)
            let report = try await fixture.withSession(request: request, outerLeaseEvidence: outer) { session in
                let evidence = try await fixture.unitEvidence(session, passedTests: count)
                #expect(evidence.resultSummary?.focusedMethod == true)
                return try session.publishTerminalForTrustedFixture(evidence, completedAt: fixture.completedAt)
            }
            #expect(report.exitCode == (count == 1 ? 0 : 3))
            #expect(report.nativeTermination == RunTermination(kind: .exit, value: 0))
        }
    }

    @Test func olderBuildContextAndNewPairedCommitmentRemainDistinct() async throws {
        let fixture = try BuildSessionFixture()
        defer { fixture.remove() }
        let report = try await fixture.withSession { session in
            try session.publishTerminal(.init(orchestrationFailures: ["fixture"]), completedAt: fixture.completedAt)
        }
        let commitments = try #require(buildSessionMember(report.canonicalValue, "commitments"))
        let legacy = buildSessionRemoving(buildSessionRemoving(buildSessionUpdated(report.canonicalValue, "commitments",
            buildSessionRemoving(commitments, "executionContextSHA256")), "destination"), "outerLeaseEvidence")
        #expect(try NotikaBuildSessionReport(data: CanonicalJSONDigest.encode(legacy)).destination == "platform=macOS,arch=arm64")
        let incomplete = buildSessionRemoving(report.canonicalValue, "outerLeaseEvidence")
        #expect(throws: (any Error).self) { try NotikaBuildSessionReport(data: CanonicalJSONDigest.encode(incomplete)) }
    }

    @Test func requiredPreparationIsIndependentAndNativeFailureRemainsAuthoritative() async throws {
        for platform in [NotikaPlatform.macOS, .iPadSimulator] {
            for preparationExit in [Int32(0), 37] {
                let fixture = try BuildSessionFixture()
                defer { fixture.remove() }
                let request = try NotikaActionRequest(makeRoute: platform == .macOS ? .testShowOnlyErrors : .testUnitFile,
                    platform: platform, testFile: platform == .macOS ? "" : "FixtureTests")
                let outer = try buildSessionOuter(platform, simulatorID: platform == .iPadSimulator ? "SIM-PREP-123" : nil)
                let report = try await fixture.withSession(request: request, destination: outer.destination,
                    outerLeaseEvidence: outer) { session in
                    let evidence = try await fixture.unitEvidence(session, preparationExit: preparationExit,
                        omitPreparation: preparationExit == 0)
                    return try session.publishTerminalForTrustedFixture(evidence, completedAt: fixture.completedAt)
                }
                #expect(report.exitCode == (preparationExit == 0 ? 3 : preparationExit))
                #expect(report.nativeTermination == RunTermination(kind: .exit, value: preparationExit))
                let result = try #require(buildSessionMember(report.canonicalValue, "resultEvidence"))
                #expect(buildSessionMember(result, "provesPassingRun") == .bool(true))
            }
        }
    }

    @Test func preparationCaptureRemainsRetainedThroughSessionExit() async throws {
        let fixture = try BuildSessionFixture()
        defer { fixture.remove() }
        let request = try NotikaActionRequest(makeRoute: .testUIOnlyFile, testFile: "FixtureUITests", testMethod: "testFocused")
        let outer = try buildSessionOuter(.macOS)
        await #expect(throws: (any Error).self) {
            try await fixture.withSession(request: request, outerLeaseEvidence: outer) { session in
                let evidence = try await fixture.unitEvidence(session, passedTests: 1)
                let report = try session.publishTerminalForTrustedFixture(evidence, completedAt: fixture.completedAt)
                #expect(report.exitCode == 0)
                let preparation = try #require(evidence.uiPreparation)
                try Data("replacement".utf8).write(to: URL(fileURLWithPath: preparation.rawCapture.standardOutput.path))
            }
        }
    }

    @Test func passingNativeAndResultCannotReplaceRequiredGateOrConsumerEvidence() async throws {
        for request in [
            try NotikaActionRequest(makeRoute: .testUnit),
            try NotikaActionRequest(makeRoute: .coverageJSON),
            try NotikaActionRequest(makeRoute: .testCanvasFramePacingPerformance),
        ] {
            let fixture = try BuildSessionFixture()
            defer { fixture.remove() }
            let outer = NotikaLeaseBoundary.requiresOuterLease(for: request) ? try buildSessionOuter(.macOS) : nil
            let report = try await fixture.withSession(request: request, outerLeaseEvidence: outer) { session in
                let evidence = try await fixture.unitEvidence(session,
                    passedTests: request.canonicalMakeRoute == .testCanvasFramePacingPerformance ? 1 : 3)
                #expect(evidence.resultSummary?.provesPassingRun == true)
                return try session.publishTerminalForTrustedFixture(evidence, completedAt: fixture.completedAt)
            }
            #expect(report.status == "inconclusive")
            #expect(report.exitCode == 3)
            #expect(report.nativeTermination == RunTermination(kind: .exit, value: 0))
        }
    }

    @Test func productionPreparationRejectsRecommittedFixtureCommand() async throws {
        let fixture = try BuildSessionFixture()
        defer { fixture.remove() }
        let request = try NotikaActionRequest(makeRoute: .testUIOnlyFile, testFile: "FixtureUITests", testMethod: "testFocused")
        let outer = try buildSessionOuter(.macOS)
        let report = try await fixture.withSession(request: request, outerLeaseEvidence: outer) { session in
            try session.publishTerminalForTrustedFixture(await fixture.unitEvidence(session, passedTests: 1),
                completedAt: fixture.completedAt)
        }
        let preparation = try #require(buildSessionMember(report.canonicalValue, "uiPreparation"))
        let forged = buildSessionUpdated(preparation, "commandAdmission", .string("production"))
        let commitments = try #require(buildSessionMember(report.canonicalValue, "commitments"))
        let changed = buildSessionUpdated(buildSessionUpdated(report.canonicalValue, "uiPreparation", forged), "commitments",
            buildSessionUpdated(commitments, "uiPreparationSHA256", .string(try CanonicalJSONDigest.sha256(forged))))
        #expect(throws: (any Error).self) { try NotikaBuildSessionReport(data: CanonicalJSONDigest.encode(changed)) }
    }

    @Test func refusedInitialResultProbeKeepsRawDiagnosticAndNativeOutcome() async throws {
        for nativeExit in [Int32(0), 29] {
            let fixture = try BuildSessionFixture()
            defer { fixture.remove() }
            let request = try NotikaActionRequest(makeRoute: .testUnitFile, testFile: "FixtureTests")
            let report = try await fixture.withSession(request: request) { session in
                let evidence = try await fixture.unitEvidence(session, nativeExit: nativeExit, rejectInitialResultProbe: true)
                #expect(evidence.resultSummary == nil)
                #expect(evidence.resultPreparation?.probe?.rawCapture.captureComplete == true)
                return try session.publishTerminalForTrustedFixture(evidence, completedAt: fixture.completedAt)
            }
            #expect(report.exitCode == (nativeExit == 0 ? 70 : nativeExit))
            #expect(report.nativeTermination == RunTermination(kind: .exit, value: nativeExit))
            #expect(buildSessionMember(report.canonicalValue, "resultEvidence") == .null)
            let preparation = try #require(buildSessionMember(report.canonicalValue, "resultPreparation"))
            let probe = try #require(buildSessionMember(preparation, "probe"))
            #expect(buildSessionMember(probe, "publicationAdmitted") == .bool(false))
            #expect(buildSessionMember(probe, "commandAdmission") == .string("diagnostic"))
            let native = try #require(buildSessionMember(probe, "native"))
            let termination = try #require(buildSessionMember(native, "termination"))
            #expect(try CanonicalJSONDigest.encode(termination) == Data(#"{"kind":"exit","value":0}"#.utf8))

            let forged = buildSessionUpdated(preparation, "probe", buildSessionUpdated(probe, "publicationAdmitted", .bool(true)))
            let commitments = try #require(buildSessionMember(report.canonicalValue, "commitments"))
            let changed = buildSessionUpdated(buildSessionUpdated(report.canonicalValue, "resultPreparation", forged), "commitments",
                buildSessionUpdated(commitments, "resultPreparationSHA256", .string(try CanonicalJSONDigest.sha256(forged))))
            #expect(throws: (any Error).self) { try NotikaBuildSessionReport(data: CanonicalJSONDigest.encode(changed)) }
        }
    }

    @Test func refusedInitialProbeStillHasRetainedRawCustodyAtSessionExit() async throws {
        let fixture = try BuildSessionFixture()
        defer { fixture.remove() }
        let request = try NotikaActionRequest(makeRoute: .testUnitFile, testFile: "FixtureTests")
        await #expect(throws: (any Error).self) {
            try await fixture.withSession(request: request) { session in
                let evidence = try await fixture.unitEvidence(session, rejectInitialResultProbe: true)
                let report = try session.publishTerminalForTrustedFixture(evidence, completedAt: fixture.completedAt)
                #expect(report.exitCode == 70)
                let probe = try #require(evidence.resultPreparation?.probe)
                try Data("changed refused probe".utf8).write(to: URL(fileURLWithPath: probe.rawCapture.standardOutput.path))
            }
        }
    }

    @Test func cancellationAfterNativeCompletionPreservesNativeExitSeparately() async throws {
        let fixture = try BuildSessionFixture()
        defer { fixture.remove() }
        let request = try NotikaActionRequest(makeRoute: .testUnitFile, testFile: "FixtureTests")
        let report = try await fixture.withSession(request: request) { session in
            try session.publishTerminalForTrustedFixture(await fixture.unitEvidence(session, cancelled: true),
                completedAt: fixture.completedAt)
        }
        #expect(report.status == "cancelled")
        #expect(report.exitCode == 130)
        #expect(report.nativeTermination == RunTermination(kind: .exit, value: 0))
        let execution = try #require(buildSessionMember(report.canonicalValue, "execution"))
        #expect(buildSessionMember(execution, "complete") == .bool(false))
        let completedCount = try #require(buildSessionMember(execution, "completedPhaseCount"))
        let plannedCount = try #require(buildSessionMember(execution, "plannedPhaseCount"))
        // One logical test expands to compile and execution. Cancellation
        // afterward changes wrapper status without discarding either result.
        #expect(try CanonicalJSONDigest.encode(completedCount) == Data("2".utf8))
        #expect(try CanonicalJSONDigest.encode(plannedCount) == Data("2".utf8))
        let observationValue = try #require(buildSessionMember(report.canonicalValue, "phaseObservations"))
        guard case .array(let observations) = observationValue else { throw BuildSessionFixtureError.invalid }
        #expect(observations.count == 2)
        for observation in observations {
            let native = try #require(buildSessionMember(observation, "native"))
            let termination = try #require(buildSessionMember(native, "termination"))
            #expect(try CanonicalJSONDigest.encode(termination) == Data(#"{"kind":"exit","value":0}"#.utf8))
        }
    }
}

private struct BuildSessionFixture: Sendable {
    let root: URL
    let path: String
    let registry: String
    let runID = UUID().uuidString
    let startedAt = Date(timeIntervalSince1970: 1_767_225_600) // 1 January 2026 UTC.
    var completedAt: Date { startedAt.addingTimeInterval(1) }
    var terminalURL: URL { URL(fileURLWithPath: path + "/Artifacts/AgentSessions/" + runID + "/manifest.json") }

    init() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("agentbuild-session-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let resolved = realpath(temporary.path, nil) else { throw BuildSessionFixtureError.invalid }
        defer { free(resolved) }
        root = URL(fileURLWithPath: String(cString: resolved))
        path = root.appendingPathComponent("repository").path
        registry = root.appendingPathComponent("registry").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func withSession<Result: Sendable>(
        request: NotikaActionRequest? = nil, destination: String? = nil, outerLeaseEvidence: NotikaOuterLeaseEvidence? = nil,
        _ operation: @Sendable (NotikaBuildSession) async throws -> Result
    ) async throws -> Result {
        try await NotikaBuildSession.withSession(canonicalRepository: path, registryRoot: registry,
            request: request ?? NotikaActionRequest(makeRoute: .buildMacOS),
            destination: destination, outerLeaseEvidence: outerLeaseEvidence, runID: runID, startedAt: startedAt,
            timeZone: TimeZone(identifier: "Europe/Madrid")!, operation: operation)
    }

    /// The fixture replaces Xcode and xcresulttool with literal shell commands.
    /// It still uses the owned helper, real result tree, pinned probe directory,
    /// raw producer capsules and the internal, explicitly marked fixture policy.
    func unitEvidence(
        _ session: NotikaBuildSession, nativeExit: Int32 = 0, probeExit: Int32 = 0,
        omitSummary: Bool = false, passedTests: Int = 3, preparationExit: Int32 = 0,
        omitPreparation: Bool = false, rejectInitialResultProbe: Bool = false, cancelled: Bool = false
    ) async throws -> NotikaBuildSessionTerminalEvidence {
        let digest = String(repeating: "a", count: 64)
        let source = sourceIdentity(status: "before")
        let toolchain = NotikaToolchainIdentity(keyMaterial: .object(["swift": .string("fixture")]))
        let profile = NotikaCacheProfile(request: session.request)
        let identity = try CacheCompatibilityIdentity(canonicalWorktree: path, toolchainHash: toolchain.digest(),
            gitlinks: [], submoduleStatusDigest: digest, submoduleWorktreeDigest: digest, projectGraphDigest: digest,
            generatedGraphDigest: digest, resolvedDependenciesDigest: digest, scheme: profile.scheme.rawValue, configuration: profile.configuration.rawValue,
            destinationFamily: profile.destinationFamily.rawValue, buildFlags: profile.buildFlags)
        let plan = try NotikaXcodeInvocationPlan(request: session.request, destination: session.plannedDestination,
            cacheDirectory: path + "/DerivedData/AgentCaches/" + identity.cacheKey(), resultBundle: session.path + "/result.xcresult")
        let ledger = try NativeInvocationLedger(plan: plan)
        let runtime = try #require(ledger.phases.last)
        let reservation = try NotikaResultBundle(sessionDirectory: session.path, runID: runID, sourceBeforeHash: source.digest(),
            request: session.request, invocation: #require(plan.invocations.last), phase: runtime)
        var capsules: [CapturedNativePhase] = []
        var observations: [NotikaOwnedPhaseObservation] = []
        let helper = AgentBuildTestPaths.packageRoot.appendingPathComponent(".build/debug/agentbuild").path
        let preparation: CapturedNativePhase?
        if session.request.platform == .iPadSimulator && !omitPreparation {
            preparation = try await CapturedNativePhaseRunner().run(helperExecutable: helper,
                command: DarwinWorkloadCommand(executable: "/bin/sh", arguments: ["-c", "exit " + String(preparationExit)],
                    workingDirectory: path, environment: ["PATH": "/usr/bin:/bin"]),
                retainedLockDescriptors: session.inheritedDescriptors(), artifactRoot: session.path)
        } else { preparation = nil }
        let uiPreparation: CapturedNativePhase?
        if NotikaBuildCoordinator.requiresUIPreparation(for: session.request) && !omitPreparation {
            // This never copies scripts into the account home: the private
            // fixture policy records a literal shell substitute explicitly.
            uiPreparation = try await CapturedNativePhaseRunner().run(helperExecutable: helper,
                command: DarwinWorkloadCommand(executable: "/bin/sh", arguments: ["-c", "exit " + String(preparationExit)],
                    workingDirectory: path, environment: ["PATH": "/usr/bin:/bin"]),
                retainedLockDescriptors: session.inheritedDescriptors(), artifactRoot: session.path)
        } else { uiPreparation = nil }
        for phase in ledger.phases {
            let claim = try await ledger.claim(ordinal: phase.ordinal, phaseOrdinal: phase.phaseOrdinal, arguments: phase.arguments)
            if !phase.requiresCompilation {
                try FileManager.default.createDirectory(atPath: reservation.path + "/Data", withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                try Data([0, 255, 128, 4]).write(to: URL(fileURLWithPath: reservation.path + "/Data/evidence"))
                #expect(chmod(reservation.path + "/Data/evidence", 0o600) == 0)
            }
            let exit = phase.requiresCompilation ? 0 : nativeExit
            let captured = try await CapturedNativePhaseRunner().run(helperExecutable: helper,
                command: DarwinWorkloadCommand(executable: "/bin/sh", arguments: ["-c", "printf native; exit " + String(exit)],
                    workingDirectory: path, environment: ["PATH": "/usr/bin:/bin"]),
                retainedLockDescriptors: session.inheritedDescriptors(), artifactRoot: session.path)
            try await ledger.complete(claim, termination: captured.observation.termination)
            capsules.append(captured)
            observations.append(.init(phase: phase, workload: captured.observation))
        }
        let outcome = NotikaOwnedExecutionOutcome(ledger: await ledger.snapshot(), observations: observations,
            orchestrationFailure: nil, cancelled: false)
        var summary: NotikaResultSummaryEvidence?
        var resultPreparation: NotikaResultPreparationFailure?
        if rejectInitialResultProbe {
            let descriptors = try session.inheritedDescriptors()
            do {
                _ = try await reservation.admitAfterRetirementForTrustedFixture(#require(capsules.last),
                    environment: ["PATH": "/usr/bin:/bin"]) { requested, directory in
                    let captured = try await CapturedNativePhaseRunner().run(helperExecutable: helper,
                        command: DarwinWorkloadCommand(executable: "/bin/sh", arguments: ["-c", "printf '{}'"],
                            workingDirectory: requested.workingDirectory, environment: requested.environment),
                        retainedLockDescriptors: descriptors, nativeWorkingDirectoryDescriptor: directory, artifactRoot: session.path)
                    // A new unrelated payload is outside the one controlled
                    // SQLite-index addition. Admission must reject it.
                    let foreign = reservation.path + "/foreign-after-native"
                    try Data("foreign".utf8).write(to: URL(fileURLWithPath: foreign))
                    #expect(chmod(foreign, 0o600) == 0)
                    return captured
                }
                Issue.record("foreign initial-probe addition received result admission")
            } catch let failure as NotikaResultPreparationFailure {
                resultPreparation = failure
            }
        } else if !omitSummary {
            let bundle = try reservation.admitAfterRetirementForTrustedFixture(#require(capsules.last))
            let descriptors = try session.inheritedDescriptors()
            summary = await bundle.observeSummaryForTrustedFixture(environment: ["PATH": "/usr/bin:/bin"]) { requested, directory in
                let json = #"{"result":"Passed","passedTests":"# + String(passedTests)
                    + #","failedTests":0,"skippedTests":0,"totalTestCount":"# + String(passedTests) + "}"
                let script = "printf '%s' '" + json + "'; exit " + String(probeExit)
                return try await CapturedNativePhaseRunner().run(helperExecutable: helper,
                    command: DarwinWorkloadCommand(executable: "/bin/sh", arguments: ["-c", script],
                        workingDirectory: requested.workingDirectory, environment: requested.environment),
                    retainedLockDescriptors: descriptors, nativeWorkingDirectoryDescriptor: directory, artifactRoot: session.path)
            }
        }
        return .init(sourceBefore: source, sourceAfter: source, toolchainBefore: toolchain, toolchainAfter: toolchain,
            compatibilityIdentity: identity, plan: plan, outcome: outcome, capturedPhases: capsules,
            resultSummary: summary, resultPreparation: resultPreparation,
            simulatorPreparation: preparation, uiPreparation: uiPreparation, cancelled: cancelled)
    }

    func nativeEvidence(
        _ session: NotikaBuildSession, shell: String, changed: Bool = false
    ) async throws -> NotikaBuildSessionTerminalEvidence {
        let digest = String(repeating: "a", count: 64)
        let source = sourceIdentity(status: "before")
        let toolchain = NotikaToolchainIdentity(keyMaterial: .object(["swift": .string("fixture")]))
        let profile = NotikaCacheProfile(request: session.request)
        let identity = try CacheCompatibilityIdentity(canonicalWorktree: path, toolchainHash: toolchain.digest(),
            gitlinks: [], submoduleStatusDigest: digest, submoduleWorktreeDigest: digest, projectGraphDigest: digest,
            generatedGraphDigest: digest, resolvedDependenciesDigest: digest, scheme: profile.scheme.rawValue, configuration: profile.configuration.rawValue,
            destinationFamily: profile.destinationFamily.rawValue, buildFlags: profile.buildFlags)
        let plan = try NotikaXcodeInvocationPlan(request: session.request, destination: session.plannedDestination,
            cacheDirectory: path + "/DerivedData/AgentCaches/" + identity.cacheKey(),
            resultBundle: session.path + "/unused.xcresult")
        let ledger = try NativeInvocationLedger(plan: plan)
        let phase = try #require(ledger.phases.first)
        let claim = try await ledger.claim(ordinal: phase.ordinal, phaseOrdinal: phase.phaseOrdinal, arguments: phase.arguments)
        let packageRoot = AgentBuildTestPaths.packageRoot
        let helper = packageRoot.appendingPathComponent(".build/debug/agentbuild").path
        #expect(FileManager.default.isExecutableFile(atPath: helper))
        let capsule = try await CapturedNativePhaseRunner().run(helperExecutable: helper,
            command: DarwinWorkloadCommand(executable: "/bin/sh", arguments: ["-c", shell], workingDirectory: path,
                                           environment: ["PATH": "/usr/bin:/bin"]),
            retainedLockDescriptors: session.inheritedDescriptors(), artifactRoot: session.path)
        try await ledger.complete(claim, termination: capsule.observation.termination)
        let outcome = NotikaOwnedExecutionOutcome(ledger: await ledger.snapshot(),
            observations: [.init(phase: phase, workload: capsule.observation)], orchestrationFailure: nil, cancelled: false)
        return NotikaBuildSessionTerminalEvidence(sourceBefore: source, sourceAfter: changed ? sourceIdentity(status: "after") : source,
            toolchainBefore: toolchain, toolchainAfter: toolchain, compatibilityIdentity: identity,
            plan: plan, outcome: outcome, capturedPhases: [capsule])
    }

    private func sourceIdentity(status: String) -> NotikaSourceIdentity {
        let digest = String(repeating: "a", count: 64)
        return NotikaSourceIdentity(canonicalWorktree: path, head: String(repeating: "a", count: 40), gitlinks: [],
            statusDigest: digest, stagedDiffDigest: digest, unstagedDiffDigest: digest, submoduleStatusDigest: digest,
            submoduleWorktreeDigest: digest, projectGraphDigest: digest, generatedGraphDigest: digest,
            resolvedDependenciesDigest: digest,
            keyMaterial: .object([
                .init(key: "canonicalWorktree", value: .string(path)),
                .init(key: "head", value: .string(String(repeating: "a", count: 40))),
                .init(key: "fixtureStatus", value: .string(status)),
                .init(key: "é", value: .string("composed")),
                .init(key: "e\u{301}", value: .string("decomposed")),
            ]))
    }
}

private enum BuildSessionFixtureError: Error { case invalid }
private func buildSessionMember(_ value: CanonicalJSONValue, _ field: String) -> CanonicalJSONValue? {
    guard case .object(let members) = value else { return nil }
    return members.first { $0.key.utf8.elementsEqual(field.utf8) }?.value
}
private func buildSessionUpdated(_ value: CanonicalJSONValue, _ field: String, _ replacement: CanonicalJSONValue) -> CanonicalJSONValue {
    guard case .object(var members) = value else { return value }
    members.removeAll { $0.key.utf8.elementsEqual(field.utf8) }
    members.append(.init(key: field, value: replacement))
    return .object(members)
}
private func buildSessionRemoving(_ value: CanonicalJSONValue, _ field: String) -> CanonicalJSONValue {
    guard case .object(let members) = value else { return value }
    return .object(members.filter { !$0.key.utf8.elementsEqual(field.utf8) })
}
private func buildSessionOuter(_ platform: NotikaPlatform, simulatorID: String? = nil) throws -> NotikaOuterLeaseEvidence {
    let value = CanonicalJSONValue.object([
        "platform": .string(platform.rawValue), "sessionID": .string("fixture-outer-session"),
        "simulatorID": simulatorID.map(CanonicalJSONValue.string) ?? .null,
        "hostResource": platform == .macOS ? .string("macos-ui") : .null,
    ])
    return try JSONDecoder().decode(NotikaOuterLeaseEvidence.self, from: CanonicalJSONDigest.encode(value))
}
private func buildSessionReplacing(_ value: CanonicalJSONValue, field: String, value replacement: CanonicalJSONValue) throws -> Data {
    guard case .object(var members) = value else { throw BuildSessionFixtureError.invalid }
    members.removeAll { $0.key.utf8.elementsEqual(field.utf8) }
    members.append(.init(key: field, value: replacement))
    return try CanonicalJSONDigest.encode(.object(members))
}
private func buildSessionLockAvailable(_ path: String) throws -> Bool {
    let descriptor = open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw BuildSessionFixtureError.invalid }
    defer { _ = Darwin.close(descriptor) }
    if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
    guard errno == EWOULDBLOCK else { throw BuildSessionFixtureError.invalid }
    return false
}
private func buildSessionLockEventuallyAvailable(_ path: String) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    repeat {
        if try buildSessionLockAvailable(path) { return true }
        try await Task.sleep(for: .milliseconds(10))
    } while clock.now < deadline
    return false
}

/// Parallel fixtures can raise retained descriptors far above any fixed scan
/// range. Ask the kernel for the actual set, retrying a full buffer if concurrent
/// opens outgrow the sizing query; the session's own retained inode stays live.
private func buildSessionProcessFileDescriptors() throws -> [Int32] {
    let stride = MemoryLayout<proc_fdinfo>.stride
    let required = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
    guard required > 0 else { throw BuildSessionFixtureError.invalid }
    var capacity = Int(required) / stride + 64
    for _ in 0..<8 {
        var entries = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let read = entries.withUnsafeMutableBytes {
            proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard read > 0, Int(read) % stride == 0 else { throw BuildSessionFixtureError.invalid }
        if Int(read) < capacity * stride {
            return entries.prefix(Int(read) / stride).map(\.proc_fd).filter { $0 >= 3 }
        }
        capacity *= 2
    }
    throw BuildSessionFixtureError.invalid
}
