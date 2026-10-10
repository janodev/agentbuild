@testable import AgentBuildCore
import Darwin
import Foundation
import Testing

@Suite("Pinned native working directory")
struct NativeWorkerDirectoryTests {
    @Test func requestBindsDirectorySeparatelyAndRejectsDescriptorSubstitution() throws {
        let fixture = try DirectoryCapabilityFixture()
        defer { fixture.remove() }
        let binding = try NativeWorkerDirectoryBinding(descriptor: fixture.descriptor, path: fixture.path)
        let command = try DarwinWorkloadCommand(executable: "/usr/bin/true", workingDirectory: fixture.path)
        let nonce = UUID().uuidString
        let request = NativeWorkerProtocol.Request(command: command, nonce: nonce, locks: [],
                                                   workingDirectoryBinding: binding)
        let data = try NativeWorkerProtocol.encodeRequest(request)
        let decoded = try NativeWorkerProtocol.decodeRequest(data, nonce: nonce)
        #expect(decoded.workingDirectoryBinding == binding)
        try decoded.workingDirectoryBinding?.validate(path: fixture.path)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var directory = try #require(object["workingDirectoryBinding"] as? [String: Any])
        directory["inode"] = binding.inode + 1
        object["workingDirectoryBinding"] = directory
        let changed = try NativeWorkerProtocol.decodeRequest(JSONSerialization.data(withJSONObject: object), nonce: nonce)
        #expect(throws: DarwinWorkloadFailure.self) {
            try changed.workingDirectoryBinding?.validate(path: fixture.path)
        }
        directory["extraAuthority"] = true
        object["workingDirectoryBinding"] = directory
        #expect(throws: (any Error).self) {
            try NativeWorkerProtocol.decodeRequest(JSONSerialization.data(withJSONObject: object), nonce: nonce)
        }
        object["workingDirectoryBinding"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(binding))
        object["lockDescriptors"] = [fixture.descriptor]
        #expect(throws: DarwinWorkloadFailure.self) {
            try NativeWorkerProtocol.decodeRequest(JSONSerialization.data(withJSONObject: object), nonce: nonce)
        }
    }

    @Test func nofollowEntryBindingRejectsRenamedDirectoryAndSymlink() throws {
        let fixture = try DirectoryCapabilityFixture()
        defer { fixture.remove() }
        let binding = try NativeWorkerDirectoryBinding(descriptor: fixture.descriptor, path: fixture.path)
        let moved = fixture.path + "-moved"
        try FileManager.default.moveItem(atPath: fixture.path, toPath: moved)
        defer { try? FileManager.default.removeItem(atPath: moved) }
        try FileManager.default.createSymbolicLink(atPath: fixture.path, withDestinationPath: moved)
        #expect(throws: DarwinWorkloadFailure.self) { try binding.validate(path: fixture.path) }
    }
}

private struct DirectoryCapabilityFixture {
    let path: String
    let descriptor: Int32

    init() throws {
        let path = "/private/tmp/agentbuild-pinned-directory-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 3 else { throw DarwinWorkloadFailure(operation: "fixture directory", code: errno) }
        self.path = path
        self.descriptor = descriptor
    }

    func remove() { _ = Darwin.close(descriptor); try? FileManager.default.removeItem(atPath: path) }
}
