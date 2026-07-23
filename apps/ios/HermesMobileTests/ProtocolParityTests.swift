import XCTest
@testable import HermesMobile

/// ABH-46: gateway/iOS protocol-parity follow-ons. Every fixture below mirrors
/// a REAL gateway emission (file:line citations inline) — never a fictional
/// shape (the ABH-45 lesson).
@MainActor
final class ProtocolParityTests: XCTestCase {

    private let activeRuntime = "rt-active"
    private let storedId = "stored-abc"

    // MARK: - Item 1: gateway `error` event

    func testErrorEventDecodes() throws {
        // server.py:813 — _emit("error", sid, {"message": "agent init failed: …"})
        let event = try XCTUnwrap(GatewayEvent(params: .object([
            "type": .string("error"),
            "session_id": .string(activeRuntime),
            "payload": .object(["message": .string("agent init failed: boom")]),
        ])))
        XCTAssertEqual(event.type, .error)
        XCTAssertEqual(event.payload["message"]?.stringValue, "agent init failed: boom")
    }

    func testGatewayErrorClearsLocalStreamingAndSurfaces() async throws {
        let (chat, _) = makeStore()
        chat.handle(event: localFrame(type: "message.start"))
        chat.handle(event: localFrame(
            type: "message.delta", payload: .object(["text": .string("partial…")])))
        await waitUntil { chat.isStreaming }  // wait for the flush, don't race it
        XCTAssertTrue(chat.isStreaming)

        chat.handle(event: localFrame(
            type: "error", payload: .object(["message": .string("turn exploded")])))
        XCTAssertFalse(chat.isStreaming, "error must clear streaming")
        XCTAssertEqual(chat.lastError, "turn exploded")
        XCTAssertNil(chat.activeToolName)
        let last = try XCTUnwrap(chat.messages.last)
        XCTAssertFalse(last.isStreaming)
        XCTAssertEqual(last.warning, "turn exploded")
    }

    // MARK: - Item 2: clarify request_id round-trip

    func testClarifyRequestIdDecodes() {
        // _block injects request_id into every clarify frame (server.py:1117).
        let payload: JSONValue = .object([
            "question": .string("Which file?"),
            "choices": .array([.string("a.txt"), .string("b.txt")]),
            "request_id": .string("ab12cd34"),
        ])
        let request = ClarifyRequestPayload(payload: payload)
        XCTAssertEqual(request.requestId, "ab12cd34")
        XCTAssertEqual(request.question, "Which file?")
        XCTAssertEqual(request.choices, ["a.txt", "b.txt"])
    }

    func testClarifyMissingRequestIdNormalizesToNil() {
        let request = ClarifyRequestPayload(payload: .object([
            "question": .string("q"), "request_id": .string("")]))
        XCTAssertNil(request.requestId)
    }

    // MARK: - Item 5: message.complete status + final reasoning

    func testMessageCompleteAppliesFinalReasoningAndErrorStatus() async throws {
        let (chat, _) = makeStore()
        chat.handle(event: localFrame(type: "message.start"))
        chat.handle(event: localFrame(
            type: "reasoning.delta", payload: .object(["text": .string("partial think")])))
        chat.handle(event: localFrame(type: "message.complete", payload: .object([
            "text": .string("answer"),
            "status": .string("interrupted"),
            "reasoning": .string("the full settled reasoning"),
        ])))
        await waitUntil { chat.messages.last?.thinking == "the full settled reasoning" }
        let last = try XCTUnwrap(chat.messages.last)
        XCTAssertEqual(last.thinking, "the full settled reasoning",
                       "final reasoning replaces streamed deltas")
        XCTAssertNotNil(last.reasoningElapsed,
                        "reasoning duration is captured from the active turn before turnStartedAt is cleared")
        XCTAssertEqual(last.warning, "Turn interrupted")
        XCTAssertFalse(chat.isStreaming)
        XCTAssertNil(chat.turnStartedAt, "completion clears the active turn source after stamping the message")
    }

    // MARK: - Item 6: approval payload surfaces the real command

    func testApprovalPayloadSurfacesCommandAndDerivesTitle() {
        // tools/approval.py request dict: {command, pattern_key, description} —
        // there is NO `title` key on the live wire.
        let payload: JSONValue = .object([
            "command": .string("rm -rf build/"),
            "pattern_key": .string("recursive delete"),
            "description": .string("Delete the build directory"),
            "request_id": .string("ff00aa11"),
        ])
        let request = ApprovalRequestPayload(payload: payload)
        XCTAssertEqual(request.command, "rm -rf build/")
        XCTAssertEqual(request.patternKey, "recursive delete")
        XCTAssertEqual(request.title, "rm -rf build/",
                       "title falls back to the real command, not a generic label")
        XCTAssertEqual(request.descriptionText, "Delete the build directory")
    }

