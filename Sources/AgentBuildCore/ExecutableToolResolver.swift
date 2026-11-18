import Darwin
import Foundation

/// Preserves the named shim path instead of resolving it to its dispatcher.
public enum ExecutableToolResolver {
    public static func resolve(_ name: String, environment: [String: String]) -> String? {
        for component in (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":") where component.hasPrefix("/") {
            let candidate = String(component) + "/" + name
            var metadata = stat()
            guard access(candidate, X_OK) == 0, stat(candidate, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFREG else { continue }
            // Mise and other tool shims dispatch from argv[0]. Preserve the named
            // executable instead of replacing a tuist symlink with the mise binary.
            return candidate
        }
        return nil
    }
}
