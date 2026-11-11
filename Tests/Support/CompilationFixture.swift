import AgentBuildCore
import AgentLeaseCore
import Darwin
import Foundation

package struct CompilationFixture: Sendable {
    package enum Failure: Error { case expected }
    package let directory: URL
    package let registry: URL
    package let paths: AgentLeasePaths

    package var environment: [String: String] { ["AGENTLEASE_COMPILE_HOME": registry.path] }

    package init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentbuild-compile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(directory.path, &buffer) != nil else { throw Failure.expected }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        self.directory = URL(fileURLWithPath: path)
        registry = self.directory.appendingPathComponent("compile-registry")
        paths = try AgentLeasePaths.open(selectedRoot: registry.path)
    }

    package func lock() throws -> FileLock {
        try FileLock(resource: ResourceName(HostCompilationAdmission.resource), paths: paths)
    }

    package func available() throws -> Bool {
        let contender = try lock()
        defer { contender.release() }
        return try contender.tryAcquire()
    }

    package func remove() { try? FileManager.default.removeItem(at: directory) }
}