    func testApprovalExplicitTitleStillWins() {
        let request = ApprovalRequestPayload(payload: .object([
            "title": .string("Custom title"), "command": .string("ls")]))
        XCTAssertEqual(request.title, "Custom title")
    }

    func testApprovalNoFieldsFallsBackToGeneric() {
        let request = ApprovalRequestPayload(payload: .object([:]))
        XCTAssertEqual(request.title, "Approval required")
        XCTAssertNil(request.command)
    }

    // MARK: - Item 7: resume `resumed` fallback as stored session id

    func testSessionOpenResultFallsBackToResumed() throws {
        // session.resume returns the stored/target id under `resumed`
        // (server.py:3241), NOT `stored_session_id`.
        let json: JSONValue = .object([
            "session_id": .string("rt1"),
            "resumed": .string("20260606_010203_abcdef"),
            "message_count": .number(4),
        ])
        let result = try XCTUnwrap(json.decoded(as: SessionOpenResult.self))
        XCTAssertEqual(result.sessionId, "rt1")
        XCTAssertEqual(result.storedSessionId, "20260606_010203_abcdef")
        XCTAssertEqual(result.messageCount, 4)
    }

    func testSessionOpenResultPrefersExplicitStoredId() throws {
        let json: JSONValue = .object([
            "session_id": .string("rt1"),
            "stored_session_id": .string("stored-explicit"),
            "resumed": .string("stored-fallback"),
        ])
        let result = try XCTUnwrap(json.decoded(as: SessionOpenResult.self))
        XCTAssertEqual(result.storedSessionId, "stored-explicit")
    }

    func testSessionOpenResultDecodesStockHistoryAndSessionKey() throws {
        let json: JSONValue = .object([
            "session_id": .string("runtime-stock"),
            "session_key": .string("stored-stock"),
            "messages": .array([
                .object(["role": .string("user"), "content": .string("hello")]),
                .object(["role": .string("assistant"), "content": .string("hi")]),
            ]),
            "queued": .array([.object(["text": .string("later")])]),
        ])
        let result = try XCTUnwrap(json.decoded(as: SessionOpenResult.self))
        XCTAssertEqual(result.storedSessionId, "stored-stock")
        XCTAssertEqual(result.messages.count, 2)
        XCTAssertEqual(result.messages.first?.role, "user")
        XCTAssertEqual(result.queued.count, 1)
    }

    func testSessionActiveListDecodesStructuredStockShape() throws {
        let json: JSONValue = .object([
            "sessions": .array([
                .object([
                    "id": .string("runtime-watch"),
                    "session_key": .string("stored-watch"),
                    "status": .string("working"),
                    "model": .string("review-model"),
                ]),
            ]),
        ])
        let result = try XCTUnwrap(json.decoded(as: SessionActiveListResult.self))
        XCTAssertEqual(result.sessions, [
            SessionActiveItem(
                id: "runtime-watch", sessionKey: "stored-watch", status: .working,
                model: "review-model"
            )
        ])
    }

    func testPassiveOpenWatchesLiveSessionWithoutResume() async {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        chat.attach(connection: connection, sessions: sessions, attachments: AttachmentStore())
        sessions.attach(connection: connection, chat: chat)
        sessions.transcriptFetch = { _ in [] }
        sessions.activeListRPC = {
            SessionActiveListResult(sessions: [
                SessionActiveItem(
                    id: "runtime-desktop", sessionKey: "stored-desktop", status: .working,
                    model: "watch-model"
                )
            ])
        }
        var resumeCalls = 0
        sessions.resumeRPC = { _, _ in
            resumeCalls += 1
            return JSONValue.object([
                "session_id": .string("must-not-resume"),
                "resumed": .string("stored-desktop"),
            ]).decoded(as: SessionOpenResult.self)!
        }

        sessions.open(SessionSummary(
            id: "stored-desktop", title: "Desktop", preview: nil,
            startedAt: 1, messageCount: 1, source: nil,
            lastActive: 1, cwd: nil
        ))
        await sessions.waitForPendingOpenForTesting()

        XCTAssertEqual(resumeCalls, 0)
        XCTAssertEqual(sessions.sessionBinding?.storedID, "stored-desktop")
        XCTAssertEqual(sessions.sessionBinding?.runtimeID, "runtime-desktop")
        XCTAssertEqual(sessions.sessionBinding?.mode, .watch)
        XCTAssertEqual(connection.sessionModelRaw, "watch-model")

        chat.handle(event: GatewayEvent(params: .object([
            "type": .string("message.start"),
            "session_id": .string("runtime-desktop"),
            "stored_session_id": .string("stored-desktop"),
            "payload": .object([:]),
        ]))!)
        XCTAssertEqual(chat.foreignMirrorTelemetry.foreignAdopted, 1)
        XCTAssertFalse(chat.localTurnInFlight)
    }

