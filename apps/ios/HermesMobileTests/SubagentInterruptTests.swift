import XCTest
@testable import HermesMobile

/// Coverage for `ChatStore.interruptSubagent(nodeId:)` — the `subagent.interrupt`
/// RPC path wired to the Stop button on the subagent tree (STR-145 / ABH-413,
/// Slice B of ABH-409).
///
/// Three load-bearing invariants under test:
/// 1. The RPC always targets the stable `subagent_id` from the event stream —
///    never a row index, `task_index`, depth, or synthesized display key.
/// 2. The RPC also carries the owning runtime `session_id` — captured on the
///    node from the `GatewayEvent` that created its branch (`SubagentNode.
///    sessionId`), so a MIRRORED (foreign) delegation tree is interrupted on
///    the runtime that actually owns it, never the phone's own local runtime.
/// 3. Idempotent race handling: a late tap after the branch already completed
///    (locally or server-side via `found:false`) is a silent no-op — never a
///    fake "cancelled" success and never a `lastError`/`.failed` surface. Only
///    a genuine transport/RPC error sets `.failed` + `lastError`, matching the
///    existing `interrupt()` / `steer()` convention.
///
/// All tests use the injectable `interruptSubagentRPC` DEBUG seam (mirrors
/// `steerRPC` — see `ChatSteerTests`) so no live gateway is required.
@MainActor
final class SubagentInterruptTests: XCTestCase {

    private let localRuntime = "rt-local"
    private let foreignRuntime = "rt-foreign"
    private let storedId = "stored-session-1"

    /// Build a wired store graph with an active local session (same shape as
    /// `ChatSteerTests.makeStore`).
    private func makeStore() -> ChatStore {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        sessions.activeRuntimeId = localRuntime
        sessions.activeStoredId = storedId
        chat.backfillFetch = { _ in [] }
        return chat
    }

    /// Inject a local `subagent.*` frame (ownership `.local`: `session_id` ==
    /// the store's `activeRuntimeId`).
    private func send(_ type: String, subagentId: String?, parentId: String? = nil,
                       taskIndex: Int? = nil, depth: Int? = nil, goal: String? = nil,
                       status: String? = nil, to chat: ChatStore) {
        var payload: [String: JSONValue] = [:]
        if let subagentId { payload["subagent_id"] = .string(subagentId) }
        if let parentId { payload["parent_id"] = .string(parentId) }
        if let taskIndex { payload["task_index"] = .number(Double(taskIndex)) }
        if let depth { payload["depth"] = .number(Double(depth)) }
        if let goal { payload["goal"] = .string(goal) }
        if let status { payload["status"] = .string(status) }

        chat.handle(event: GatewayEvent(params: .object([
            "type": .string(type),
            "session_id": .string(localRuntime),
            "payload": .object(payload),
        ]))!)
    }

    /// Inject a broadcast `subagent.*` frame from a FOREIGN runtime, tagged
    /// with the stored id the app has open (so it passes the correlation gate
    /// in `ChatStore.ownership(of:)` — same pattern as
    /// `ChatStoreForeignMirrorTests.foreignFrame`). Requires a prior foreign
    /// `message.start` on the same runtime so the mirror is adopted first.
    private func sendForeign(_ type: String, subagentId: String?, parentId: String? = nil,
                              taskIndex: Int? = nil, depth: Int? = nil, goal: String? = nil,
                              status: String? = nil, to chat: ChatStore) {
        var payload: [String: JSONValue] = [:]
        if let subagentId { payload["subagent_id"] = .string(subagentId) }
        if let parentId { payload["parent_id"] = .string(parentId) }
        if let taskIndex { payload["task_index"] = .number(Double(taskIndex)) }
        if let depth { payload["depth"] = .number(Double(depth)) }
        if let goal { payload["goal"] = .string(goal) }
        if let status { payload["status"] = .string(status) }

        chat.handle(event: GatewayEvent(params: .object([
            "type": .string(type),
            "session_id": .string(foreignRuntime),
            "stored_session_id": .string(storedId),
            "payload": .object(payload),
        ]))!)
    }

    // MARK: - Race: late tap after local completion is a no-op

    /// REQUIRED: `subagent.start` -> `subagent.complete` -> delayed
    /// `interruptSubagent` must be a true no-op. No RPC call, no state change,
    /// `lastError` untouched — the branch already finished before the tap.
    func testLateTapAfterLocalCompletionIsNoOp() async {
        let chat = makeStore()
        send("subagent.start", subagentId: "sub-1", goal: "Do the thing", to: chat)
        send("subagent.complete", subagentId: "sub-1", status: "completed", to: chat)

        var rpcCalled = false
        chat.interruptSubagentRPC = { _, _ in
            rpcCalled = true
            return ChatStore.SubagentInterruptResponse(found: true, subagentId: "sub-1")
        }

        await chat.interruptSubagent(nodeId: "sub-1")

        XCTAssertFalse(rpcCalled, "a tap on an already-completed node must never call the RPC")
        XCTAssertNil(chat.lastError, "a no-op late tap must not set lastError")
        XCTAssertNil(chat.subagentInterruptStates["sub-1"],
                     "state must stay absent (== idle) for a no-op late tap")
    }

