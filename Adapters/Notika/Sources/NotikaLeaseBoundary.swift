import AgentBuildCore
import Darwin
import Foundation

public enum NotikaLeaseBoundaryError: Error, Equatable, Sendable {
    case partialEnvironment
    case missingLease
    case invalidSessionID
    case invalidSimulatorID
    case conflictingPlatform
    case missingDevice
    case toolUnavailable(String)
    case invalidReexecution
    case executionFailed(Int32)
}

/// Observed inherited SimLease fields. These are provenance, not a transferable
/// capability: the supervising SimLease process owns the actual kernel lease.
public struct NotikaOuterLeaseEvidence: Codable, Equatable, Sendable {
    public let platform: NotikaPlatform
    public let sessionID: String
    public let simulatorID: String?
    public let hostResource: String?

    public var destination: String {
        platform == .macOS ? "platform=macOS,arch=arm64"
            : "platform=iOS Simulator,id=" + (simulatorID ?? "")
    }

    private enum CodingKeys: String, CodingKey {
        case platform, sessionID, simulatorID, hostResource
    }

    public init(platform: NotikaPlatform, sessionID: String,
                simulatorID: String?, hostResource: String?) throws {
        guard Self.safeIdentifier(sessionID, maximum: 128) else {
            throw NotikaLeaseBoundaryError.invalidSessionID
        }
        switch platform {
        case .macOS:
            guard simulatorID == nil, hostResource == "macos-ui" else {
                throw NotikaLeaseBoundaryError.conflictingPlatform
            }
        case .iPadSimulator:
            guard let simulatorID, Self.safeIdentifier(simulatorID, maximum: 128), hostResource == nil else {
                throw NotikaLeaseBoundaryError.invalidSimulatorID
            }
        }
        self.platform = platform
        self.sessionID = sessionID
        self.simulatorID = simulatorID
        self.hostResource = hostResource
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(platform: values.decode(NotikaPlatform.self, forKey: .platform),
                      sessionID: values.decode(String.self, forKey: .sessionID),
                      simulatorID: values.decodeIfPresent(String.self, forKey: .simulatorID),
                      hostResource: values.decodeIfPresent(String.self, forKey: .hostResource))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(platform, forKey: .platform)
        try values.encode(sessionID, forKey: .sessionID)
        try values.encode(simulatorID, forKey: .simulatorID)
        try values.encode(hostResource, forKey: .hostResource)
    }

    private static func safeIdentifier(_ value: String, maximum: Int) -> Bool {
        guard (1...maximum).contains(value.utf8.count),
              value.utf8.first.map({ Self.alphanumeric($0) }) == true else { return false }
        return value.utf8.allSatisfy { Self.alphanumeric($0) || $0 == 45 }
    }

    private static func alphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }
}

/// Exactly one outer lease. Reexecution replaces the current CLI process before
/// session/graph/cache admission, so cancellation remains SimLease's job and no
/// inner controller can accidentally outlive a disposable simulator.
public enum NotikaLeaseBoundary {
    public static func requiresOuterLease(for request: NotikaActionRequest) -> Bool {
        guard let route = request.canonicalMakeRoute else { return request.requiresOuterLease }
        return request.requiresOuterLease
            || [.testUI, .testUIFile, .testUIOnly, .testUIOnlyFile].contains(route)
    }

