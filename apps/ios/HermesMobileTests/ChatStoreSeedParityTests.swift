import XCTest
@testable import HermesMobile

/// ABH-87 Batch B — the headline structural-parity suite (contract §4.test 1-3,
/// as far as Batch B enables them).
///
/// The acceptance invariant is `structure(seed(history)) == structure(stream(frames))`
/// for any conversation. These tests encode it by:
///  - running a conversation's frames through the LIVE stream producer
///    (`ChatStore.handle`), then serializing `[ChatMessage]` to a structural
///    signature;
///  - independently running the SAME conversation's history through the SEED
///    producer (`ChatStore.toChatMessages`) and serializing it the same way;
///  - asserting identical signatures.
///
/// Every fixture mirrors the contract's required set: the live 15-row session
/// shape, `text→tool→text→tool→text`, tool-only, interrupted, errored,
/// multi-tool-cluster.
@MainActor
final class ChatStoreSeedParityTests: XCTestCase {

    private let activeRuntime = "rt-seed-parity"
    private let storedId = "stored-seed-parity"

    // MARK: - Structural signature

    /// A conversation reduced to `(role, [part-kind + id-shape + text-or-toolids])`,
    /// the §4.test 1 signature. We compare the SHAPE of ids (kind + ordinal-or-
    /// toolcallid), not their literal message-id prefix, because the seed message
    /// id (`{ts}-{index}-{role}`) and the streamed message id (a fresh UUID minted
    /// at `message.start`) legitimately differ — what must match is the ORDER,
    /// kinds, per-part text, tool ids, and the *within-message* id structure.
    private func signature(_ messages: [ChatMessage]) -> [String] {
        messages.map { message in
            let parts = message.parts.map { partSignature($0, messageID: message.id.uuidString) }
            return "\(message.role.rawValue)::[\(parts.joined(separator: "|"))]"
        }
    }

    private func partSignature(_ part: ChatMessagePart, messageID: String) -> String {
        switch part {
        case .reasoning(let id, let text):
            return "reasoning(\(idShape(id, messageID: messageID)),\(text))"
        case .text(let id, let text):
            return "text(\(idShape(id, messageID: messageID)),\(text))"
        case .warning(let id, let text):
            return "warning(\(idShape(id, messageID: messageID)),\(text))"
        case .usage(let id, _):
            return "usage(\(idShape(id, messageID: messageID)))"
        case .tools(_, let tools, _, _):
            // Cluster id is the first tool's id by construction in both producers;
            // compare the ordered tool ids + states + names, which is the
            // structural content that must match part-for-part.
            let toolSig = tools.map { "\($0.id):\($0.name):\(stateTag($0.state))" }.joined(separator: ",")
            return "tools[\(toolSig)]"
        }
    }

    /// Normalize a run-index part id to its kind+ordinal suffix, dropping the
    /// message-id prefix (which differs seed vs stream — see `signature`).
    private func idShape(_ id: String, messageID: String) -> String {
        if id.hasPrefix(messageID + "-") {
            return String(id.dropFirst(messageID.count + 1))
        }
        // Already a suffix-style id, or a tool-derived id: keep its trailing
        // kind-ordinal token.
        if let dashRange = id.range(of: "-", options: .backwards),
           let kindRange = id.range(of: "-", options: .backwards, range: id.startIndex..<dashRange.lowerBound) {
            return String(id[kindRange.upperBound...])
        }
        return id
    }

    private func stateTag(_ state: ToolActivity.State) -> String {
        switch state {
        case .running: return "running"
        case .done: return "done"
        case .failed: return "failed"
        }
    }

    // MARK: - Conversation model (drives BOTH producers)

    /// An abstract turn description that lowers to BOTH wire history rows and a
    /// stream frame sequence, so the two producers are fed the same conversation.
    private struct Turn {
        var userText: String?
        /// Ordered assistant content: reasoning?, then interleaved text / tool
        /// steps, then optional final text.
        var reasoning: String?
        /// Each step is either prose or a tool (name, callId, result, failed).
        enum Step {
            case text(String)
            case tool(name: String, callId: String, result: String, failed: Bool)
        }
        var steps: [Step]
        var finalText: String?
        var interrupted: Bool = false
        var errored: String? = nil
    }

    // MARK: history lowering

