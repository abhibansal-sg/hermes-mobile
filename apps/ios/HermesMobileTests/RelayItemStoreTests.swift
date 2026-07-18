import XCTest
@testable import HermesMobile

/// Wave-2 relay client — item-store reducer coverage (RELAY-PHONE-PROTOCOL
/// §2/§4). Pins the reduction contract that the reliability spine depends on:
/// `completed` is authoritative, deltas accumulate, re-application is idempotent,
/// and a `snapshot` reconciles by `item_id` gap-free. Deterministic; no I/O.
final class RelayItemStoreTests: XCTestCase {

    // MARK: - Frame builders

    private func started(_ id: String, _ type: ChatItemType, ord: Int, seq: Int,
                         body: JSONValue = .null) -> RelayFrame {
        frame(seq: seq, kind: "item.started",
              body: itemBody(id, type, status: "in_progress", ord: ord, body: body))
    }

    private func delta(_ id: String, seq: Int, patch: JSONValue) -> RelayFrame {
        frame(seq: seq, kind: "item.delta",
              body: .object(["item_id": .string(id), "patch": patch]))
    }

    private func completed(_ id: String, _ type: ChatItemType, ord: Int, seq: Int,
                           status: String = "completed", body: JSONValue = .null) -> RelayFrame {
        frame(seq: seq, kind: "item.completed",
              body: itemBody(id, type, status: status, ord: ord, body: body))
    }

    private func itemBody(_ id: String, _ type: ChatItemType, status: String, ord: Int,
                          body: JSONValue) -> JSONValue {
        .object([
            "item_id": .string(id),
            "type": .string(type.rawValue),
            "status": .string(status),
            "ord": .number(Double(ord)),
            "body": body,
        ])
    }

    private func frame(seq: Int, kind: String, body: JSONValue) -> RelayFrame {
        RelayFrame(seq: seq, sid: "s", turn: "t", kind: RelayFrameKind(wire: kind), body: body)
    }

    // MARK: - Lifecycle: started → delta* → completed

    func testDeltasAccumulateThenCompletedIsAuthoritative() {
        var store = RelayItemStore()
        store.apply(started("msg-1", .agentMessage, ord: 2, seq: 1, body: ["text": ""]))
        store.apply(delta("msg-1", seq: 2, patch: ["text": "On it — "]))
        store.apply(delta("msg-1", seq: 3, patch: ["text": "here is the plan."]))

        // Optimistic streaming state accumulates the deltas.
        XCTAssertEqual(store.itemsByID["msg-1"]?.textBody, "On it — here is the plan.")
        XCTAssertEqual(store.itemsByID["msg-1"]?.status, .inProgress)

        // completed replaces whatever accumulated — authoritative.
        store.apply(completed("msg-1", .agentMessage, ord: 2, seq: 4,
                              body: ["text": "Final answer."]))
        XCTAssertEqual(store.itemsByID["msg-1"]?.textBody, "Final answer.")
        XCTAssertEqual(store.itemsByID["msg-1"]?.status, .completed)
        XCTAssertEqual(store.lastSeq, 4)
    }

    func testDeltaAfterCompletedIsIgnored() {
        var store = RelayItemStore()
        store.apply(completed("msg-1", .agentMessage, ord: 0, seq: 1, body: ["text": "done"]))
        // A late delta (e.g. reordered on the wire) must not mutate an authoritative item.
        store.apply(delta("msg-1", seq: 2, patch: ["text": " and more"]))
        XCTAssertEqual(store.itemsByID["msg-1"]?.textBody, "done")
    }

    func testDeltaBeforeStartedMaterializesPlaceholder() {
        var store = RelayItemStore()
        // Dropped `started`: the delta still streams via a generic in-progress item…
        store.apply(delta("msg-1", seq: 5, patch: ["text": "partial"]))
        XCTAssertEqual(store.itemsByID["msg-1"]?.textBody, "partial")
        XCTAssertEqual(store.itemsByID["msg-1"]?.status, .inProgress)
        // …and a later completed heals it to the authoritative shape.
        store.apply(completed("msg-1", .agentMessage, ord: 1, seq: 6, body: ["text": "healed"]))
        XCTAssertEqual(store.itemsByID["msg-1"]?.type, .agentMessage)
        XCTAssertEqual(store.itemsByID["msg-1"]?.textBody, "healed")
    }

    func testLateStartedDoesNotClobberAccumulatedItem() {
        var store = RelayItemStore()
        store.apply(started("msg-1", .agentMessage, ord: 0, seq: 1, body: ["text": ""]))
        store.apply(delta("msg-1", seq: 2, patch: ["text": "streamed"]))
        // A duplicate/late started must not reset the accumulated body.
        store.apply(started("msg-1", .agentMessage, ord: 0, seq: 1, body: ["text": ""]))
        XCTAssertEqual(store.itemsByID["msg-1"]?.textBody, "streamed")
    }

    // MARK: - Ordering

    func testItemsRenderInOrdOrderRegardlessOfArrival() {
        var store = RelayItemStore()
        // Arrive out of ord order.
        store.apply(completed("b", .agentMessage, ord: 5, seq: 1))
        store.apply(completed("a", .userMessage, ord: 0, seq: 2))
        store.apply(completed("c", .usage, ord: 9, seq: 3))
        XCTAssertEqual(store.items.map(\.itemID), ["a", "b", "c"])
    }

    // MARK: - Seq admission (§4)

