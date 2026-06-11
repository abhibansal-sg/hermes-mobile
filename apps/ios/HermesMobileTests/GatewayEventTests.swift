import XCTest
@testable import HermesMobile

/// Coverage for `GatewayEvent(params:)` across every `GatewayEventType`
/// case, plus decoding of the streaming payload structs reached through the
/// event payload.
final class GatewayEventTests: XCTestCase {

    /// Build a `params` object in the shape the gateway delivers:
    /// `{type, session_id?, payload?}`.
    private func params(
        type: String,
        sessionId: String? = "sess-1",
        payload: JSONValue = .null
    ) -> JSONValue {
        var object: [String: JSONValue] = ["type": .string(type), "payload": payload]
        if let sessionId { object["session_id"] = .string(sessionId) }
        return .object(object)
    }

    // MARK: - Envelope parsing

    func testReturnsNilWhenTypeMissing() {
        XCTAssertNil(GatewayEvent(params: ["payload": ["text": "hi"]]))
        XCTAssertNil(GatewayEvent(params: .null))
        XCTAssertNil(GatewayEvent(params: "not an object"))
    }

    func testMissingSessionIdIsNil() {
        let event = GatewayEvent(params: params(type: "gateway.ready", sessionId: nil))
        XCTAssertNotNil(event)
        XCTAssertNil(event?.sessionId)
    }

    func testMissingPayloadDefaultsToNull() {
        let event = GatewayEvent(params: .object(["type": .string("status.update")]))
        XCTAssertEqual(event?.payload, .null)
    }

    // MARK: - Each event type

    func testGatewayReady() {
        let event = GatewayEvent(params: params(type: "gateway.ready", sessionId: nil))
        XCTAssertEqual(event?.type, .gatewayReady)
        XCTAssertEqual(event?.rawType, "gateway.ready")
    }

    func testMessageStart() {
        let event = GatewayEvent(params: params(type: "message.start", payload: ["role": "assistant"]))
        XCTAssertEqual(event?.type, .messageStart)
        XCTAssertEqual(event?.sessionId, "sess-1")
    }

    func testMessageDelta() {
        let event = GatewayEvent(params: params(type: "message.delta", payload: ["text": "partial "]))
        XCTAssertEqual(event?.type, .messageDelta)
        XCTAssertEqual(event?.payload["text"], .string("partial "))
    }

    func testThinkingDelta() {
        let event = GatewayEvent(params: params(type: "thinking.delta", payload: ["text": "let me think"]))
        XCTAssertEqual(event?.type, .thinkingDelta)
        XCTAssertEqual(event?.payload["text"], .string("let me think"))
    }

    func testReasoningDelta() {
        let event = GatewayEvent(params: params(type: "reasoning.delta", payload: ["text": "reasoning"]))
        XCTAssertEqual(event?.type, .reasoningDelta)
    }

    func testToolProgress() {
        // Real wire convention: `tool_id` (tui_gateway/server.py emits ids
        // under `tool_id` for all tool.* events).
        let event = GatewayEvent(params: params(
            type: "tool.progress",
            payload: ["tool_id": "tc1", "text": "downloading…"]
        ))
        XCTAssertEqual(event?.type, .toolProgress)
        let progress = ToolProgressPayload(payload: try! XCTUnwrap(event?.payload))
        XCTAssertEqual(progress.toolCallId, "tc1")
        XCTAssertEqual(progress.text, "downloading…")
    }

    func testToolProgressLegacyKeyFallback() {
        // Legacy-only fixture shape — kept to pin the fallback, NOT the contract.
        let progress = ToolProgressPayload(payload: ["tool_call_id": "tc1", "text": "x"])
        XCTAssertEqual(progress.toolCallId, "tc1")
    }

    func testStatusUpdate() {
        let event = GatewayEvent(params: params(type: "status.update", payload: ["running": true]))
        XCTAssertEqual(event?.type, .statusUpdate)
        XCTAssertEqual(event?.payload["running"], .bool(true))
    }