    private func history(_ turns: [Turn]) -> [StoredMessage] {
        var rows: [StoredMessage] = []
        var ts = 1_700_000_000.0
        func push(_ m: StoredMessage) { rows.append(m); ts += 1 }
        for turn in turns {
            if let u = turn.userText {
                push(StoredMessage(role: "user", content: .string(u), timestamp: ts))
            }
            // Group consecutive tool steps into a single assistant row's
            // tool_calls[] when no prose intervenes — matching how the wire
            // actually batches calls (one assistant row carries N tool_calls,
            // followed by N tool-result rows). Prose opens/extends text.
            var i = 0
            var firstAssistantRowEmitted = false
            while i < turn.steps.count {
                switch turn.steps[i] {
                case .text(let t):
                    push(StoredMessage(
                        role: "assistant", content: .string(t), timestamp: ts,
                        reasoning: (!firstAssistantRowEmitted ? turn.reasoning : nil)
                    ))
                    firstAssistantRowEmitted = true
                    i += 1
                case .tool:
                    // Gather the consecutive tool run.
                    var calls: [WireToolCall] = []
                    var results: [(String, String, Bool)] = []
                    while i < turn.steps.count, case .tool(let name, let callId, let result, let failed) = turn.steps[i] {
                        calls.append(WireToolCall(callId: callId, name: name, arguments: "{}"))
                        results.append((callId, result, failed))
                        i += 1
                    }
                    push(StoredMessage(
                        role: "assistant", content: .string(""), timestamp: ts,
                        toolCalls: calls,
                        reasoning: (!firstAssistantRowEmitted ? turn.reasoning : nil),
                        finishReason: "tool_calls"
                    ))
                    firstAssistantRowEmitted = true
                    for (callId, result, failed) in results {
                        let content: JSONValue = failed ? .object(["error": .string(result)]) : .string(result)
                        push(StoredMessage(
                            role: "tool", content: content, timestamp: ts,
                            toolCallId: callId, toolName: nil
                        ))
                    }
                }
            }
            if let f = turn.finalText {
                push(StoredMessage(
                    role: "assistant", content: .string(f), timestamp: ts,
                    reasoning: (!firstAssistantRowEmitted ? turn.reasoning : nil),
                    finishReason: "stop"
                ))
            }
        }
        return rows
    }

    // MARK: stream lowering (drive the live producer)

    private func streamSignature(_ turns: [Turn]) async -> [ChatMessage] {
        let chat = makeStore()
        for turn in turns {
            if let u = turn.userText {
                // The user bubble is appended by the send path in the real app; for
                // structural parity of ASSISTANT turns we append it directly so the
                // signature lines up with history (which always carries the user row).
                chat.messages.append(ChatMessage(role: .user, text: u))
            }
            chat.handle(event: frame(type: "message.start"))
            if let r = turn.reasoning {
                chat.handle(event: frame(type: "reasoning.delta", payload: .object(["text": .string(r)])))
                // Batch C (D3): the flush reducer now applies reasoning BEFORE
                // text within a single ~40ms window (wire-order rule, contract
                // §2.5), so reasoning settles in its correct leading position even
                // when the first answer-text delta lands in the SAME flush window.
                // We deliberately DO NOT separate them with a sleep here — letting
                // reasoning and the first text delta share a window is exactly the
                // same-flush-window ordering the fix must get right. (The
                // dedicated same-window regression lives in
                // ChatStoreBatchCStreamTests.)
            }
            for step in turn.steps {
                switch step {
                case .text(let t):
                    chat.handle(event: frame(type: "message.delta", payload: .object(["text": .string(t)])))
                    // Deterministic drain: flush the 40ms coalescing buffer so
                    // the text delta lands before the next tool event — no
                    // wall-clock dependency (CI-safe).
                    #if DEBUG
                    chat.drainFlushForTesting()
                    #else
                    try? await Task.sleep(for: .milliseconds(50))  // let the flush land before a tool
                    #endif
                case .tool(let name, let callId, let result, let failed):
                    chat.handle(event: frame(type: "tool.start", payload: .object([
                        "tool_id": .string(callId), "name": .string(name)])))
                    let resultPayload: JSONValue = failed
                        ? .object(["error": .string(result)])
                        : .object(["output": .string(result)])
                    chat.handle(event: frame(type: "tool.complete", payload: .object([
                        "tool_id": .string(callId), "name": .string(name),
                        "result": resultPayload])))
                }
            }
            var completePayload: [String: JSONValue] = [:]
            if let f = turn.finalText { completePayload["text"] = .string(f) }
            if turn.interrupted { completePayload["status"] = .string("interrupted") }
            if let e = turn.errored {
                chat.handle(event: frame(type: "error", payload: .object(["message": .string(e)])))
            } else {
                chat.handle(event: frame(type: "message.complete", payload: .object(completePayload)))
            }
            // handleMessageComplete calls flushBuffersImmediately() synchronously;
            // a yield lets any remaining MainActor mutations propagate.
            await Task.yield()
        }
        return chat.messages
    }