    func testOpenResumesOnceWhenSessionIsNotLive() async {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        chat.attach(connection: connection, sessions: sessions, attachments: AttachmentStore())
        sessions.attach(connection: connection, chat: chat)
        sessions.transcriptFetch = { _ in [] }
        sessions.activeListRPC = { SessionActiveListResult(sessions: []) }
        var resumeCalls = 0
        sessions.resumeRPC = { _, _ in
            resumeCalls += 1
            return JSONValue.object([
                "session_id": .string("runtime-phone"),
                "session_key": .string("stored-idle"),
                "messages": .array([]),
            ]).decoded(as: SessionOpenResult.self)!
        }

        sessions.open(SessionSummary(
            id: "stored-idle", title: "Idle", preview: nil,
            startedAt: 1, messageCount: 1, source: nil,
            lastActive: 1, cwd: nil
        ))
        await sessions.waitForPendingOpenForTesting()

        XCTAssertEqual(resumeCalls, 1)
        XCTAssertEqual(sessions.sessionBinding?.runtimeID, "runtime-phone")
        XCTAssertEqual(sessions.sessionBinding?.mode, .drive)
        XCTAssertEqual(sessions.sessionBinding?.generation, 0)
    }

    // MARK: - Item 8: broadcast_gap parsing

    func testBroadcastGapParsesFromFrameTopLevel() throws {
        // The gateway writes broadcast_gap at the FRAME TOP LEVEL (a sibling of
        // `method`/`params`): tui_gateway/ws.py — obj = {**obj, "broadcast_gap":
        // dropped}. Exercise the REAL wire path end to end: decode a full
        // JSON-RPC frame via JSONRPCInboundFrame (which must surface the gap at
        // the top level), then construct the event exactly as the client's
        // `handleEvent` does. A prior version of this test injected broadcast_gap
        // INSIDE `params`, green-lighting the old buggy decode against input that
        // never occurs on the wire.
        // Decode raw frame bytes with the SAME plain JSONDecoder the socket
        // handler uses (HermesGatewayClient.decoder / handleEvent), so this
        // exercises the real wire path. (A JSONValue round-trip would apply
        // .convertFromSnakeCase and mask the top-level decode.)
        let frameData = Data("""
        {"jsonrpc":"2.0","method":"event","broadcast_gap":7,\
        "params":{"type":"message.delta","session_id":"rt9",\
        "payload":{"text":"x"}}}
        """.utf8)
        let frame = try XCTUnwrap(
            try? JSONDecoder().decode(JSONRPCInboundFrame.self, from: frameData))
        XCTAssertEqual(frame.broadcastGap, 7, "the gap must decode at the frame top level")
        let event = try XCTUnwrap(
            GatewayEvent(params: frame.params ?? .null, broadcastGap: frame.broadcastGap))
        XCTAssertEqual(event.broadcastGap, 7)
    }

    func testBroadcastGapAbsentOrZeroIsNil() throws {
        let absent = try XCTUnwrap(GatewayEvent(params: .object([
            "type": .string("message.delta"), "payload": .null])))
        XCTAssertNil(absent.broadcastGap)
        let zero = try XCTUnwrap(GatewayEvent(params: .object([
            "type": .string("message.delta"),
            "broadcast_gap": .number(0), "payload": .null])))
        XCTAssertNil(zero.broadcastGap)
    }

    // MARK: - Item 9: subagent failed/interrupted → error

    func testSubagentTerminalStatusMapping() {
        XCTAssertEqual(SubagentNode.Status(completionStatus: "failed"), .error)
        XCTAssertEqual(SubagentNode.Status(completionStatus: "interrupted"), .error)
        XCTAssertEqual(SubagentNode.Status(completionStatus: "error"), .error)
        XCTAssertEqual(SubagentNode.Status(completionStatus: "timeout"), .timeout)
        XCTAssertEqual(SubagentNode.Status(completionStatus: "completed"), .completed)
        XCTAssertEqual(SubagentNode.Status(completionStatus: nil), .completed)
    }

    // MARK: - Desktop-style assistant parts