    func testUnknownTypePreservesRawType() {
        let event = GatewayEvent(params: params(type: "some.future.event", payload: ["k": "v"]))
        XCTAssertEqual(event?.type, .unknown)
        XCTAssertEqual(event?.rawType, "some.future.event")
        XCTAssertEqual(event?.payload["k"], .string("v"))
    }

    // MARK: - message.complete → MessageCompletePayload + UsageStats

    func testMessageCompleteWithUsage() throws {
        let payload: JSONValue = [
            "text": "Final answer.",
            "status": "completed",
            "reasoning": "did the work",
            "warning": "truncated context",
            "usage": [
                "input": 1200,
                "output": 350,
                "total": 1550,
                "calls": 2,
                "cost_usd": 0.0234
            ]
        ]
        let event = try XCTUnwrap(GatewayEvent(params: params(type: "message.complete", payload: payload)))
        XCTAssertEqual(event.type, .messageComplete)

        // MessageCompletePayload decodes via snake_case .decoded(as:).
        let complete = try XCTUnwrap(event.payload.decoded(as: MessageCompletePayload.self))
        XCTAssertEqual(complete.text, "Final answer.")
        XCTAssertEqual(complete.status, "completed")
        XCTAssertEqual(complete.reasoning, "did the work")
        XCTAssertEqual(complete.warning, "truncated context")

        let usage = try XCTUnwrap(complete.usage)
        XCTAssertEqual(usage.input, 1200)
        XCTAssertEqual(usage.output, 350)
        XCTAssertEqual(usage.total, 1550)
        XCTAssertEqual(usage.calls, 2)
        XCTAssertEqual(usage.costUsd, 0.0234)
    }

    func testMessageCompleteWithoutUsage() throws {
        let payload: JSONValue = ["text": "ok", "status": "completed"]
        let event = try XCTUnwrap(GatewayEvent(params: params(type: "message.complete", payload: payload)))
        let complete = try XCTUnwrap(event.payload.decoded(as: MessageCompletePayload.self))
        XCTAssertEqual(complete.text, "ok")
        XCTAssertNil(complete.usage)
        XCTAssertNil(complete.warning)
    }

    func testUsageStatsDecodesCostUsdSnakeCase() {
        let value: JSONValue = ["input": 10, "output": 20, "total": 30, "calls": 1, "cost_usd": 0.5]
        let usage = value.decoded(as: UsageStats.self)
        XCTAssertEqual(usage?.costUsd, 0.5)
        XCTAssertEqual(usage?.total, 30)
    }

    // MARK: - tool.start → ToolStartPayload

    func testToolStartPayload() throws {
        // REAL wire shape — mirrors tui_gateway/server.py _on_tool_start:
        // payload = {"tool_id": tool_call_id, "name": name, "args": args}
        let payload: JSONValue = [
            "tool_id": "call-abc",
            "name": "read_file",
            "args": ["path": "/etc/hosts", "lines": 50]
        ]
        let event = try XCTUnwrap(GatewayEvent(params: params(type: "tool.start", payload: payload)))
        XCTAssertEqual(event.type, .toolStart)

        let start = try XCTUnwrap(ToolStartPayload(payload: event.payload))
        XCTAssertEqual(start.toolCallId, "call-abc")
        XCTAssertEqual(start.name, "read_file")
        XCTAssertEqual(start.args["path"], .string("/etc/hosts"))
        XCTAssertEqual(start.args["lines"], .number(50))
    }

    func testToolStartPayloadLegacyKeyFallback() throws {
        // Legacy-only fixture shape — pins the fallback, NOT the contract.
        let start = try XCTUnwrap(ToolStartPayload(payload: ["tool_call_id": "old", "name": "noop"]))
        XCTAssertEqual(start.toolCallId, "old")
    }