    // MARK: - The property tests (§4.test 1)

    /// text→tool→text→tool→text: one assistant bubble, five interleaved parts,
    /// identical seed vs stream.
    func testParity_textToolTextToolText() async {
        let turns = [Turn(
            userText: "go",
            reasoning: nil,
            steps: [
                .text("A "),
                .tool(name: "shell", callId: "c1", result: "r1", failed: false),
                .text("B "),
                .tool(name: "grep", callId: "c2", result: "r2", failed: false),
                .text("C")
            ],
            finalText: nil
        )]
        await assertParity(turns)
    }

    /// A tool-only turn: one assistant bubble whose sole content is a tool cluster.
    func testParity_toolOnly() async {
        let turns = [Turn(
            userText: "run it",
            reasoning: "thinking first",
            steps: [.tool(name: "shell", callId: "t-only", result: "done", failed: false)],
            finalText: nil
        )]
        await assertParity(turns)
    }

    /// A multi-tool consecutive cluster (two tools back-to-back, no prose between):
    /// one cluster carrying both tools.
    func testParity_multiToolCluster() async {
        let turns = [Turn(
            userText: "batch",
            reasoning: nil,
            steps: [
                .tool(name: "shell", callId: "m1", result: "r1", failed: false),
                .tool(name: "grep", callId: "m2", result: "r2", failed: false)
            ],
            finalText: "all done"
        )]
        await assertParity(turns)
    }

    /// An errored turn: inline `.warning` part persists AND the body is
    /// structurally identical to the seed of the same history (Batch C strict
    /// cross-producer equivalence — the warning is footer-class per §2.6 and is
    /// excluded from the body signature, so the BODY must match part-for-part,
    /// not merely "the stream has a warning").
    func testParity_erroredTurnBodyMatchesSeedAndKeepsWarning() async {
        let turns = [Turn(
            userText: "boom",
            reasoning: "thinking before the crash",
            steps: [
                .text("partial "),
                .tool(name: "shell", callId: "e1", result: "ran", failed: false)
            ],
            finalText: nil,
            errored: "kaboom"
        )]
        let streamed = await streamSignature(turns)
        let seeded = ChatStore.toChatMessages(history(turns))
        // STRICT cross-producer body equivalence (footer-class warning excluded).
        XCTAssertEqual(bodySignature(seeded), bodySignature(streamed),
                       "errored-turn body is structurally identical to its seed")
        // The footer-class warning persists on the streamed turn.
        let last = streamed.last
        XCTAssertEqual(last?.warning, "kaboom", "errored turn keeps an inline warning")
        XCTAssertTrue(last?.parts.contains { if case .text(_, let t) = $0 { return t.hasPrefix("partial") }; return false } ?? false,
                      "the streamed body text survives alongside the warning")
    }

    /// FLIPPED (Batch C acceptance): an interrupted turn whose authoritative
    /// final-text AGREES with the streamed concatenation. Its full body —
    /// reasoning, the interleaved text→tool→text it managed to stream — must be
    /// structurally identical to the seed of the same history (STRICT
    /// cross-producer body equivalence, footer-class warning excluded).
    func testParity_interruptedBodyMatchesSeed() async {
        let turns = [Turn(
            userText: "stop",
            reasoning: "mid thought",
            steps: [
                .text("before "),
                .tool(name: "shell", callId: "i1", result: "ok", failed: false),
                .text("after")
            ],
            // A cut-off interrupt commonly carries NO authoritative final text
            // (the turn never reached `stop`); the streamed interleaving IS the
            // body. This keeps the parity arm deterministic — `applyFinalText`
            // never runs, so the body is exactly what streamed.
            finalText: nil,
            interrupted: true
        )]
        let streamed = await streamSignature(turns)
        let seeded = ChatStore.toChatMessages(history(turns))
        XCTAssertEqual(bodySignature(seeded), bodySignature(streamed),
                       "interrupted-turn body is structurally identical to its seed")
    }