    func testAssistantPartsPreserveTextToolTextOrder() async throws {
        let (chat, _) = makeStore()
        chat.handle(event: localFrame(type: "message.start"))
        chat.handle(event: localFrame(
            type: "message.delta",
            payload: .object(["text": .string("Before tool. ")])))
        chat.handle(event: localFrame(type: "tool.start", payload: .object([
            "tool_id": .string("t-order"),
            "name": .string("shell"),
        ])))
        chat.handle(event: localFrame(type: "tool.complete", payload: .object([
            "tool_id": .string("t-order"),
            "name": .string("shell"),
            "result": .object(["output": .string("ok")]),
            "duration_s": .number(0.1),
        ])))
        chat.handle(event: localFrame(
            type: "message.delta",
            payload: .object(["text": .string("After tool.")])))

        await waitUntil { (chat.messages.last?.parts.count ?? 0) == 3 }

        let message = try XCTUnwrap(chat.messages.last)
        XCTAssertEqual(message.text, "Before tool. After tool.")
        XCTAssertEqual(message.tools.count, 1)
        let parts = message.parts
        XCTAssertEqual(parts.count, 3)
        guard parts.count == 3 else { return }
        guard case .text(_, let firstText) = parts[0] else {
            return XCTFail("expected leading text part")
        }
        XCTAssertEqual(firstText, "Before tool. ")
        guard case .tools(_, let tools, _, _) = parts[1] else {
            return XCTFail("expected middle tool part")
        }
        XCTAssertEqual(tools.first?.id, "t-order")
        guard case .text(_, let secondText) = parts[2] else {
            return XCTFail("expected trailing text part")
        }
        XCTAssertEqual(secondText, "After tool.")
    }

    // MARK: - Parts adoption review fixes (#1–#5, #7)

    /// Review #7(a) + #5: the FOREIGN-mirrored live path must preserve
    /// text→tool→text order too — the `flushBuffersImmediately()` at the top of
    /// `handleToolStart` is what guarantees the pre-tool text is flushed into a
    /// part before the tool part is created, on both the local and foreign
    /// switches. The stash only tested the local path.
    func testForeignMirroredPartsPreserveTextToolTextOrder() async throws {
        let (chat, _) = makeStore()
        let foreign = "rt-foreign"
        // Adopt the foreign turn (no local turn in flight), then drive its live
        // deltas: text → tool → text, all tagged with the open stored id.
        chat.handle(event: foreignFrame(type: "message.start", runtime: foreign))
        XCTAssertTrue(chat.isStreaming, "adopting a foreign start should begin streaming")
        chat.handle(event: foreignFrame(
            type: "message.delta", runtime: foreign,
            payload: .object(["text": .string("Before tool. ")])))
        chat.handle(event: foreignFrame(type: "tool.start", runtime: foreign, payload: .object([
            "tool_id": .string("ft-order"), "name": .string("shell")])))
        chat.handle(event: foreignFrame(type: "tool.complete", runtime: foreign, payload: .object([
            "tool_id": .string("ft-order"), "name": .string("shell"),
            "result": .object(["output": .string("ok")]), "duration_s": .number(0.1)])))
        chat.handle(event: foreignFrame(
            type: "message.delta", runtime: foreign,
            payload: .object(["text": .string("After tool.")])))

        await waitUntil { (chat.messages.last?.parts.count ?? 0) == 3 }

        let message = try XCTUnwrap(chat.messages.last)
        let parts = message.parts
        XCTAssertEqual(parts.count, 3, "foreign mirror keeps text→tool→text as three ordered parts")
        guard parts.count == 3 else { return }
        guard case .text(_, let firstText) = parts[0] else { return XCTFail("expected leading text") }
        XCTAssertEqual(firstText, "Before tool. ")
        guard case .tools(_, let tools, _, _) = parts[1] else { return XCTFail("expected middle tool") }
        XCTAssertEqual(tools.first?.id, "ft-order")
        guard case .text(_, let secondText) = parts[2] else { return XCTFail("expected trailing text") }
        XCTAssertEqual(secondText, "After tool.")
    }

