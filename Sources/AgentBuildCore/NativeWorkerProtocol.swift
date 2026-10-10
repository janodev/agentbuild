import AgentLeaseCore
import Darwin
import Dispatch
import Foundation

/// Private, inherited-descriptor protocol. No pathname grants command or lock authority.
enum NativeWorkerProtocol {
    static let maximumRequestBytes = 256 * 1_024
    static let maximumReportBytes = 128 * 1_024

    struct Request: Codable, Sendable {
        let schemaVersion: Int
        let nonce: String
        let executable: String
        let arguments: [String]
        let workingDirectory: String
        let environment: [String: String]
        let lockDescriptors: [Int32]
        let workingDirectoryBinding: NativeWorkerDirectoryBinding?

        init(command: DarwinWorkloadCommand, nonce: String, locks: [Int32],
             workingDirectoryBinding: NativeWorkerDirectoryBinding? = nil) {
            schemaVersion = 1
            self.nonce = nonce
            executable = command.executable
            arguments = command.arguments
            workingDirectory = command.workingDirectory
            environment = command.environment
            lockDescriptors = locks
            self.workingDirectoryBinding = workingDirectoryBinding
        }

        func command() throws -> DarwinWorkloadCommand {
            try DarwinWorkloadCommand(executable: executable, arguments: arguments,
                                      workingDirectory: workingDirectory, environment: environment)
        }
    }

    struct Report: Codable, Sendable {
        let schemaVersion: Int
        let nonce: String
        let requestDigest: String
        let kind: String
        let nativePID: Int32?
        let result: DarwinWorkloadResult?

        static func started(nonce: String, digest: String, pid: Int32) -> Self {
            Self(schemaVersion: 1, nonce: nonce, requestDigest: digest,
                 kind: "started", nativePID: pid, result: nil)
        }

        static func terminal(nonce: String, digest: String, result: DarwinWorkloadResult) -> Self {
            Self(schemaVersion: 1, nonce: nonce, requestDigest: digest,
                 kind: "terminal", nativePID: nil, result: result)
        }
    }

    static func encodeRequest(_ request: Request) throws -> Data {
        let data = try JSONEncoder().encode(request)
        _ = try decodeRequest(data, nonce: request.nonce)
        return data
    }

    static func decodeRequest(_ data: Data, nonce: String) throws -> Request {
        let limits = try StrictJSONLimits(maximumBytes: maximumRequestBytes, maximumDepth: 8, maximumNodes: 32_768)
        let object = try StrictJSONDocument(data: data, limits: limits).root.requireObject()
            .project(requiredKeys: ["schemaVersion", "nonce", "executable", "arguments", "workingDirectory", "environment", "lockDescriptors"],
                     optionalKeys: ["workingDirectoryBinding"])
        guard try integer(object, "schemaVersion") == 1,
              UUID(uuidString: nonce) != nil, try string(object, "nonce").utf8.elementsEqual(nonce.utf8),
              case .array(let arguments) = try object.requiredValue(forKey: "arguments"), arguments.count <= 4_096,
              arguments.allSatisfy({ if case .string = $0 { true } else { false } }),
              case .object(let environment) = try object.requiredValue(forKey: "environment"), environment.members.count <= 4_096,
              environment.members.allSatisfy({ if case .string = $0.value { true } else { false } }),
              case .array(let locks) = try object.requiredValue(forKey: "lockDescriptors"), locks.count <= 128 else {
            throw protocolFailure("invalid request schema")
        }
        let request = try JSONDecoder().decode(Request.self, from: data)
        guard request.lockDescriptors.allSatisfy({ $0 >= 3 }),
              Set(request.lockDescriptors).count == request.lockDescriptors.count else {
            throw protocolFailure("invalid lock descriptor whitelist")
        }
        if let value = object.value(forKey: "workingDirectoryBinding") {
            let directory = try value.requireObject().project(requiredKeys: ["descriptor", "device", "inode", "owner", "mode"])
            guard let binding = request.workingDirectoryBinding,
                  binding.descriptor >= 3, !request.lockDescriptors.contains(binding.descriptor),
                  try integer(directory, "descriptor") == Int64(binding.descriptor),
                  try integer(directory, "device") == binding.device,
                  try unsignedInteger(directory, "inode") == binding.inode,
                  try integer(directory, "owner") == Int64(binding.owner),
                  try integer(directory, "mode") == Int64(binding.mode) else {
                throw protocolFailure("invalid directory descriptor whitelist")
            }
        }
        _ = try request.command()
        return request
    }

