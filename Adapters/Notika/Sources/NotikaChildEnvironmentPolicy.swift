import AgentBuildCore
import Foundation

/// Trusted literal values supplied after command/cache admission. This value
/// neither resolves paths nor proves custody, tool identity or device authority.
public struct NotikaNativeEnvironmentBindings: Equatable, Sendable {
    public let repository: String
    public let toolSearchPath: String
    public let derivedData: String

    public init(repository: String, toolSearchPath: String, derivedData: String) throws {
        guard nativeEnvironmentPath(repository) else { throw ChildEnvironmentError.invalidBinding("repository") }
        guard !toolSearchPath.utf8.contains(0) else { throw ChildEnvironmentError.invalidBinding("toolSearchPath") }
        guard nativeEnvironmentPath(derivedData) else { throw ChildEnvironmentError.invalidBinding("derivedData") }
        self.repository = repository
        self.toolSearchPath = toolSearchPath
        self.derivedData = derivedData
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.repository.utf8.elementsEqual(rhs.repository.utf8) &&
            lhs.toolSearchPath.utf8.elementsEqual(rhs.toolSearchPath.utf8) &&
            lhs.derivedData.utf8.elementsEqual(rhs.derivedData.utf8)
    }
}

/// Exact Python CHILD_ENVIRONMENT_ALLOWLIST. SimLease fields are carried as
/// observations only; another admission layer must establish actual ownership.
/// Select account compilation admission using the original environment before
/// applying this policy. HOME never selects the compilation registry.
public enum NotikaChildEnvironmentPolicy {
    public static let inheritedNames = ChildEnvironmentPolicy.inheritedNames

    public static func inheritedEnvironment(from environment: [String: String]) throws -> [String: String] {
        try ChildEnvironmentPolicy.inheritedEnvironment(from: environment)
    }

    /// Pins Make's repository-tool PATH and the cache consumed by Rust Xcode
    /// phases. Route flags, descriptors, session transports and compiler settings
    /// are never accepted as an inherited override dictionary.
    public static func nativeEnvironment(
        from environment: [String: String], bindings: NotikaNativeEnvironmentBindings
    ) throws -> [String: String] {
        var child = try inheritedEnvironment(from: environment)
        let base = bindings.repository == "/" ? "" : bindings.repository
        child["SRCROOT"] = bindings.repository
        child["PATH"] = base + "/Scripts:" + bindings.toolSearchPath
        child["NOTIKA_DERIVED_DATA"] = bindings.derivedData
        return child
    }
}

private func nativeEnvironmentPath(_ value: String) -> Bool {
    value.hasPrefix("/") && (value == "/" || !value.hasSuffix("/")) && !value.contains("//") &&
        !value.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) &&
        !value.unicodeScalars.contains(where: { $0.value <= 0x1f || (0x7f...0x9f).contains($0.value) })
}

public typealias NotikaChildEnvironmentError = ChildEnvironmentError