    /// Review #7(c): `message.complete` carrying authoritative
    /// text/reasoning/warning/usage must keep the LEGACY fields and the ordered
    /// PARTS in sync — the whole point of the dual-representation model.
    func testMessageCompleteKeepsLegacyFieldsAndPartsInSync() async throws {
        let (chat, _) = makeStore()
        chat.handle(event: localFrame(type: "message.start"))
        chat.handle(event: localFrame(
            type: "message.delta", payload: .object(["text": .string("partial ")])))
        chat.handle(event: localFrame(type: "message.complete", payload: .object([
            "text": .string("partial answer"),
            "reasoning": .string("settled reasoning"),
            "warning": .string("heads up"),
            "usage": .object(["input_tokens": .number(10), "output_tokens": .number(5)]),
        ])))
        await waitUntil { chat.messages.last?.text == "partial answer" }

        let message = try XCTUnwrap(chat.messages.last)
        // Legacy fields.
        XCTAssertEqual(message.text, "partial answer")
        XCTAssertEqual(message.thinking, "settled reasoning")
        XCTAssertEqual(message.warning, "heads up")
        XCTAssertNotNil(message.usage)
        // Ordered parts mirror them — and exactly once each (no double-emit).
        let parts = message.parts
        XCTAssertEqual(parts.filter { if case .warning = $0 { return true }; return false }.count, 1,
                       "exactly one warning part")
        XCTAssertEqual(parts.filter { if case .usage = $0 { return true }; return false }.count, 1,
                       "exactly one usage part")
        let textParts = parts.compactMap { part -> String? in
            if case .text(_, let t) = part { return t }; return nil
        }
        XCTAssertEqual(textParts.joined(), "partial answer", "settled text reflected in parts")
        let reasoningParts = parts.compactMap { part -> String? in
            if case .reasoning(_, let t) = part { return t }; return nil
        }
        XCTAssertEqual(reasoningParts.joined(), "settled reasoning", "settled reasoning reflected in parts")
    }

    /// Review #1 + #7(d): a connection drop mid-stream on a turn that already
    /// accumulated ordered parts must land "Connection lost" as an in-order
    /// `.warning` PART (via `setWarningPart`), not just the legacy field.
    func testConnectionDropWarningRendersAsOrderedPart() async throws {
        let (chat, _) = makeStore()
        chat.handle(event: localFrame(type: "message.start"))
        chat.handle(event: localFrame(
            type: "message.delta", payload: .object(["text": .string("half a reply")])))
        await waitUntil { chat.isStreaming }
        XCTAssertTrue(chat.isStreaming)

        chat.handleConnectionDrop()

        let message = try XCTUnwrap(chat.messages.last)
        XCTAssertFalse(message.isStreaming)
        XCTAssertEqual(message.warning, "Connection lost")
        // The warning is a real ordered part now — the part list is not silently
        // inconsistent with the legacy field (review fix #1).
        XCTAssertTrue(message.parts.contains { if case .warning(_, let t) = $0 { return t == "Connection lost" }; return false },
                      "Connection lost must be an ordered .warning part")
        // parts must not double-emit it.
        let warningCount = message.parts.filter {
            if case .warning = $0 { return true }; return false
        }.count
        XCTAssertEqual(warningCount, 1, "warning rendered exactly once")
    }

    /// ABH-87 Batch D / §3.2 (fixes D8): a turn with text-interleaved single-tool
    /// clusters (text→toolA→text→toolB) collapses PER-CLUSTER, not on the turn
    /// total. Each cluster has only ONE tool, so NEITHER collapses — the turn
    /// shows two lone tool rows, never two "1 tool call" capsules. The derived
    /// `toolsCollapsed` (true iff ANY cluster collapsed) is therefore FALSE here.
    ///
    /// (Supersedes the pre-Batch-D `testInterleavedToolClustersCollapseConsistently`,
    /// which asserted the turn-total collapse-all behavior the contract names as
    /// the D8 defect.)
    func testInterleavedSingleToolClustersDoNotCollapse() async throws {
        let (chat, _) = makeStore()
        chat.handle(event: localFrame(type: "message.start"))
        chat.handle(event: localFrame(
            type: "message.delta", payload: .object(["text": .string("A ")])))
        chat.handle(event: localFrame(type: "tool.start", payload: .object([
            "tool_id": .string("c1"), "name": .string("shell")])))
        chat.handle(event: localFrame(type: "tool.complete", payload: .object([
            "tool_id": .string("c1"), "name": .string("shell"),
            "result": .object(["output": .string("ok")]), "duration_s": .number(0.1)])))
        chat.handle(event: localFrame(
            type: "message.delta", payload: .object(["text": .string("B ")])))
        chat.handle(event: localFrame(type: "tool.start", payload: .object([
            "tool_id": .string("c2"), "name": .string("grep")])))
        chat.handle(event: localFrame(type: "tool.complete", payload: .object([
            "tool_id": .string("c2"), "name": .string("grep"),
            "result": .object(["output": .string("ok")]), "duration_s": .number(0.1)])))
        chat.handle(event: localFrame(type: "message.complete", payload: .object([
            "text": .string("A B done")])))
        await waitUntil { (chat.messages.last?.tools.count ?? 0) == 2 }

        let message = try XCTUnwrap(chat.messages.last)
        XCTAssertEqual(message.tools.count, 2, "two tools total across two clusters")
        let toolClusters = message.parts.compactMap { part -> Bool? in
            if case .tools(_, _, let collapsed, _) = part { return collapsed }; return nil
        }
        XCTAssertEqual(toolClusters.count, 2, "interleaving yields two single-tool clusters")
        XCTAssertTrue(toolClusters.allSatisfy { $0 == false },
                      "neither single-tool cluster collapses (per-cluster decision, §3.2)")
        XCTAssertFalse(message.toolsCollapsed,
                       "derived flag is false: no cluster collapsed")
    }

