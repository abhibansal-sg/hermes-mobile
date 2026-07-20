import XCTest
@testable import HermesMobile

/// Wave-2 N4 / A5 coverage: iOS decodes the relay `taskList` item NATIVELY
/// (not as a generic `.toolCall` fallback) and bridges it into the SAME
/// `ChatStore.latestTodoList` accessor the Turn Dock's task box reads, so the
/// dock works identically on the relay and direct paths.
///
/// Deterministic; no I/O. Frame builders mirror the wire shape the relay's
/// `reframer._tasks_body` emits (`{ tasks:[{id,text,status}], counts,
/// all_complete }`, RELAY-PHONE-PROTOCOL §2 "taskList semantics") — a body the
/// DIRECT path's `TodoList(todosArray:)` initializer must ALSO parse, because
/// the gateway's `{id,content,status}` and the relay's `{id,text,status}` are
/// the same data with a renamed field.
@MainActor
final class RelayTaskListBridgeTests: XCTestCase {

    // MARK: - Frame builders (mirror the relay's reframer._tasks_body shape)

    private func taskListCompletedFrame(seq: Int, itemID: String, ord: Int,
                                        status: String = "completed",
                                        tasks: [(id: String, text: String, status: String)],
                                        allComplete: Bool) -> RelayFrame {
        let taskArray: [JSONValue] = tasks.map { task in
            .object([
                "id": .string(task.id),
                "text": .string(task.text),
                "status": .string(task.status),
            ])
        }
        let body: JSONValue = .object([
            "item_id": .string(itemID),
            "type": .string(ChatItemType.taskList.rawValue),
            "status": .string(status),
            "ord": .number(Double(ord)),
            "body": .object([
                "tasks": .array(taskArray),
                "counts": .object([
                    "total": .number(Double(taskArray.count)),
                ]),
                "all_complete": .bool(allComplete),
            ]),
        ])
        return RelayFrame(seq: seq, sid: "s", turn: "t",
                          kind: RelayFrameKind(wire: "item.completed"), body: body)
    }

    /// `item.delta` carrying a full-list REPLACE patch (RELAY-PHONE-PROTOCOL §3
    /// — "For a taskList item the patch is a full-list REPLACE").
    private func taskListDeltaFrame(seq: Int, itemID: String,
                                    tasks: [(id: String, text: String, status: String)]) -> RelayFrame {
        let taskArray: [JSONValue] = tasks.map { task in
            .object([
                "id": .string(task.id),
                "text": .string(task.text),
                "status": .string(task.status),
            ])
        }
        let patch: JSONValue = .object([
            "tasks": .array(taskArray),
            "counts": .object(["total": .number(Double(taskArray.count))]),
            "all_complete": .bool(false),
        ])
        return RelayFrame(seq: seq, sid: "s", turn: "t",
                          kind: RelayFrameKind(wire: "item.delta"),
                          body: .object(["item_id": .string(itemID), "patch": patch]))
    }

    // MARK: - Native decode (A5: "iOS decodes type taskList natively, not generic")

    func testTaskListWireTypeDecodesNativelyNotGenericFallback() throws {
        // A `taskList` wire frame must decode as `.taskList`, NOT fold to the
        // generic `.toolCall`. (Pre-N4 it WAS `.toolCall`, so the dock accessor
        // never saw it.)
        let frame = taskListCompletedFrame(
            seq: 1, itemID: "s1:tasks", ord: 4,
            tasks: [("1", "Read auth.py", "completed"),
                    ("2", "Run migration 35", "in_progress"),
                    ("3", "Open a PR", "pending")],
            allComplete: false
        )
        let item = try XCTUnwrap(frame.item, "item.completed must project a ChatItem")
        XCTAssertEqual(item.type, .taskList, "taskList wire type must decode to .taskList natively")
        XCTAssertEqual(item.rawType, "taskList")
        XCTAssertEqual(item.itemID, "s1:tasks")
    }

