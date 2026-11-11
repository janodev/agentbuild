import ArgumentParser
import Darwin
import MachO

/// Resolve this process through dyld; argv[0] and PATH cannot select the helper.
package func currentAgentBuildExecutable() throws -> String {
    var count: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &count)
    guard count > 0, count <= 1_048_576 else { throw ValidationError("Cannot resolve the AgentBuild executable.") }
    var bytes = [CChar](repeating: 0, count: Int(count))
    guard _NSGetExecutablePath(&bytes, &count) == 0,
          let pointer = bytes.withUnsafeBufferPointer({ realpath($0.baseAddress!, nil) }) else {
        throw ValidationError("Cannot resolve the AgentBuild executable.")
    }
    defer { free(pointer) }
    guard let path = String(validatingCString: pointer), path.hasPrefix("/") else {
        throw ValidationError("The current executable path is invalid.")
    }
    var metadata = stat()
    guard lstat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
          access(path, X_OK) == 0 else { throw ValidationError("AgentBuild must be an executable regular file.") }
    return path
}