    /// D4 acceptance (focused, stream-only because seed cannot reconstruct a
    /// contradicting interrupt completion): an interrupted turn whose
    /// authoritative final-text CONTRADICTS the streamed trailing run must NOT
    /// move prose across the tool boundary. The pre-fix `replaceTextParts` fused
    /// every text run into the last slot, floating the pre-tool prose below the
    /// tool and collapsing the interleaving. The fix reconciles ONLY the trailing
    /// run, leaving the pre-tool prose and the tool boundary exactly as streamed.
    func testStream_interruptedContradictingFinalTextDoesNotCrossToolBoundary() async {
        let turns = [Turn(
            userText: "stop",
            reasoning: "mid thought",
            steps: [
                .text("before "),
                .tool(name: "shell", callId: "i1", result: "ok", failed: false),
                .text("after")
            ],
            // Agrees with the leading prose ("before ") but rewrites the trailing
            // run ("after" → "AFTER-FINAL"). Only the trailing run may change.
            finalText: "before AFTER-FINAL",
            interrupted: true
        )]
        let streamed = await streamSignature(turns)
        let assistant = try! XCTUnwrap(streamed.first { $0.role == .assistant })
        let kinds = assistant.parts.compactMap { part -> String? in
            switch part {
            case .text(_, let t): return "text(\(t))"
            case .tools: return "tool"
            case .reasoning(_, let t): return "reasoning(\(t))"
            default: return nil  // exclude footer-class warning
            }
        }
        XCTAssertEqual(
            kinds,
            ["reasoning(mid thought)", "text(before )", "tool", "text(AFTER-FINAL)"],
            "pre-tool prose stays before the tool; only the trailing run is reconciled"
        )
    }

    /// The live 15-row session shape (cron user row + a long agentic turn that
    /// interleaves reasoning, four parallel tool_calls, their results, then more
    /// reasoning+tool steps, then a final text row).
    func testParity_liveSessionShape() async {
        let turns = [Turn(
            userText: String(repeating: "x", count: 200),  // a normal-length user row
            reasoning: "plan the work",
            steps: [
                .tool(name: "skill_view", callId: "k1", result: "a", failed: false),
                .tool(name: "skill_view", callId: "k2", result: "b", failed: false),
                .tool(name: "skill_view", callId: "k3", result: "c", failed: false),
                .tool(name: "skill_view", callId: "k4", result: "d", failed: false),
                .tool(name: "execute_code", callId: "k5", result: "e", failed: false),
                .tool(name: "write_file", callId: "k6", result: "f", failed: false),
                .tool(name: "terminal", callId: "k7", result: "g", failed: false),
                .tool(name: "terminal", callId: "k8", result: "h", failed: false)
            ],
            finalText: "Here is the summary."
        )]
        let seeded = ChatStore.toChatMessages(history(turns))
        // Gate target: ONE assistant bubble per agentic turn (plus the user row).
        XCTAssertEqual(seeded.filter { $0.role == .assistant }.count, 1,
                       "the whole agentic turn collapses to ONE assistant bubble")
        XCTAssertEqual(seeded.filter { $0.role == .tool }.count, 0, "no standalone tool rows")
        let assistant = seeded.first { $0.role == .assistant }
        XCTAssertEqual(assistant?.tools.count, 8, "all eight tool results merged in")
        XCTAssertTrue(assistant?.tools.allSatisfy { $0.state == .done } ?? false,
                      "every tool result merged onto its call (no lost results)")
        XCTAssertEqual(assistant?.thinking, "plan the work", "reasoning preserved")
        XCTAssertEqual(assistant?.text, "Here is the summary.", "final text preserved")
        await assertParity(turns)
    }

    // MARK: - §4.test 2: id stability across reseed

