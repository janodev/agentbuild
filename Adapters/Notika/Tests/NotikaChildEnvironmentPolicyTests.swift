import AgentBuildCore
import Foundation
@testable import NotikaAdapter
import Testing

@Suite("Notika child environment policy")
struct NotikaChildEnvironmentPolicyTests {
    @Test func inheritedNamesMatchStaticPythonOracle() throws {
        // json.dumps(sorted(CHILD_ENVIRONMENT_ALLOWLIST), ensure_ascii=False,
        // separators=(",", ":")) from the reference driver.
        let names = NotikaChildEnvironmentPolicy.inheritedNames.sorted()
        #expect(names.count == 21)
        #expect(try CanonicalJSONDigest.sha256(.array(names.map { .string($0) })) ==
                "89064871754c1857192c057057672c2db908e06bf33d2d20afb87106162b48cc")
        let input = Dictionary(uniqueKeysWithValues: names.map { ($0, "value-" + $0) })
        #expect(try NotikaChildEnvironmentPolicy.inheritedEnvironment(from: input) == input)
    }

    @Test func inheritedOverridesAndUnknownMalformedValuesAreDropped() throws {
        let input = [
            "HOME": "/account", "PATH": "/tools", "LANG": "", "SDKROOT": "/foreign/sdk",
            "NOTIKA_ROUTE_AUTHORITY_FD": "64", "NOTIKA_ROUTE_GRAPH_LOCK_FD": "65",
            "NOTIKA_INTERACTIVE_HOST_CUSTODY_FD": "66", "NOTIKA_REPORT_HANDOFF_FD": "67",
            "NOTIKA_DERIVED_DATA": "/foreign/cache", "AGENTLEASE_LEASE_DESCRIPTORS": "foreign manifest",
            "AGENTLEASE_HELD_RESOURCES": "foreign ownership", "AGENTLEASE_RUN_ID": "foreign run",
            "XCODEBUILD": "/foreign/xcodebuild", "XCODEBUILD_FLAGS": "foreign flags",
            "TEST_XCODEBUILD_FLAGS": "foreign flags", "TEST_RUNNER_NOTIKA_AGENT_SESSION_ID": "foreign session",
            "SWIFTFLAGS": "foreign flags", "CARGO_TARGET_DIR": "/foreign/cargo", "RUSTFLAGS": "foreign flags",
            "USE_CACHED_DEPENDENCIES": "1", "TUIST_USE_LOCAL_MD_VAULT": "1", "TUIST_USE_LOCAL_MARKDOWN_ENGINE": "1",
            "unknown\0key": "ignored\0value",
        ]
        #expect(try NotikaChildEnvironmentPolicy.inheritedEnvironment(from: input) ==
                ["HOME": "/account", "PATH": "/tools", "LANG": ""])
    }

    @Test func malformedRetainedValueIsRejectedRatherThanTruncated() throws {
        #expect(throws: NotikaChildEnvironmentError.invalidInheritedValue("PATH")) {
            try NotikaChildEnvironmentPolicy.inheritedEnvironment(from: ["PATH": "/tools\0suffix"])
        }
        #expect(throws: NotikaChildEnvironmentError.invalidInheritedValue("SIMULATOR_ID")) {
            try NotikaChildEnvironmentPolicy.inheritedEnvironment(from: ["SIMULATOR_ID": "id\0suffix"])
        }
    }

    @Test func trustedBindingsPinRepositoryToolPathAndCacheWithoutLegacyAuthority() throws {
        let bindings = try NotikaNativeEnvironmentBindings(repository: "/repo with space",
                                                           toolSearchPath: "/admitted/tools:/usr/bin:/bin", derivedData: "/repo with space/cache")
        let child = try NotikaChildEnvironmentPolicy.nativeEnvironment(
            from: ["PATH": "/foreign/tools", "HOME": "/account", "SRCROOT": "/foreign/repo",
                   "NOTIKA_DERIVED_DATA": "/foreign/cache", "NOTIKA_AGENT_SESSION_DIR": "/foreign/session"],
            bindings: bindings)
        #expect(child == ["PATH": "/repo with space/Scripts:/admitted/tools:/usr/bin:/bin", "HOME": "/account",
                          "SRCROOT": "/repo with space", "NOTIKA_DERIVED_DATA": "/repo with space/cache"])
        #expect(child["NOTIKA_AGENT_SESSION_DIR"] == nil)
        #expect(child["SIMULATOR_ID"] == nil)
        #expect(child["SIMLEASE_SESSION_ID"] == nil)
        let emptyPath = try NotikaNativeEnvironmentBindings(repository: "/repo", toolSearchPath: "", derivedData: "/cache")
        #expect(try NotikaChildEnvironmentPolicy.nativeEnvironment(from: [:], bindings: emptyPath)["PATH"] == "/repo/Scripts:")
    }

    @Test func simLeaseExportsAreCarriedWithoutInventingAdditionalOwnership() throws {
        let existing = ["SIMLEASE_SESSION_ID": "existing-session", "SIMULATOR_ID": "existing-id"]
        #expect(try NotikaChildEnvironmentPolicy.inheritedEnvironment(from: existing) == existing)
        let partial = try NotikaChildEnvironmentPolicy.inheritedEnvironment(from: ["SIMULATOR_ID": "unvalidated-id"])
        #expect(partial == ["SIMULATOR_ID": "unvalidated-id"])
        #expect(partial["SIMULATOR_UDID"] == nil)
        #expect(partial["SIMLEASE_SESSION_ID"] == nil)
        #expect(partial["SIMLEASE_MACOS_UI"] == nil)
    }

    @Test func accountCompilationSelectionRemainsIndependentOfInheritedHome() throws {
        let original = ["HOME": "/untrusted/home", "AGENTLEASE_HOME": "/checkout/.agentlease",
                        "AGENTLEASE_COMPILE_HOME": "/account/compile-registry", "XCODEBUILD_FLAGS": "foreign"]
        let filtered = try NotikaChildEnvironmentPolicy.inheritedEnvironment(from: original)
        #expect(try HostCompilationAdmission.selectedRoot(environment: original) == "/account/compile-registry")
        #expect(try HostCompilationAdmission.selectedRoot(environment: filtered) == "/account/compile-registry")
        let account = try HostCompilationAdmission.selectedRoot(environment: ["HOME": "/untrusted/home", "AGENTLEASE_HOME": "/checkout/.agentlease"])
        #expect(account != "/untrusted/home/.agentlease")
        #expect(account != "/checkout/.agentlease")
    }

    @Test(arguments: ["relative", "/repo/../cache", "/repo//cache", "/repo/cache/", "/repo/\0cache"])
    func malformedTrustedPathsAreRejected(_ path: String) throws {
        #expect(throws: NotikaChildEnvironmentError.invalidBinding("repository")) {
            try NotikaNativeEnvironmentBindings(repository: path, toolSearchPath: "/tools", derivedData: "/cache")
        }
        #expect(throws: NotikaChildEnvironmentError.invalidBinding("derivedData")) {
            try NotikaNativeEnvironmentBindings(repository: "/repo", toolSearchPath: "/tools", derivedData: path)
        }
    }
}
