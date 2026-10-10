import CryptoKit
import Foundation

/// Integer-only JSON covers build identities and filesystem metadata without
/// introducing floating-point formatting differences between Swift and Python.
public indirect enum CanonicalJSONValue: Equatable, Sendable {
    case array([CanonicalJSONValue])
    case bool(Bool)
    case integer(Int64)
    case null
    case object([CanonicalJSONMember])
    case string(String)
    case unsignedInteger(UInt64)

    public static func object(_ values: [String: CanonicalJSONValue]) -> Self {
        .object(values.map { CanonicalJSONMember(key: $0.key, value: $0.value) })
    }

    /// Swift String equality normalizes Unicode. Identity equality instead keeps
    /// the exact UTF-8 spelling, as Python strings and the encoded bytes do.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.array(let left), .array(let right)): left == right
        case (.bool(let left), .bool(let right)): left == right
        case (.integer(let left), .integer(let right)): left == right
        case (.null, .null): true
        case (.object(let left), .object(let right)):
            left.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
                == right.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
        case (.string(let left), .string(let right)): left.utf8.elementsEqual(right.utf8)
        case (.unsignedInteger(let left), .unsignedInteger(let right)): left == right
        default: false
        }
    }
}

/// Member arrays retain distinct UTF-8 keys even when Swift considers their
/// composed and decomposed spellings canonically equivalent.
public struct CanonicalJSONMember: Equatable, Sendable {
    public let key: String
    public let value: CanonicalJSONValue

    public init(key: String, value: CanonicalJSONValue) {
        self.key = key
        self.value = value
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key.utf8.elementsEqual(rhs.key.utf8) && lhs.value == rhs.value
    }
}

public enum CanonicalJSONError: Error, Equatable, Sendable {
    case duplicateObjectKey(String)
    case nestingLimitExceeded
}

/// Matches Python json.dumps(sort_keys=True, ensure_ascii=False,
/// separators=(",", ":")) for the integer-only identity domain. Keys sort by
/// Unicode scalar value; strings retain their original Unicode spelling.
public enum CanonicalJSONDigest {
    public static let maximumNestingDepth = 128

    public static func encode(_ value: CanonicalJSONValue) throws -> Data {
        var bytes = Data()
        try append(value, to: &bytes, depth: 0)
        return bytes
    }

    public static func sha256(_ value: CanonicalJSONValue) throws -> String {
        digest(try encode(value))
    }

    public static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func append(_ value: CanonicalJSONValue, to bytes: inout Data, depth: Int) throws {
        guard depth <= maximumNestingDepth else { throw CanonicalJSONError.nestingLimitExceeded }
        switch value {
        case .array(let values):
            bytes.append(0x5B)
            for (index, value) in values.enumerated() {
                if index > 0 { bytes.append(0x2C) }
                try append(value, to: &bytes, depth: depth + 1)
            }
            bytes.append(0x5D)
        case .bool(let value):
            bytes.append(contentsOf: (value ? "true" : "false").utf8)
        case .integer(let value):
            bytes.append(contentsOf: String(value).utf8)
        case .null:
            bytes.append(contentsOf: "null".utf8)
        case .object(let members):
            var keys = Set<Data>()
            for member in members {
                guard keys.insert(Data(member.key.utf8)).inserted else {
                    throw CanonicalJSONError.duplicateObjectKey(member.key)
                }
            }
            let ordered = members.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
            bytes.append(0x7B)
            for (index, member) in ordered.enumerated() {
                if index > 0 { bytes.append(0x2C) }
                appendString(member.key, to: &bytes)
                bytes.append(0x3A)
                try append(member.value, to: &bytes, depth: depth + 1)
            }
            bytes.append(0x7D)
        case .string(let value):
            appendString(value, to: &bytes)
        case .unsignedInteger(let value):
            bytes.append(contentsOf: String(value).utf8)
        }
    }

    private static func appendString(_ value: String, to bytes: inout Data) {
        bytes.append(0x22)
        for scalar in value.unicodeScalars {
            let escaped: String?
            switch scalar.value {
            case 0x08: escaped = "\\b"
            case 0x09: escaped = "\\t"
            case 0x0A: escaped = "\\n"
            case 0x0C: escaped = "\\f"
            case 0x0D: escaped = "\\r"
            case 0x22: escaped = "\\\""
            case 0x5C: escaped = "\\\\"
            case 0..<0x20: escaped = String(format: "\\u%04x", scalar.value)
            default: escaped = nil
            }
            bytes.append(contentsOf: (escaped ?? String(scalar)).utf8)
        }
        bytes.append(0x22)
    }
}
