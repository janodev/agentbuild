import Foundation

public struct ToolCheck: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case available, failed, missing, passed
    }

    public let name: String
    public let required: Bool
    public let path: String?
    public let status: Status
    public let version: String?
    public let detail: String?
}

public struct DoctorReport: Codable, Equatable, Sendable {
    public let schemaVersion = 1
    public let toolVersion: String
    public let stage = "bootstrap"
    public let tools: [ToolCheck]

    public var ready: Bool {
        tools.allSatisfy { !$0.required || $0.status == .passed }
    }

    private enum CodingKeys: String, CodingKey {
        case ready, schemaVersion, stage, toolVersion, tools
    }

    public init(tools: [ToolCheck]) {
        self.toolVersion = AgentBuild.version
        self.tools = tools
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .schemaVersion) == schemaVersion,
              try values.decode(String.self, forKey: .stage) == stage else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "Unsupported doctor report"
            ))
        }
        toolVersion = try values.decode(String.self, forKey: .toolVersion)
        tools = try values.decode([ToolCheck].self, forKey: .tools)
        guard try values.decode(Bool.self, forKey: .ready) == ready else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "Inconsistent doctor readiness"
            ))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(toolVersion, forKey: .toolVersion)
        try values.encode(stage, forKey: .stage)
        try values.encode(ready, forKey: .ready)
        try values.encode(tools, forKey: .tools)
    }
}

public enum AgentBuild {
    public static let version = "0.3.0"
}

public struct ToolchainDoctor: Sendable {
    private let searchPath: String
    private let currentDirectory: String

    public init(
        searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) {
        self.searchPath = searchPath
        self.currentDirectory = currentDirectory
    }

    public func inspect() async -> DoctorReport {
        let definitions: [(String, [String]?)] = [
            ("swift", ["--version"]),
            ("xcodebuild", ["-version"]),
            ("agentlease", ["--version"]),
            ("tuist", nil),
            ("simlease", nil),
            ("simslim", nil),
            ("make", nil),
            ("git", nil),
        ]
        var checks: [ToolCheck] = []
        for (name, probe) in definitions {
            let required = probe != nil
            guard let path = executable(named: name) else {
                checks.append(.init(
                    name: name, required: required, path: nil, status: .missing,
                    version: nil, detail: "Executable not found on PATH"
                ))
                continue
            }
            guard let probe else {
                checks.append(.init(
                    name: name, required: required, path: path, status: .available,
                    version: nil, detail: nil
                ))
                continue
            }
            do {
                let result = try await CommandRunner().run(executable: path, arguments: probe)
                let passed = result.termination == .exited(0)
                checks.append(.init(
                    name: name, required: required, path: path,
                    status: passed ? .passed : .failed,
                    version: passed ? bounded(result.standardOutput) : nil,
                    detail: passed ? nil : bounded("\(result.termination): \(result.standardError)")
                ))
            } catch {
                checks.append(.init(
                    name: name, required: required, path: path, status: .failed,
                    version: nil, detail: bounded(String(describing: error))
                ))
            }
        }
        return DoctorReport(tools: checks)
    }

    private func executable(named name: String) -> String? {
        let base = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        for directory in searchPath.split(separator: ":", omittingEmptySubsequences: false) {
            let path = URL(
                fileURLWithPath: directory.isEmpty ? "." : String(directory),
                isDirectory: true, relativeTo: base
            ).appendingPathComponent(name).absoluteURL.path
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
               !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private func bounded(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
    }
}
