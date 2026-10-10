import AgentBuildCore
import Foundation
import Testing

@Suite("Python-compatible canonical JSON")
struct CanonicalJSONTests {
    // Static byte/digest vectors generated with Python json.dumps(sort_keys=True,
    // ensure_ascii=False, separators=(",", ":")) and hashlib.sha256 on 2026-10-10.
    @Test(arguments: canonicalOracles)
    func bytesAndDigestsMatchPython(_ oracle: CanonicalOracle) throws {
        let bytes = try CanonicalJSONDigest.encode(oracle.value)
        let actualHex = bytes.map { String(format: "%02x", $0) }.joined()
        #expect(actualHex == oracle.hex, "\(oracle.name)")
        #expect(try CanonicalJSONDigest.sha256(oracle.value) == oracle.sha256, "\(oracle.name)")
    }

    @Test func objectMemberOrderDoesNotChangeBytes() throws {
        let first: CanonicalJSONValue = .object([
            CanonicalJSONMember(key: "z", value: .array([.integer(1), .null])),
            CanonicalJSONMember(key: "a", value: .bool(true)),
        ])
        let reversed: CanonicalJSONValue = .object([
            CanonicalJSONMember(key: "a", value: .bool(true)),
            CanonicalJSONMember(key: "z", value: .array([.integer(1), .null])),
        ])
        #expect(first == reversed)
        #expect(try CanonicalJSONDigest.encode(first) == CanonicalJSONDigest.encode(reversed))
    }

    @Test func valueEqualityRetainsUnicodeSpelling() throws {
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        #expect(composed == decomposed)
        #expect(CanonicalJSONValue.string(composed) != .string(decomposed))
        #expect(CanonicalJSONMember(key: composed, value: .null)
            != CanonicalJSONMember(key: decomposed, value: .null))
        let first: CanonicalJSONValue = .object([CanonicalJSONMember(key: composed, value: .string(composed))])
        let second: CanonicalJSONValue = .object([CanonicalJSONMember(key: decomposed, value: .string(decomposed))])
        #expect(first != second)
        // Independent Python oracle hashes preserve the two spellings.
        #expect(try CanonicalJSONDigest.sha256(first)
            == "e8b55b29bf172acb65a8ec20d1762cd9d6112c7abd6799895503d9151b8f42ab")
        #expect(try CanonicalJSONDigest.sha256(second)
            == "b98131ef426c7a9368e586407f639060d85b2b4582d1fe96851950bf6de90ee2")
    }

    @Test func rawDuplicateKeysAreRejected() {
        let value: CanonicalJSONValue = .object([
            CanonicalJSONMember(key: "same", value: .integer(1)),
            CanonicalJSONMember(key: "same", value: .integer(2)),
        ])
        #expect(throws: CanonicalJSONError.duplicateObjectKey("same")) {
            try CanonicalJSONDigest.encode(value)
        }
    }

    @Test func integerEncodingsPreserveNumbersWithoutFloatingPointCoercion() throws {
        #expect(try CanonicalJSONDigest.encode(.integer(1)) == CanonicalJSONDigest.encode(.unsignedInteger(1)))
        #expect(try CanonicalJSONDigest.encode(.bool(true)) != CanonicalJSONDigest.encode(.integer(1)))
        #expect(try CanonicalJSONDigest.encode(.unsignedInteger(.max)) == Data("18446744073709551615".utf8))
    }

    @Test func excessiveNestingIsRejected() {
        var value = CanonicalJSONValue.null
        for _ in 0...(CanonicalJSONDigest.maximumNestingDepth + 1) {
            value = .array([value])
        }
        #expect(throws: CanonicalJSONError.nestingLimitExceeded) {
            try CanonicalJSONDigest.encode(value)
        }
    }
}

struct CanonicalOracle: Sendable {
    let name: String
    let value: CanonicalJSONValue
    let hex: String
    let sha256: String
}

private let canonicalOracles: [CanonicalOracle] = [
    CanonicalOracle(
        name: "escapes",
        value: .object([
            "z": .string("quote \" slash / backslash \\\u{08}\u{0C}\n\r\t\u{00}\u{1F}\u{7F}"),
            "a": .string("Caf\u{00E9} e\u{0301} 漢字 🧭\u{2028}\u{2029}"),
        ]),
        hex: "7b2261223a22436166c3a92065cc8120e6bca2e5ad9720f09fa7ade280a8e280a9222c227a223a2271756f7465205c2220736c617368202f206261636b736c617368205c5c5c625c665c6e5c725c745c75303030305c75303031667f227d",
        sha256: "67d7a0eed7a9cf957c4ca91a2744b3fc31fef864b0191af14cc585a7bec90ab5"
    ),
    CanonicalOracle(
        name: "unicode-order",
        value: .object(["🧭": .integer(3), "漢": .integer(2), "é": .integer(1), "a": .integer(0)]),
        hex: "7b2261223a302c22c3a9223a312c22e6bca2223a322c22f09fa7ad223a337d",
        sha256: "5413955fa34de3f0d0da65b370c5bf7397f0c8c8d79b3356808e43ad39c21335"
    ),
    CanonicalOracle(
        name: "integers",
        value: .array([.integer(.min), .integer(-1), .integer(0), .integer(.max), .unsignedInteger(.max),
                       .bool(true), .bool(false), .null]),
        hex: "5b2d393232333337323033363835343737353830382c2d312c302c393232333337323033363835343737353830372c31383434363734343037333730393535313631352c747275652c66616c73652c6e756c6c5d",
        sha256: "65ed1d0a5c7c2cbc4116aea58758e79923ae59ffe722d08c9fc28b62940f1810"
    ),
    CanonicalOracle(
        name: "equivalent-keys",
        value: .object([
            CanonicalJSONMember(key: "\u{00E9}", value: .integer(1)),
            CanonicalJSONMember(key: "e\u{0301}", value: .integer(2)),
        ]),
        hex: "7b2265cc81223a322c22c3a9223a317d",
        sha256: "a7962fb10dc1255be368ece9c22b2256605921dc6d0a8c9409d3ee406bcb86e5"
    ),
]
