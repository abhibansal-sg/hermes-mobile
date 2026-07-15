import XCTest
@testable import HermesMobile

/// Coverage for `StoredMessage` construction from heterogeneous wire content
/// and its `text` flattening (string / block-array / null content).
final class StoredMessageTests: XCTestCase {

    // MARK: - Construction

    func testInitRequiresRole() {
        XCTAssertNil(StoredMessage(json: ["content": "hi"]))           // missing role
        XCTAssertNil(StoredMessage(json: .null))
        XCTAssertNil(StoredMessage(json: ["role": 5, "content": "x"])) // role not a string
    }

    func testInitParsesRoleContentTimestamp() throws {
        let message = try XCTUnwrap(StoredMessage(json: [
            "role": "user",
            "content": "hello",
            "timestamp": 1_700_000_000.0
        ]))
        XCTAssertEqual(message.role, "user")
        XCTAssertEqual(message.content, .string("hello"))
        XCTAssertEqual(message.timestamp, 1_700_000_000.0)
    }

    func testMissingTimestampIsNil() throws {
        let message = try XCTUnwrap(StoredMessage(json: ["role": "assistant", "content": "x"]))
        XCTAssertNil(message.timestamp)
    }

    func testMissingContentDefaultsToNull() throws {
        let message = try XCTUnwrap(StoredMessage(json: ["role": "user"]))
        XCTAssertEqual(message.content, .null)
    }

    // MARK: - text flattening: string content

    func testStringContentText() throws {
        let message = try XCTUnwrap(StoredMessage(json: ["role": "user", "content": "plain text"]))
        XCTAssertEqual(message.text, "plain text")
    }

    // MARK: - text flattening: block-array content

    func testBlockArrayContentText() throws {
        let message = try XCTUnwrap(StoredMessage(json: [
            "role": "assistant",
            "content": [
                ["type": "text", "text": "first line"],
                ["type": "text", "text": "second line"]
            ]
        ]))
        XCTAssertEqual(message.text, "first line\nsecond line")
    }

    func testBlockArraySkipsBlocksWithoutText() throws {
        // Non-text blocks (e.g. tool_use / image) carry no `text` and are dropped.
        let message = try XCTUnwrap(StoredMessage(json: [
            "role": "assistant",
            "content": [
                ["type": "text", "text": "keep me"],
                ["type": "tool_use", "name": "search", "input": ["q": "swift"]],
                ["type": "image", "source": "data:..."],
                ["type": "text", "text": "and me"]
            ]
        ]))
        XCTAssertEqual(message.text, "keep me\nand me")
    }

    func testEmptyBlockArrayProducesEmptyText() throws {
        let message = try XCTUnwrap(StoredMessage(json: ["role": "assistant", "content": []]))
        XCTAssertEqual(message.text, "")
    }

    // MARK: - text flattening: null / other content

    func testNullContentTextIsEmpty() throws {
        let message = try XCTUnwrap(StoredMessage(json: ["role": "system", "content": nil]))
        XCTAssertEqual(message.text, "")
    }

    func testImplicitNullContentTextIsEmpty() throws {
        // No `content` key at all → defaults to .null → empty text.
        let message = try XCTUnwrap(StoredMessage(json: ["role": "system"]))
        XCTAssertEqual(message.text, "")
    }

    func testObjectContentFallsBackToCompactDescription() throws {
        // Unexpected object content is not crashed on; it renders compactly.
        let message = try XCTUnwrap(StoredMessage(json: [
            "role": "tool",
            "content": ["status": "ok", "code": 0]
        ]))
        XCTAssertEqual(message.text, "{code: 0, status: ok}")
    }

    // MARK: - ABH-87 Batch B (§2.3) — widened wire fields

    /// The live tool-heavy session shape (re-verified against
    /// `cron_ebc83e783d98_20260607_155217`): an assistant row carries `reasoning`
    /// + a `tool_calls[]` whose entries have `call_id`/`id` and
    /// `function:{name, arguments(JSON string)}`; `call_id == id`.
    func testAssistantRowDecodesToolCallsAndReasoning() throws {
        let message = try XCTUnwrap(StoredMessage(json: [
            "role": "assistant",
            "content": "",
            "reasoning": "let me plan",
            "finish_reason": "tool_calls",
            "tool_calls": [
                ["call_id": "call_A", "id": "call_A", "type": "function",
                 "function": ["name": "skill_view", "arguments": "{\"q\":1}"]],
                ["call_id": "call_B", "id": "call_B",
                 "function": ["name": "execute_code", "arguments": "{}"]]
            ]
        ]))
        XCTAssertEqual(message.reasoning, "let me plan")
        XCTAssertEqual(message.finishReason, "tool_calls")
        XCTAssertEqual(message.toolCalls?.count, 2)
        XCTAssertEqual(message.toolCalls?[0].callId, "call_A")
        XCTAssertEqual(message.toolCalls?[0].name, "skill_view")
        XCTAssertEqual(message.toolCalls?[0].arguments, "{\"q\":1}")
        XCTAssertEqual(message.toolCalls?[1].name, "execute_code")
        // tool-row fields are absent on an assistant row.
        XCTAssertNil(message.toolCallId)
        XCTAssertNil(message.toolName)
    }

    /// A role:tool result row carries `tool_call_id` + `tool_name`, content is the
    /// (often huge) raw result string, and the tool-call/reasoning fields are
    /// empty — the wire sends `""`/`null`, which must normalize to nil.
    func testToolResultRowDecodesCorrelationFields() throws {
        let message = try XCTUnwrap(StoredMessage(json: [
            "role": "tool",
            "content": "the big result",
            "tool_call_id": "call_A",
            "tool_name": "skill_view",
            "reasoning": "",            // empty on the wire → nil
            "tool_calls": []            // empty array → nil
        ]))
        XCTAssertEqual(message.toolCallId, "call_A")
        XCTAssertEqual(message.toolName, "skill_view")
        XCTAssertEqual(message.text, "the big result")
        XCTAssertNil(message.reasoning, "empty reasoning string normalizes to nil")
        XCTAssertNil(message.toolCalls, "empty tool_calls array normalizes to nil")
    }

    /// `reasoning` falls back to `reasoning_content` then `reasoning_details`
    /// (first non-empty), per desktop chat-messages.ts:739-742.
    func testReasoningFallbackChain() throws {
        let viaContent = try XCTUnwrap(StoredMessage(json: [
            "role": "assistant", "content": "x",
            "reasoning": "", "reasoning_content": "from content"
        ]))
        XCTAssertEqual(viaContent.reasoning, "from content")

        let viaDetails = try XCTUnwrap(StoredMessage(json: [
            "role": "assistant", "content": "x",
            "reasoning_details": "from details"
        ]))
        XCTAssertEqual(viaDetails.reasoning, "from details")
    }

    /// A tool_call entry with only `id` (no `call_id`) still decodes; an entry
    /// with neither is dropped.
    func testWireToolCallIdFallbackAndDrop() throws {
        let message = try XCTUnwrap(StoredMessage(json: [
            "role": "assistant", "content": "",
            "tool_calls": [
                ["id": "only_id", "function": ["name": "t", "arguments": ""]],
                ["function": ["name": "no_id"]]   // no call_id and no id → dropped
            ]
        ]))
        XCTAssertEqual(message.toolCalls?.count, 1)
        XCTAssertEqual(message.toolCalls?[0].callId, "only_id")
    }
}