    static func decodeReport(_ data: Data, nonce: String, digest: String) throws -> Report {
        let limits = try StrictJSONLimits(maximumBytes: maximumReportBytes, maximumDepth: 8, maximumNodes: 2_048)
        let object = try StrictJSONDocument(data: data, limits: limits).root.requireObject()
        let kind = try string(object, "kind")
        _ = try object.project(requiredKeys: ["schemaVersion", "nonce", "requestDigest", "kind", kind == "started" ? "nativePID" : "result"])
        guard try integer(object, "schemaVersion") == 1,
              try string(object, "nonce").utf8.elementsEqual(nonce.utf8),
              try string(object, "requestDigest") == digest else { throw protocolFailure("report identity mismatch") }
        if kind == "started" {
            guard try integer(object, "nativePID") > 0 else { throw protocolFailure("invalid native PID") }
        } else if kind == "terminal" {
            let result = try object.requiredValue(forKey: "result").requireObject()
                .project(requiredKeys: ["retirement", "failures"], optionalKeys: ["processIdentifier", "termination", "stopReason"])
            if let value = result.value(forKey: "termination") {
                let termination = try value.requireObject().project(requiredKeys: ["kind", "value"])
                let kind = try string(termination, "kind")
                let value = try integer(termination, "value")
                guard (kind == "exit" && (0...255).contains(value)) ||
                      (kind == "signal" && (1..<Int64(NSIG)).contains(value)) else {
                    throw protocolFailure("invalid native termination")
                }
            }
            guard case .array(let failures) = try result.requiredValue(forKey: "failures"), failures.count <= 32 else {
                throw protocolFailure("invalid failure list")
            }
            for value in failures {
                let failure = try value.requireObject().project(requiredKeys: ["operation"], optionalKeys: ["code", "detail"])
                guard try string(failure, "operation").utf8.count <= 4_096 else { throw protocolFailure("failure text limit") }
                if failure.value(forKey: "detail") != nil,
                   try string(failure, "detail").utf8.count > 4_096 { throw protocolFailure("failure text limit") }
            }
        } else { throw protocolFailure("unknown report kind") }
        let report = try JSONDecoder().decode(Report.self, from: data)
        if let result = report.result {
            switch result.retirement {
            case .notStarted:
                guard result.processIdentifier == nil, result.termination == nil else { throw protocolFailure("invalid not-started result") }
            case .reaped:
                guard let pid = result.processIdentifier, pid > 0, result.termination != nil else {
                    throw protocolFailure("invalid retired result")
                }
            }
        }
        return report
    }

    static func frame(_ data: Data, limit: Int) throws -> Data {
        guard !data.isEmpty, data.count <= limit else { throw protocolFailure("frame byte limit") }
        let size = UInt32(data.count)
        var framed = Data([UInt8(size >> 24), UInt8(truncatingIfNeeded: size >> 16),
                           UInt8(truncatingIfNeeded: size >> 8), UInt8(truncatingIfNeeded: size)])
        framed.append(data)
        return framed
    }

    static func takeFrame(_ buffer: inout Data, limit: Int) throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let count = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0, count <= limit else { throw protocolFailure("frame byte limit") }
        guard buffer.count >= 4 + Int(count) else { return nil }
        let frame = Data(buffer.dropFirst(4).prefix(Int(count)))
        buffer.removeFirst(4 + Int(count))
        return frame
    }

    static func writeReport(_ report: Report, descriptor: Int32) throws {
        let data = try frame(JSONEncoder().encode(report), limit: maximumReportBytes)
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if count > 0 { offset += count }
            else if count < 0 && errno == EINTR { continue }
            else { throw DarwinWorkloadFailure(operation: "write worker report", code: count < 0 ? errno : EIO) }
        }
    }

    static func requirePipe(_ descriptor: Int32, mode: Int32) throws {
        var status = stat()
        let flags = fcntl(descriptor, F_GETFL)
        guard descriptor >= 3, fstat(descriptor, &status) == 0, flags >= 0,
              status.st_mode & S_IFMT == S_IFIFO, flags & O_ACCMODE == mode else {
            throw protocolFailure("invalid inherited protocol descriptor")
        }
    }

    static func protocolFailure(_ detail: String) -> DarwinWorkloadFailure {
        DarwinWorkloadFailure(operation: "native worker protocol", code: EPROTO, detail: detail)
    }

    private static func string(_ object: StrictJSONObject, _ key: String) throws -> String {
        guard case .string(let value) = try object.requiredValue(forKey: key) else { throw protocolFailure("expected string") }
        return value
    }

    private static func integer(_ object: StrictJSONObject, _ key: String) throws -> Int64 {
        guard case .number(let value) = try object.requiredValue(forKey: key) else { throw protocolFailure("expected integer") }
        return try value.int64()
    }

    private static func unsignedInteger(_ object: StrictJSONObject, _ key: String) throws -> UInt64 {
        guard case .number(let value) = try object.requiredValue(forKey: key) else { throw protocolFailure("expected unsigned integer") }
        return try value.uint64()
    }
}

