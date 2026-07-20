import XCTest
@testable import HermesMobile

/// QA-2 R12/R13 — Turn Dock task-pill lifecycle + session-scoping regression
/// coverage. The dock's task box is the owner's redesign target: a native
/// capsule, width-to-fit centered, side-by-side with the pending pill when both
/// are live, reflecting REAL task state, clearing at turn end (even with missed
/// frames via the local-turn watchdog), strictly session-scoped (a list owned by
/// session A never shows in session B), and never wedged.
///
/// These tests exercise the pure model seams (`ChatStore.dockShowsTaskBox`,
/// `handleRelayTurnCompleted`, the local-turn watchdog force-settle) because
/// the test target has no view-inspection harness; the SwiftUI capsule surface
/// is structural. Frame builders mirror `RelayTaskListBridgeTests`.
@MainActor
final class TaskDockLifecycleTests: XCTestCase {

    // MARK: - Frame builder (relay taskList item.completed shape)

    private func taskListFrame(itemID: String = "s1:tasks",
                               tasks: [(id: String, text: String, status: String)],
                               status: String = "in_progress",
                               allComplete: Bool = false) -> RelayFrame {
        let taskArray: [JSONValue] = tasks.map {
            .object(["id": .string($0.id), "text": .string($0.text), "status": .string($0.status)])
        }
        let body: JSONValue = .object([
            "item_id": .string(itemID),
            "type": .string(ChatItemType.taskList.rawValue),
            "status": .string(status),
            "ord": .number(4),
            "body": .object([
                "tasks": .array(taskArray),
                "counts": .object(["total": .number(Double(taskArray.count))]),
                "all_complete": .bool(allComplete),
            ]),
        ])
        return RelayFrame(seq: 1, sid: "s", turn: "t",
                          kind: RelayFrameKind(wire: "item.completed"), body: body)
    }

    /// Bare `ChatStore()` (no sessions attached) — `activeSessionId` resolves to
    /// `nil`, so the owner-identity gate in `dockShowsTaskBox` is skipped
    /// (nil-vs-nil passes). Used for the lifecycle tests that don't need a
    /// session switch.
    private func bareChat() -> ChatStore { ChatStore() }

    /// A ChatStore wired to a real SessionStore so `activeSessionId` reflects the
    /// active runtime id — required to prove the A-vs-B session-scoping rule.
    private func attachedChat() -> (chat: ChatStore, sessions: SessionStore) {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        chat.attach(connection: connection, sessions: sessions, attachments: AttachmentStore())
        return (chat, sessions)
    }

    // MARK: - R12: visibility is turn-lifecycle-driven (clears at turn end)

    func testDockHiddenWhenNoTaskList() {
        let chat = bareChat()
        chat.isStreaming = true
        XCTAssertFalse(chat.dockShowsTaskBox, "no list → dock never shows the task box")
    }

    func testDockHiddenWhenTurnNotLive_R12ClearsAtTurnEnd() {
        // R12: "clears when the turn ends". A settled turn (`isStreaming == false`)
        // must NEVER surface the task pill, even when a list still exists in the
        // relay item store (the item persists after the turn). Before the fix the
        // dock gated on `latestTodoList != nil` alone and the pill wedged.
        let chat = bareChat()
        chat.applyRelayItems([ChatItem(
            itemID: "s1:tasks", type: .taskList, status: .inProgress, ord: 4,
            body: [
                "tasks": [["id": "1", "text": "Read auth.py", "status": "in_progress"]],
                "all_complete": false,
            ]
        )])
        XCTAssertNotNil(chat.latestTodoList, "precondition: the list DATA still exists post-turn")
        chat.isStreaming = false  // turn ended
        XCTAssertFalse(chat.dockShowsTaskBox, "R12: pill must clear the instant the owning turn ends")
    }

    func testDockShownWhileTurnLiveAndListPresent() {
        let chat = bareChat()
        chat.applyRelayItems([ChatItem(
            itemID: "s1:tasks", type: .taskList, status: .inProgress, ord: 4,
            body: [
                "tasks": [
                    ["id": "1", "text": "Read auth.py", "status": "completed"],
                    ["id": "2", "text": "Run migration", "status": "in_progress"],
                ],
                "all_complete": false,
            ]
        )])
        chat.isStreaming = true  // turn live
        XCTAssertTrue(chat.dockShowsTaskBox, "live turn + non-terminal list → pill visible")
    }

    // MARK: - R13: terminal list auto-dismisses (agent closed it)

