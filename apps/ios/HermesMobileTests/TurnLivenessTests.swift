import XCTest
@testable import HermesMobile

/// QA-3 S8/A4 — the per-turn LIVENESS fallback: no frames + no completion
/// within a window means SILENT resync (snapshot from relay/cache), and
/// eternal double-working is impossible.
///
/// The round-3 failure (IMG_2591, the "??" Aheli session): turn 1's items
/// stuck `.inProgress` rendered "Working… · ToolCall 5s" FOREVER while turn 2
/// streamed — the QA-2 R12 watchdog was per-STORE and re-armed by ANY item
/// batch (turn 2's frames kept it alive), and even when it fired, the next
/// projection re-derived streaming from the still-`.inProgress` items. Two
/// mechanisms now make eternal-working unreachable BY CONSTRUCTION:
///
///  1. PRIOR-TURN SETTLE (deterministic, every projection): a still-inProgress
///     item BEFORE the last `userMessage` item belongs to a turn a newer turn
///     superseded — it folds as a muted "Interrupted" row (never an error
///     banner — C3). The moment turn 2's `userMessage` lands, turn 1 heals.
///  2. TWO-STAGE WATCHDOG (per-turn silence clock, refreshed ONLY by current-
///     turn frames): stage 1 at 45 s of silence — one silent `resync{last_seq}`
///     (self-heals a dropped terminal frame); stage 2 at 480 s — the dead
///     turn's stuck items are locally settled (Interrupted) and the live flag
///     clears. The settle is PROVISIONAL: a late frame against a locally-settled
///     item RESURRECTS it (replace-not-drop — fix-round 1), so a false-positive
///     settle on a healthy-but-frame-silent slow turn (one long opaque tool) is
///     lossless.
///
/// Tests drive frames through the REAL render lane (RelayClient pump →
/// coordinator ingest → ChatStore projection) over the in-process fake relay;
/// the DEBUG seams fire the watchdog stages synchronously (production triggers
/// them via the tick loop's sleeps — never in tests). On the unfixed
/// `qa3/base` the shipped-bug tests FAIL (the stuck turn stays streaming).
@MainActor
final class TurnLivenessTests: XCTestCase {

    private typealias MockRelayTransport = RelaySessionCoordinatorTests.MockRelayTransport

    private let relayURL = URL(string: "ws://127.0.0.1:9999/relay")!
    private let sessionID = "liveness-sess"

    /// Minimal stored-session summary (mirrors ContractReconcileW2dTests) so
    /// the tests drive `SessionStore.open` exactly like a drawer tap.
    private func summary(_ id: String) -> SessionSummary {
        SessionSummary(id: id, title: "Session \(id)", preview: nil, startedAt: nil,
                       messageCount: nil, source: nil, lastActive: nil, cwd: nil)
    }

    private struct Graph {
        let chat: ChatStore
        let sessions: SessionStore
        let connection: ConnectionStore
        let transport: MockRelayTransport
        let coordinator: RelaySessionCoordinator
    }