    // MARK: - Stable subagent_id targeting (never row index / task_index / depth)

    /// REQUIRED: the RPC call must carry the branch's real `subagent_id`, never
    /// its `task_index`, `depth`, or a synthesized `parent|index` key. Uses a
    /// nested child whose `task_index`/`depth` numerically collide with other
    /// values in the tree, so any accidental substitution would be caught.
    /// Also asserts the owning `session_id` is the local active runtime — the
    /// RPC's other required param (STR-145 review).
    func testInterruptTargetsStableSubagentIdNotTaskIndexOrDepth() async {
        let chat = makeStore()
        // Parent: task_index 0, depth 0.
        send("subagent.start", subagentId: "sub-parent", goal: "Parent", to: chat)
        // Child: task_index 3, depth 2 — deliberately distinct numeric values
        // that must NOT leak into the RPC param in place of the real id.
        send("subagent.start", subagentId: "sub-child", parentId: "sub-parent",
             taskIndex: 3, depth: 2, goal: "Child", to: chat)

        var capturedId: String?
        var capturedSessionId: String?
        chat.interruptSubagentRPC = { sessionId, subagentId in
            capturedSessionId = sessionId
            capturedId = subagentId
            return ChatStore.SubagentInterruptResponse(found: true, subagentId: subagentId)
        }

        await chat.interruptSubagent(nodeId: "sub-child")

        XCTAssertEqual(capturedId, "sub-child",
                       "RPC must target the stable subagent_id, not task_index/depth/row order")
        XCTAssertNotEqual(capturedId, "3", "must not have substituted task_index for the id")
        XCTAssertNotEqual(capturedId, "2", "must not have substituted depth for the id")
        XCTAssertEqual(capturedSessionId, localRuntime,
                       "RPC must carry the owning runtime session_id alongside subagent_id")
    }

    // MARK: - Mirrored (foreign) subagent targets the FOREIGN runtime's session_id

    /// REQUIRED (STR-145 review): a subagent branch delegated by an ADOPTED
    /// foreign mirror must be interrupted on the foreign runtime that actually
    /// owns it — never the phone's own local `activeRuntimeId`, which never
    /// started this turn at all. Node identity captures `session_id` from the
    /// `GatewayEvent` at branch-creation time (`SubagentNode.sessionId`), not
    /// from `activeSessionId`/`mirroringRuntimeId` re-derived at tap time.
    func testInterruptOnMirroredForeignSubagentTargetsForeignSessionId() async {
        let chat = makeStore()
        // Adopt the foreign mirror first (no local turn in flight).
        chat.handle(event: GatewayEvent(params: .object([
            "type": .string("message.start"),
            "session_id": .string(foreignRuntime),
            "stored_session_id": .string(storedId),
            "payload": .object(["role": .string("assistant")]),
        ]))!)
        sendForeign("subagent.start", subagentId: "sub-foreign", goal: "Mirrored delegation", to: chat)

        var capturedSessionId: String?
        var capturedId: String?
        chat.interruptSubagentRPC = { sessionId, subagentId in
            capturedSessionId = sessionId
            capturedId = subagentId
            return ChatStore.SubagentInterruptResponse(found: true, subagentId: subagentId)
        }

        await chat.interruptSubagent(nodeId: "sub-foreign")

        XCTAssertEqual(capturedId, "sub-foreign")
        XCTAssertEqual(capturedSessionId, foreignRuntime,
                       "a mirrored subagent must be interrupted on the FOREIGN runtime, not local")
        XCTAssertNotEqual(capturedSessionId, localRuntime,
                          "must never substitute the phone's own local runtime for a mirrored branch")
    }

    // MARK: - found:false is a silent no-op, not an error

    /// REQUIRED: when the server-side branch already finished before the RPC
    /// landed (`found:false`), this is idempotent and benign — no "cancelled"
    /// success signal, no `.failed` state, no `lastError`.
    func testServerFoundFalseIsQuietNoOp() async {
        let chat = makeStore()
        send("subagent.start", subagentId: "sub-2", goal: "Still going", to: chat)

        chat.interruptSubagentRPC = { _, subagentId in
            ChatStore.SubagentInterruptResponse(found: false, subagentId: subagentId)
        }

        await chat.interruptSubagent(nodeId: "sub-2")

        XCTAssertEqual(chat.subagentInterruptStates["sub-2"], .idle,
                       "found:false must reset to .idle, not .failed")
        XCTAssertNil(chat.lastError, "found:false must never set lastError")
    }