/// Only the private CLI entry calls this in an independent helper process.
public struct NativeWorkerEntry: Sendable {
    public init() {}

    public func run(requestDescriptor: Int32, reportDescriptor: Int32, ownerDescriptor: Int32, nonce: String) async -> Int32 {
        do {
            guard Set([requestDescriptor, reportDescriptor, ownerDescriptor]).count == 3 else {
                throw NativeWorkerProtocol.protocolFailure("aliased protocol descriptors")
            }
            try NativeWorkerProtocol.requirePipe(requestDescriptor, mode: O_RDONLY)
            try NativeWorkerProtocol.requirePipe(reportDescriptor, mode: O_WRONLY)
            try NativeWorkerProtocol.requirePipe(ownerDescriptor, mode: O_RDONLY)
            guard fcntl(reportDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
                throw DarwinWorkloadFailure(operation: "report F_SETNOSIGPIPE", code: errno)
            }
            let data = try readRequest(requestDescriptor)
            let request = try NativeWorkerProtocol.decodeRequest(data, nonce: nonce)
            let digest = CanonicalJSONDigest.digest(data)
            let result: DarwinWorkloadResult
            do {
                try validateCapabilities(request, controls: [requestDescriptor, reportDescriptor, ownerDescriptor])
                result = await DarwinWorkloadSupervisor().run(
                    try request.command(), retainedLockDescriptors: request.lockDescriptors,
                    ownerLifelineDescriptor: ownerDescriptor,
                    nativeWorkingDirectoryDescriptor: request.workingDirectoryBinding?.descriptor,
                    onStart: { pid in
                        try NativeWorkerProtocol.writeReport(.started(nonce: nonce, digest: digest, pid: pid), descriptor: reportDescriptor)
                    }
                )
            } catch {
                // A decoded request has an authenticated identity and no spawn
                // occurred here. Report that fact rather than strand its locks.
                let failure = (error as? DarwinWorkloadFailure) ?? DarwinWorkloadFailure(
                    operation: "native worker preflight", detail: String(describing: error))
                result = DarwinWorkloadResult(processIdentifier: nil, termination: nil,
                                              stopReason: .ancillaryFailure, retirement: .notStarted, failures: [failure])
            }
            try NativeWorkerProtocol.writeReport(.terminal(nonce: nonce, digest: digest, result: result), descriptor: reportDescriptor)
            return 0 // Helper protocol completion; native status is exclusively in the receipt.
        } catch { return 70 }
    }

    private func validateCapabilities(_ request: NativeWorkerProtocol.Request, controls: Set<Int32>) throws {
        guard Set(request.lockDescriptors).isDisjoint(with: controls) else {
            throw NativeWorkerProtocol.protocolFailure("lock aliases protocol descriptor")
        }
        if let directory = request.workingDirectoryBinding {
            guard !controls.contains(directory.descriptor) else {
                throw NativeWorkerProtocol.protocolFailure("working directory aliases protocol descriptor")
            }
            try directory.validate(path: request.workingDirectory)
        }
        for descriptor in request.lockDescriptors {
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
                throw NativeWorkerProtocol.protocolFailure("lock descriptor is not an open regular file")
            }
        }
    }

    private func readRequest(_ descriptor: Int32) throws -> Data {
        let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 8_192)
        while true {
            var polling = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            var count: Int32
            repeat { count = poll(&polling, 1, 20) } while count < 0 && errno == EINTR
            guard count >= 0 else { throw DarwinWorkloadFailure(operation: "poll worker request", code: errno) }
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw NativeWorkerProtocol.protocolFailure("request deadline") }
            if polling.revents & Int16(POLLERR | POLLNVAL) != 0 { throw NativeWorkerProtocol.protocolFailure("request pipe invalid") }
            if polling.revents & Int16(POLLIN | POLLHUP) != 0 {
                let read = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if read == 0 { break }
                if read < 0 && errno == EINTR { continue }
                guard read > 0 else { throw DarwinWorkloadFailure(operation: "read worker request", code: errno) }
                data.append(contentsOf: bytes.prefix(read))
                guard data.count <= NativeWorkerProtocol.maximumRequestBytes + 4 else {
                    throw NativeWorkerProtocol.protocolFailure("request byte limit")
                }
            }
        }
        let frame = try NativeWorkerProtocol.takeFrame(&data, limit: NativeWorkerProtocol.maximumRequestBytes)
        guard let frame, data.isEmpty else { throw NativeWorkerProtocol.protocolFailure("incomplete or extra request frame") }
        return frame
    }
}