    func testDockHiddenWhenListIsTerminal_AgentClosed_R13() {
        // R13: "closed/short-closed by the agent". When every task is completed or
        // cancelled the agent has finished the list and the pill dismisses even
        // mid-turn (no point showing "3 of 3" forever).
        let chat = bareChat()
        chat.applyRelayItems([ChatItem(
            itemID: "s1:tasks", type: .taskList, status: .completed, ord: 4,
            body: [
                "tasks": [
                    ["id": "1", "text": "Done A", "status": "completed"],
                    ["id": "2", "text": "Done B", "status": "completed"],
                ],
                "all_complete": true,
            ]
        )])
        chat.isStreaming = true
        XCTAssertNotNil(chat.latestTodoList, "precondition: list data present")
        XCTAssertFalse(chat.dockShowsTaskBox, "R13: terminal list must auto-dismiss")
    }

    func testHandleRelayTurnCompletedKeepsDataForBridgeContract() {
        // R12: the dock pill is hidden at turn end by the `dockShowsTaskBox`
        // visibility gate (isStreaming settles false), NOT by dropping the list
        // data — the bridge DATA persists so a resumed turn / the render-
        // conformance contract still observes it. `handleRelayTurnCompleted` is
        // an intentional no-op seam; the cross-turn re-seed is `turn.started`'s
        // job. Asserting the data survives here pins that contract.
        let chat = bareChat()
        chat.applyRelayItems([ChatItem(
            itemID: "s1:tasks", type: .taskList, status: .completed, ord: 4,
            body: [
                "tasks": [["id": "1", "text": "Done", "status": "completed"]],
                "all_complete": true,
            ]
        )])
        chat.isStreaming = true
        XCTAssertNotNil(chat.latestTodoList, "precondition: list data present mid-turn")
        chat.handleRelayTurnCompleted()
        XCTAssertNotNil(chat.latestTodoList,
                        "R12: turn.completed keeps the list data (visibility gate hides the pill)")
    }

    // MARK: - R13: strict session-scoping (A vs B / A6)

    func testTaskListNeverLeaksAcrossSessions_R13AvsB() {
        // A6: "taskList in session A never shows in session B". A list mirrored
        // while session A owns it must NOT surface when the active session
        // becomes B. Before the fix the dock gated on `latestTodoList != nil`
        // with no ownership check.
        let (chat, sessions) = attachedChat()
        sessions.activeRuntimeId = "sessionA"
        chat.applyRelayItems([ChatItem(
            itemID: "sA:tasks", type: .taskList, status: .inProgress, ord: 4,
            body: [
                "tasks": [["id": "1", "text": "A's task", "status": "in_progress"]],
                "all_complete": false,
            ]
        )])
        chat.isStreaming = true
        XCTAssertTrue(chat.dockShowsTaskBox, "precondition: pill visible in the owning session A")

        // Switch the active session to B WITHOUT reset() (the hard case — proves
        // the owner-identity gate, not just the reset() clear).
        sessions.activeRuntimeId = "sessionB"
        XCTAssertFalse(chat.dockShowsTaskBox,
                       "R13/A6: session A's task list must NEVER show in session B")
    }

    func testTaskListVisibleAgainWhenOwningSessionReactivates() {
        // Belt-and-braces: switching BACK to the owning session re-shows the pill
        // (the owner check is symmetric; the data was never dropped).
        let (chat, sessions) = attachedChat()
        sessions.activeRuntimeId = "sessionA"
        chat.applyRelayItems([ChatItem(
            itemID: "sA:tasks", type: .taskList, status: .inProgress, ord: 4,
            body: [
                "tasks": [["id": "1", "text": "A's task", "status": "in_progress"]],
                "all_complete": false,
            ]
        )])
        chat.isStreaming = true
        sessions.activeRuntimeId = "sessionB"
        XCTAssertFalse(chat.dockShowsTaskBox)
        sessions.activeRuntimeId = "sessionA"
        XCTAssertTrue(chat.dockShowsTaskBox, "pill re-shows in the owning session A")
    }

    func testResetClearsOwnerAndMirror() {
        // Session teardown (`reset()`) drops both mirror and owner so a next
        // session never inherits the previous session's dock box.
        let (chat, sessions) = attachedChat()
        sessions.activeRuntimeId = "sessionA"
        chat.applyRelayItems([ChatItem(
            itemID: "sA:tasks", type: .taskList, status: .inProgress, ord: 4,
            body: [
                "tasks": [["id": "1", "text": "A's task", "status": "in_progress"]],
                "all_complete": false,
            ]
        )])
        chat.isStreaming = true
        XCTAssertNotNil(chat.latestTodoList)

        chat.reset()
        XCTAssertNil(chat.latestTodoList, "reset clears the mirror")
        XCTAssertFalse(chat.dockShowsTaskBox, "reset hides the dock pill")
    }

    // MARK: - R12: stop-state wedge kill (local-turn watchdog)