    /// ABH-87 Batch D / §3.2: consecutive tools with NO prose between them form
    /// ONE cluster of ≥2 tools, which DOES collapse into a single summary. This is
    /// the other half of the per-cluster contract (§4.test item 4): one collapsed
    /// cluster here vs. two un-collapsed single-tool clusters above.
    func testConsecutiveToolsFormOneCollapsedCluster() async throws {
        let (chat, _) = makeStore()
        chat.handle(event: localFrame(type: "message.start"))
        // Two tools back-to-back, no intervening prose → ONE cluster.
        chat.handle(event: localFrame(type: "tool.start", payload: .object([
            "tool_id": .string("d1"), "name": .string("shell")])))
        chat.handle(event: localFrame(type: "tool.complete", payload: .object([
            "tool_id": .string("d1"), "name": .string("shell"),
            "result": .object(["output": .string("ok")]), "duration_s": .number(0.1)])))
        chat.handle(event: localFrame(type: "tool.start", payload: .object([
            "tool_id": .string("d2"), "name": .string("grep")])))
        chat.handle(event: localFrame(type: "tool.complete", payload: .object([
            "tool_id": .string("d2"), "name": .string("grep"),
            "result": .object(["output": .string("ok")]), "duration_s": .number(0.1)])))
        chat.handle(event: localFrame(type: "message.complete", payload: .object([
            "text": .string("done")])))
        await waitUntil { (chat.messages.last?.tools.count ?? 0) == 2 }

        let message = try XCTUnwrap(chat.messages.last)
        let toolClusters = message.parts.compactMap { part -> (Int, Bool)? in
            if case .tools(_, let tools, let collapsed, _) = part { return (tools.count, collapsed) }
            return nil
        }
        XCTAssertEqual(toolClusters.count, 1, "consecutive tools form a single cluster")
        XCTAssertEqual(toolClusters.first?.0, 2, "the cluster carries both tools")
        XCTAssertEqual(toolClusters.first?.1, true, "a ≥2-tool cluster collapses")
        XCTAssertTrue(message.toolsCollapsed, "derived flag is true: the cluster collapsed")
    }

    /// ABH-87 §2.1: a SEEDED message materializes its scalar seed content into
    /// deterministic `parts` at construction (single source of truth, no parallel
    /// legacy fields, no salvage). Warning/usage appear EXACTLY ONCE and the
    /// derived accessors read back through `parts`.
    func testSeededMessageRendersWithoutDoubleWarningOrUsage() throws {
        // Decode UsageStats from the wire shape rather than coupling to its
        // memberwise init (it is Decodable-only with private storage names).
        let usage = try XCTUnwrap(JSONValue.object([
            "input": .number(3), "output": .number(4), "total": .number(7),
        ]).decoded(as: UsageStats.self))
        let seeded = ChatMessage(
            role: .assistant,
            text: "seeded body",
            usage: usage,
            warning: "seeded warning"
        )
        // Seed content is now materialized into parts at construction time.
        XCTAssertFalse(seeded.parts.isEmpty, "seed content materializes into ordered parts")

        let parts = seeded.parts
        XCTAssertEqual(parts.filter { if case .warning = $0 { return true }; return false }.count, 1,
                       "warning materialized exactly once")
        XCTAssertEqual(parts.filter { if case .usage = $0 { return true }; return false }.count, 1,
                       "usage materialized exactly once")
        // Derived accessors read back through parts.
        XCTAssertEqual(seeded.text, "seeded body")
        XCTAssertEqual(seeded.warning, "seeded warning")
        XCTAssertNotNil(seeded.usage)
    }

