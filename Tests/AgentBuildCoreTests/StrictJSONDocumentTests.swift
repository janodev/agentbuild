import AgentBuildCore
import Foundation
import Testing

@Suite("Strict evidence JSON")
struct StrictJSONDocumentTests {
    @Test func rfc8259ObjectRetainsItsTypedContents() throws {
        let document = try strictDocument(#"""
            {
              "Image": {
                "Width": 800, "Height": 600, "Title": "View from 15th Floor",
                "Thumbnail": {"Url": "http://www.example.com/image/481989943",
                              "Height": 125, "Width": 100},
                "Animated": false, "IDs": [116, 943, 234, 38793]
              }
            }
            """#)
        let root = try document.root.requireObject().project(requiredKeys: ["Image"])
        let image = try root.requiredValue(forKey: "Image").requireObject().project(
            requiredKeys: ["Width", "Height", "Title", "Thumbnail", "Animated", "IDs"]
        )
        #expect(try number(image.requiredValue(forKey: "Width")).uint64() == 800)
        #expect(try number(image.requiredValue(forKey: "Height")).int64() == 600)
        #expect(image.value(forKey: "Title") == .string("View from 15th Floor"))
        #expect(image.value(forKey: "Animated") == .bool(false))
        let thumbnail = try image.requiredValue(forKey: "Thumbnail").requireObject()
        #expect(thumbnail.value(forKey: "Url") == .string("http://www.example.com/image/481989943"))
        let identifiers = try #require(image.value(forKey: "IDs"))
        guard case .array(let values) = identifiers else {
            Issue.record("RFC example IDs must be an array")
            return
        }
        #expect(try values.map { try number($0).int64() } == [116, 943, 234, 38793])
        #expect(document.nodeCount == 15)
    }

    @Test(arguments: strictStringOracles)
    func unicodeAndEscapesFollowJSONScalarRules(_ oracle: StrictJSONStringOracle) throws {
        let document = try strictDocument(oracle.json)
        #expect(document.root == .string(oracle.decoded))
        guard case .string(let value) = document.root else {
            Issue.record("String oracle did not produce a string")
            return
        }
        #expect(Data(value.utf8) == Data(oracle.decoded.utf8))
    }

    @Test func distinctUnicodeKeysAndValuesSurviveLookupAndProjection() throws {
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        #expect(composed == decomposed)
        let object = try strictDocument(#"{"é":"é","e\u0301":"e\u0301"}"#).root.requireObject()
        #expect(object.members.count == 2)
        #expect(object.value(forKey: composed) == .string(composed))
        #expect(object.value(forKey: decomposed) == .string(decomposed))
        #expect(object.value(forKey: composed) != object.value(forKey: decomposed))
        #expect(object.members[0] != object.members[1])
        #expect(StrictJSONError.missingField(composed) != .missingField(decomposed))
        let projection = try object.project(requiredKeys: [composed, decomposed])
        #expect(projection.members.count == 2)
        _ = try object.project(requiredKeys: [composed], optionalKeys: [decomposed])
        let first = try strictDocument(#""é""#)
        let second = try strictDocument(#""e\u0301""#)
        #expect(first.root != second.root)
        #expect(first.digest != second.digest)
    }

    @Test(arguments: [
        StrictJSONDuplicateOracle(json: #"{"key":1,"key":2}"#, key: "key", offset: 9),
        StrictJSONDuplicateOracle(json: #"{"key":1,"\u006bey":2}"#, key: "key", offset: 9),
        StrictJSONDuplicateOracle(json: #"{"outer":{"x":null,"x":false}}"#, key: "x", offset: 19),
        StrictJSONDuplicateOracle(json: #"{"é":1,"\u00e9":2}"#, key: "é", offset: 8),
    ])
    func duplicateDecodedUTF8KeysAreRejected(_ oracle: StrictJSONDuplicateOracle) {
        #expect(throws: StrictJSONError.duplicateObjectKey(oracle.key, offset: oracle.offset)) {
            try strictDocument(oracle.json)
        }
    }

    @Test func schemaProjectionRejectsAmbiguousOrUnexpectedFields() throws {
        let object = try strictDocument(#"{"required":true,"optional":null}"#).root.requireObject()
        #expect(try object.project(requiredKeys: ["required"], optionalKeys: ["optional"]) == object)
        #expect(throws: StrictJSONError.unexpectedField("optional")) {
            try object.project(requiredKeys: ["required"])
        }
        #expect(throws: StrictJSONError.missingField("missing")) {
            try object.project(requiredKeys: ["required", "missing"], optionalKeys: ["optional"])
        }
        #expect(throws: StrictJSONError.invalidSchema) {
            try object.project(requiredKeys: ["required", "required"])
        }
        #expect(throws: StrictJSONError.invalidSchema) {
            try object.project(requiredKeys: ["required"], optionalKeys: ["required"])
        }
        #expect(throws: StrictJSONError.invalidSchema) {
            try object.project(requiredKeys: ["required"], optionalKeys: ["optional", "optional"])
        }
        #expect(throws: StrictJSONError.expectedObject) { try strictDocument("[]").root.requireObject() }
        #expect(throws: StrictJSONError.missingField("missing")) { try object.requiredValue(forKey: "missing") }
        #expect(try strictDocument("{}").root.requireObject().project(requiredKeys: []).members.isEmpty)
        let reordered = try strictDocument(#"{"optional":null,"required":true}"#).root.requireObject()
        #expect(object == reordered)
    }

    @Test func integerConversionIsCheckedAndDoesNotCoerceFloatOrBoolean() throws {
        #expect(try strictNumber("-9223372036854775808").int64() == .min)
        #expect(try strictNumber("9223372036854775807").int64() == .max)
        #expect(try strictNumber("18446744073709551615").uint64() == .max)
        #expect(try strictNumber("-0").uint64() == 0)
        #expect(try strictNumber("-0").int64() == 0)
        #expect(try strictNumber("9223372036854775808").uint64() == 9_223_372_036_854_775_808)
        for token in ["9223372036854775808", "-9223372036854775809", "1.0", "1e0"] {
            #expect(throws: StrictJSONError.integerConversion(token)) { try strictNumber(token).int64() }
        }
        for token in ["18446744073709551616", "-1", "0.0"] {
            #expect(throws: StrictJSONError.integerConversion(token)) { try strictNumber(token).uint64() }
        }
        #expect(try strictDocument("true").root == .bool(true))
        #expect(try strictDocument(#""1""#).root == .string("1"))
    }

    @Test func largeIntegersRemainLexicalUntilTheSchemaConvertsThem() throws {
        let token = String(repeating: "9", count: 1_000)
        let value = try strictNumber(token)
        #expect(value.isInteger)
        #expect(value.lexicalValue == token)
        #expect(throws: StrictJSONError.integerConversion(token)) { try value.int64() }
        #expect(throws: StrictJSONError.integerConversion(token)) { try value.uint64() }
        #expect(throws: StrictJSONError.finiteDoubleConversion(token)) { try value.finiteDouble() }
    }

    @Test func finiteFloatsPreserveSpellingAndCheckedConversion() throws {
        #expect(try strictNumber("-12.5e+2").finiteDouble() == -1_250)
        #expect(try strictNumber("1.7976931348623157e308").finiteDouble() == Double.greatestFiniteMagnitude)
        #expect(try strictNumber("1e-9999").finiteDouble() == 0)
        let negativeZero = try strictNumber("-0.0")
        #expect(!negativeZero.isInteger)
        #expect(negativeZero.lexicalValue == "-0.0")
        #expect(try negativeZero.finiteDouble().sign == .minus)
        for token in ["1e400", "-1e400", "1.7976931348623159e308"] {
            #expect(throws: StrictJSONError.unsupportedNumber(token, offset: 0)) { try strictDocument(token) }
        }
        let documents = try ["0", "-0", "0.0", "0e0"].map { try strictDocument($0) }
        #expect(Set(documents.map(\.digest)).count == 4)
    }

    @Test(arguments: strictHostileJSON)
    func malformedOrUnsupportedDocumentsAreRejected(_ input: String) {
        #expect(throws: StrictJSONError.self) { try strictDocument(input) }
    }

    @Test(arguments: [
        [UInt8(0x22), 0x80, 0x22],
        [UInt8(0x22), 0xC2, 0x22],
        [UInt8(0x22), 0xC0, 0xAF, 0x22],
        [UInt8(0x22), 0xED, 0xA0, 0x80, 0x22],
        [UInt8(0x22), 0xF4, 0x90, 0x80, 0x80, 0x22],
    ])
    func malformedUTF8IsRejectedBeforeParsing(_ bytes: [UInt8]) {
        #expect(throws: StrictJSONError.invalidUTF8) { try StrictJSONDocument(data: Data(bytes)) }
    }

    @Test func byteBudgetUsesOriginalUTF8BytesAndIncludesWhitespace() throws {
        let input = Data(#""é""#.utf8)
        let exact = try StrictJSONLimits(maximumBytes: 4)
        #expect(try StrictJSONDocument(data: input, limits: exact).root == .string("é"))
        #expect(throws: StrictJSONError.byteBudgetExceeded(3)) {
            try StrictJSONDocument(data: input, limits: StrictJSONLimits(maximumBytes: 3))
        }
        #expect(throws: StrictJSONError.byteBudgetExceeded(4)) {
            try StrictJSONDocument(data: input + Data(" ".utf8), limits: exact)
        }
        let boundary = Data(("\"" + String(repeating: "x", count: 256 * 1_024 - 2) + "\"").utf8)
        #expect(try StrictJSONDocument(data: boundary).nodeCount == 1)
        #expect(throws: StrictJSONError.byteBudgetExceeded(256 * 1_024)) {
            try StrictJSONDocument(data: boundary + Data(" ".utf8))
        }
    }

    @Test func depthBudgetCountsRootAsZeroAndRejectsOnlyTheNextDepth() throws {
        let limits = try StrictJSONLimits(maximumDepth: 1)
        #expect(try strictDocument("[[]]", limits: limits).nodeCount == 2)
        #expect(try strictDocument(#"{"a":{}}"#, limits: limits).nodeCount == 2)
        #expect(throws: StrictJSONError.depthBudgetExceeded(1)) {
            try strictDocument("[[null]]", limits: limits)
        }
        #expect(throws: StrictJSONError.depthBudgetExceeded(1)) {
            try strictDocument(#"{"a":{"b":0}}"#, limits: limits)
        }
        let exact = String(repeating: "[", count: 64) + "null" + String(repeating: "]", count: 64)
        #expect(try strictDocument(exact).nodeCount == 65)
        #expect(throws: StrictJSONError.depthBudgetExceeded(64)) { try strictDocument("[" + exact + "]") }
    }

    @Test func nodeBudgetCountsValuesWithoutCountingObjectKeys() throws {
        let limits = try StrictJSONLimits(maximumNodes: 3)
        #expect(try strictDocument(#"{"a":true,"b":null}"#, limits: limits).nodeCount == 3)
        #expect(try strictDocument("[true,false]", limits: limits).nodeCount == 3)
        #expect(throws: StrictJSONError.nodeBudgetExceeded(3)) {
            try strictDocument("[true,false,null]", limits: limits)
        }
        #expect(throws: StrictJSONError.nodeBudgetExceeded(2)) {
            try strictDocument(#"{"a":true,"b":null}"#, limits: StrictJSONLimits(maximumNodes: 2))
        }
        #expect(try strictDocument(#""long strings remain a single value""#, limits: StrictJSONLimits(maximumNodes: 1)).nodeCount == 1)
    }

    @Test func invalidAndUnboundedLimitConfigurationsAreRejected() {
        for maximum in [-1, 0, Int.max] {
            #expect(throws: StrictJSONError.invalidLimits) { try StrictJSONLimits(maximumBytes: maximum) }
            #expect(throws: StrictJSONError.invalidLimits) { try StrictJSONLimits(maximumDepth: maximum) }
            #expect(throws: StrictJSONError.invalidLimits) { try StrictJSONLimits(maximumNodes: maximum) }
        }
        #expect(throws: StrictJSONError.invalidLimits) { try StrictJSONLimits(maximumBytes: 16 * 1_024 * 1_024 + 1) }
        #expect(throws: StrictJSONError.invalidLimits) { try StrictJSONLimits(maximumDepth: 257) }
        #expect(throws: StrictJSONError.invalidLimits) { try StrictJSONLimits(maximumNodes: 1_000_001) }
    }

    @Test func originalBytesAndDigestAreEvidenceRatherThanNormalizedJSON() throws {
        var input = Data("null".utf8)
        let document = try StrictJSONDocument(data: input)
        input[0] = 0x20
        #expect(document.originalData == Data("null".utf8))
        // Independent hashlib.sha256 oracle; JSON was not re-encoded.
        #expect(document.digest == "74234e98afe7498fb5daf1f36ac2d78acc339464f950703b8c019892f982b90b")
        let whitespace = try strictDocument(" null\n")
        #expect(whitespace.root == document.root)
        #expect(whitespace.digest != document.digest)
        #expect(whitespace.originalData == Data(" null\n".utf8))
        #expect(throws: StrictJSONError.trailingBytes(offset: 5)) { try strictDocument("null true") }
    }
}

private func strictDocument(_ input: String, limits: StrictJSONLimits = .standard) throws -> StrictJSONDocument {
    try StrictJSONDocument(data: Data(input.utf8), limits: limits)
}

private func strictNumber(_ token: String) throws -> StrictJSONNumber {
    try number(strictDocument(token).root)
}

private func number(_ value: StrictJSONValue) throws -> StrictJSONNumber {
    guard case .number(let number) = value else { throw StrictJSONError.invalidSchema }
    return number
}

struct StrictJSONStringOracle: Sendable {
    let json: String
    let decoded: String
}

struct StrictJSONDuplicateOracle: Sendable {
    let json: String
    let key: String
    let offset: Int
}

private let strictStringOracles = [
    StrictJSONStringOracle(json: #""Café é 漢字 🧭""#, decoded: "Café e\u{0301} 漢字 🧭"),
    StrictJSONStringOracle(json: #""\u00e9e\u0301""#, decoded: "\u{00E9}e\u{0301}"),
    StrictJSONStringOracle(json: #""\"\\\/\b\f\n\r\t\u0000\u001f""#, decoded: "\"\\/\u{08}\u{0C}\n\r\t\u{00}\u{1F}"),
    StrictJSONStringOracle(json: #""\uD83D\uDE00""#, decoded: "\u{1F600}"),
    StrictJSONStringOracle(json: #""\uD800\uDC00""#, decoded: "\u{10000}"),
    StrictJSONStringOracle(json: #""\uDBFF\uDFFF""#, decoded: "\u{10FFFF}"),
    StrictJSONStringOracle(json: #""\u2028\u2029\u007f""#, decoded: "\u{2028}\u{2029}\u{7F}"),
]

private let strictHostileJSON = [
    "", " ", "\u{FEFF}null", "{", "[", "tru", "falsee", "nil", "True", "NULL",
    "null null", "{}[]", "/* comment */ null", "// comment\nnull", "undefined",
    "{a:1}", #"{"a" 1}"#, #"{"a":}"#, #"{"a":1,}"#, #"{"a":1 "b":2}"#,
    "[1,]", "[,1]", "[1 2]", #""unterminated"#, "\"raw\nnewline\"", "\"raw\tcontrol\"",
    #""\x00""#, #""\v""#, #""\u123""#, #""\u12xz""#,
    #""\uD800""#, #""\uDC00""#, #""\uD800\u0041""#, #""\uD800x""#,
    #""\uD800\uD800""#, #""\uDC00\uD800""#,
    "NaN", "Infinity", "-Infinity", "+1", ".1", "-.1", "01", "-01", "1.",
    "1e", "1e+", "1e-", "1e1e1", "0x10", "1_000", "1e400", "-1e400",
]
