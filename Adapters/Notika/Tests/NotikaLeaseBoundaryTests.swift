@testable import AgentBuildCore
import Foundation
@testable import NotikaAdapter
import Testing

@Suite("Notika outer UI and simulator boundary")
struct NotikaLeaseBoundaryTests {
    @Test func buildAndFocusedUnitsRemainUnleasedWhileEveryUIRouteRequiresOwnership() throws {
        for route: NotikaMakeRoute in [.buildMacOS, .testUnitFile] {
            let request = try NotikaActionRequest(makeRoute: route,
                testFile: route == .testUnitFile ? "FixtureTests" : "")
            #expect(try NotikaLeaseBoundary.admit(request: request, environment: [:]) == nil)
        }
        for route: NotikaMakeRoute in [.testUI, .testUIOnly, .testUIOnlyFile, .testUIVisual] {
            let request = try NotikaActionRequest(makeRoute: route,
                testFile: route == .testUIOnlyFile ? "FixtureUITests" : "",
                testMethod: route == .testUIOnlyFile ? "testFixture" : "")
            #expect(throws: NotikaLeaseBoundaryError.missingLease) {
                try NotikaLeaseBoundary.admit(request: request, environment: [:])
            }
        }
    }

    @Test func partialAndConflictingInheritedFieldsCannotStartASecondLease() throws {
        let request = try NotikaActionRequest(makeRoute: .buildMacOS)
        #expect(throws: NotikaLeaseBoundaryError.partialEnvironment) {
            try NotikaLeaseBoundary.admit(request: request, environment: ["SIMLEASE_MACOS_UI": "1"])
        }
        #expect(throws: NotikaLeaseBoundaryError.conflictingPlatform) {
            try NotikaLeaseBoundary.admit(request: request, environment: [
                "SIMLEASE_SESSION_ID": "session-123", "SIMLEASE_MACOS_UI": "1",
                "SIMLEASE_HOST_RESOURCE": "macos-ui", "SIMULATOR_ID": "other-123"
            ])
        }
        #expect(throws: NotikaLeaseBoundaryError.conflictingPlatform) {
            try NotikaLeaseBoundary.reexecuteIfRequired(request: request, environment: [
                "SIMLEASE_SESSION_ID": "session-123", "SIMULATOR_ID": "other-123"
            ], executable: "/fixture/agentbuild", arguments: [], label: "fixture")
        }
    }

    @Test func inheritedMacOSLeaseHasExactNullAndDestinationFields() throws {
        let request = try NotikaActionRequest(makeRoute: .testUIOnly)
        let evidence = try #require(try NotikaLeaseBoundary.admit(request: request, environment: [
            "SIMLEASE_SESSION_ID": "session-123", "SIMLEASE_MACOS_UI": "1", "SIMLEASE_HOST_RESOURCE": "macos-ui"
        ]))
        #expect(evidence.destination == "platform=macOS,arch=arm64")
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(evidence)) as? [String: Any])
        #expect(Set(object.keys) == ["platform", "sessionID", "simulatorID", "hostResource"])
        #expect(object["simulatorID"] is NSNull)
        #expect(try JSONDecoder().decode(NotikaOuterLeaseEvidence.self,
            from: JSONEncoder().encode(evidence)) == evidence)
        try NotikaLeaseBoundary.reexecuteIfRequired(request: request, environment: [
            "SIMLEASE_SESSION_ID": "session-123", "SIMLEASE_MACOS_UI": "1", "SIMLEASE_HOST_RESOURCE": "macos-ui"
        ], executable: "/fixture/agentbuild", arguments: [], label: "fixture")
    }

    @Test func simulatorDestinationUsesOnlyMatchingExportedPrivateDevice() throws {
        let request = try NotikaActionRequest(makeRoute: .buildIOS)
        let environment = ["SIMLEASE_SESSION_ID": "session-123", "SIMULATOR_ID": "private-456",
                           "SIMULATOR_UDID": "private-456"]
        let evidence = try #require(try NotikaLeaseBoundary.admit(request: request, environment: environment))
        #expect(evidence.destination == "platform=iOS Simulator,id=private-456")
        var mismatched = environment
        mismatched["SIMULATOR_UDID"] = "foreign-789"
        #expect(throws: NotikaLeaseBoundaryError.conflictingPlatform) {
            try NotikaLeaseBoundary.admit(request: request, environment: mismatched)
        }
        var unsafe = environment
        unsafe["SIMULATOR_ID"] = "private;$(false)"
        unsafe["SIMULATOR_UDID"] = "private;$(false)"
        #expect(throws: NotikaLeaseBoundaryError.invalidSimulatorID) {
            try NotikaLeaseBoundary.admit(request: request, environment: unsafe)
        }
    }

    @Test func freshBoundaryPreservesLiteralArgumentsAndSelectsAnExplicitIPad() throws {
        let request = try NotikaActionRequest(makeRoute: .testUIFile, platform: .iPadSimulator,
            testFile: "FixtureUITests", testMethod: "testFixture", device: "iPad Air 13-inch (M4)")
        let literal = ["notika", "build", "--file", "$(false) `literal`"]
        #expect(try NotikaLeaseBoundary.outerArguments(request: request, executable: "/fixture/agentbuild",
            arguments: literal, label: "fixture") == ["run", "--label", "fixture", "--device",
            "iPad Air 13-inch (M4)", "--", "/fixture/agentbuild"] + literal)
    }

    @Test func rustOwnershipOnlySharesGraphAndNeverInventsXcodeCache() throws {
        let plan = try NotikaProjectOwnershipPlan(rustTestFor: "/fixture/Notika")
        #expect(plan.cacheDirectory == nil)
        #expect(plan.orderedLeases.count == 1)
        #expect(plan.orderedLeases.first?.resource.value.hasPrefix("notika:generated-xcode-graph:") == true)
        #expect(plan.orderedLeases.first?.mode == .shared)
    }
}