    func testIDStabilityAcrossReseed() {
        let turns = [Turn(
            userText: "go", reasoning: "r",
            steps: [.text("A "), .tool(name: "shell", callId: "c1", result: "r1", failed: false), .text("B")],
            finalText: nil
        )]
        let h = history(turns)
        let first = ChatStore.toChatMessages(h)
        let second = ChatStore.toChatMessages(h)
        XCTAssertEqual(first.map(\.id), second.map(\.id), "message ids are stable across reseed")
        let firstPartIDs = first.flatMap { $0.parts.map(\.id) }
        let secondPartIDs = second.flatMap { $0.parts.map(\.id) }
        XCTAssertEqual(firstPartIDs, secondPartIDs, "every part id is stable across reseed")
    }

    // MARK: - §4.test 3: seed-path ordering (prose never crosses a tool boundary)

    func testSeedPreservesTextToolTextOrder() {
        let turns = [Turn(
            userText: nil, reasoning: nil,
            steps: [
                .text("Before tool. "),
                .tool(name: "shell", callId: "c1", result: "ok", failed: false),
                .text("After tool.")
            ],
            finalText: nil
        )]
        let seeded = ChatStore.toChatMessages(history(turns))
        let assistant = try! XCTUnwrap(seeded.first { $0.role == .assistant })
        let kinds = assistant.parts.map { part -> String in
            switch part {
            case .text(_, let t): return "text(\(t))"
            case .tools: return "tool"
            case .reasoning: return "reasoning"
            default: return "other"
            }
        }
        XCTAssertEqual(kinds, ["text(Before tool. )", "tool", "text(After tool.)"],
                       "seed keeps prose on the correct side of the tool boundary")
    }

    func testSeedReasoningStaysInWirePosition() {
        // reasoning is the first within-row part; after a tool it must NOT jump
        // anywhere — it leads the bubble because it led the first assistant row.
        let turns = [Turn(
            userText: nil, reasoning: "lead reasoning",
            steps: [.text("body "), .tool(name: "shell", callId: "c1", result: "ok", failed: false)],
            finalText: "end"
        )]
        let seeded = ChatStore.toChatMessages(history(turns))
        let assistant = try! XCTUnwrap(seeded.first { $0.role == .assistant })
        guard case .reasoning(_, let r) = assistant.parts.first else {
            return XCTFail("reasoning must lead the bubble")
        }
        XCTAssertEqual(r, "lead reasoning")
    }

    // MARK: - empty-row filtering / collapse preservation (must-not-regress)

    func testSeedDropsEmptyRowsAndKeepsTextlessToolBubble() {
        let turns = [Turn(
            userText: "hi", reasoning: nil,
            steps: [.tool(name: "shell", callId: "c1", result: "ok", failed: false)],
            finalText: nil
        )]
        let seeded = ChatStore.toChatMessages(history(turns))
        // user + one tool-only assistant bubble; no empty rows.
        XCTAssertEqual(seeded.count, 2)
        XCTAssertFalse(seeded.contains { $0.role == .tool })
    }

    func testSeedCollapsesCronPreamble() {
        let preamble = "[" + String(repeating: "IMPORTANT scheduled cron job ", count: 20) + "]"
        let rows = [
            StoredMessage(role: "user", content: .string(preamble), timestamp: 1),
            StoredMessage(role: "assistant", content: .string("ok"), timestamp: 2, finishReason: "stop")
        ]
        let seeded = ChatStore.toChatMessages(rows)
        let user = try! XCTUnwrap(seeded.first { $0.role == .user })
        guard case .collapsed(let label) = user.presentation else {
            return XCTFail("a long bracketed cron preamble must collapse")
        }
        XCTAssertEqual(label, "Automation instructions")
    }

    func testSeedCollapsesSystemPrompt() {
        let rows = [
            StoredMessage(role: "system", content: .string("You are a helpful assistant."), timestamp: 1),
            StoredMessage(role: "user", content: .string("hi"), timestamp: 2)
        ]
        let seeded = ChatStore.toChatMessages(rows)
        let system = try! XCTUnwrap(seeded.first { $0.role == .system })
        guard case .collapsed = system.presentation else {
            return XCTFail("system prompt must collapse")
        }
    }

    // MARK: - user-row context stripping (desktop displayContentForMessage)