    private func makeGraph() async throws -> Graph {
        UserDefaults.standard.set(TransportPath.relay.rawValue, forKey: DefaultsKeys.transportPath)
        let transport = MockRelayTransport(script: { upstream, relay in
            guard let id = upstream.id else { return }
            if upstream.method == "submit" {
                let sid = (upstream.params["session_id"] as? String) ?? "liveness-new-1"
                relay.deliverResult(id: id, result: .object(["session_id": .string(sid)]))
            } else {
                relay.deliverResult(id: id, result: .object(["ok": .bool(true)]))
            }
        })
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        chat.attach(connection: connection, sessions: sessions, attachments: AttachmentStore())
        connection.relayCoordinatorFactory = {
            RelaySessionCoordinator(chatStore: chat, clientFactory: { RelayClient { _ in transport } })
        }
        let coordinator = connection.ensureRelayCoordinator()
        let edgesBefore = coordinator.readinessEdgeCount
        try await coordinator.start(url: relayURL)
        await waitUntil { coordinator.readinessEdgeCount > edgesBefore }
        return Graph(chat: chat, sessions: sessions, connection: connection,
                     transport: transport, coordinator: coordinator)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.transportPath)
        super.tearDown()
    }

    // MARK: - Frame delivery

    private var seq = 0

    private func envelope(_ kind: String, _ body: [String: Any], turn: String? = nil) -> String {
        seq += 1
        var frame: [String: Any] = ["seq": seq, "sid": sessionID, "kind": kind, "body": body]
        if let turn { frame["turn"] = turn }
        let data = (try? JSONSerialization.data(withJSONObject: frame)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func itemBody(_ id: String, _ type: String, _ status: String, _ ord: Int,
                          _ body: [String: Any] = [:]) -> [String: Any] {
        ["item_id": id, "type": type, "status": status, "ord": ord, "summary": "", "body": body]
    }

    /// Deliver turn 1's stuck state: userMessage → turn.started → an
    /// inProgress toolCall that NEVER completes (the dead turn).
    private func deliverStuckTurn1(_ g: Graph, prompt: String = "turn one prompt") {
        g.transport.deliver(envelope("item.completed",
            itemBody("\(sessionID):u1", "userMessage", "completed", 0,
                     ["text": prompt]), turn: nil))
        g.transport.deliver(envelope("turn.started", [:], turn: "\(sessionID):t1"))
        g.transport.deliver(envelope("item.started",
            itemBody("\(sessionID):a1", "toolCall", "in_progress", 1,
                     ["name": "shell"]), turn: "\(sessionID):t1"))
    }

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("waitUntil timed out")
    }

    private func assistantRows(_ chat: ChatStore) -> [ChatMessage] {
        chat.messages.filter { $0.role == .assistant && $0.relayProjected }
    }

    // MARK: - Prior-turn settle (IMG_2591: eternal double-working, killed)

    /// The round-3 set piece: turn 1 stuck `.inProgress` + turn 2 streaming.
    /// The moment turn 2's `userMessage` lands, turn 1's stuck row settles to
    /// a muted "Interrupted" (non-streaming) — exactly ONE live working
    /// surface remains. FAILS on qa3/base (turn 1 keeps `isStreaming` forever).
    func testStuckPriorTurnSettlesTheMomentNextTurnStarts() async throws {
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        // Production-faithful drive (r4 integration): open VIA SESSIONSTORE so
        // the send's target pin (I5: the selected stored id) matches the
        // session the frames name. A coordinator-level open alone leaves
        // SessionStore.activeStoredId nil, turning the send into a true-draft
        // nil-pin submit whose create-adoption (I6) moves the write-gate to
        // the minted id — correct in production, where open() always sets the
        // stored id before any send can happen.
        g.sessions.open(summary(sessionID))
        await g.sessions.waitForPendingOpenForTesting()
        _ = await g.chat.send(text: "turn one prompt")

        deliverStuckTurn1(g)
        // Fix-round 1: gate on the REAL precondition — the stuck item has
        // actually landed in the render store. The streaming-ROW wait was
        // satisfied PREMATURELY by send's optimistic caret row (tagged,
        // parts=0, streaming) before the pump ingested the frames, so the
        // stage-2 DEBUG settle below raced frame ingestion and flipped
        // nothing. The caret is not the turn's items.
        await waitUntil {
            g.coordinator.store.items.contains {
                $0.itemID == "\(self.sessionID):a1" && $0.status == .inProgress
            }
        }
        XCTAssertTrue(g.chat.isStreaming, "turn 1 live while its tool runs")

        // Turn 2 arrives (the owner's "??"): its userMessage bounds the new
        // current turn — turn 1's stuck item is now a PRIOR turn's.
        g.transport.deliver(envelope("item.completed",
            itemBody("\(sessionID):u2", "userMessage", "completed", 2,
                     ["text": "??"]), turn: nil))
        g.transport.deliver(envelope("turn.started", [:], turn: "\(sessionID):t2"))
        g.transport.deliver(envelope("item.started",
            itemBody("\(sessionID):a2", "toolCall", "in_progress", 3,
                     ["name": "shell"]), turn: "\(sessionID):t2"))

        await waitUntil {
            let rows = self.assistantRows(g.chat)
            return rows.contains { $0.interrupted } && rows.contains { $0.isStreaming }
        }
        let rows = assistantRows(g.chat)
        let turn1 = rows.first
        let turn2 = rows.last
        XCTAssertEqual(rows.count, 2)
        XCTAssertNotNil(turn1)
        XCTAssertNotNil(turn2)
        XCTAssertFalse(turn1!.isStreaming, "A4: the dead prior turn stops 'working' the instant the next turn starts")
        XCTAssertTrue(turn1!.interrupted, "A4: it folds as a muted Interrupted row (C3: never an error)")
        XCTAssertTrue(turn2!.isStreaming, "A4: the live turn is unaffected")
        XCTAssertFalse(turn2!.interrupted)
        XCTAssertTrue(g.chat.isStreaming, "the store is still streaming (turn 2)")
        XCTAssertEqual(rows.filter { $0.isStreaming }.count, 1,
                       "A4: exactly ONE live working surface — never a double-working")
        XCTAssertNil(g.chat.lastError, "C3: the settle is silent — no error surface")
    }

    /// A prior turn whose items ALL completed renders the honest "Worked"
    /// fold — the interrupted marker is reserved for force-settled turns.
    func testCompletedPriorTurnIsNotInterrupted() async throws {
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        // Production-faithful drive (r4 integration): open VIA SESSIONSTORE so
        // the send's target pin (I5: the selected stored id) matches the
        // session the frames name. A coordinator-level open alone leaves
        // SessionStore.activeStoredId nil, turning the send into a true-draft
        // nil-pin submit whose create-adoption (I6) moves the write-gate to
        // the minted id — correct in production, where open() always sets the
        // stored id before any send can happen.
        g.sessions.open(summary(sessionID))
        await g.sessions.waitForPendingOpenForTesting()

        g.transport.deliver(envelope("item.completed",
            itemBody("\(sessionID):u1", "userMessage", "completed", 0, ["text": "one"])))
        g.transport.deliver(envelope("item.started",
            itemBody("\(sessionID):a1", "toolCall", "in_progress", 1, ["name": "shell"]),
            turn: "\(sessionID):t1"))
        g.transport.deliver(envelope("item.completed",
            itemBody("\(sessionID):a1", "toolCall", "completed", 1, ["name": "shell"]),
            turn: "\(sessionID):t1"))
        g.transport.deliver(envelope("turn.completed", [:], turn: "\(sessionID):t1"))
        g.transport.deliver(envelope("item.completed",
            itemBody("\(sessionID):u2", "userMessage", "completed", 2, ["text": "two"])))
        g.transport.deliver(envelope("item.started",
            itemBody("\(sessionID):a2", "toolCall", "in_progress", 3, ["name": "shell"]),
            turn: "\(sessionID):t2"))

        await waitUntil { self.assistantRows(g.chat).count >= 2 }
        let rows = assistantRows(g.chat)
        XCTAssertFalse(rows[0].interrupted, "a normally-completed prior turn is Worked, not Interrupted")
        XCTAssertFalse(rows[0].isStreaming)
        XCTAssertTrue(rows[1].isStreaming)
    }

    // MARK: - Stage 1: silent resync (self-heals a dropped terminal frame)

    /// A dead turn with no completion: stage 1 requests a `resync{last_seq}`
    /// — SILENT (no lastError), at most once — and if the relay replays the
    /// dropped terminal frames, the turn settles NATURALLY. FAILS on
    /// qa3/base (no silence-driven resync exists anywhere).
    func testSilentResyncRecoversDroppedCompletion() async throws {
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        // Production-faithful drive (r4 integration): open VIA SESSIONSTORE so
        // the send's target pin (I5: the selected stored id) matches the
        // session the frames name. A coordinator-level open alone leaves
        // SessionStore.activeStoredId nil, turning the send into a true-draft
        // nil-pin submit whose create-adoption (I6) moves the write-gate to
        // the minted id — correct in production, where open() always sets the
        // stored id before any send can happen.
        g.sessions.open(summary(sessionID))
        await g.sessions.waitForPendingOpenForTesting()
        _ = await g.chat.send(text: "turn one prompt")

        deliverStuckTurn1(g)
        // Fix-round 1: gate on the REAL precondition — the stuck item has
        // actually landed in the render store. The streaming-ROW wait was
        // satisfied PREMATURELY by send's optimistic caret row (tagged,
        // parts=0, streaming) before the pump ingested the frames, so the
        // stage-2 DEBUG settle below raced frame ingestion and flipped
        // nothing. The caret is not the turn's items.
        await waitUntil {
            g.coordinator.store.items.contains {
                $0.itemID == "\(self.sessionID):a1" && $0.status == .inProgress
            }
        }

        // Stage 1 (production: 45 s of silence; synchronous via the DEBUG seam).
        let fired = g.chat._debugFireTurnLivenessResync()
        XCTAssertTrue(fired)
        XCTAssertEqual(g.chat.turnLivenessResyncCount, 1)
        XCTAssertNil(g.chat.lastError, "C3: the resync is silent — never surfaced")
        XCTAssertTrue(g.chat.isStreaming, "stage 1 alone does not settle")
        // The relay saw a resync{last_seq} upstream.
        await waitUntil { g.transport.upstreams().contains { $0.method == "resync" } }
        XCTAssertTrue(g.transport.upstreams().contains { $0.method == "resync" })

        // The resync replayed the dropped completion → natural settle.
        g.transport.deliver(envelope("item.completed",
            itemBody("\(sessionID):a1", "toolCall", "completed", 1, ["name": "shell"]),
            turn: "\(sessionID):t1"))
        g.transport.deliver(envelope("turn.completed", [:], turn: "\(sessionID):t1"))
        await waitUntil { !g.chat.isStreaming }
        XCTAssertFalse(g.chat.isStreaming)
        let row = try XCTUnwrap(assistantRows(g.chat).first)
        XCTAssertFalse(row.interrupted, "the resync HEALED the turn — it settles as Worked, not Interrupted")
    }

    // MARK: - Stage 2: the dead turn is settled as Interrupted

    /// The authority has nothing more (the resync recovered nothing): stage 2
    /// settles the stuck items locally — muted Interrupted fold, live flag
    /// cleared, SILENT (C3). Eternal-working unreachable. FAILS on qa3/base
    /// (the QA-2 force-settle cleared the store flag, but the next projection
    /// re-derived streaming from the still-inProgress items → eternal working).
    func testDeadTurnForceSettlesAsInterruptedAndSilent() async throws {
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        // Production-faithful drive (r4 integration): open VIA SESSIONSTORE so
        // the send's target pin (I5: the selected stored id) matches the
        // session the frames name. A coordinator-level open alone leaves
        // SessionStore.activeStoredId nil, turning the send into a true-draft
        // nil-pin submit whose create-adoption (I6) moves the write-gate to
        // the minted id — correct in production, where open() always sets the
        // stored id before any send can happen.
        g.sessions.open(summary(sessionID))
        await g.sessions.waitForPendingOpenForTesting()
        _ = await g.chat.send(text: "turn one prompt")

        deliverStuckTurn1(g)
        // Fix-round 1: gate on the REAL precondition — the stuck item has
        // actually landed in the render store. The streaming-ROW wait was
        // satisfied PREMATURELY by send's optimistic caret row (tagged,
        // parts=0, streaming) before the pump ingested the frames, so the
        // stage-2 DEBUG settle below raced frame ingestion and flipped
        // nothing. The caret is not the turn's items.
        await waitUntil {
            g.coordinator.store.items.contains {
                $0.itemID == "\(self.sessionID):a1" && $0.status == .inProgress
            }
        }

        g.chat._debugFireTurnLivenessResync()          // stage 1: silent resync (recovers nothing here)
        let settled = g.chat._debugFireLocalTurnWatchdog()   // stage 2: settle
        XCTAssertTrue(settled)
        XCTAssertFalse(g.chat.isStreaming, "A4: the dead turn's live flag is gone")
        XCTAssertFalse(g.chat.relayTurnLive)
        XCTAssertNil(g.chat.lastError, "C3: no error banner — the fold is the only surface")
        let row = try XCTUnwrap(assistantRows(g.chat).first)
        XCTAssertFalse(row.isStreaming, "A4: the stuck row is terminal now")
        XCTAssertTrue(row.interrupted, "A4: muted Interrupted fold")

        // ETERNAL-WORKING IMPOSSIBLE: a re-projection of the SAME store must
        // NOT re-light streaming (the qa3/base bug re-derived it from the
        // inProgress items).
        g.chat.applyRelayItems(g.coordinator.store.items)
        XCTAssertFalse(g.chat.isStreaming, "A4: re-projection can never resurrect the dead turn")
        XCTAssertTrue(assistantRows(g.chat).first?.interrupted == true)
    }

    /// The local settle is PROVISIONAL: a late authoritative frame (the truth
    /// arrives after all) replaces the item by id and heals the Interrupted
    /// state — the honest completion wins.
    func testLateAuthoritativeFrameHealsLocalSettle() async throws {
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        // Production-faithful drive (r4 integration): open VIA SESSIONSTORE so
        // the send's target pin (I5: the selected stored id) matches the
        // session the frames name. A coordinator-level open alone leaves
        // SessionStore.activeStoredId nil, turning the send into a true-draft
        // nil-pin submit whose create-adoption (I6) moves the write-gate to
        // the minted id — correct in production, where open() always sets the
        // stored id before any send can happen.
        g.sessions.open(summary(sessionID))
        await g.sessions.waitForPendingOpenForTesting()
        _ = await g.chat.send(text: "turn one prompt")

        deliverStuckTurn1(g)
        // Fix-round 1: gate on the REAL precondition — the stuck item has
        // actually landed in the render store. The streaming-ROW wait was
        // satisfied PREMATURELY by send's optimistic caret row (tagged,
        // parts=0, streaming) before the pump ingested the frames, so the
        // stage-2 DEBUG settle below raced frame ingestion and flipped
        // nothing. The caret is not the turn's items.
        await waitUntil {
            g.coordinator.store.items.contains {
                $0.itemID == "\(self.sessionID):a1" && $0.status == .inProgress
            }
        }
        g.chat._debugFireTurnLivenessResync()
        _ = g.chat._debugFireLocalTurnWatchdog()
        XCTAssertTrue(assistantRows(g.chat).first?.interrupted == true)

        // The truth lands late: the tool completed after all.
        g.transport.deliver(envelope("item.completed",
            itemBody("\(sessionID):a1", "toolCall", "completed", 1, ["name": "shell"]),
            turn: "\(sessionID):t1"))
        g.transport.deliver(envelope("turn.completed", [:], turn: "\(sessionID):t1"))
        await waitUntil { self.assistantRows(g.chat).first?.interrupted == false }
        let row = try XCTUnwrap(assistantRows(g.chat).first)
        XCTAssertFalse(row.interrupted, "the authoritative completion heals the provisional settle")
        XCTAssertFalse(row.isStreaming)
    }

    /// Fix-round 1 (Gate-3): a HEALTHY but frame-silent slow turn — one long
    /// opaque tool with no incremental output and no heartbeat — can outlive
    /// the stage-2 silence window. Even if the watchdog false-positives on it,
    /// the settle must be LOSSLESS: the first frame that lands proves liveness,
    /// resurrects the item (replace-not-drop in `RelayItemStore.applyDelta`),
    /// re-lights the streaming row, and the turn continues to its honest
    /// completion. Pre-fix the late delta hit the terminal guard and was
    /// DROPPED — streamed content in the window was silently lost until the
    /// wholesale `completed` replace.
    func testLateDeltaAfterFalseSettleResurrectsTheTurnLosslessly() async throws {
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        // Production-faithful drive (r4 integration): open VIA SESSIONSTORE so
        // the send's target pin (I5: the selected stored id) matches the
        // session the frames name. A coordinator-level open alone leaves
        // SessionStore.activeStoredId nil, turning the send into a true-draft
        // nil-pin submit whose create-adoption (I6) moves the write-gate to
        // the minted id — correct in production, where open() always sets the
        // stored id before any send can happen.
        g.sessions.open(summary(sessionID))
        await g.sessions.waitForPendingOpenForTesting()
        _ = await g.chat.send(text: "turn one prompt")

        deliverStuckTurn1(g)
        // Fix-round 1: gate on the REAL precondition — the stuck item has
        // actually landed in the render store. The streaming-ROW wait was
        // satisfied PREMATURELY by send's optimistic caret row (tagged,
        // parts=0, streaming) before the pump ingested the frames, so the
        // stage-2 DEBUG settle below raced frame ingestion and flipped
        // nothing. The caret is not the turn's items.
        await waitUntil {
            g.coordinator.store.items.contains {
                $0.itemID == "\(self.sessionID):a1" && $0.status == .inProgress
            }
        }

        g.chat._debugFireTurnLivenessResync()          // stage 1: silent resync (recovers nothing here)
        _ = g.chat._debugFireLocalTurnWatchdog()       // stage 2: the false-positive settle
        XCTAssertFalse(g.chat.isStreaming)
        XCTAssertTrue(assistantRows(g.chat).first?.interrupted == true)

        // The turn was alive after all: the opaque tool finally emits output.
        g.transport.deliver(envelope("item.delta",
            ["item_id": "\(sessionID):a1", "patch": ["text": "tool output"]],
            turn: "\(sessionID):t1"))

        await waitUntil { g.chat.isStreaming }
        let live = try XCTUnwrap(assistantRows(g.chat).first)
        XCTAssertTrue(live.isStreaming, "the late delta resurrects the turn — streaming resumes")
        XCTAssertFalse(live.interrupted, "the Interrupted fold clears the moment liveness is proven")

        // And the turn completes honestly: the authoritative truth wins.
        g.transport.deliver(envelope("item.completed",
            itemBody("\(sessionID):a1", "toolCall", "completed", 1, ["name": "shell"]),
            turn: "\(sessionID):t1"))
        g.transport.deliver(envelope("turn.completed", [:], turn: "\(sessionID):t1"))
        await waitUntil { !g.chat.isStreaming }
        let settled = try XCTUnwrap(assistantRows(g.chat).first)
        XCTAssertFalse(settled.interrupted)
        XCTAssertFalse(settled.isStreaming)
    }

    // MARK: - Item store settle semantics (pure)

    func testSettleInProgressLocallyMarksOnlyStuckItemsAndHealsOnCompleted() {
        func itemFrame(_ seq: Int, _ kind: String, _ id: String, _ type: String,
                       _ status: String, _ ord: Int, _ body: JSONValue = .null) -> RelayFrame {
            RelayFrame(
                seq: seq, sid: "s", turn: "t", kind: RelayFrameKind(wire: kind),
                body: .object([
                    "item_id": .string(id), "type": .string(type), "status": .string(status),
                    "ord": .number(Double(ord)), "summary": .string(""), "body": body,
                ])
            )
        }

        var store = RelayItemStore()
        store.apply(itemFrame(1, "item.started", "x1", "toolCall", "in_progress", 0))
        store.apply(itemFrame(2, "item.completed", "x2", "agentMessage", "completed", 1,
                              .object(["text": .string("done")])))

        XCTAssertTrue(store.settleInProgressLocally())
        XCTAssertEqual(store.itemsByID["x1"]?.status, .completed)
        XCTAssertTrue(store.itemsByID["x1"]?.locallyInterrupted == true)
        XCTAssertFalse(store.itemsByID["x2"]?.locallyInterrupted == true,
                       "an honestly-completed item is never marked interrupted")

        // A second settle finds nothing stuck.
        XCTAssertFalse(store.settleInProgressLocally())

        // A late authoritative completed REPLACES the item (marker cleared).
        store.apply(itemFrame(3, "item.completed", "x1", "toolCall", "completed", 0))
        XCTAssertFalse(store.itemsByID["x1"]?.locallyInterrupted == true)

        // REPLACE-NOT-DROP (fix-round 1, Gate-3): a delta against a LOCALLY
        // settled item proves the turn was alive after all (the stage-2 settle
        // false-positived on a healthy-but-frame-silent slow turn) — it
        // RESURRECTS the item: marker cleared, re-opened to .inProgress, patch
        // merged onto the pre-settle body so no streamed content is lost.
        var store2 = RelayItemStore()
        store2.apply(itemFrame(1, "item.started", "y1", "agentMessage", "in_progress", 0,
                               .object(["text": .string("hel")])))
        store2.settleInProgressLocally()
        store2.apply(RelayFrame(
            seq: 2, sid: "s", turn: "t", kind: .itemDelta,
            body: .object(["item_id": .string("y1"), "patch": .object(["text": .string("lo")])])
        ))
        XCTAssertEqual(store2.itemsByID["y1"]?.status, .inProgress,
                       "a late delta resurrects the provisionally-settled item")
        XCTAssertFalse(store2.itemsByID["y1"]?.locallyInterrupted == true,
                       "resurrection clears the Interrupted marker")
        XCTAssertEqual(store2.itemsByID["y1"]?.body["text"]?.stringValue, "hello",
                       "the delta merges onto the pre-settle body — content is not lost")

        // The terminal guard still holds for an AUTHORITATIVE terminal: a delta
        // after a real `completed` from the wire is stale and dropped.
        var store3 = RelayItemStore()
        store3.apply(itemFrame(1, "item.started", "z1", "agentMessage", "in_progress", 0,
                               .object(["text": .string("hel")])))
        store3.apply(itemFrame(2, "item.completed", "z1", "agentMessage", "completed", 0,
                               .object(["text": .string("done")])))
        store3.apply(RelayFrame(
            seq: 3, sid: "s", turn: "t", kind: .itemDelta,
            body: .object(["item_id": .string("z1"), "patch": .object(["text": .string("LO")])])
        ))
        XCTAssertEqual(store3.itemsByID["z1"]?.body["text"]?.stringValue, "done",
                       "deltas after an authoritative completed are still dropped")
        XCTAssertEqual(store3.itemsByID["z1"]?.status, .completed)
    }

    // MARK: - Fold label (pure)

    func testInterruptedFoldLabel() {
        XCTAssertEqual(WorkingSectionModel.settledLabel(seconds: 12, interrupted: true), "Interrupted")
        XCTAssertEqual(WorkingSectionModel.settledLabel(seconds: 12, interrupted: false), "Worked for 12s")
        XCTAssertEqual(WorkingSectionModel.settledLabel(seconds: nil, interrupted: true), "Interrupted")
        XCTAssertEqual(
            WorkingSectionModel.summaryAccessibilityLabel(seconds: nil, hasFailure: false, interrupted: true),
            "Interrupted"
        )
    }
}