    /// Review #4: a mirrored turn that received text→tool but whose authoritative
    /// final text EXTENDS into post-tool prose must keep the new prose AFTER the
    /// tool, not float it above by merging into the pre-tool text part.
    func testApplyFinalTextKeepsPostToolProseAfterTool() {
        var message = ChatMessage(role: .assistant)
        message.appendAssistantTextDelta("Before. ")
        message.upsertToolActivity(ToolActivity(
            id: "t1", name: "shell", argsSummary: "", progressText: "",
            resultPreview: "", state: .done, durationMs: 100, todos: nil))
        // The settled completion carries the full text including the post-tool
        // tail the throttled client never received as a delta.
        message.applyFinalText("Before. After.")

        let order = message.parts.map { part -> String in
            switch part {
            case .text(_, let t): return "text(\(t))"
            case .tools: return "tool"
            default: return "other"
            }
        }
        // text(Before. ) → tool → text(After.) — the tail stays below the tool.
        XCTAssertEqual(order, ["text(Before. )", "tool", "text(After.)"],
                       "post-tool prose must render after the tool, not above it")
        XCTAssertEqual(message.text, "Before. After.")
    }

    // MARK: - Item 10: structured todos retained untruncated

    func testToolCompleteRetainsStructuredTodos() async throws {
        let (chat, _) = makeStore()
        chat.handle(event: localFrame(type: "message.start"))
        chat.handle(event: localFrame(type: "tool.start", payload: .object([
            "tool_id": .string("t1"), "name": .string("todo")])))
        // A list long enough that the 300-char resultPreview truncates — the
        // structured field must survive verbatim regardless.
        let todos: [JSONValue] = (0..<20).map { i in
            .object([
                "id": .string("todo-\(i)"),
                "content": .string("A reasonably long todo item number \(i) with detail"),
                "status": .string(i % 2 == 0 ? "completed" : "pending"),
            ])
        }
        chat.handle(event: localFrame(type: "tool.complete", payload: .object([
            "tool_id": .string("t1"),
            "name": .string("todo"),
            "result": .object(["todos": .array(todos), "summary": .object([:])]),
            "todos": .array(todos),
            "duration_s": .number(0.2),
        ])))
        await waitUntil { chat.messages.last?.tools.first?.todos?.count == 20 }
        let tool = try XCTUnwrap(chat.messages.last?.tools.first)
        XCTAssertEqual(tool.todos?.count, 20, "structured todos retained")
        XCTAssertTrue(tool.resultPreview.count <= 300)
        let todosArray = try XCTUnwrap(tool.todos)
        let parsed = try XCTUnwrap(TodoList(todosArray: todosArray))
        XCTAssertEqual(parsed.items.count, 20)
    }

    // MARK: - STR-460: inline diff rendering for file-edit tools

    func testToolCompleteRetainsFullDiffForPatchTool() async throws {
        let (chat, _) = makeStore()
        chat.handle(event: localFrame(type: "message.start"))
        chat.handle(event: localFrame(type: "tool.start", payload: .object([
            "tool_id": .string("t1"), "name": .string("patch")])))
        // Long enough that the 300-char resultPreview truncates the JSON blob —
        // the diff must survive untruncated on `fullDiff` regardless.
        let hunkLines = (0..<20).map { "+added context line number \($0) with enough text to pad" }
        let diff = "┊ review diff\n" + hunkLines.joined(separator: "\n")
        chat.handle(event: localFrame(type: "tool.complete", payload: .object([
            "tool_id": .string("t1"),
            "name": .string("patch"),
            "result": .object(["inline_diff": .string(diff), "message": .string("applied")]),
            "duration_s": .number(0.2),
        ])))
        await waitUntil { chat.messages.last?.tools.first?.state == .done }
        let tool = try XCTUnwrap(chat.messages.last?.tools.first)
        let fullDiff = try XCTUnwrap(tool.fullDiff)
        XCTAssertFalse(fullDiff.hasPrefix("┊"), "leading review-diff chrome must be stripped")
        XCTAssertTrue(fullDiff.contains("added context line number 19"), "diff kept untruncated")
        XCTAssertGreaterThan(fullDiff.count, 300)
        XCTAssertTrue(tool.resultPreview.count <= 300, "resultPreview stays truncated/normal")
    }

    func testToolCompleteRetainsFullDiffForWriteFileTool() async throws {
        let (chat, _) = makeStore()
        chat.handle(event: localFrame(type: "message.start"))
        chat.handle(event: localFrame(type: "tool.start", payload: .object([
            "tool_id": .string("t2"), "name": .string("write_file")])))
        chat.handle(event: localFrame(type: "tool.complete", payload: .object([
            "tool_id": .string("t2"),
            "name": .string("write_file"),
            "result": .object(["diff": .string("+new line\n-old line")]),
            "duration_s": .number(0.1),
        ])))
        await waitUntil { chat.messages.last?.tools.first?.state == .done }
        let tool = try XCTUnwrap(chat.messages.last?.tools.first)
        XCTAssertEqual(tool.fullDiff, "+new line\n-old line")
    }

