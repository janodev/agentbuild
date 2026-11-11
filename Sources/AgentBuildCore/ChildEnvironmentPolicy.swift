import Foundation

public enum ChildEnvironmentError: Error, Equatable, Sendable {
    case invalidInheritedValue(String)
    case invalidBinding(String)
}

/// Explicit inherited environment shared by supervised project workflows.
public enum ChildEnvironmentPolicy {
    public static let inheritedNames: Set<String> = [
        "AGENTLEASE_HOME", "AGENTLEASE_COMPILE_HOME", "COLORTERM", "DEVELOPER_DIR", "HOME",
        "LANG", "LC_ALL", "LC_CTYPE", "LOGNAME", "PATH", "SIMLEASE_HOST_RESOURCE", "SIMLEASE_HOME",
        "SIMLEASE_MACOS_UI", "SIMLEASE_SESSION_ID", "SIMULATOR_ID", "SIMULATOR_UDID", "TERM",
        "TMPDIR", "TOOLCHAINS", "USER", "__CF_USER_TEXT_ENCODING",
    ]

    public static func inheritedEnvironment(from environment: [String: String]) throws -> [String: String] {
        var retained: [String: String] = [:]
        for name in inheritedNames {
            guard let value = environment[name] else { continue }
            guard !value.utf8.contains(0) else { throw ChildEnvironmentError.invalidInheritedValue(name) }
            retained[name] = value
        }
        return retained
    }

}
