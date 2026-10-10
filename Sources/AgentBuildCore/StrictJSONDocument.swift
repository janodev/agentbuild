import Foundation

public enum StrictJSONError: Error, Equatable, Sendable {
    case invalidLimits
    case byteBudgetExceeded(Int)
    case depthBudgetExceeded(Int)
    case nodeBudgetExceeded(Int)
    case invalidUTF8
    case malformedJSON(offset: Int)
    case trailingBytes(offset: Int)
    case malformedUnicodeEscape(offset: Int)
    case duplicateObjectKey(String, offset: Int)
    case unsupportedNumber(String, offset: Int)
    case expectedObject
    case invalidSchema
    case missingField(String)
    case unexpectedField(String)
    case integerConversion(String)
    case finiteDoubleConversion(String)

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.invalidLimits, .invalidLimits), (.invalidUTF8, .invalidUTF8),
             (.expectedObject, .expectedObject), (.invalidSchema, .invalidSchema): true
        case (.byteBudgetExceeded(let left), .byteBudgetExceeded(let right)),
             (.depthBudgetExceeded(let left), .depthBudgetExceeded(let right)),
             (.nodeBudgetExceeded(let left), .nodeBudgetExceeded(let right)): left == right
        case (.malformedJSON(let left), .malformedJSON(let right)),
             (.trailingBytes(let left), .trailingBytes(let right)),
             (.malformedUnicodeEscape(let left), .malformedUnicodeEscape(let right)): left == right
        case (.duplicateObjectKey(let left, let leftOffset), .duplicateObjectKey(let right, let rightOffset)),
             (.unsupportedNumber(let left, let leftOffset), .unsupportedNumber(let right, let rightOffset)):
            leftOffset == rightOffset && left.utf8.elementsEqual(right.utf8)
        case (.missingField(let left), .missingField(let right)),
             (.unexpectedField(let left), .unexpectedField(let right)),
             (.integerConversion(let left), .integerConversion(let right)),
             (.finiteDoubleConversion(let left), .finiteDoubleConversion(let right)):
            left.utf8.elementsEqual(right.utf8)
        default: false
        }
    }
}

/// Defaults match the Python evidence reader. Upper bounds also constrain
/// explicitly supplied limits, so a caller cannot enable unbounded recursion.
public struct StrictJSONLimits: Equatable, Sendable {
    public static let standard = Self(bytes: 256 * 1_024, depth: 64, nodes: 250_000)
    public let maximumBytes: Int
    public let maximumDepth: Int
    public let maximumNodes: Int

    public init(
        maximumBytes: Int = 256 * 1_024,
        maximumDepth: Int = 64,
        maximumNodes: Int = 250_000
    ) throws {
        guard (1...(16 * 1_024 * 1_024)).contains(maximumBytes),
              (1...256).contains(maximumDepth),
              (1...1_000_000).contains(maximumNodes) else {
            throw StrictJSONError.invalidLimits
        }
        self.init(bytes: maximumBytes, depth: maximumDepth, nodes: maximumNodes)
    }

    private init(bytes: Int, depth: Int, nodes: Int) {
        maximumBytes = bytes
        maximumDepth = depth
        maximumNodes = nodes
    }
}

/// A validated JSON token, retained without coercing a large integer into a
/// floating-point value. Schema owners must perform a checked conversion before
/// trusting an integer field. Negative integer zero converts to unsigned zero.
public struct StrictJSONNumber: Equatable, Sendable {
    public let lexicalValue: String
    public let isInteger: Bool

    fileprivate init(lexicalValue: String, isInteger: Bool) {
        self.lexicalValue = lexicalValue
        self.isInteger = isInteger
    }

    public func int64() throws -> Int64 {
        guard isInteger, let value = Int64(lexicalValue) else {
            throw StrictJSONError.integerConversion(lexicalValue)
        }
        return value
    }

    public func uint64() throws -> UInt64 {
        if isInteger, lexicalValue == "-0" { return 0 }
        guard isInteger, let value = UInt64(lexicalValue) else {
            throw StrictJSONError.integerConversion(lexicalValue)
        }
        return value
    }