    func testUnknownWireTypeStillFoldsToGenericToolCall() throws {
        // Forward-compat (§2): an unrecognized `type` STILL falls back to
        // `.toolCall`. Adding `.taskList` did not narrow this guarantee.
        let json = """
        { "seq": 9, "sid": "s", "turn": "t", "kind": "item.completed",
          "body": { "item_id": "x-1", "type": "future_flux_capacitor",
                    "status": "completed", "ord": 0,
                    "body": { "name": "future_flux_capacitor" } } }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let frame = try JSONDecoder().decode(RelayFrame.self, from: data)
        let item = try XCTUnwrap(frame.item)
        XCTAssertEqual(item.type, .toolCall, "unknown type must still fold to generic toolCall")
        XCTAssertEqual(item.rawType, "future_flux_capacitor", "raw wire type preserved")
        XCTAssertEqual(item.toolName, "future_flux_capacitor")
    }

    // MARK: - taskListBody parse (relay {id,text,status} shape)

    func testTaskListBodyParsesRelayShape() throws {
        let frame = taskListCompletedFrame(
            seq: 1, itemID: "s1:tasks", ord: 4,
            tasks: [("1", "Read auth.py", "completed"),
                    ("2", "Run migration 35", "in_progress"),
                    ("3", "Open a PR", "pending")],
            allComplete: false
        )
        let item = try XCTUnwrap(frame.item)
        let list = try XCTUnwrap(item.taskListBody, "taskList body must parse into a TodoList")
        XCTAssertEqual(list.items.count, 3)
        XCTAssertEqual(list.items[0].content, "Read auth.py")
        XCTAssertEqual(list.items[0].status, .completed)
        XCTAssertEqual(list.items[1].content, "Run migration 35")
        XCTAssertEqual(list.items[1].status, .inProgress)
        XCTAssertEqual(list.items[2].status, .pending)
    }

    func testTaskListBodyNilForNonTaskList() {
        // A non-`.taskList` item must NOT yield a taskListBody even if its body
        // happens to carry a `tasks` key — the accessor is type-gated.
        let nonTask = ChatItem(itemID: "x", type: .toolCall, status: .completed, ord: 0,
                               body: ["tasks": [["id": "1", "text": "nope", "status": "pending"]]])
        XCTAssertNil(nonTask.taskListBody)
    }

    func testTaskListBodyNilForEmptyList() {
        // An empty `tasks` array yields no parseable list (mirrors the legacy
        // scan's skip-empty semantics — keeps the prior list rather than
        // blanking the dock on a mid-stream skeleton).
        let empty = ChatItem(itemID: "x", type: .taskList, status: .inProgress, ord: 0,
                             body: ["tasks": .array([])])
        XCTAssertNil(empty.taskListBody)
    }

    // MARK: - RelayItemStore fold (N4: "RelayItemStore consume it")

    func testRelayItemStoreFoldsTaskListDeltaAsFullListReplace() {
        // §3: a taskList `item.delta` patch is a full-list REPLACE, not an
        // append. mergePatch overwrites every key except `text`, so `tasks`
        // replaces wholesale — the dock mirror must reflect the latest patch.
        var store = RelayItemStore()
        let started = RelayFrame(
            seq: 1, sid: "s", turn: "t", kind: RelayFrameKind(wire: "item.started"),
            body: .object([
                "item_id": .string("s1:tasks"),
                "type": .string(ChatItemType.taskList.rawValue),
                "status": .string("in_progress"),
                "ord": .number(4),
                "body": .object([
                    "tasks": .array([
                        ["id": "1", "text": "First", "status": "pending"],
                    ]),
                    "all_complete": false,
                ]),
            ])
        )
        store.apply(started)
        store.apply(taskListDeltaFrame(seq: 2, itemID: "s1:tasks", tasks: [
            ("1", "First", "completed"),
            ("2", "Second", "in_progress"),
        ]))

        let folded = store.itemsByID["s1:tasks"]
        XCTAssertEqual(folded?.type, .taskList)
        XCTAssertEqual(folded?.taskListBody?.items.count, 2,
                       "delta patch replaces tasks wholesale (not append)")
        XCTAssertEqual(folded?.taskListBody?.items[0].status, .completed)
        XCTAssertEqual(folded?.taskListBody?.items[1].content, "Second")
    }

    // MARK: - ChatStore bridge (N4: "dock works identically on relay + direct")

    func testRelayTaskListFramePopulatesDockAccessor() {
        // THE core N4 contract: a taskList frame folded into the relay item
        // store, then synced into ChatStore, populates the SAME accessor the
        // Turn Dock's task box reads (`chatStore.latestTodoList`). Before the
        // bridge, the relay path produced NO dock task box at all.
        var relayStore = RelayItemStore()
        relayStore.apply(taskListCompletedFrame(
            seq: 1, itemID: "s1:tasks", ord: 4,
            tasks: [("1", "Read auth.py", "completed"),
                    ("2", "Run migration 35", "in_progress")],
            allComplete: false
        ))

        let chat = ChatStore()
        XCTAssertNil(chat.latestTodoList, "baseline: no todo list before sync")
        chat.syncRelayTaskList(from: relayStore)

        XCTAssertEqual(chat.latestTodoToolID, "s1:tasks", "dock accessor keys on the relay item id")
        let list = chat.latestTodoList
        XCTAssertEqual(list?.items.count, 2)
        XCTAssertEqual(list?.items[0].content, "Read auth.py")
        XCTAssertEqual(list?.items[0].status, .completed)
        XCTAssertEqual(list?.items[1].content, "Run migration 35")
        XCTAssertEqual(list?.items[1].status, .inProgress)
    }

    func testRelaySnapshotClearsDockAccessorWhenNoTaskListRemains() {
        // Snapshot reconciliation: if a `resync` snapshot drops the taskList
        // (session has no todo activity), the dock mirror must CLEAR — not
        // strand a stale list.
        var relayStore = RelayItemStore()
        relayStore.apply(taskListCompletedFrame(
            seq: 1, itemID: "s1:tasks", ord: 4,
            tasks: [("1", "Old", "completed")], allComplete: true
        ))

        let chat = ChatStore()
        chat.syncRelayTaskList(from: relayStore)
        XCTAssertNotNil(chat.latestTodoList, "precondition: mirror populated")

        // A fresh store with no taskList (e.g. a new session's snapshot).
        let emptyStore = RelayItemStore()
        chat.syncRelayTaskList(from: emptyStore)
        XCTAssertNil(chat.latestTodoList, "dock mirror must clear when no taskList remains")
        XCTAssertNil(chat.latestTodoToolID)
    }

    func testRelayMirrorPreferredOverEmptyDirectScan() {
        // When the relay mirror is populated, the accessor returns it EVEN IF
        // the direct-path `messages` scan is empty (the relay path is
        // authoritative when active). The two paths never corrupt each other.
        var relayStore = RelayItemStore()
        relayStore.apply(taskListCompletedFrame(
            seq: 1, itemID: "s1:tasks", ord: 0,
            tasks: [("1", "Only in relay", "in_progress")], allComplete: false
        ))

        let chat = ChatStore()
        chat.messages = []  // no direct-path todo activity
        chat.syncRelayTaskList(from: relayStore)
        XCTAssertEqual(chat.latestTodoList?.items.first?.content, "Only in relay")
    }

    func testRelayItemDecodesFromJSONStringRoundTrip() throws {
        // End-to-end wire JSON → ChatItem, mirroring the canonical decode test
        // for the other item kinds. Pins the body shape the relay emits.
        let json = """
        { "seq": 5, "sid": "3d62926c", "turn": "turn-1", "kind": "item.completed",
          "body": { "item_id": "3d62926c:tasks", "type": "taskList", "status": "in_progress",
                    "ord": 4, "summary": "Tasks 1/2",
                    "body": { "tasks": [{"id":"1","text":"A","status":"completed"},
                                        {"id":"2","text":"B","status":"in_progress"}],
                              "counts": {"total": 2, "completed": 1, "in_progress": 1},
                              "all_complete": false } } }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let frame = try JSONDecoder().decode(RelayFrame.self, from: data)
        let item = try XCTUnwrap(frame.item)
        XCTAssertEqual(item.type, .taskList)
        XCTAssertEqual(item.summary, "Tasks 1/2")
        XCTAssertEqual(item.taskListBody?.items.count, 2)
        XCTAssertEqual(item.taskListBody?.items[1].status, .inProgress)
    }