    func testLocalTurnWatchdogForceSettlesStuckTurn() {
        // R12: "turn end ALWAYS clears the pill even with missed frames (timeout
        // reconcile), no force-close ever needed". A turn stuck streaming with
        // no terminal frame is force-settled by the local-turn watchdog. We
        // drive the watchdog's fire path directly via the DEBUG seam (production
        // triggers it via `Task.sleep(localTurnStaleTimeout)`).
        let chat = bareChat()
        chat.applyRelayItems([ChatItem(
            itemID: "s1:tasks", type: .taskList, status: .inProgress, ord: 4,
            body: [
                "tasks": [["id": "1", "text": "Stuck task", "status": "in_progress"]],
                "all_complete": false,
            ]
        )])
        chat.isStreaming = true
        XCTAssertTrue(chat.dockShowsTaskBox, "precondition: pill visible mid-turn")

        let fired = chat._debugFireLocalTurnWatchdog()
        XCTAssertTrue(fired, "watchdog fire path should run when streaming")
        XCTAssertFalse(chat.isStreaming, "R12: watchdog force-settles the stuck turn")
        XCTAssertFalse(chat.dockShowsTaskBox, "R12: pill clears with the stuck turn — no force-close needed")
    }

    func testLocalTurnWatchdogNoOpWhenNotStreaming() {
        let chat = bareChat()
        let fired = chat._debugFireLocalTurnWatchdog()
        XCTAssertFalse(fired, "watchdog is a no-op when no turn is live")
        XCTAssertFalse(chat.isStreaming)
    }

    // MARK: - R12: new turn re-seeds the dock clean (no stale list)

    func testRelaySendClearsStaleMirrorForFreshTurn() {
        // The relay send path + `turn.started` clear the mirror so a NEW turn
        // never re-shows the PREVIOUS turn's task list before its own `taskList`
        // arrives. We can't call `send(text:)` here (no real coordinator), but
        // the same clearing runs through `handleRelayTurnStarted` (the frame the
        // coordinator delivers at the new-turn boundary); verify the contract
        // directly by re-applying a fresh task list after the clear.
        let chat = bareChat()
        chat.applyRelayItems([ChatItem(
            itemID: "sOld:tasks", type: .taskList, status: .completed, ord: 2,
            body: ["tasks": [["id": "1", "text": "Old", "status": "completed"]], "all_complete": true]
        )])
        chat.handleRelayTurnStarted()  // new turn boundary clears the mirror
        XCTAssertNil(chat.latestTodoList, "previous turn's list cleared at the new-turn edge")

        // A new turn emits its own task list → dock re-seeds from the new data.
        chat.applyRelayItems([ChatItem(
            itemID: "sNew:tasks", type: .taskList, status: .inProgress, ord: 1,
            body: [
                "tasks": [["id": "1", "text": "New turn task", "status": "in_progress"]],
                "all_complete": false,
            ]
        )])
        chat.isStreaming = true
        XCTAssertEqual(chat.latestTodoList?.items.first?.content, "New turn task")
        XCTAssertTrue(chat.dockShowsTaskBox, "fresh turn's list re-seeds the dock")
    }

    func testHandleRelayTurnStartedClearsPriorList() {
        // R12/R13: `turn.started` is the authoritative "new turn" edge — the
        // dock must drop the previous turn's list so the pill never flashes
        // stale data when the new turn begins streaming. The relay item store
        // still holds the old `<sid>:tasks` item until the new turn emits its
        // own, so this clear is what prevents a stale re-mirror on the next
        // `applyRelayItems`.
        let chat = bareChat()
        chat.applyRelayItems([ChatItem(
            itemID: "s1:tasks", type: .taskList, status: .inProgress, ord: 4,
            body: [
                "tasks": [["id": "1", "text": "Previous turn", "status": "in_progress"]],
                "all_complete": false,
            ]
        )])
        chat.isStreaming = true
        XCTAssertTrue(chat.dockShowsTaskBox, "precondition: pill visible for prior turn")

        chat.handleRelayTurnStarted()
        XCTAssertNil(chat.latestTodoList, "turn.started clears the prior list mirror")
        XCTAssertFalse(chat.dockShowsTaskBox, "pill hidden until the new turn emits its own list")
    }

    // MARK: - Frame stamping (observability for the watchdog)

    func testApplyRelayItemsStampsFrameArrival() {
        // `lastRelayItemFrameAt` is the watchdog's liveness signal — a frame
        // batch must stamp it. (Indirect: we assert the watchdog re-arm path
        // doesn't crash on a streaming turn with frame batches.)
        let chat = bareChat()
        chat.isStreaming = true
        chat.applyRelayItems([ChatItem(
            itemID: "s1:m1", type: .agentMessage, status: .inProgress, ord: 0,
            body: ["text": .string("hi")]
        )])
        // No crash + the streaming flag survives a frame batch.
        XCTAssertTrue(chat.isStreaming)
    }
}
