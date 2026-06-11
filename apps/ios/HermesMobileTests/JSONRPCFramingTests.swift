import XCTest
@testable import HermesMobile

/// Coverage for the JSON-RPC envelope: inbound frame discrimination
/// (success / error / event), numeric-id normalization via `RPCID`, and
/// outbound `JSONRPCRequest` encoding.
final class JSONRPCFramingTests: XCTestCase {

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private func frame(_ json: String) throws -> JSONRPCInboundFrame {
        try decoder.decode(JSONRPCInboundFrame.self, from: Data(json.utf8))
    }

    // MARK: - Success response

    func testDecodeSuccessResponse() throws {
        let json = #"""
        {"jsonrpc":"2.0","id":"r1","result":{"session_id":"abc","message_count":3}}
        """#
        let frame = try frame(json)

        XCTAssertTrue(frame.isResponse)
        XCTAssertFalse(frame.isEvent)
        XCTAssertEqual(frame.id?.stringValue, "r1")
        XCTAssertNil(frame.error)
        XCTAssertEqual(frame.result?["session_id"], .string("abc"))
        XCTAssertEqual(frame.result?["message_count"], .number(3))
    }

    func testDecodeSuccessResponseWithArrayResult() throws {
        let json = #"""
        {"jsonrpc":"2.0","id":"r7","result":{"sessions":[{"id":"s1"},{"id":"s2"}]}}
        """#
        let frame = try frame(json)
        XCTAssertTrue(frame.isResponse)
        XCTAssertEqual(frame.result?["sessions"]?.arrayValue?.count, 2)
        XCTAssertEqual(frame.result?["sessions"]?[0]?["id"], .string("s1"))
    }

    // MARK: - Error response

    func testDecodeErrorResponse() throws {
        let json = #"""
        {"jsonrpc":"2.0","id":"r2","error":{"code":4007,"message":"session not found"}}
        """#
        let frame = try frame(json)

        XCTAssertTrue(frame.isResponse)
        XCTAssertFalse(frame.isEvent)
        XCTAssertEqual(frame.id?.stringValue, "r2")
        XCTAssertNil(frame.result)
        XCTAssertEqual(frame.error?.code, 4007)
        XCTAssertEqual(frame.error?.message, "session not found")
        XCTAssertEqual(frame.error?.code, GatewayErrorCode.sessionNotFound)
    }

    // MARK: - Numeric id normalization

    func testNumericIdNormalizesToString() throws {
        let json = #"{"jsonrpc":"2.0","id":17,"result":{"ok":true}}"#
        let frame = try frame(json)
        XCTAssertTrue(frame.isResponse)
        XCTAssertEqual(frame.id, .number(17))
        XCTAssertEqual(frame.id?.stringValue, "17")
    }

    func testStringIdPreserved() throws {
        let frame = try frame(#"{"jsonrpc":"2.0","id":"r42","result":1}"#)
        XCTAssertEqual(frame.id, .string("r42"))
        XCTAssertEqual(frame.id?.stringValue, "r42")
    }

    func testRPCIDDirectDecodeStringAndNumber() throws {
        let asString = try decoder.decode(RPCID.self, from: Data(#""r9""#.utf8))
        XCTAssertEqual(asString, .string("r9"))
        XCTAssertEqual(asString.stringValue, "r9")

        let asNumber = try decoder.decode(RPCID.self, from: Data("99".utf8))
        XCTAssertEqual(asNumber, .number(99))
        XCTAssertEqual(asNumber.stringValue, "99")
    }

    // MARK: - Event frame

    func testDecodeEventFrame() throws {
        let json = #"""
        {"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"abc","payload":{"text":"hi"}}}
        """#
        let frame = try frame(json)

        XCTAssertTrue(frame.isEvent)
        XCTAssertFalse(frame.isResponse)
        XCTAssertNil(frame.id)
        XCTAssertNil(frame.result)
        XCTAssertNil(frame.error)
        XCTAssertEqual(frame.method, "event")

        let params = try XCTUnwrap(frame.params)
        XCTAssertEqual(params["type"], .string("message.delta"))
        XCTAssertEqual(params["session_id"], .string("abc"))
        XCTAssertEqual(params["payload"]?["text"], .string("hi"))

        // The frame's params feed straight into GatewayEvent.
        let event = try XCTUnwrap(GatewayEvent(params: params))
        XCTAssertEqual(event.type, .messageDelta)
        XCTAssertEqual(event.sessionId, "abc")
        XCTAssertEqual(event.payload["text"], .string("hi"))
    }

    func testEventFrameIsNotResponse() throws {
        // Event frames carry no id, so must never satisfy isResponse.
        let frame = try frame(#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready"}}"#)
        XCTAssertTrue(frame.isEvent)
        XCTAssertFalse(frame.isResponse)
    }

    func testResponseWithoutResultOrErrorIsNotResponse() throws {
        // An id alone (no result/error) is not a valid resolved response.
        let frame = try frame(#"{"jsonrpc":"2.0","id":"r1"}"#)
        XCTAssertFalse(frame.isResponse)
        XCTAssertFalse(frame.isEvent)
    }

    // MARK: - Outbound request encoding

    func testRequestEncodingProducesExpectedKeys() throws {
        let request = JSONRPCRequest(
            id: "r1",
            method: "session.create",
            params: ["model": "claude", "lazy": true]
        )
        let data = try encoder.encode(request)

        // Re-decode as JSONValue to assert on structure regardless of key order.
        let object = try decoder.decode(JSONValue.self, from: data)
        XCTAssertEqual(object["jsonrpc"], .string("2.0"))
        XCTAssertEqual(object["id"], .string("r1"))
        XCTAssertEqual(object["method"], .string("session.create"))
        XCTAssertEqual(object["params"]?["model"], .string("claude"))
        XCTAssertEqual(object["params"]?["lazy"], .bool(true))

        // All four top-level keys present, nothing extra.
        XCTAssertEqual(
            Set(object.objectValue?.keys ?? [:].keys),
            ["jsonrpc", "id", "method", "params"]
        )
    }

    func testRequestEncodesIntegerParamsWithoutDecimal() throws {
        let request = JSONRPCRequest(
            id: "r3",
            method: "terminal.resize",
            params: ["cols": 80, "rows": 24]
        )
        let json = String(decoding: try encoder.encode(request), as: UTF8.self)
        XCTAssertTrue(json.contains("\"cols\":80"))
        XCTAssertTrue(json.contains("\"rows\":24"))
        // Assert no trailing ".0" on the integer *params* specifically. The full
        // frame legitimately contains ".0" via the JSON-RPC version `"jsonrpc":"2.0"`,
        // so scope the check to the encoded params object.
        let paramsJSON = String(
            decoding: try encoder.encode(request.params),
            as: UTF8.self
        )
        XCTAssertFalse(paramsJSON.contains(".0"))
    }

    func testRequestRoundTripsThroughFrameShape() throws {
        // An outbound request is not an inbound response, but decoding its
        // bytes as a frame should still recover id + method cleanly.
        let request = JSONRPCRequest(id: "r5", method: "session.list", params: .null)
        let frame = try decoder.decode(JSONRPCInboundFrame.self, from: encoder.encode(request))
        XCTAssertEqual(frame.id?.stringValue, "r5")
        XCTAssertEqual(frame.method, "session.list")
        XCTAssertFalse(frame.isEvent)
    }
}