    func testUserAttachedContextStripsAndHoistsRefs() {
        let raw = """
        Please review this.
        --- Attached Context ---
        @file:"/tmp/a.swift" some blob @file:"/tmp/a.swift" @url:https://x.com
        --- Context Warnings ---
        truncated 1 file
        """
        let out = ChatStore.displayContentForUserMessage(raw)
        XCTAssertTrue(out.contains("@file:\"/tmp/a.swift\""), "ref chip hoisted")
        XCTAssertTrue(out.contains("@url:https://x.com"), "url chip hoisted")
        XCTAssertTrue(out.contains("Please review this."), "visible text kept")
        XCTAssertFalse(out.contains("--- Attached Context ---"), "scaffolding stripped")
        XCTAssertFalse(out.contains("Context Warnings"), "warnings stripped")
        XCTAssertFalse(out.contains("some blob"), "non-ref context dropped")
        // deduped: the repeated @file chip appears once.
        let occurrences = out.components(separatedBy: "@file:\"/tmp/a.swift\"").count - 1
        XCTAssertEqual(occurrences, 1, "duplicate ref chips deduped")
    }

    // MARK: - withUniqueSeedPartIds de-dup safety net (Batch A scrutiny note #1)

    func testDuplicateToolCallIdsAreDeDuped() {
        // Two separate turns whose tool_call_ids collide (wire can violate the
        // global-uniqueness invariant): the second occurrence is re-keyed, the
        // first preserved.
        let rows = [
            StoredMessage(role: "user", content: .string("one"), timestamp: 1),
            StoredMessage(role: "assistant", content: .string(""), timestamp: 2,
                          toolCalls: [WireToolCall(callId: "dup", name: "shell")], finishReason: "tool_calls"),
            StoredMessage(role: "tool", content: .string("r1"), timestamp: 3, toolCallId: "dup", toolName: "shell"),
            StoredMessage(role: "assistant", content: .string("mid"), timestamp: 4, finishReason: "stop"),
            StoredMessage(role: "user", content: .string("two"), timestamp: 5),
            StoredMessage(role: "assistant", content: .string(""), timestamp: 6,
                          toolCalls: [WireToolCall(callId: "dup", name: "grep")], finishReason: "tool_calls"),
            StoredMessage(role: "tool", content: .string("r2"), timestamp: 7, toolCallId: "dup", toolName: "grep"),
            StoredMessage(role: "assistant", content: .string("end"), timestamp: 8, finishReason: "stop")
        ]
        let seeded = ChatStore.toChatMessages(rows)
        let allToolIDs = seeded.flatMap { $0.tools.map(\.id) }
        XCTAssertEqual(allToolIDs.count, 2, "two tools across two turns")
        XCTAssertEqual(Set(allToolIDs).count, 2, "colliding tool_call_ids were made unique")
        XCTAssertTrue(allToolIDs.contains("dup"), "the first occurrence keeps its id")
    }

    // MARK: - helpers

    private func assertParity(_ turns: [Turn], file: StaticString = #filePath, line: UInt = #line) async {
        let streamed = await streamSignature(turns)
        let seeded = ChatStore.toChatMessages(history(turns))
        XCTAssertEqual(bodySignature(seeded), bodySignature(streamed),
                       "seed and stream structural signatures must be identical",
                       file: file, line: line)
    }

    /// Signature excluding footer-class parts (usage / warning), which §2.6 places
    /// outside the structural body and which the stream adds but a plain history
    /// seed cannot reconstruct.
    private func bodySignature(_ messages: [ChatMessage]) -> [String] {
        messages.map { message in
            let parts = message.parts.compactMap { part -> String? in
                switch part {
                case .usage, .warning: return nil
                default: return partSignature(part, messageID: message.id.uuidString)
                }
            }
            return "\(message.role.rawValue)::[\(parts.joined(separator: "|"))]"
        }
    }

    // MARK: - store harness

    private func makeStore() -> ChatStore {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        sessions.activeRuntimeId = activeRuntime
        sessions.activeStoredId = storedId
        chat.backfillFetch = { _ in [] }
        return chat
    }

    private func frame(type: String, payload: JSONValue = .null) -> GatewayEvent {
        GatewayEvent(params: .object([
            "type": .string(type),
            "session_id": .string(activeRuntime),
            "payload": payload,
        ]))!
    }
}