    // MARK: - Direct-path parity (TodoList initializer tolerates both field names)

    func testDirectPathContentFieldStillParses() {
        // The TodoList(todosArray:) initializer was extended to read EITHER
        // `content` (gateway/direct) OR `text` (relay). The direct path's
        // existing shape must still parse — regression guard for the legacy
        // TurnDockTests-style fixture.
        let gatewayShape: [JSONValue] = [
            ["id": "1", "content": "Gateway task", "status": "pending"],
        ]
        let list = TodoList(todosArray: gatewayShape)
        XCTAssertEqual(list?.items.first?.content, "Gateway task")
    }

    func testMixedShapeEntriesParseViaEitherField() {
        // Tolerant parse: an entry with `content` and an entry with `text` both
        // yield a TodoItem. (Defensive — the relay and gateway don't mix in
        // practice, but the parser shouldn't drop an entry over a field name.)
        let mixed: [JSONValue] = [
            ["id": "1", "content": "from content", "status": "completed"],
            ["id": "2", "text": "from text", "status": "in_progress"],
        ]
        let list = TodoList(todosArray: mixed)
        XCTAssertEqual(list?.items.count, 2)
        XCTAssertEqual(list?.items[0].content, "from content")
        XCTAssertEqual(list?.items[1].content, "from text")
    }
}