    public func finiteDouble() throws -> Double {
        guard let value = Double(lexicalValue), value.isFinite else {
            throw StrictJSONError.finiteDoubleConversion(lexicalValue)
        }
        return value
    }
}

public struct StrictJSONMember: Equatable, Sendable {
    public let key: String
    public let value: StrictJSONValue

    fileprivate init(key: String, value: StrictJSONValue) {
        self.key = key
        self.value = value
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key.utf8.elementsEqual(rhs.key.utf8) && lhs.value == rhs.value
    }
}

/// Objects are constructed only by the reader, after duplicate decoded UTF-8
/// keys have been rejected. Member arrays retain distinct NFC/NFD keys.
public struct StrictJSONObject: Equatable, Sendable {
    public let members: [StrictJSONMember]

    fileprivate init(members: [StrictJSONMember]) {
        self.members = members
    }

    public func value(forKey key: String) -> StrictJSONValue? {
        members.first { $0.key.utf8.elementsEqual(key.utf8) }?.value
    }

    public func requiredValue(forKey key: String) throws -> StrictJSONValue {
        guard let value = value(forKey: key) else { throw StrictJSONError.missingField(key) }
        return value
    }

    /// Reject unknown/missing fields before the schema owner trusts a projection.
    /// Names compare by decoded UTF-8 bytes, including in the schema itself.
    public func project(requiredKeys: [String], optionalKeys: [String] = []) throws -> Self {
        let required = Set(requiredKeys.map { Data($0.utf8) })
        let optional = Set(optionalKeys.map { Data($0.utf8) })
        guard required.count == requiredKeys.count, optional.count == optionalKeys.count,
              required.isDisjoint(with: optional) else { throw StrictJSONError.invalidSchema }
        for key in requiredKeys where value(forKey: key) == nil {
            throw StrictJSONError.missingField(key)
        }
        let allowed = required.union(optional)
        for member in members where !allowed.contains(Data(member.key.utf8)) {
            throw StrictJSONError.unexpectedField(member.key)
        }
        return self
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.members.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
            == rhs.members.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
    }
}

public indirect enum StrictJSONValue: Equatable, Sendable {
    case array([StrictJSONValue])
    case bool(Bool)
    case null
    case number(StrictJSONNumber)
    case object(StrictJSONObject)
    case string(String)

    public func requireObject() throws -> StrictJSONObject {
        guard case .object(let object) = self else { throw StrictJSONError.expectedObject }
        return object
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.array(let left), .array(let right)): left == right
        case (.bool(let left), .bool(let right)): left == right
        case (.null, .null): true
        case (.number(let left), .number(let right)): left == right
        case (.object(let left), .object(let right)): left == right
        case (.string(let left), .string(let right)): left.utf8.elementsEqual(right.utf8)
        default: false
        }
    }
}

/// Parses one UTF-8 JSON value with bounded bytes, nesting, and value nodes.
/// The root has depth zero; object keys are not value nodes, matching Python's
/// evidence traversal. Original bytes and their digest remain separate from
/// decoded values: whitespace, escape spelling, and numeric spelling are evidence.
public struct StrictJSONDocument: Equatable, Sendable {
    public let originalData: Data
    public let digest: String
    public let root: StrictJSONValue
    public let nodeCount: Int

    public init(data: Data, limits: StrictJSONLimits = .standard) throws {
        guard data.count <= limits.maximumBytes else {
            throw StrictJSONError.byteBudgetExceeded(limits.maximumBytes)
        }
        guard String(data: data, encoding: .utf8) != nil else { throw StrictJSONError.invalidUTF8 }
        var reader = StrictJSONReader(bytes: Array(data), limits: limits)
        root = try reader.read()
        nodeCount = reader.nodeCount
        originalData = data
        digest = CanonicalJSONDigest.digest(data)
    }
}

private struct StrictJSONReader {
    let bytes: [UInt8]
    let limits: StrictJSONLimits
    var offset = 0
    var nodeCount = 0