    func testSeqAdmissionClassification() {
        var store = RelayItemStore()
        XCTAssertEqual(store.classify(seq: 1), .inOrder)
        store.apply(completed("a", .agentMessage, ord: 0, seq: 1))
        XCTAssertEqual(store.classify(seq: 1), .duplicate)
        XCTAssertEqual(store.classify(seq: 2), .inOrder)
        XCTAssertEqual(store.classify(seq: 5), .gap(missing: 2..<5))
    }

    func testDuplicateSeqReapplyIsIdempotent() {
        var store = RelayItemStore()
        let frame = completed("a", .agentMessage, ord: 0, seq: 3, body: ["text": "x"])
        store.apply(frame)
        let afterFirst = store
        // Re-applying the exact frame (a replayed duplicate) converges to the same state.
        store.apply(frame)
        XCTAssertEqual(store, afterFirst)
        XCTAssertEqual(store.lastSeq, 3)
    }

    // MARK: - Snapshot reconciliation (§4)

    func testSnapshotReconcilesByItemIDAndRetainsOthers() {
        var store = RelayItemStore()
        store.apply(completed("keep", .agentMessage, ord: 0, seq: 1, body: ["text": "kept"]))
        store.apply(completed("stale", .agentMessage, ord: 1, seq: 2, body: ["text": "old"]))

        let snapshotBody: JSONValue = .object([
            "cursor": .number(10),
            "items": .array([
                itemBody("stale", .agentMessage, status: "completed", ord: 1, body: ["text": "new"]),
                itemBody("fresh", .toolCall, status: "completed", ord: 2, body: ["name": "grep"]),
            ]),
        ])
        store.apply(frame(seq: 11, kind: "snapshot", body: snapshotBody))

        // Snapshot item replaces the stale copy; new item added; untouched item kept.
        XCTAssertEqual(store.itemsByID["stale"]?.textBody, "new")
        XCTAssertEqual(store.itemsByID["fresh"]?.toolName, "grep")
        XCTAssertEqual(store.itemsByID["keep"]?.textBody, "kept")
        // Cursor advances the watermark past the raw seqs.
        XCTAssertEqual(store.lastSeq, 11)
    }

    // MARK: - Gap-free reconciliation (§4) — the reliability guarantee

    /// The core invariant: a store that MISSED a run of frames and then reconciled
    /// a `snapshot` converges to the SAME state as a store that saw every frame.
    func testDropThenSnapshotConvergesToNoDropState() {
        let full = fullTurnFrames()

        // Reference: apply every frame, no drop.
        var reference = RelayItemStore()
        reference.apply(full)

        // Lossy: apply only frames 1–2, miss 3–5, then reconcile a snapshot that
        // carries the authoritative state of every item.
        var lossy = RelayItemStore()
        lossy.apply(full.prefix(2))
        XCTAssertNil(lossy.itemsByID["tool-1"], "precondition: dropped frames not yet seen")
        lossy.apply(snapshotFrame(seq: 99, from: full))

        XCTAssertEqual(lossy.items.map(\.itemID), reference.items.map(\.itemID),
                       "reconciled item set must match the no-drop set (gap-free)")
        for id in reference.itemsByID.keys {
            XCTAssertEqual(lossy.itemsByID[id]?.textBody, reference.itemsByID[id]?.textBody,
                           "item \(id) must reconcile to authoritative body")
            XCTAssertEqual(lossy.itemsByID[id]?.status, reference.itemsByID[id]?.status)
        }
    }

    /// Within-ring replay path: replaying the missed frames themselves (not a
    /// snapshot) is also idempotent and gap-free — applying the full sequence
    /// after a partial prefix equals applying it once.
    func testReplayOfMissedFramesIsIdempotent() {
        let full = fullTurnFrames()
        var reference = RelayItemStore()
        reference.apply(full)

        var replayed = RelayItemStore()
        replayed.apply(full.prefix(2))          // saw 1–2
        replayed.apply(full)                    // relay replays 1..head; 1–2 are duplicates
        XCTAssertEqual(replayed, reference)
    }

    // MARK: - Fixtures

    private func fullTurnFrames() -> [RelayFrame] {
        [
            completed("user-1", .userMessage, ord: 0, seq: 1, body: ["text": "Refactor"]),
            started("msg-1", .agentMessage, ord: 1, seq: 2, body: ["text": ""]),
            delta("msg-1", seq: 3, patch: ["text": "Working…"]),
            completed("tool-1", .toolCall, ord: 2, seq: 4, body: ["name": "read_file"]),
            completed("msg-1", .agentMessage, ord: 1, seq: 5, body: ["text": "Done."]),
        ]
    }

    /// Build a `snapshot` frame carrying the authoritative final state of every
    /// completed item in `frames` (what the relay would send on a too-big gap).
    private func snapshotFrame(seq: Int, from frames: [RelayFrame]) -> RelayFrame {
        let items: [JSONValue] = [
            itemBody("user-1", .userMessage, status: "completed", ord: 0, body: ["text": "Refactor"]),
            itemBody("msg-1", .agentMessage, status: "completed", ord: 1, body: ["text": "Done."]),
            itemBody("tool-1", .toolCall, status: "completed", ord: 2, body: ["name": "read_file"]),
        ]
        return frame(seq: seq, kind: "snapshot",
                     body: .object(["cursor": .number(Double(seq - 1)), "items": .array(items)]))
    }
}
