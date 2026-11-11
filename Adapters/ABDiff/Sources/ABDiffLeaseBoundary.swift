import AgentBuildCore
import Darwin
import Foundation

/// One foreground SimLease supervisor surrounds UI work; no SimSlim policy is
/// inherited from the independent Notika adapter.
public enum ABDiffLeaseBoundary {
    public static func requiresOuterLease(for request: ABDiffProjectRequest) -> Bool {
        request.needsOuterLease
    }

    public static func admit(request: ABDiffProjectRequest, environment: [String: String]) throws {
        guard requiresOuterLease(for: request) else { return }
        guard let session = environment["SIMLEASE_SESSION_ID"], !session.isEmpty else {
            throw ABDiffProjectDriverError.invalidArgument("missing outer SimLease")
        }
        if request.platform == "ipad-simulator" {
            guard let id = environment["SIMULATOR_ID"], UUID(uuidString: id) != nil,
                  (environment["SIMULATOR_UDID"] ?? id) == id,
                  (environment["SIMLEASE_MACOS_UI"] ?? "").isEmpty else {
                throw ABDiffProjectDriverError.invalidArgument("conflicting simulator lease")
            }
        } else {
            guard environment["SIMLEASE_MACOS_UI"] == "1",
                  environment["SIMLEASE_HOST_RESOURCE"] == "macos-ui",
                  (environment["SIMULATOR_ID"] ?? "").isEmpty else {
                throw ABDiffProjectDriverError.invalidArgument("conflicting macOS UI lease")
            }
        }
    }

    public static func reexecuteIfRequired(
        request: ABDiffProjectRequest, environment: [String: String],
        executable: String, arguments: [String], label: String
    ) throws {
        guard requiresOuterLease(for: request) else { return }
        if !(environment["SIMLEASE_SESSION_ID"] ?? "").isEmpty {
            try admit(request: request, environment: environment)
            return
        }
        guard executable.hasPrefix("/"), !executable.utf8.contains(0),
              !arguments.contains(where: { $0.utf8.contains(0) }) else {
            throw ABDiffProjectDriverError.invalidArgument("SimLease reexecution")
        }
        let tool = try abdiffResolveTool("simlease", environment: environment)
        let prefix: [String]
        if request.platform == "ipad-simulator" {
            prefix = ["run", "--label", label, "--device", request.device ?? "iPad Pro 13-inch (M5)", "--", executable]
        } else { prefix = ["macos-ui", "--label", label, "--", "/usr/bin/caffeinate", "-dimsu", executable] }
        let values = [tool] + prefix + arguments
        var pointers = values.map { strdup($0) }
        guard !pointers.contains(where: { $0 == nil }) else {
            for case let pointer? in pointers { free(pointer) }
            throw ABDiffProjectDriverError.io("allocate reexecution", ENOMEM)
        }
        pointers.append(nil)
        defer { for case let pointer? in pointers { free(pointer) } }
        _ = pointers.withUnsafeMutableBufferPointer { execv(tool, $0.baseAddress!) }
        throw ABDiffProjectDriverError.io("exec SimLease", errno)
    }
}

internal func abdiffResolveTool(_ name: String, environment: [String: String]) throws -> String {
    guard let tool = ExecutableToolResolver.resolve(name, environment: environment) else {
        throw ABDiffProjectDriverError.unavailableTool(name)
    }
    return tool
}