    mutating func read() throws -> StrictJSONValue {
        skipWhitespace()
        let value = try readValue(depth: 0)
        skipWhitespace()
        guard offset == bytes.count else { throw StrictJSONError.trailingBytes(offset: offset) }
        return value
    }

    private mutating func readValue(depth: Int) throws -> StrictJSONValue {
        guard depth <= limits.maximumDepth else { throw StrictJSONError.depthBudgetExceeded(limits.maximumDepth) }
        guard nodeCount < limits.maximumNodes else { throw StrictJSONError.nodeBudgetExceeded(limits.maximumNodes) }
        nodeCount += 1
        guard offset < bytes.count else { throw malformed() }
        switch bytes[offset] {
        case 0x22: return .string(try readString())
        case 0x5B: return try readArray(depth: depth)
        case 0x7B: return try readObject(depth: depth)
        case 0x74:
            try readLiteral([0x74, 0x72, 0x75, 0x65])
            return .bool(true)
        case 0x66:
            try readLiteral([0x66, 0x61, 0x6C, 0x73, 0x65])
            return .bool(false)
        case 0x6E:
            try readLiteral([0x6E, 0x75, 0x6C, 0x6C])
            return .null
        case 0x2D, 0x30...0x39: return .number(try readNumber())
        default: throw malformed()
        }
    }

    private mutating func readArray(depth: Int) throws -> StrictJSONValue {
        offset += 1
        skipWhitespace()
        var values: [StrictJSONValue] = []
        if consume(0x5D) { return .array(values) }
        while true {
            values.append(try readValue(depth: depth + 1))
            skipWhitespace()
            if consume(0x5D) { return .array(values) }
            guard consume(0x2C) else { throw malformed() }
            skipWhitespace()
        }
    }

    private mutating func readObject(depth: Int) throws -> StrictJSONValue {
        offset += 1
        skipWhitespace()
        var members: [StrictJSONMember] = []
        var keys = Set<Data>()
        if consume(0x7D) { return .object(StrictJSONObject(members: members)) }
        while true {
            let keyOffset = offset
            guard offset < bytes.count, bytes[offset] == 0x22 else { throw malformed() }
            let key = try readString()
            guard keys.insert(Data(key.utf8)).inserted else {
                throw StrictJSONError.duplicateObjectKey(key, offset: keyOffset)
            }
            skipWhitespace()
            guard consume(0x3A) else { throw malformed() }
            skipWhitespace()
            members.append(StrictJSONMember(key: key, value: try readValue(depth: depth + 1)))
            skipWhitespace()
            if consume(0x7D) { return .object(StrictJSONObject(members: members)) }
            guard consume(0x2C) else { throw malformed() }
            skipWhitespace()
        }
    }

    private mutating func readString() throws -> String {
        guard consume(0x22) else { throw malformed() }
        var decoded = Data()
        var segmentStart = offset
        while offset < bytes.count {
            switch bytes[offset] {
            case 0x22:
                decoded.append(contentsOf: bytes[segmentStart..<offset])
                offset += 1
                guard let value = String(data: decoded, encoding: .utf8) else { throw StrictJSONError.invalidUTF8 }
                return value
            case 0x5C:
                decoded.append(contentsOf: bytes[segmentStart..<offset])
                offset += 1
                guard offset < bytes.count else { throw malformed() }
                let escape = bytes[offset]
                offset += 1
                switch escape {
                case 0x22, 0x2F, 0x5C: decoded.append(escape)
                case 0x62: decoded.append(0x08)
                case 0x66: decoded.append(0x0C)
                case 0x6E: decoded.append(0x0A)
                case 0x72: decoded.append(0x0D)
                case 0x74: decoded.append(0x09)
                case 0x75:
                    let escapeOffset = offset - 2
                    var scalar = try readHexQuad(escapeOffset: escapeOffset)
                    if (0xD800...0xDBFF).contains(scalar) {
                        guard bytes.count - offset >= 6, bytes[offset] == 0x5C, bytes[offset + 1] == 0x75 else {
                            throw StrictJSONError.malformedUnicodeEscape(offset: escapeOffset)
                        }
                        offset += 2
                        let low = try readHexQuad(escapeOffset: escapeOffset)
                        guard (0xDC00...0xDFFF).contains(low) else {
                            throw StrictJSONError.malformedUnicodeEscape(offset: escapeOffset)
                        }
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + low - 0xDC00
                    } else if (0xDC00...0xDFFF).contains(scalar) {
                        throw StrictJSONError.malformedUnicodeEscape(offset: escapeOffset)
                    }
                    guard let value = UnicodeScalar(scalar) else {
                        throw StrictJSONError.malformedUnicodeEscape(offset: escapeOffset)
                    }
                    decoded.append(contentsOf: String(value).utf8)
                default: throw malformed()
                }
                segmentStart = offset
            case 0..<0x20: throw malformed()
            default: offset += 1
            }
        }
        throw malformed()
    }