    /// Negative: a non-file-edit tool whose result happens to carry a `diff`
    /// key must NOT be treated as a file-edit diff.
    func testToolCompleteIgnoresDiffKeyForNonFileEditTool() async throws {
        let (chat, _) = makeStore()
        chat.handle(event: localFrame(type: "message.start"))
        chat.handle(event: localFrame(type: "tool.start", payload: .object([
            "tool_id": .string("t3"), "name": .string("web_search")])))
        chat.handle(event: localFrame(type: "tool.complete", payload: .object([
            "tool_id": .string("t3"),
            "name": .string("web_search"),
            "result": .object(["diff": .string("+not a real edit diff")]),
            "duration_s": .number(0.1),
        ])))
        await waitUntil { chat.messages.last?.tools.first?.state == .done }
        let tool = try XCTUnwrap(chat.messages.last?.tools.first)
        XCTAssertNil(tool.fullDiff, "only patch/write_file/edit_file extract a diff")
    }

    /// STR-463: `resultSummary` must be derived from the FULL `payload.result`,
    /// not the already-truncated `resultPreview`. Here the meaningful
    /// `message` field sorts (alphabetically, per `compactDescription`) after
    /// a long `filler` field that alone exceeds the 300-char preview cutoff —
    /// so `resultPreview` never reaches "message" at all, while
    /// `resultSummary` (built from the untruncated result) must still surface it.
    func testToolCompleteSummaryDerivedFromFullResultBeyondPreviewTruncation() async throws {
        let (chat, _) = makeStore()
        chat.handle(event: localFrame(type: "message.start"))
        chat.handle(event: localFrame(type: "tool.start", payload: .object([
            "tool_id": .string("t-summary"), "name": .string("extract")])))
        let filler = String(repeating: "x", count: 400)
        chat.handle(event: localFrame(type: "tool.complete", payload: .object([
            "tool_id": .string("t-summary"),
            "name": .string("extract"),
            "result": .object([
                "filler": .string(filler),
                "message": .string("archive extracted to /tmp/output"),
            ]),
            "duration_s": .number(0.3),
        ])))
        await waitUntil { chat.messages.last?.tools.first?.state == .done }

        let tool = try XCTUnwrap(chat.messages.last?.tools.first)
        XCTAssertTrue(tool.resultPreview.count <= 300, "resultPreview stays truncated")
        XCTAssertFalse(
            tool.resultPreview.contains("archive extracted"),
            "the truncated preview never reaches the message field"
        )
        let summary = try XCTUnwrap(tool.resultSummary, "resultSummary must be derived even when the preview truncates")
        XCTAssertTrue(
            summary.contains("archive extracted to /tmp/output"),
            "resultSummary reads the full untruncated result, not the truncated preview"
        )
    }

    // MARK: - Harness (mirrors ChatStoreForeignMirrorTests.makeStore)

    /// Poll a @MainActor condition until it holds or `timeout` elapses. Replaces
    /// fixed `Task.sleep(120ms)` waits that race the streaming debounce flush
    /// (~40ms) and flake under heavy parallel-build load: the fix is to wait for
    /// the actual end-state (e.g. "3 parts coalesced") rather than a guessed
    /// duration, so the test is correct by construction regardless of machine
    /// load. Returns as soon as the condition is satisfied; on timeout the
    /// caller's subsequent assertions report the real failure.
    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(2),
        interval: Duration = .milliseconds(5),
        _ condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: interval)
        }
    }

    private func makeStore() -> (ChatStore, SessionStore) {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        sessions.activeRuntimeId = activeRuntime
        sessions.activeStoredId = storedId
        chat.backfillFetch = { _ in [] }
        return (chat, sessions)
    }

    private func localFrame(type: String, payload: JSONValue = .null) -> GatewayEvent {
        GatewayEvent(params: .object([
            "type": .string(type),
            "session_id": .string(activeRuntime),
            "payload": payload,
        ]))!
    }

    /// A broadcast frame from a FOREIGN runtime, tagged with the stored id the
    /// app has open (so it passes the correlation gate and is adopted as a
    /// mirror). Mirrors `ChatStoreForeignMirrorTests.foreignFrame`.
    private func foreignFrame(type: String, runtime: String, payload: JSONValue = .null) -> GatewayEvent {
        GatewayEvent(params: .object([
            "type": .string(type),
            "session_id": .string(runtime),
            "stored_session_id": .string(storedId),
            "payload": payload,
        ]))!
    }
}