    func testToolStartPayloadPrefersWireKeyOverLegacy() throws {
        // If both keys ever appear, the real wire key wins.
        let start = try XCTUnwrap(ToolStartPayload(
            payload: ["tool_id": "wire", "tool_call_id": "legacy", "name": "noop"]))
        XCTAssertEqual(start.toolCallId, "wire")
    }

    func testToolStartPayloadReturnsNilWithoutRequiredKeys() {
        XCTAssertNil(ToolStartPayload(payload: ["name": "x"]))      // no tool_id / tool_call_id
        XCTAssertNil(ToolStartPayload(payload: ["tool_id": "x"]))   // missing name
        XCTAssertNil(ToolStartPayload(payload: .null))
    }

    func testToolStartPayloadDefaultsArgsToNull() throws {
        let start = try XCTUnwrap(ToolStartPayload(payload: ["tool_id": "t", "name": "noop"]))
        XCTAssertEqual(start.args, .null)
    }

    // MARK: - tool.complete → ToolCompletePayload

    func testToolCompletePayload() {
        // REAL wire shape — mirrors tui_gateway/server.py _on_tool_complete:
        // {"tool_id": ..., "name": ..., "args": ..., "duration_s": <seconds>,
        //  "result": ...}. duration_s is SECONDS on the wire; the decoder
        // converts to the app's internal milliseconds unit.
        let payload: JSONValue = [
            "tool_id": "call-abc",
            "name": "read_file",
            "result": ["bytes": 2048, "ok": true],
            "duration_s": 1.2345
        ]
        let complete = ToolCompletePayload(payload: payload)
        XCTAssertEqual(complete.toolCallId, "call-abc")
        XCTAssertEqual(complete.name, "read_file")
        XCTAssertEqual(complete.result["bytes"], .number(2048))
        XCTAssertEqual(complete.result["ok"], .bool(true))
        XCTAssertEqual(try XCTUnwrap(complete.durationMs), 1234.5, accuracy: 0.0001)
    }

    func testToolCompletePayloadLegacyKeysFallback() {
        // Legacy-only fixture shape — pins the fallback, NOT the contract.
        let complete = ToolCompletePayload(payload: [
            "tool_call_id": "old", "duration_ms": 1234.5
        ])
        XCTAssertEqual(complete.toolCallId, "old")
        XCTAssertEqual(complete.durationMs, 1234.5)
    }

    func testToolCompletePayloadPrefersWireDurationOverLegacy() {
        // If both duration keys ever appear, the wire's seconds win.
        let complete = ToolCompletePayload(payload: [
            "tool_id": "t", "duration_s": 2.0, "duration_ms": 999.0
        ])
        XCTAssertEqual(complete.durationMs, 2000.0)
    }

    func testToolCompletePayloadDefaults() {
        let complete = ToolCompletePayload(payload: ["tool_id": "t"])
        XCTAssertEqual(complete.toolCallId, "t")
        XCTAssertNil(complete.name)
        XCTAssertEqual(complete.result, .null)
        XCTAssertNil(complete.durationMs)
    }

    // MARK: - approval.request → ApprovalRequestPayload

    func testApprovalRequestPayload() throws {
        let payload: JSONValue = [
            "id": "appr-1",
            "title": "Run shell command",
            "description": "Executes `rm -rf build`",
            "action": "shell",
            "target": "rm -rf build"
        ]
        let event = try XCTUnwrap(GatewayEvent(params: params(type: "approval.request", payload: payload)))
        XCTAssertEqual(event.type, .approvalRequest)

        let approval = ApprovalRequestPayload(payload: event.payload)
        XCTAssertEqual(approval.id, "appr-1")
        XCTAssertEqual(approval.title, "Run shell command")
        XCTAssertEqual(approval.descriptionText, "Executes `rm -rf build`")
        XCTAssertEqual(approval.action, "shell")
        XCTAssertEqual(approval.target, "rm -rf build")
    }

