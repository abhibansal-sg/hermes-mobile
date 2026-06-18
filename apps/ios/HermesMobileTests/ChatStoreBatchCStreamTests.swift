import XCTest
@testable import HermesMobile

/// ABH-87 **Batch C** — stream reducer parity (contract §2.5 + the D3/D4 fixes).
///
/// Distinct from `ChatStoreBatchCTests` (which pins the *ABH-48* R1 "Batch C"
/// composer-queue/foreign-mirror family — same letter, different epic). This
/// suite is the transcript-parity Batch C:
///  - **D3** reasoning lands/settles IN PLACE, including same-flush-window
///    ordering (reasoning-then-text when both deltas land in one ~40ms window);
///  - **D4** authoritative final text NEVER crosses a tool boundary.
///
/// Every fixture mirrors a real gateway emission shape.
@MainActor
final class ChatStoreBatchCStreamTests: XCTestCase {

    private let activeRuntime = "rt-batchc"
    private let storedId = "stored-batchc"

    // MARK: - D3: reasoning-then-text within ONE flush window

    /// When a reasoning delta and a text delta land in the SAME ~40ms flush
    /// window, the flush must apply reasoning FIRST so it settles in its leading
    /// wire position. The pre-fix flush appended text before reasoning, producing
    /// `[text, reasoning]` (D3 same-window family).
    func testReasoningBeforeTextInSameFlushWindow() async throws {
        let (chat, _) = makeStore()
        chat.handle(event: localFrame(type: "message.start"))
        // Both deltas enqueue before the single scheduled flush fires.
        chat.handle(event: localFrame(
            type: "reasoning.delta", payload: .object(["text": .string("think ")])))
        chat.handle(event: localFrame(
            type: "message.delta", payload: .object(["text": .string("answer")])))
        // Deterministic drain: cancel the 40ms coalescing Task and call
        // flushBuffers() directly — no wall-clock dependency (CI-safe).
        #if DEBUG
        chat.drainFlushForTesting()
        #else
        try await Task.sleep(for: .milliseconds(120))
        #endif

        let message = try XCTUnwrap(chat.messages.last)
        let kinds = message.parts.map { part -> String in
            switch part {
            case .reasoning(_, let t): return "reasoning(\(t))"
            case .text(_, let t): return "text(\(t))"
            default: return "other"
            }
        }
        XCTAssertEqual(kinds, ["reasoning(think )", "text(answer)"],
                       "reasoning settles before text even when both share one flush window")
    }

    // MARK: - D3: reasoning settles IN PLACE at completion (no index-0 yank)

    /// Reasoning that streamed AFTER an early text/tool must stay where it
    /// streamed when the authoritative final reasoning settles — never get
    /// yanked to index 0 (the pre-fix `applyFinalReasoning` `insert at:0`).
    func testFinalReasoningSettlesInPlaceNotAtTop() {
        var message = ChatMessage(role: .assistant)
        message.appendAssistantTextDelta("lead text ")
        message.upsertToolActivity(ToolActivity(
            id: "t1", name: "shell", argsSummary: "", progressText: "",
            resultPreview: "", state: .done, durationMs: 100, todos: nil))
        message.appendReasoningDelta("partial think")
        // Settle authoritative reasoning (a superset of the streamed partial).
        message.applyFinalReasoning("partial thinking, now complete")

        let kinds = message.parts.map { part -> String in
            switch part {
            case .reasoning: return "reasoning"
            case .text: return "text"
            case .tools: return "tool"
            default: return "other"
            }
        }
        XCTAssertEqual(kinds, ["text", "tool", "reasoning"],
                       "reasoning stays in its streamed position; it is NOT moved to index 0")
        XCTAssertEqual(message.thinking, "partial thinking, now complete",
                       "the settled reasoning replaces the streamed partial in place")
    }

    /// When NO reasoning streamed, the settled reasoning opens a leading run at
    /// the front (reasoning leads a turn on the wire) — the one legitimate
    /// front-insert.
    func testFinalReasoningWithNoStreamedRunLeadsTheBubble() {
        var message = ChatMessage(role: .assistant)
        message.appendAssistantTextDelta("answer only")
        message.applyFinalReasoning("after-the-fact reasoning")

        guard case .reasoning(_, let r) = message.parts.first else {
            return XCTFail("a settled reasoning with no streamed run leads the bubble")
        }
        XCTAssertEqual(r, "after-the-fact reasoning")
    }

    // MARK: - D4: final text never crosses a tool boundary

    /// A multi-run interleaving `text→tool→text` whose authoritative final text
    /// CONTRADICTS the streamed concatenation must reconcile only the trailing
    /// run — the pre-tool prose and the tool boundary stay put. The pre-fix
    /// `replaceTextParts` fused everything into the last slot (D4).
    func testApplyFinalTextNeverFusesAcrossToolBoundary() {
        var message = ChatMessage(role: .assistant)
        message.appendAssistantTextDelta("before ")
        message.upsertToolActivity(ToolActivity(
            id: "t1", name: "shell", argsSummary: "", progressText: "",
            resultPreview: "", state: .done, durationMs: 100, todos: nil))
        message.appendAssistantTextDelta("after")
        // Contradicting final: agrees on the leading run, rewrites the trailing.
        message.applyFinalText("before AFTER-FINAL")

        let order = message.parts.map { part -> String in
            switch part {
            case .text(_, let t): return "text(\(t))"
            case .tools: return "tool"
            default: return "other"
            }
        }
        XCTAssertEqual(order, ["text(before )", "tool", "text(AFTER-FINAL)"],
                       "pre-tool prose stays before the tool; only the trailing run reconciles")
    }

    /// A single text run with a contradicting final replaces in place (no new
    /// part, position preserved) — the safe single-run path.
    func testApplyFinalTextSingleRunReplacesInPlace() {
        var message = ChatMessage(role: .assistant)
        message.appendAssistantTextDelta("draft answer")
        message.applyFinalText("final answer")

        XCTAssertEqual(message.parts.count, 1)
        guard case .text(_, let t) = message.parts.first else {
            return XCTFail("expected a single text part")
        }
        XCTAssertEqual(t, "final answer")
    }

    // MARK: - harness

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
}