    private mutating func readHexQuad(escapeOffset: Int) throws -> UInt32 {
        guard bytes.count - offset >= 4 else { throw StrictJSONError.malformedUnicodeEscape(offset: escapeOffset) }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let digit: UInt32
            switch bytes[offset] {
            case 0x30...0x39: digit = UInt32(bytes[offset] - 0x30)
            case 0x41...0x46: digit = UInt32(bytes[offset] - 0x41 + 10)
            case 0x61...0x66: digit = UInt32(bytes[offset] - 0x61 + 10)
            default: throw StrictJSONError.malformedUnicodeEscape(offset: escapeOffset)
            }
            value = (value << 4) + digit
            offset += 1
        }
        return value
    }

    private mutating func readNumber() throws -> StrictJSONNumber {
        let start = offset
        _ = consume(0x2D)
        guard offset < bytes.count else { throw malformed() }
        if consume(0x30) {
            guard offset == bytes.count || !isDigit(bytes[offset]) else { throw malformed() }
        } else {
            guard (0x31...0x39).contains(bytes[offset]) else { throw malformed() }
            while offset < bytes.count, isDigit(bytes[offset]) { offset += 1 }
        }
        var isInteger = true
        if consume(0x2E) {
            isInteger = false
            try readRequiredDigits()
        }
        if offset < bytes.count, (bytes[offset] == 0x65 || bytes[offset] == 0x45) {
            isInteger = false
            offset += 1
            if offset < bytes.count, (bytes[offset] == 0x2B || bytes[offset] == 0x2D) { offset += 1 }
            try readRequiredDigits()
        }
        guard offset == bytes.count || isValueBoundary(bytes[offset]) else { throw malformed() }
        let token = String(decoding: bytes[start..<offset], as: UTF8.self)
        let number = StrictJSONNumber(lexicalValue: token, isInteger: isInteger)
        if !isInteger, (try? number.finiteDouble()) == nil {
            throw StrictJSONError.unsupportedNumber(token, offset: start)
        }
        return number
    }

    private mutating func readRequiredDigits() throws {
        guard offset < bytes.count, isDigit(bytes[offset]) else { throw malformed() }
        while offset < bytes.count, isDigit(bytes[offset]) { offset += 1 }
    }

    private mutating func readLiteral(_ literal: [UInt8]) throws {
        guard bytes.count - offset >= literal.count, bytes[offset..<(offset + literal.count)].elementsEqual(literal) else {
            throw malformed()
        }
        offset += literal.count
    }

    private mutating func skipWhitespace() {
        while offset < bytes.count, isWhitespace(bytes[offset]) { offset += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard offset < bytes.count, bytes[offset] == byte else { return false }
        offset += 1
        return true
    }

    private func malformed() -> StrictJSONError { .malformedJSON(offset: offset) }

    private func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }

    private func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private func isValueBoundary(_ byte: UInt8) -> Bool {
        isWhitespace(byte) || byte == 0x2C || byte == 0x5D || byte == 0x7D
    }
}