    public static func admit(request: NotikaActionRequest,
                             environment: [String: String]) throws -> NotikaOuterLeaseEvidence? {
        let session = environment["SIMLEASE_SESSION_ID"] ?? ""
        let fields = ["SIMULATOR_ID", "SIMULATOR_UDID", "SIMLEASE_MACOS_UI", "SIMLEASE_HOST_RESOURCE"]
        if session.isEmpty {
            guard !fields.contains(where: { !(environment[$0] ?? "").isEmpty }) else {
                throw NotikaLeaseBoundaryError.partialEnvironment
            }
            guard !requiresOuterLease(for: request) else { throw NotikaLeaseBoundaryError.missingLease }
            return nil
        }
        switch request.platform {
        case .macOS:
            guard environment["SIMLEASE_MACOS_UI"] == "1",
                  environment["SIMLEASE_HOST_RESOURCE"] == "macos-ui",
                  (environment["SIMULATOR_ID"] ?? "").isEmpty,
                  (environment["SIMULATOR_UDID"] ?? "").isEmpty else {
                throw NotikaLeaseBoundaryError.conflictingPlatform
            }
            return try .init(platform: .macOS, sessionID: session, simulatorID: nil, hostResource: "macos-ui")
        case .iPadSimulator:
            guard let device = request.device, !device.isEmpty else { throw NotikaLeaseBoundaryError.missingDevice }
            guard let simulator = environment["SIMULATOR_ID"], !simulator.isEmpty,
                  (environment["SIMULATOR_UDID"] ?? simulator) == simulator,
                  (environment["SIMLEASE_MACOS_UI"] ?? "").isEmpty,
                  (environment["SIMLEASE_HOST_RESOURCE"] ?? "").isEmpty else {
                throw NotikaLeaseBoundaryError.conflictingPlatform
            }
            return try .init(platform: .iPadSimulator, sessionID: session, simulatorID: simulator, hostResource: nil)
        }
    }

    /// Exact literal argv for one fresh lease; pure planning grants no authority.
    public static func outerArguments(request: NotikaActionRequest, executable: String,
                                      arguments: [String], label: String) throws -> [String] {
        guard executable.hasPrefix("/"), !executable.utf8.contains(0),
              !arguments.contains(where: { $0.utf8.contains(0) }),
              !label.isEmpty, label.utf8.count <= 256, !label.utf8.contains(0) else {
            throw NotikaLeaseBoundaryError.invalidReexecution
        }
        switch request.platform {
        case .macOS:
            return ["macos-ui", "--label", label, "--", "/usr/bin/caffeinate", "-dimsu", executable] + arguments
        case .iPadSimulator:
            guard let device = request.device, !device.isEmpty else { throw NotikaLeaseBoundaryError.missingDevice }
            return ["run", "--label", label, "--device", device, "--", executable] + arguments
        }
    }

    /// Returns for an admitted inherited lease or an unleased build/unit route.
    /// On a fresh UI/simulator route, exec replaces this process with SimLease.
    public static func reexecuteIfRequired(request: NotikaActionRequest, environment: [String: String],
                                          executable: String, arguments: [String], label: String) throws {
        do { _ = try admit(request: request, environment: environment); return }
        catch NotikaLeaseBoundaryError.missingLease {
            guard requiresOuterLease(for: request) else { throw NotikaLeaseBoundaryError.missingLease }
        }
        let tool = try resolveTool("simlease", environment: environment)
        let values = [tool] + (try outerArguments(request: request, executable: executable,
                                                 arguments: arguments, label: label))
        var pointers: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
        guard !pointers.contains(where: { $0 == nil }) else {
            for case let pointer? in pointers { free(pointer) }
            throw NotikaLeaseBoundaryError.executionFailed(ENOMEM)
        }
        pointers.append(nil)
        defer { for case let pointer? in pointers { free(pointer) } }
        _ = pointers.withUnsafeMutableBufferPointer { execv(tool, $0.baseAddress!) }
        throw NotikaLeaseBoundaryError.executionFailed(errno)
    }

    private static func resolveTool(_ name: String, environment: [String: String]) throws -> String {
        for component in (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":", omittingEmptySubsequences: false) {
            guard component.hasPrefix("/") else { continue }
            let candidate = String(component) + "/" + name
            guard !candidate.utf8.contains(0), access(candidate, X_OK) == 0,
                  let pointer = realpath(candidate, nil) else { continue }
            defer { free(pointer) }
            guard let resolved = String(validatingCString: pointer) else { continue }
            var metadata = stat()
            guard lstat(resolved, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { continue }
            return resolved
        }
        throw NotikaLeaseBoundaryError.toolUnavailable(name)
    }
}