    func testApprovalRequestPayloadDefaults() {
        let approval = ApprovalRequestPayload(payload: .object([:]))
        XCTAssertFalse(approval.id.isEmpty)               // falls back to a UUID
        XCTAssertEqual(approval.title, "Approval required")
        XCTAssertNil(approval.descriptionText)
        XCTAssertNil(approval.action)
        XCTAssertNil(approval.target)
    }

    // MARK: - clarify.request → ClarifyRequestPayload

    func testClarifyRequestPayloadWithChoices() throws {
        let payload: JSONValue = [
            "question": "Which environment?",
            "choices": ["staging", "production", "local"]
        ]
        let event = try XCTUnwrap(GatewayEvent(params: params(type: "clarify.request", payload: payload)))
        XCTAssertEqual(event.type, .clarifyRequest)

        let clarify = ClarifyRequestPayload(payload: event.payload)
        XCTAssertEqual(clarify.question, "Which environment?")
        XCTAssertEqual(clarify.choices, ["staging", "production", "local"])
    }

    func testClarifyRequestPayloadDefaults() {
        let clarify = ClarifyRequestPayload(payload: .object([:]))
        XCTAssertEqual(clarify.question, "The agent needs input")
        XCTAssertTrue(clarify.choices.isEmpty)
    }

    func testClarifyRequestPayloadFiltersNonStringChoices() {
        let clarify = ClarifyRequestPayload(payload: ["question": "Pick", "choices": ["a", 2, "c"]])
        XCTAssertEqual(clarify.choices, ["a", "c"])
    }

    // MARK: - stored_session_id correlation guard (H3)

    func testStoredSessionIdDecodesFromString() {
        let event = GatewayEvent(params: .object([
            "type": .string("message.delta"),
            "session_id": .string("rt-1"),
            "stored_session_id": .string("stored-abc"),
            "payload": ["text": "hi"],
        ]))
        XCTAssertEqual(event?.storedSessionId, "stored-abc")
    }

    /// A numeric `stored_session_id` must NOT coerce to nil (which would silently
    /// zero the mirror correlation); it coerces to its string form.
    func testStoredSessionIdDecodesFromNumber() {
        let event = GatewayEvent(params: .object([
            "type": .string("message.delta"),
            "session_id": .string("rt-1"),
            "stored_session_id": .number(409921),
            "payload": ["text": "hi"],
        ]))
        XCTAssertEqual(event?.storedSessionId, "409921")
    }

    /// A whole-number stored id round-trips without a trailing ".0" so it matches
    /// the id the server stored.
    func testStoredSessionIdWholeNumberHasNoTrailingDecimal() {
        XCTAssertEqual(JSONValue.number(7).coercedStringValue, "7")
        XCTAssertEqual(JSONValue.number(7.0).coercedStringValue, "7")
    }

    func testStoredSessionIdTrimsWhitespace() {
        let event = GatewayEvent(params: .object([
            "type": .string("message.delta"),
            "session_id": .string("rt-1"),
            "stored_session_id": .string("  stored-abc \n"),
            "payload": ["text": "hi"],
        ]))
        XCTAssertEqual(event?.storedSessionId, "stored-abc")
    }

    /// A blank/whitespace-only stored id normalizes to nil so it can never
    /// falsely match an equally-blank active id.
    func testBlankStoredSessionIdNormalizesToNil() {
        let event = GatewayEvent(params: .object([
            "type": .string("message.delta"),
            "session_id": .string("rt-1"),
            "stored_session_id": .string("   "),
            "payload": ["text": "hi"],
        ]))
        XCTAssertNil(event?.storedSessionId)
    }

    /// Non-coercible scalars (bool/null/object/array) still yield nil.
    func testStoredSessionIdRejectsNonScalar() {
        XCTAssertNil(JSONValue.bool(true).coercedStringValue)
        XCTAssertNil(JSONValue.null.coercedStringValue)
        XCTAssertNil(JSONValue.array([.string("x")]).coercedStringValue)
        XCTAssertNil(JSONValue.object(["k": .string("v")]).coercedStringValue)
    }
}