    // MARK: - Genuine RPC/transport error IS observable

    /// A true transport/RPC failure (NOT found:false) must set `.failed` and
    /// `lastError`, matching `interrupt()` / `steer()` — this must not regress.
    func testGenuineRPCErrorSetsFailedAndLastError() async {
        let chat = makeStore()
        send("subagent.start", subagentId: "sub-3", goal: "Flaky", to: chat)

        chat.interruptSubagentRPC = { _, _ in
            throw GatewayError.rpc(code: 4009, message: "gateway unreachable")
        }

        await chat.interruptSubagent(nodeId: "sub-3")

        guard let state = chat.subagentInterruptStates["sub-3"], case .failed(let message) = state else {
            XCTFail("expected .failed state, got \(String(describing: chat.subagentInterruptStates["sub-3"]))")
            return
        }
        XCTAssertTrue(message.contains("4009") || message.contains("unreachable"),
                     "failure message should reference the gateway error: \(message)")
        XCTAssertNotNil(chat.lastError, "a genuine RPC error must set lastError (no regression)")
    }

    // MARK: - Interruptibility gating

    /// Only a `.running` node with a real (server-issued) `subagent_id` is
    /// interruptible — a synthesized-key node (id-less emitter) and a
    /// completed node are not.
    func testInterruptibilityGating() async {
        let chat = makeStore()
        // Real id, running -> interruptible.
        send("subagent.start", subagentId: "sub-real", goal: "Real id", to: chat)
        // No subagent_id -> synthesized "root|0" key, running -> NOT interruptible.
        send("subagent.start", subagentId: nil, taskIndex: 0, goal: "Id-less", to: chat)

        XCTAssertTrue(chat.isSubagentInterruptible("sub-real"))
        XCTAssertFalse(chat.isSubagentInterruptible("root|0"),
                       "a node without a real server subagent_id must never be interruptible")

        send("subagent.complete", subagentId: "sub-real", status: "completed", to: chat)
        XCTAssertFalse(chat.isSubagentInterruptible("sub-real"),
                       "a completed node must not be interruptible")
    }

    // MARK: - Re-tap while stopping / after stopped is a no-op

    /// Once the first interrupt call has been signalled (`.stopped`), a second
    /// tap before the terminal `subagent.complete` frame arrives must not fire
    /// a second RPC.
    func testReTapAfterStoppedIsNoOp() async {
        let chat = makeStore()
        send("subagent.start", subagentId: "sub-4", goal: "Once", to: chat)

        chat.interruptSubagentRPC = { _, subagentId in
            ChatStore.SubagentInterruptResponse(found: true, subagentId: subagentId)
        }
        await chat.interruptSubagent(nodeId: "sub-4")
        XCTAssertEqual(chat.subagentInterruptStates["sub-4"], .stopped)

        var secondCallFired = false
        chat.interruptSubagentRPC = { _, subagentId in
            secondCallFired = true
            return ChatStore.SubagentInterruptResponse(found: true, subagentId: subagentId)
        }
        await chat.interruptSubagent(nodeId: "sub-4")

        XCTAssertFalse(secondCallFired, "a re-tap after .stopped must not fire a second RPC")
        XCTAssertEqual(chat.subagentInterruptStates["sub-4"], .stopped)
    }

    // MARK: - Reset clears interrupt state on a new turn

    /// `resetSubagentTree()` (called from `beginLocalTurn()` on a fresh
    /// `message.start`) must also clear any stale interrupt state from the
    /// prior turn's branches.
    func testNewTurnClearsInterruptStates() async {
        let chat = makeStore()
        send("subagent.start", subagentId: "sub-5", goal: "Old turn", to: chat)
        chat.interruptSubagentRPC = { _, subagentId in
            ChatStore.SubagentInterruptResponse(found: true, subagentId: subagentId)
        }
        await chat.interruptSubagent(nodeId: "sub-5")
        XCTAssertEqual(chat.subagentInterruptStates["sub-5"], .stopped)

        // A fresh local turn begins.
        chat.handle(event: GatewayEvent(params: .object([
            "type": .string("message.start"),
            "session_id": .string(localRuntime),
            "payload": .object(["role": .string("assistant")]),
        ]))!)

        XCTAssertNil(chat.subagentInterruptStates["sub-5"],
                     "a new turn must clear stale interrupt state from the prior turn")
    }
}
