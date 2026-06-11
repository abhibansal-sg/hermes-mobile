import XCTest
@testable import HermesMobile

/// Coverage for the foundational `JSONValue` codec: round-trips, integer
/// encoding without a trailing ".0", snake_case → camelCase re-decoding,
/// subscript access, and `compactDescription` rendering.
final class JSONValueTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Round-trip

    func testRoundTripNestedStructure() throws {
        let value: JSONValue = [
            "name": "hermes",
            "count": 3,
            "ratio": 1.5,
            "enabled": true,
            "missing": nil,
            "tags": ["a", "b", "c"],
            "nested": [
                "deep": ["x": 1, "y": 2],
                "list": [10, 20, 30]
            ]
        ]

        let data = try encoder.encode(value)
        let decoded = try decoder.decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testRoundTripScalars() throws {
        let scalars: [JSONValue] = [
            .null, .bool(true), .bool(false),
            .number(0), .number(-42), .number(3.14159),
            .string(""), .string("hello world")
        ]
        for scalar in scalars {
            let data = try encoder.encode(scalar)
            let decoded = try decoder.decode(JSONValue.self, from: data)
            XCTAssertEqual(decoded, scalar, "round-trip failed for \(scalar)")
        }
    }

    func testDecodeFromRawJSON() throws {
        let raw = #"{"jsonrpc":"2.0","items":[1,2,3],"flag":false,"none":null}"#
        let data = Data(raw.utf8)
        let value = try decoder.decode(JSONValue.self, from: data)

        XCTAssertEqual(value["jsonrpc"], .string("2.0"))
        XCTAssertEqual(value["items"], .array([.number(1), .number(2), .number(3)]))
        XCTAssertEqual(value["flag"], .bool(false))
        XCTAssertEqual(value["none"], .null)
    }

    // MARK: - Integer encoding (no trailing ".0")

    func testWholeNumberEncodesWithoutDecimalPoint() throws {
        let value: JSONValue = .number(42)
        let json = String(decoding: try encoder.encode(value), as: UTF8.self)
        XCTAssertEqual(json, "42")
        XCTAssertFalse(json.contains("."), "whole number must not encode a decimal point")
    }

    func testNegativeWholeNumberEncodesAsInteger() throws {
        let json = String(decoding: try encoder.encode(JSONValue.number(-7)), as: UTF8.self)
        XCTAssertEqual(json, "-7")
    }

    func testFractionalNumberKeepsDecimal() throws {
        let json = String(decoding: try encoder.encode(JSONValue.number(1.5)), as: UTF8.self)
        XCTAssertEqual(json, "1.5")
    }

    func testIntegerWithinObjectEncodesCleanly() throws {
        let value: JSONValue = ["cols": 80, "limit": 100, "ordinal": 1]
        let json = String(decoding: try encoder.encode(value), as: UTF8.self)
        XCTAssertTrue(json.contains("\"cols\":80"))
        XCTAssertTrue(json.contains("\"limit\":100"))
        XCTAssertTrue(json.contains("\"ordinal\":1"))
        XCTAssertFalse(json.contains(".0"))
    }

    // MARK: - decoded(as:) snake_case → camelCase

    private struct WireSample: Decodable, Equatable {
        let sessionId: String
        let messageCount: Int
        let startedAt: Double
        let costUsd: Double?
    }

    func testDecodedConvertsSnakeCaseToCamelCase() {
        let value: JSONValue = [
            "session_id": "abc123",
            "message_count": 7,
            "started_at": 1_700_000_000.0,
            "cost_usd": 0.0125
        ]
        let sample = value.decoded(as: WireSample.self)
        XCTAssertEqual(
            sample,
            WireSample(
                sessionId: "abc123",
                messageCount: 7,
                startedAt: 1_700_000_000.0,
                costUsd: 0.0125
            )
        )
    }

    func testDecodedReturnsNilOnTypeMismatch() {
        let value: JSONValue = ["session_id": 42] // number where String expected
        XCTAssertNil(value.decoded(as: WireSample.self))
    }

    func testDecodedHandlesMissingOptional() {
        let value: JSONValue = [
            "session_id": "s1",
            "message_count": 0,
            "started_at": 1.0
        ]
        let sample = value.decoded(as: WireSample.self)
        XCTAssertEqual(sample?.sessionId, "s1")
        XCTAssertNil(sample?.costUsd)
    }

    // MARK: - Subscripts & accessors

    func testKeySubscript() {
        let value: JSONValue = ["a": 1, "b": "two"]
        XCTAssertEqual(value["a"], .number(1))
        XCTAssertEqual(value["b"], .string("two"))
        XCTAssertNil(value["missing"])
        XCTAssertNil(JSONValue.string("scalar")["a"]) // subscript on non-object
    }

    func testIndexSubscript() {
        let value: JSONValue = ["zero", "one", "two"]
        XCTAssertEqual(value[0], .string("zero"))
        XCTAssertEqual(value[2], .string("two"))
        XCTAssertNil(value[3])                  // out of bounds
        XCTAssertNil(value[-1])                 // negative index
        XCTAssertNil(JSONValue.number(1)[0])    // subscript on non-array
    }

    func testTypedAccessors() {
        XCTAssertEqual(JSONValue.string("hi").stringValue, "hi")
        XCTAssertEqual(JSONValue.number(3.5).doubleValue, 3.5)
        XCTAssertEqual(JSONValue.number(9.9).intValue, 9)
        XCTAssertEqual(JSONValue.bool(true).boolValue, true)
        XCTAssertEqual(JSONValue.array([1, 2]).arrayValue, [.number(1), .number(2)])
        XCTAssertEqual(JSONValue.object(["k": 1]).objectValue, ["k": .number(1)])
        XCTAssertTrue(JSONValue.null.isNull)
        XCTAssertFalse(JSONValue.bool(false).isNull)

        // Cross-type accessors return nil rather than coercing.
        XCTAssertNil(JSONValue.number(1).stringValue)
        XCTAssertNil(JSONValue.string("x").doubleValue)
        XCTAssertNil(JSONValue.string("x").boolValue)
    }

    // MARK: - compactDescription

    func testCompactDescriptionScalars() {
        XCTAssertEqual(JSONValue.null.compactDescription, "null")
        XCTAssertEqual(JSONValue.bool(true).compactDescription, "true")
        XCTAssertEqual(JSONValue.bool(false).compactDescription, "false")
        XCTAssertEqual(JSONValue.number(42).compactDescription, "42")
        XCTAssertEqual(JSONValue.number(1.5).compactDescription, "1.5")
        XCTAssertEqual(JSONValue.string("hello").compactDescription, "hello")
    }

    func testCompactDescriptionArray() {
        let value: JSONValue = [1, "two", true]
        XCTAssertEqual(value.compactDescription, "[1, two, true]")
    }

    func testCompactDescriptionObjectIsKeySorted() {
        // Object keys are emitted in sorted order for deterministic previews.
        let value: JSONValue = ["b": 2, "a": 1, "c": 3]
        XCTAssertEqual(value.compactDescription, "{a: 1, b: 2, c: 3}")
    }

    func testCompactDescriptionNested() {
        let value: JSONValue = ["path": "/tmp/x", "lines": [1, 2]]
        XCTAssertEqual(value.compactDescription, "{lines: [1, 2], path: /tmp/x}")
    }

    // MARK: - Literal conveniences

    func testExpressibleByLiterals() {
        let nilLit: JSONValue = nil
        let boolLit: JSONValue = true
        let intLit: JSONValue = 5
        let floatLit: JSONValue = 2.5
        let strLit: JSONValue = "s"
        let arrLit: JSONValue = [1, 2]
        let dictLit: JSONValue = ["k": "v"]

        XCTAssertEqual(nilLit, .null)
        XCTAssertEqual(boolLit, .bool(true))
        XCTAssertEqual(intLit, .number(5))
        XCTAssertEqual(floatLit, .number(2.5))
        XCTAssertEqual(strLit, .string("s"))
        XCTAssertEqual(arrLit, .array([.number(1), .number(2)]))
        XCTAssertEqual(dictLit, .object(["k": .string("v")]))
    }
}
