import XCTest
import SwiftUI
import GRDB
@testable import HermesMobile

/// ROUND-4 W0a — STORE-LEVEL replay tests for `docs/INTERACTION-CONTRACT.md`
/// §4 invariants (the test oracle). Each test replays a synthesized relay
/// downstream frame sequence through the REAL render lane (production decoders
/// → `RelaySessionCoordinator.ingest` → `RelayItemStore` → `ChatStore`
/// projection) over the in-process fake relay and asserts the contract clause.
///
/// Invariants covered here (plan W0a, amended): **I1, I2, I6, I7 (STORE layer
/// only — ord monotone + userMessage-before-agent-items incl. foreign turns),
/// I8, I9 (reason-dependent halves RED-BY-DESIGN until relay lane L3 —
/// amendment I9-gate), I10 (virtual clock — amendment W0-determinism), I15,
/// I21, I23 (pending-gate recovery across restart — amendment G3)**. The
/// I7/I19 VOID-GEOMETRY properties are RENDER-layer and live in W0b
/// (amendment A1) — nothing here asserts view geometry.
///
/// **Determinism (amendment W0-determinism):** no wall-clock sleeps pace the
/// contract's time-driven behavior. The I10 liveness stages are advanced by an
/// injected VIRTUAL CLOCK — the test itself schedules the stage transitions
/// through the DEBUG seams (`_debugFireTurnLivenessResync` /
/// `_debugFireLocalTurnWatchdog`, the seams `TurnLivenessTests` pins the
/// production tick loop against); zero `Task.sleep` in the stage path. The
/// absolute time BOUNDARIES (45 s / 480 s) are constants the injectable-clock
/// rewire (R5 / W2e) will pin; W0a pins stage ORDERING + EFFECTS. The only
/// sleeps in this file are bounded pump-settle graces for ABSENCE assertions
/// (the established render_conformance pattern, e.g.
/// `testIdleSessionOpen_KeepsTranscriptNonEmpty`) — observation windows, never
/// stage pacing.
///
/// **RED-on-base is the point:** most of these FAIL on `r4/base`
/// (main @ c44e7f8d9) — the contract encodes the TARGET, and the RED matrix
/// (`hermes-tmp/evidence/round4/w0a-red-matrix.md`) is the fail-before evidence
/// each Wave-2 rewire lane flips green with its own deletions (RR7: no fixture
/// edit without a recorded fail-before/pass-after sequence). Tests expected
/// GREEN on base are PINS guarding already-fixed behavior (S4/S6/S8/S11/R16
/// fixes) through the rewires. Frame sequences are synthesized inline (not new
/// fixture files) so they are byte-stable by construction.
@MainActor
final class ContractInvariantsW0aTests: XCTestCase {

    private typealias MockRelayTransport = RelaySessionCoordinatorTests.MockRelayTransport

    private let relayURL = URL(string: "ws://127.0.0.1:9999/relay")!

    // MARK: - Relay store graph (flag ON, mock transport, RPC-answering script)

    private struct Graph {
        let chat: ChatStore
        let sessions: SessionStore
        let connection: ConnectionStore
        let transport: MockRelayTransport
        let coordinator: RelaySessionCoordinator
    }

    /// The session id the mock relay mints for a nil-target SUBMIT (the relay
    /// creates the session — DS:759-763). A target-carrying SUBMIT echoes its
    /// own target back, exactly like the real relay.
    private static let createdSessionID = "w0a-created-1"

    private func makeGraph() async throws -> Graph {
        UserDefaults.standard.set(TransportPath.relay.rawValue, forKey: DefaultsKeys.transportPath)
        let createdSessionID = Self.createdSessionID
        let transport = MockRelayTransport(script: { upstream, relay in
            guard let id = upstream.id else { return }
            if upstream.method == "submit" {
                let sid = (upstream.params["session_id"] as? String) ?? createdSessionID
                relay.deliverResult(id: id, result: .object(["session_id": .string(sid)]))
            } else {
                relay.deliverResult(id: id, result: .object(["ok": .bool(true)]))
            }
        })
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        chat.attach(connection: connection, sessions: sessions, attachments: AttachmentStore())
        // Production shape (AppEnvironment wires both): the draft lane
        // (`startDraft`) and the cache-first open read `connection` /
        // `chat` off the SessionStore.
        sessions.attach(connection: connection, chat: chat)
        connection.relayCoordinatorFactory = {
            RelaySessionCoordinator(chatStore: chat, clientFactory: { RelayClient { _ in transport } })
        }
        let coordinator = connection.ensureRelayCoordinator()
        XCTAssertEqual(connection.transportPath, .relay)
        let edgesBefore = coordinator.readinessEdgeCount
        try await coordinator.start(url: relayURL)
        // A9 determinism: await the readiness EDGE (not a wall-clock sleep) so
        // the phase is stably open before any test sends.
        await waitUntil { coordinator.readinessEdgeCount > edgesBefore }
        return Graph(chat: chat, sessions: sessions, connection: connection,
                     transport: transport, coordinator: coordinator)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.transportPath)
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.activeProfile)
        // I23 durability hygiene: the answered-gate record persists across
        // stores BY DESIGN — clear it so no run's state leaks into the next.
        ChatStore._debugClearDurableResolvedGates()
        super.tearDown()
    }

    // MARK: - Synthesized frame sequences (byte-stable by construction)

    /// Dense-seq downstream frame builder for one session — the same wire
    /// format the recorded fixtures carry (`{seq, sid, turn, kind, body}`),
    /// synthesized inline so the sequences are deterministic by construction.
    private struct Frames {
        let sid: String
        private(set) var seq = 0
        init(_ sid: String) { self.sid = sid }

        private mutating func bump() -> Int { seq += 1; return seq }

        private func text(_ frame: [String: Any]) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: frame)) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }

        mutating func item(_ kind: String, id: String, type: String, status: String,
                           ord: Int, body: [String: Any], turn: String? = nil,
                           summary: String = "") -> String {
            var frame: [String: Any] = [
                "seq": bump(), "sid": sid, "kind": kind,
                "body": ["item_id": id, "type": type, "status": status,
                         "ord": ord, "summary": summary, "body": body],
            ]
            if let turn { frame["turn"] = turn }
            return text(frame)
        }

        mutating func userCompleted(id: String, ord: Int, text: String,
                                    cmid: String? = nil, turn: String? = nil) -> String {
            var body: [String: Any] = ["text": text]
            if let cmid { body["client_message_id"] = cmid }
            return item("item.completed", id: id, type: "userMessage",
                        status: "completed", ord: ord, body: body, turn: turn)
        }

        mutating func turnStarted(_ turn: String) -> String {
            text(["seq": bump(), "sid": sid, "turn": turn,
                  "kind": "turn.started", "body": [String: Any]()])
        }

        mutating func turnCompleted(_ turn: String, extra: [String: Any] = [:]) -> String {
            var body: [String: Any] = ["usage": [String: Any](), "duration_s": 2.0]
            for (key, value) in extra { body[key] = value }
            return text(["seq": bump(), "sid": sid, "turn": turn,
                         "kind": "turn.completed", "body": body])
        }

        mutating func agentStarted(id: String, ord: Int, turn: String? = nil) -> String {
            item("item.started", id: id, type: "agentMessage", status: "in_progress",
                 ord: ord, body: ["text": ""], turn: turn)
        }

        mutating func agentDelta(id: String, _ chunk: String) -> String {
            text(["seq": bump(), "sid": sid, "kind": "item.delta",
                  "body": ["item_id": id, "patch": ["text": chunk]]])
        }

        mutating func agentCompleted(id: String, ord: Int, text: String,
                                     turn: String? = nil) -> String {
            item("item.completed", id: id, type: "agentMessage", status: "completed",
                 ord: ord, body: ["text": text], turn: turn)
        }

        mutating func toolStarted(id: String, ord: Int, name: String,
                                  turn: String? = nil) -> String {
            item("item.started", id: id, type: "toolCall", status: "in_progress",
                 ord: ord, body: ["name": name, "args": [String: Any]()], turn: turn)
        }

        mutating func toolCompleted(id: String, ord: Int, name: String,
                                    turn: String? = nil) -> String {
            item("item.completed", id: id, type: "toolCall", status: "completed",
                 ord: ord, body: ["name": name, "args": [String: Any]()], turn: turn)
        }

        mutating func usageCompleted(id: String, ord: Int, turn: String? = nil) -> String {
            item("item.completed", id: id, type: "usage", status: "completed",
                 ord: ord, body: ["input_tokens": 10, "output_tokens": 20], turn: turn)
        }

        mutating func errorFailed(id: String, ord: Int, turn: String? = nil) -> String {
            item("item.completed", id: id, type: "error", status: "failed",
                 ord: ord, body: ["message": "boom"], turn: turn)
        }

        mutating func taskList(id: String, ord: Int, status: String,
                               tasks: [[String: Any]], allComplete: Bool,
                               turn: String? = nil) -> String {
            let done = tasks.filter { ($0["status"] as? String) == "completed" }.count
            return item(status == "completed" ? "item.completed" : "item.started",
                        id: id, type: "taskList", status: status, ord: ord, body: [
                            "tasks": tasks,
                            "counts": ["total": tasks.count, "pending": tasks.count - done,
                                       "in_progress": 0, "completed": done, "cancelled": 0],
                            "all_complete": allComplete,
                        ], turn: turn, summary: "Tasks \(done)/\(tasks.count)")
        }

        mutating func clarifyRequest(requestID: String, question: String,
                                     choices: [String], turn: String? = nil) -> String {
            var frame: [String: Any] = ["seq": bump(), "sid": sid,
                                        "kind": "clarify.request",
                                        "body": ["request_id": requestID,
                                                 "question": question, "choices": choices]]
            if let turn { frame["turn"] = turn }
            return text(frame)
        }

        mutating func snapshot(items: [[String: Any]], cursor: Int) -> String {
            text(["seq": bump(), "sid": sid, "kind": "snapshot",
                  "body": ["items": items, "cursor": cursor]])
        }

        static func snapshotItem(id: String, type: String, status: String,
                                 ord: Int, body: [String: Any]) -> [String: Any] {
            ["item_id": id, "type": type, "status": status, "ord": ord, "body": body]
        }
    }

    private func deliver(_ g: Graph, _ frames: [String]) {
        for frame in frames { g.transport.deliver(frame) }
    }

    // MARK: - Assertion helpers

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("waitUntil timed out")
    }

    /// Bounded pump-settle grace for ABSENCE assertions — the established
    /// render_conformance pattern (never paces a contract stage; see header).
    private func pumpSettle() async {
        try? await Task.sleep(for: .milliseconds(150))
    }

    /// A MainActor-bound counter box the turn-end seams (`onTurnComplete` /
    /// `onTurnDiscarded`) increment — the queue-drain / LA-end side-effect
    /// record (AppEnvironment wires these to `queueStore.wake()` /
    /// `LiveActivityManager.end()`; the closures ARE the side effect).
    private final class Counter {
        var value = 0
    }

    private func assistantRows(_ g: Graph) -> [ChatMessage] {
        g.chat.messages.filter { $0.role == .assistant && $0.relayProjected }
    }

    // MARK: - QA-3 cache harness (in-memory CacheStore, hermetic open())

    private static let serverURL = "https://w0a.contract.test:9443"

    private func makeInMemoryCache() throws -> CacheStore {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(configuration: config)
        return try CacheStore(testDB: queue)
    }

    private func summary(_ id: String) -> SessionSummary {
        SessionSummary(id: id, title: "T-\(id)", preview: nil, startedAt: 1_000,
                       messageCount: 3, source: nil, lastActive: nil, cwd: nil)
    }

    private func cacheIdentity(_ g: Graph, _ sessionId: String) throws -> CacheIdentity {
        try XCTUnwrap(g.sessions.cacheIdentity(sessionId))
    }

    private func stageCacheFirstOpen(_ g: Graph) async throws -> CacheStore {
        let cache = try makeInMemoryCache()
        g.chat.attachCache(cache)
        g.sessions.attachCache(cache)
        g.connection.serverURLString = Self.serverURL
        g.sessions.transcriptFetchShaped = { _, _, _ in [] }
        return cache
    }

    private func storedHistory(_ rows: [(role: String, text: String)]) -> [StoredMessage] {
        rows.enumerated().map { index, row in
            StoredMessage(role: row.role, content: .string(row.text),
                          timestamp: 1_700_000_000 + Double(index), wireId: index + 1)
        }
    }

    // MARK: - I1 — Session identity

    /// I1: with A active, a frame whose `sid` names session B folds into B's
    /// entry — NEVER into A's transcript. `B.messages` (here: the active A's
    /// messages) stays byte-identical. FAILS on r4/base: `ingest` folds ANY
    /// `sid` into the one shared store and projects it onto the active
    /// transcript (RSC:454-458 — the D3 leak root).
    func testI1_ForeignSessionFrameNeverReachesActiveTranscript() async throws {
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open("w0a-i1-A")
        g.sessions.activeRuntimeId = "w0a-i1-A"
        // Session A's cache-painted settled transcript.
        g.chat.messages = [
            ChatMessage(role: .user, text: "A-q"),
            ChatMessage(role: .assistant, text: "A-a"),
        ]
        let before = g.chat.messages

        // Session B's turn streams — the user is looking at A.
        var f = Frames("w0a-i1-B")
        deliver(g, [
            f.userCompleted(id: "w0a-i1-B:u1", ord: 0, text: "B-q"),
            f.turnStarted("w0a-i1-B:t1"),
            f.agentStarted(id: "w0a-i1-B:a1", ord: 1, turn: "w0a-i1-B:t1"),
        ])
        await pumpSettle()   // let the pump fold (or, on target, route to entry B)

        XCTAssertEqual(g.chat.messages, before,
            "I1: a frame for a non-active session must never touch the active transcript — it folds into THAT session's entry (R1 routing). Base folds any sid into the one shared store (RSC:454-458).")
    }

    /// I1: a frame with NO attributable session (an id the app never opened,
    /// not the active session, no durable binding) is DROPPED — never folded
    /// into the active session, never creates a phantom entry. FAILS on
    /// r4/base (folded into the shared store, projected onto the active
    /// transcript).
    func testI1_UnattributableFrameDroppedNoEntryCreated() async throws {
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open("w0a-i1-A")
        g.sessions.activeRuntimeId = "w0a-i1-A"
        g.chat.messages = [ChatMessage(role: .user, text: "A-q")]
        let before = g.chat.messages

        var f = Frames("w0a-never-opened")
        deliver(g, [
            f.userCompleted(id: "w0a-unknown:u1", ord: 0, text: "phantom"),
        ])
        await pumpSettle()

        XCTAssertEqual(g.chat.messages, before,
            "I1: an unattributable frame is dropped, never folded into the active session")
        XCTAssertTrue(g.coordinator.store.items.isEmpty,
            "I1: no entry is created for a session id the app never opened (base folds it into the shared store)")
    }

    // MARK: - I2 — Single projection (write-gate)

    /// I2: after a switch A→B, ZERO rows in `messages` derive from A's store;
    /// the outgoing entry KEEPS folding frames received after the switch
    /// (nothing stream-side is cancelled); no `applyRelayItems([])` blank
    /// frame is ever emitted. FAILS on r4/base: the one shared store means
    /// A's post-switch frames project onto B's transcript (plus the
    /// switch-time store reset — RSC:740-757 — is the anti-pattern R1 deletes).
    func testI2_SwitchMovesProjection_OutgoingKeepsFolding_NeverVoids() async throws {
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open("w0a-i2-A")
        g.sessions.activeRuntimeId = "w0a-i2-A"

        // A goes live.
        var a = Frames("w0a-i2-A")
        deliver(g, [
            a.userCompleted(id: "w0a-i2-A:u1", ord: 0, text: "A-q1"),
            a.turnStarted("w0a-i2-A:t1"),
            a.agentStarted(id: "w0a-i2-A:a1", ord: 1, turn: "w0a-i2-A:t1"),
        ])
        await waitUntil { g.chat.isStreaming && g.chat.messages.contains { $0.text == "A-q1" } }

        // Switch to B; the cache paints B's settled transcript.
        let watcher = Task { @MainActor [chat = g.chat] in
            var sawEmpty = false
            for _ in 0..<60 {                       // ~300 ms observation window
                if chat.messages.isEmpty { sawEmpty = true; break }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return sawEmpty
        }
        _ = try await g.coordinator.open("w0a-i2-B")
        g.sessions.activeRuntimeId = "w0a-i2-B"
        g.chat.messages = [
            ChatMessage(role: .user, text: "B-q"),
            ChatMessage(role: .assistant, text: "B-a"),
        ]

        // A's turn keeps streaming AFTER the switch (the gateway never stopped).
        deliver(g, [
            a.agentCompleted(id: "w0a-i2-A:a1", ord: 1, text: "A-a1-done", turn: "w0a-i2-A:t1"),
            a.agentCompleted(id: "w0a-i2-A:a2", ord: 2, text: "A-a2", turn: "w0a-i2-A:t1"),
        ])
        await pumpSettle()   // let the pump route (or, on base, mis-fold)

        let texts = g.chat.messages.map(\.text)
        XCTAssertFalse(texts.contains { $0.hasPrefix("A-") },
            "I2: after switch A→B, zero rows in messages derive from A's store — the write-gate moved (base folds A's post-switch frames onto B's transcript)")
        // The outgoing entry keeps folding frames (nothing was cancelled): the
        // items live in A's store for a zero-refetch switch-back (I14). [R1
        // reconciles this accessor to the entry map — RR7.]
        XCTAssertTrue(g.coordinator.store.items.contains { $0.itemID == "w0a-i2-A:a2" },
            "I2: the outgoing session's frames keep folding after the switch (parked entry, never torn down)")
        let sawEmpty = await watcher.value
        XCTAssertFalse(sawEmpty,
            "I2/QA-1 B4: the switch never emits an applyRelayItems([]) blank frame")
    }

    // MARK: - I6 — Draft isolation

    /// I6: a new-chat draft renders ONLY its empty timeline while another
    /// session's turn streams — structurally, no frame from any session can
    /// reach it. (R1 makes this structural — a draft is the ABSENCE of an
    /// entry; on base the `projectionSuppressed` flag (S11) carries it, which
    /// this test pins behaviorally until the flag deletes.) PIN: expected
    /// GREEN on r4/base.
    func testI6_DraftTimelineStaysEmptyUnderForeignFrameTraffic() async throws {
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open("w0a-i6-A")
        g.sessions.activeRuntimeId = "w0a-i6-A"

        // A goes live.
        var f = Frames("w0a-i6-A")
        deliver(g, [
            f.userCompleted(id: "w0a-i6-A:u1", ord: 0, text: "A-q"),
            f.turnStarted("w0a-i6-A:t1"),
            f.agentStarted(id: "w0a-i6-A:a1", ord: 1, turn: "w0a-i6-A:t1"),
            f.agentDelta(id: "w0a-i6-A:a1", "streaming…"),
        ])
        await waitUntil { g.chat.isStreaming }

        // The user taps New Chat mid-stream.
        g.sessions.startDraft()
        XCTAssertTrue(g.chat.messages.isEmpty, "a draft holds no transcript")

        // …and A's turn keeps streaming for its full lifetime.
        deliver(g, [
            f.agentDelta(id: "w0a-i6-A:a1", " more"),
            f.agentCompleted(id: "w0a-i6-A:a1", ord: 1, text: "streaming… more", turn: "w0a-i6-A:t1"),
            f.usageCompleted(id: "w0a-i6-A:usage", ord: 2, turn: "w0a-i6-A:t1"),
            f.turnCompleted("w0a-i6-A:t1"),
        ])
        // Synchronize on the store settling (frames fold even while the
        // projection is parked — fast switch-back relies on it).
        await waitUntil {
            g.coordinator.store.items.contains {
                $0.itemID == "w0a-i6-A:a1" && $0.status == .completed
            }
        }
        await pumpSettle()

        XCTAssertTrue(g.chat.messages.isEmpty,
            "I6: the draft timeline stays empty under a full turn's frame traffic — no session's frames/snapshot/parked state can reach it")
        XCTAssertFalse(g.chat.isStreaming, "I6: the draft surface has no live turn")
    }

    /// I6: a draft send submits with a NIL target (the relay creates the
    /// session); the returned id is adopted atomically; the immediately
    /// following send targets the NEW id. FAILS on r4/base: `submit` falls
    /// back to the retained `activeSessionID` (RSC:654) — the draft sends into
    /// the PREVIOUS session (D2), and the created-id adoption never runs.
    func testI6_DraftSendTargetsNil_SecondSendTargetsNewID() async throws {
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open("w0a-i6-A")
        g.sessions.activeStoredId = "w0a-i6-A"
        g.sessions.activeRuntimeId = "w0a-i6-A"

        // New Chat — the draft has no session.
        g.sessions.startDraft()
        XCTAssertNil(g.sessions.activeStoredId, "precondition: the draft holds no stored id")

        _ = await g.chat.send(text: "first draft send")
        var submits = g.transport.upstreams().filter { $0.method == "submit" }
        XCTAssertEqual(submits.count, 1)
        XCTAssertNil(submits.first?.params["session_id"] as? String,
            "I6/A4: the draft send submits with a nil target — the relay creates; there is NO fallback to the previously-driven session (D2, RSC:654)")
        XCTAssertEqual(g.coordinator.activeStoredSessionID, Self.createdSessionID,
            "I6: the relay-created id is adopted atomically as the stored identity")

        _ = await g.chat.send(text: "second draft send")
        submits = g.transport.upstreams().filter { $0.method == "submit" }
        XCTAssertEqual(submits.count, 2)
        XCTAssertEqual(submits.last?.params["session_id"] as? String, Self.createdSessionID,
            "I6: the immediately-following send targets the NEW id")
    }

    // MARK: - I7 — Chronology (STORE layer only; void geometry is W0b)

    /// I7 STORE layer: the rendered timeline is a stable chronological merge
    /// keyed by `(ord, arrivalOrder)` — `ord` non-decreasing across the item
    /// stream, and the `userMessage` ALWAYS precedes its turn's agent items —
    /// for LOCAL turns AND FOREIGN turns (the foreign turn's `userMessage` is
    /// the relay-emitted L6-shaped item; at the store layer the fixture
    /// synthesizes it directly). PIN: expected GREEN on r4/base (the
    /// render-layer VOID-GEOMETRY half is W0b — amendment A1).
    func testI7_StoreLayerChronology_LocalAndForeignTurns() async throws {
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open("w0a-i7-A")
        g.sessions.activeRuntimeId = "w0a-i7-A"

        var f = Frames("w0a-i7-A")
        // Turn 1 — LOCAL-shaped (cmid-carrying userMessage).
        deliver(g, [
            f.userCompleted(id: "w0a-i7-A:u1", ord: 0, text: "q-local", cmid: "cmid-i7-1"),
            f.turnStarted("w0a-i7-A:t1"),
            f.agentStarted(id: "w0a-i7-A:a1", ord: 1, turn: "w0a-i7-A:t1"),
            f.agentDelta(id: "w0a-i7-A:a1", "Hel"),
            f.agentDelta(id: "w0a-i7-A:a1", "lo."),
            f.agentCompleted(id: "w0a-i7-A:a1", ord: 1, text: "Hello.", turn: "w0a-i7-A:t1"),
            f.usageCompleted(id: "w0a-i7-A:usage1", ord: 2, turn: "w0a-i7-A:t1"),
            f.turnCompleted("w0a-i7-A:t1"),
        ])
        // Turn 2 — FOREIGN (desktop-originated: the relay-emitted userMessage
        // item carries a foreign cmid no local echo matches — the L6 shape).
        // Text (ord 3) precedes the tool (ord 4): no tool row ever renders
        // ahead of preceding text.
        deliver(g, [
            f.userCompleted(id: "w0a-i7-A:u2", ord: 3, text: "q-foreign", cmid: "foreign-cmid-desktop"),
            f.turnStarted("w0a-i7-A:t2"),
            f.agentStarted(id: "w0a-i7-A:a2", ord: 4, turn: "w0a-i7-A:t2"),
            f.agentDelta(id: "w0a-i7-A:a2", "Foreign answer."),
            f.agentCompleted(id: "w0a-i7-A:a2", ord: 4, text: "Foreign answer.", turn: "w0a-i7-A:t2"),
            f.toolCompleted(id: "w0a-i7-A:tool2", ord: 5, name: "read", turn: "w0a-i7-A:t2"),
            f.turnCompleted("w0a-i7-A:t2"),
        ])
        await waitUntil {
            !g.chat.isStreaming && g.chat.messages.contains { $0.text == "Foreign answer." }
        }

        // ord non-decreasing across the reconciled item stream.
        let ords = g.coordinator.store.items.map(\.ord)
        XCTAssertTrue(zip(ords, ords.dropFirst()).allSatisfy { $0 <= $1 },
            "I7: the item stream's ord is non-decreasing (got \(ords))")

        // Chronological transcript: each userMessage precedes its turn's agent
        // content — local AND foreign.
        let texts = g.chat.messages.map(\.text)
        XCTAssertEqual(texts, ["q-local", "Hello.", "q-foreign", "Foreign answer."],
            "I7: strictly chronological — userMessage before its turn's agent items, local AND foreign turns")
        XCTAssertLessThan(texts.firstIndex(of: "q-local")!, texts.firstIndex(of: "Hello.")!)
        XCTAssertLessThan(texts.firstIndex(of: "q-foreign")!, texts.firstIndex(of: "Foreign answer.")!,
            "I7: the foreign turn's relay-emitted userMessage row precedes its agent items")

        // The tool (ord 5) never renders ahead of the preceding text (ord 4):
        // within the turn-2 assistant message the text part precedes the item.
        let turn2 = try XCTUnwrap(g.chat.messages.first { $0.text == "Foreign answer." })
        var textIdx = -1
        var toolIdx = -1
        for (index, part) in turn2.parts.enumerated() {
            switch part {
            case .text: if textIdx < 0 { textIdx = index }
            case .item: if toolIdx < 0 { toolIdx = index }
            default: break
            }
        }
        XCTAssertGreaterThanOrEqual(textIdx, 0, "the turn-2 text part renders")
        XCTAssertGreaterThanOrEqual(toolIdx, 0, "the turn-2 tool part renders")
        XCTAssertLessThan(textIdx, toolIdx,
            "I7: a tool frame never renders ahead of preceding text (ord-flushed)")
    }

    // MARK: - I8 — One echo identity

    /// I8: exactly one durable echo per send, carrying the outbox row's cmid;
    /// it morphs IN PLACE on `userMessage` adoption by cmid — never
    /// removed-then-re-presented, never re-keyed; a flap-resubmit (the relay
    /// re-emits the same item after cmid dedup) still yields ONE bubble with
    /// the SAME row id. PIN: expected GREEN on r4/base (cmid adoption +
    /// sticky re-mark are on main — guards the clause through the rewires).
    func testI8_EchoMorphsInPlaceOnCMIDAdoption_FlapDedupOneBubble() async throws {
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open("w0a-i8-A")
        g.sessions.activeStoredId = "w0a-i8-A"
        g.sessions.activeRuntimeId = "w0a-i8-A"

        _ = await g.chat.send(text: "echo flap")
        let echo = try XCTUnwrap(g.chat.messages.first { $0.role == .user && $0.text == "echo flap" })
        let echoID = echo.id
        let cmid = try XCTUnwrap(echo.clientMessageID, "the echo carries the outbox cmid")

        // The relay's synthesized userMessage adopts the echo IN PLACE by cmid.
        var f = Frames("w0a-i8-A")
        deliver(g, [
            f.userCompleted(id: "w0a-i8-A:u1", ord: 0, text: "echo flap", cmid: cmid),
            f.turnStarted("w0a-i8-A:t1"),
        ])
        await waitUntil {
            g.chat.messages.contains { $0.id == echoID && $0.relayProjected }
        }

        // FLAP-RESUBMIT: the relay re-emits the SAME item (cmid dedup replayed
        // the submit — DS:729-738). One bubble, same row id.
        deliver(g, [
            f.userCompleted(id: "w0a-i8-A:u1", ord: 0, text: "echo flap", cmid: cmid),
            f.agentCompleted(id: "w0a-i8-A:a1", ord: 1, text: "reply", turn: "w0a-i8-A:t1"),
            f.turnCompleted("w0a-i8-A:t1"),
        ])
        await waitUntil { !g.chat.isStreaming && g.chat.messages.contains { $0.text == "reply" } }

        let bubbles = g.chat.messages.filter { $0.role == .user && $0.text == "echo flap" }
        XCTAssertEqual(bubbles.count, 1, "I8/I21: flap-resubmit dedup → exactly one bubble")
        XCTAssertEqual(bubbles.first?.id, echoID,
            "I8: the echo morphs IN PLACE on adoption — never removed-then-re-presented, never re-keyed")
    }

    /// I8: the echo survives a session switch and store rebuild until
    /// reconciled — switch away and back ⇒ the echo is the SAME row id
    /// (repainted from the durable warm snapshot before any relay frame), and
    /// the `userMessage` adoption keeps that id. PIN: expected GREEN on
    /// r4/base (S6 durable echo) — the row-ID identity is the contract
    /// sharpening over the presence pin.
    func testI8_EchoSurvivesSwitchAndBack_SameRowID() async throws {
        UserDefaults.standard.set(DefaultsKeys.allProfilesScope, forKey: DefaultsKeys.activeProfile)
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        let cache = try await stageCacheFirstOpen(g)

        let rowsA = storedHistory([("user", "prior-q"), ("assistant", "prior-a")])
        try await cache.saveSessionList([summary("w0a-i8s-A")], scope: CacheScope(
            serverId: Self.serverURL, profileId: DefaultsKeys.allProfilesScope))
        try await cache.saveTranscript(identity: try cacheIdentity(g, "w0a-i8s-A"), messages: rowsA)

        g.sessions.open(summary("w0a-i8s-A"), bindRuntime: false)
        await g.sessions.waitForPendingOpenForTesting()
        XCTAssertEqual(g.chat.messages.map(\.text), ["prior-q", "prior-a"])

        _ = await g.chat.send(text: "durable echo?")
        await waitUntil { g.chat.messages.contains { $0.role == .user && $0.text == "durable echo?" } }
        let echo = try XCTUnwrap(g.chat.messages.first { $0.text == "durable echo?" })
        let echoID = echo.id
        let cmid = try XCTUnwrap(echo.clientMessageID)

        // Switch away, then back — no relay frame re-lands in between.
        g.sessions.open(summary("w0a-i8s-B"), bindRuntime: false)
        await g.sessions.waitForPendingOpenForTesting()
        XCTAssertFalse(g.chat.messages.contains { $0.text == "durable echo?" },
            "precondition: B's paint replaced the transcript")

        g.sessions.open(summary("w0a-i8s-A"), bindRuntime: false)
        await g.sessions.waitForPendingOpenForTesting()

        let repainted = try XCTUnwrap(
            g.chat.messages.first { $0.role == .user && $0.text == "durable echo?" },
            "I8: the echo repaints from the durable warm snapshot before any relay frame")
        XCTAssertEqual(repainted.id, echoID,
            "I8: switch away and back ⇒ the echo is the SAME row id (one durable identity)")

        // The relay's userMessage adopts THAT id in place — still one bubble,
        // still the same row.
        var f = Frames("w0a-i8s-A")
        deliver(g, [
            f.userCompleted(id: "u-dur", ord: 0, text: "durable echo?", cmid: cmid),
            f.agentCompleted(id: "msg-dur", ord: 1, text: "still here."),
            f.turnCompleted("t-dur"),
        ])
        await waitUntil {
            g.chat.messages.filter { $0.text == "durable echo?" }.count == 1
                && g.chat.messages.contains { $0.text == "still here." }
        }
        let adopted = try XCTUnwrap(g.chat.messages.first { $0.text == "durable echo?" })
        XCTAssertEqual(adopted.id, echoID,
            "I8: adoption re-homes the echo onto the server item's ord with the row id UNCHANGED — never onto a re-keyed row (amendment G4)")
    }

    /// I8: adoption matches by CMID ONLY — a `userMessage` carrying a FOREIGN
    /// cmid (a desktop-originated turn whose prompt text equals a cache-painted
    /// row) must NEVER adopt that row; the cache twin survives and the foreign
    /// prompt renders as its own wire-true row. FAILS on r4/base: the
    /// exact-text fallback in `adoptRelayEcho` (CS:5005+) consumes the
    /// cmid-less cache twin — the fuzzy adoption R1 deletes.
    func testI8_ForeignCMIDNeverAdoptsCacheTwinByText() async throws {
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open("w0a-i8f-A")
        g.sessions.activeRuntimeId = "w0a-i8f-A"
        // A cache-painted user row with NO cmid (the GRDB paint carries none).
        g.chat.messages = [ChatMessage(role: .user, text: "hello cache twin")]

        // A foreign turn whose prompt happens to have the identical text but a
        // foreign cmid no local echo carries.
        var f = Frames("w0a-i8f-A")
        deliver(g, [
            f.userCompleted(id: "w0a-i8f-A:u1", ord: 0, text: "hello cache twin",
                            cmid: "foreign-cmid-9"),
            f.agentCompleted(id: "w0a-i8f-A:a1", ord: 1, text: "foreign answer"),
            f.turnCompleted("w0a-i8f-A:t1"),
        ])
        await waitUntil { g.chat.messages.contains { $0.text == "foreign answer" } }

        let twins = g.chat.messages.filter { $0.text == "hello cache twin" }
        XCTAssertEqual(twins.count, 2,
            "I8: adoption matches by cmid ONLY — the foreign-cmid item never adopts the same-text cache twin (base's fuzzy text fallback consumes it). Wire truth: the cache row + the foreign user row are TWO rows.")
        XCTAssertTrue(twins.contains { !$0.relayProjected },
            "I8: the untagged cache-painted twin survives the foreign turn's projection")
    }

    // MARK: - I9 — Turn-end semantics

    /// I9: a local STOP settles the UI FIRST — streaming clears immediately,
    /// the partial text is kept — and gates LATE frames for that turn to
    /// no-ops; the interrupt RPC carries the turn's explicit session id
    /// (I18). FAILS on r4/base: `interrupt()` fires the RPC with no local
    /// settlement (no `settling` mark) — late deltas keep mutating the
    /// transcript and the turn stays "streaming" until the server's frame.
    func testI9_LocalStopSettlesFirst_GatesLateFrames() async throws {
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open("w0a-i9-A")
        g.sessions.activeStoredId = "w0a-i9-A"
        g.sessions.activeRuntimeId = "w0a-i9-A"

        _ = await g.chat.send(text: "stop me")
        let echo = try XCTUnwrap(g.chat.messages.first { $0.role == .user && $0.text == "stop me" })
        let cmid = try XCTUnwrap(echo.clientMessageID)
        var f = Frames("w0a-i9-A")
        deliver(g, [
            f.userCompleted(id: "w0a-i9-A:u1", ord: 0, text: "stop me", cmid: cmid),
            f.turnStarted("w0a-i9-A:t1"),
            f.agentStarted(id: "w0a-i9-A:a1", ord: 1, turn: "w0a-i9-A:t1"),
            f.agentDelta(id: "w0a-i9-A:a1", "partial "),
        ])
        await waitUntil {
            g.chat.messages.contains { $0.role == .assistant && $0.text == "partial " }
        }

        await g.chat.interrupt()

        // I18 adjacency: the interrupt targets the turn's explicit session.
        let interrupt = g.transport.upstreams().first { $0.method == "interrupt" }
        XCTAssertNotNil(interrupt, "the stop travels over the relay")
        XCTAssertEqual(interrupt?.params["session_id"] as? String, "w0a-i9-A",
            "I9/I18: the interrupt frame carries the turn's explicit session id")

        // LOCAL SETTLEMENT FIRST: the UI settles the instant the tap lands.
        XCTAssertFalse(g.chat.isStreaming,
            "I9/B1: a local STOP settles the UI immediately (the settling mark) — streaming clears before any server frame")
        XCTAssertTrue(g.chat.messages.contains { $0.role == .assistant && $0.text == "partial " },
            "I9/B1: the non-empty partial text is kept")

        // LATE FRAMES for this turn are no-ops.
        deliver(g, [
            f.agentDelta(id: "w0a-i9-A:a1", "MORE"),
            f.agentCompleted(id: "w0a-i9-A:a1", ord: 1, text: "server full text", turn: "w0a-i9-A:t1"),
        ])
        await pumpSettle()
        XCTAssertFalse(g.chat.messages.contains { $0.text.contains("MORE") },
            "I9/B1: the settling mark gates late deltas for this turn to no-ops (base applies them)")
        XCTAssertFalse(g.chat.messages.contains { $0.text == "server full text" },
            "I9/B1: a late item.completed for the stopped turn never re-opens it")
    }

    /// I9 **RED-BY-DESIGN until relay lane L3 (amendment I9-gate):**
    /// `turn.completed{reason:interrupted}` (a user stop) settles the entry
    /// and does NOT drain the queue — stopped ≠ completed. FAILS on r4/base
    /// by design: the relay stamps no `reason` yet, so iOS fires
    /// `onTurnComplete` (the queue-drain + LA-end seam) on EVERY
    /// `turn.completed` — the wire-truth `reason` split lands with L3/W2e,
    /// which deletes the local `settling`-mark + `relayTurnTerminatedByError`
    /// latch compensation.
    func testI9_InterruptedCompletionHoldsQueue_RedByDesignUntilL3() async throws {
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open("w0a-i9r-A")
        g.sessions.activeStoredId = "w0a-i9r-A"
        g.sessions.activeRuntimeId = "w0a-i9r-A"

        let drains = Counter()
        let discards = Counter()
        g.chat.onTurnComplete = { drains.value += 1 }
        g.chat.onTurnDiscarded = { discards.value += 1 }

        _ = await g.chat.send(text: "stop mid-turn")
        let echo = try XCTUnwrap(g.chat.messages.first { $0.text == "stop mid-turn" })
        let cmid = try XCTUnwrap(echo.clientMessageID)
        var f = Frames("w0a-i9r-A")
        deliver(g, [
            f.userCompleted(id: "w0a-i9r-A:u1", ord: 0, text: "stop mid-turn", cmid: cmid),
            f.turnStarted("w0a-i9r-A:t1"),
            f.agentStarted(id: "w0a-i9r-A:a1", ord: 1, turn: "w0a-i9r-A:t1"),
            f.agentDelta(id: "w0a-i9r-A:a1", "some partial text"),
            f.agentCompleted(id: "w0a-i9r-A:a1", ord: 1, text: "some partial text", turn: "w0a-i9r-A:t1"),
            // L3 wire shape: the relay stamps the reason (absent on base).
            f.turnCompleted("w0a-i9r-A:t1", extra: ["reason": "interrupted"]),
        ])
        await waitUntil { !g.chat.isStreaming }

        XCTAssertEqual(discards.value, 1,
            "I9: reason:interrupted ⇒ one discard (LA ends)")
        XCTAssertEqual(drains.value, 0,
            "I9: reason:interrupted ⇒ the queue HOLDS — stopped ≠ completed. RED-BY-DESIGN until L3: base ignores `reason` and drains on every turn.completed")
    }

    /// I9: an `.error` item followed by the trailing `turn.completed` ⇒
    /// exactly ONE discard seam, ZERO drains (the `relayTurnTerminatedByError`
    /// latch suppresses the completion). PIN: expected GREEN on r4/base (R16
    /// latch) — guards the clause the L3 `reason` field natively replaces.
    func testI9_ErrorThenCompleted_OneDiscardZeroDrains() async throws {
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open("w0a-i9e-A")
        g.sessions.activeStoredId = "w0a-i9e-A"
        g.sessions.activeRuntimeId = "w0a-i9e-A"

        let drains = Counter()
        let discards = Counter()
        g.chat.onTurnComplete = { drains.value += 1 }
        g.chat.onTurnDiscarded = { discards.value += 1 }

        _ = await g.chat.send(text: "turn that errors")
        let echo = try XCTUnwrap(g.chat.messages.first { $0.text == "turn that errors" })
        let cmid = try XCTUnwrap(echo.clientMessageID)
        var f = Frames("w0a-i9e-A")
        deliver(g, [
            f.userCompleted(id: "w0a-i9e-A:u1", ord: 0, text: "turn that errors", cmid: cmid),
            f.turnStarted("w0a-i9e-A:t1"),
            f.errorFailed(id: "w0a-i9e-A:err", ord: 1, turn: "w0a-i9e-A:t1"),
            f.turnCompleted("w0a-i9e-A:t1"),
        ])
        await waitUntil { !g.chat.isStreaming }
        await pumpSettle()

        XCTAssertEqual(discards.value, 1, "I9: [error, turn.completed] ⇒ exactly one discard")
        XCTAssertEqual(drains.value, 0, "I9: [error, turn.completed] ⇒ zero drains")
        XCTAssertNil(g.chat.lastError, "C3: the relay error surfaces via the item fold, never raw")
    }

    /// I9 **compat branch (RR5 — deleted in W3b):** a pre-L3 relay stamps NO
    /// `reason` on `turn.completed`; the phone falls back to the local signals
    /// the deleted `relayTurnTerminatedByError` latch carried — a user STOP
    /// (the `settling` mark) ⇒ discard + queue HOLD. Pins the compat semantics
    /// so nothing removes the branch before W3b ships the relay-side ratchet.
    /// (The reasonless HAPPY path — no stop, no error ⇒ drain — is pinned by
    /// `testI21_FixtureReplayConverges_TranscriptAndSideEffects`'s `d1 == 1`.)
    func testI9_PreL3Compat_ReasonlessStopThenCompletion_HoldsQueue() async throws {
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open("w0a-i9c-A")
        g.sessions.activeStoredId = "w0a-i9c-A"
        g.sessions.activeRuntimeId = "w0a-i9c-A"

        let drains = Counter()
        let discards = Counter()
        g.chat.onTurnComplete = { drains.value += 1 }
        g.chat.onTurnDiscarded = { discards.value += 1 }

        _ = await g.chat.send(text: "stop then reasonless completion")
        let echo = try XCTUnwrap(g.chat.messages.first { $0.text == "stop then reasonless completion" })
        let cmid = try XCTUnwrap(echo.clientMessageID)
        var f = Frames("w0a-i9c-A")
        deliver(g, [
            f.userCompleted(id: "w0a-i9c-A:u1", ord: 0,
                            text: "stop then reasonless completion", cmid: cmid),
            f.turnStarted("w0a-i9c-A:t1"),
            f.agentStarted(id: "w0a-i9c-A:a1", ord: 1, turn: "w0a-i9c-A:t1"),
            f.agentDelta(id: "w0a-i9c-A:a1", "partial"),
        ])
        await waitUntil {
            g.chat.messages.contains { $0.role == .assistant && $0.text == "partial" }
        }
        await g.chat.interrupt()   // local settlement: the settling mark arms

        // Pre-L3 wire: `turn.completed` WITHOUT `reason` — the compat branch
        // reads the settling mark ⇒ discard, queue HOLD.
        deliver(g, [f.turnCompleted("w0a-i9c-A:t1")])
        await pumpSettle()

        XCTAssertEqual(discards.value, 1,
            "I9 compat: a stopped turn's reasonless completion discards (LA ends)")
        XCTAssertEqual(drains.value, 0,
            "I9 compat: …and the queue HOLDS — the settling mark carries the stop the deleted latch used to")
    }

    // MARK: - I10 — Liveness (injected virtual clock; no wall-clock sleeps)

    /// I10: a dead turn runs the two-stage watchdog — stage 1 one silent
    /// idempotent `resync{last_seq}`; stage 2 provisional settle (muted
    /// "Interrupted", ends LA + gates) that does NOT drain the queue; a late
    /// delta resurrects. VIRTUAL CLOCK (amendment W0-determinism): the test
    /// schedules the stage transitions through the DEBUG seams — zero
    /// wall-clock sleeps in the stage path (production fires them off the tick
    /// loop's silence clock; `TurnLivenessTests` pins the seam↔tick parity).
    /// The drain-HOLD half FAILS on r4/base: `fireTurnLivenessSettle` fires
    /// `onTurnComplete` — the Matrix B §4 gap R5 deletes (a provisional
    /// settle never drains).
    func testI10_DeadTurnStages_VirtualClock_QueueUntouched() async throws {
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open("w0a-i10-A")
        g.sessions.activeStoredId = "w0a-i10-A"
        g.sessions.activeRuntimeId = "w0a-i10-A"

        let drains = Counter()
        g.chat.onTurnComplete = { drains.value += 1 }

        _ = await g.chat.send(text: "turn that dies")
        let echo = try XCTUnwrap(g.chat.messages.first { $0.text == "turn that dies" })
        let cmid = try XCTUnwrap(echo.clientMessageID)
        var f = Frames("w0a-i10-A")
        deliver(g, [
            f.userCompleted(id: "w0a-i10-A:u1", ord: 0, text: "turn that dies", cmid: cmid),
            f.turnStarted("w0a-i10-A:t1"),
            f.toolStarted(id: "w0a-i10-A:tool", ord: 1, name: "shell", turn: "w0a-i10-A:t1"),
        ])
        // Gate on the REAL precondition — the stuck item folded into the store
        // (the optimistic caret row satisfies a streaming-row wait prematurely).
        await waitUntil {
            g.coordinator.store.items.contains {
                $0.itemID == "w0a-i10-A:tool" && $0.status == .inProgress
            }
        }

        // VIRTUAL CLOCK t := baseline + turnLivenessResyncAfter → stage 1.
        XCTAssertTrue(g.chat._debugFireTurnLivenessResync())
        XCTAssertEqual(g.chat.turnLivenessResyncCount, 1, "stage 1 fires exactly once")
        XCTAssertTrue(g.chat._debugFireTurnLivenessResync(), "the seam is re-entrant…")
        XCTAssertEqual(g.chat.turnLivenessResyncCount, 1, "…but the latch admits ONE resync per turn")
        await waitUntil { g.transport.upstreams().contains { $0.method == "resync" } }
        XCTAssertTrue(g.chat.isStreaming, "stage 1 alone does not settle")
        XCTAssertEqual(drains.value, 0)
        XCTAssertNil(g.chat.lastError, "C3: the resync is silent")

        // VIRTUAL CLOCK t := baseline + localTurnStaleTimeout → stage 2.
        XCTAssertTrue(g.chat._debugFireLocalTurnWatchdog())
        XCTAssertFalse(g.chat.isStreaming, "I10: the dead turn's live flag clears")
        let settled = try XCTUnwrap(assistantRows(g).first)
        XCTAssertTrue(settled.interrupted, "I10: muted 'Interrupted' fold — never an error banner (C3)")
        XCTAssertNil(g.chat.lastError, "C3: no error theater over the settle")
        XCTAssertEqual(drains.value, 0,
            "I10/B4: a PROVISIONAL watchdog settle ends LA + gates but does NOT drain the queue (base fires onTurnComplete — the Matrix B §4 4009-churn gap)")

        // A late delta RESURRECTS the provisionally-settled turn (the settle
        // false-positived on a healthy-but-frame-silent tool).
        deliver(g, [f.agentDelta(id: "w0a-i10-A:tool", "late output")])
        await waitUntil {
            self.assistantRows(g).contains { !$0.interrupted && $0.isStreaming }
        }
        XCTAssertTrue(g.chat.isStreaming, "I10: a late frame resurrects — the settle is provisional, lossless")
    }

    /// I10: a cold-resume of a LIVE turn (snapshot-with-in-progress, no local
    /// send — foreign OR force-close reopen) arms the watchdog from the FIRST
    /// projection: the silence clock baselines off the snapshot and stage 1 is
    /// reachable (the arming-gap closure, A1/I10/D11). PIN: expected GREEN on
    /// r4/base (the projection's setStreaming edge arms the watchdog).
    func testI10_ColdResumeArmsWatchdogFromSnapshot() async throws {
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open("w0a-i10-resume")
        g.sessions.activeRuntimeId = "w0a-i10-resume"

        // The resume snapshot carries an in-progress turn — no local send.
        var f = Frames("w0a-i10-resume")
        deliver(g, [
            f.snapshot(items: [
                Frames.snapshotItem(id: "w0a-i10-resume:u1", type: "userMessage",
                                    status: "completed", ord: 0,
                                    body: ["text": "resumed question"]),
                Frames.snapshotItem(id: "w0a-i10-resume:tool", type: "toolCall",
                                    status: "in_progress", ord: 1,
                                    body: ["name": "shell", "args": [String: Any]()]),
            ], cursor: 1),
        ])
        await waitUntil { g.chat.isStreaming }

        XCTAssertNotNil(g.chat.turnStartedAt,
            "I10/A3: the resumed live turn baselines its chrome + liveness off the snapshot itself")
        // The watchdog is armed from the first projection: stage 1 fires and
        // the silent resync reaches the wire.
        XCTAssertTrue(g.chat._debugFireTurnLivenessResync(),
            "I10: a snapshot-resumed live turn arms the watchdog from the first projection (arming-gap closed)")
        await waitUntil { g.transport.upstreams().contains { $0.method == "resync" } }
        XCTAssertEqual(g.chat.turnLivenessResyncCount, 1)
        XCTAssertNil(g.chat.lastError, "C3: silent")
    }

    // MARK: - I15 — taskList scoping

    /// I15: the pill shows iff the ACTIVE entry has a live turn AND a
    /// non-terminal list owned by THAT session. PHASE 1 (FAILS on r4/base):
    /// A's taskList frames while B is active must NOT mirror — base folds any
    /// sid into the shared store and re-stamps the mirror owner to the ACTIVE
    /// session (the cross-session pill). PHASE 2 (PIN): switch to A mid-turn ⇒
    /// pill. PHASE 3 (PIN): turn end dismisses. PHASE 4 (FAILS on r4/base): a
    /// resync replay of the DISMISSED list never re-raises it past its turn —
    /// base re-mirrors the replayed list under the next live turn.
    func testI15_TaskListScopedToOwningSession_DismissedStaysDismissed() async throws {
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }

        // PHASE 1 — B is on screen; A's taskList turn streams.
        _ = try await g.coordinator.open("w0a-i15-B")
        g.sessions.activeRuntimeId = "w0a-i15-B"
        g.chat.messages = [ChatMessage(role: .user, text: "B-q")]

        let pendingTasks = [["id": "t1", "text": "First thing", "status": "completed"],
                            ["id": "t2", "text": "Second thing", "status": "pending"]]
        var a = Frames("w0a-i15-A")
        deliver(g, [
            a.userCompleted(id: "w0a-i15-A:u1", ord: 0, text: "A-q"),
            a.turnStarted("w0a-i15-A:t1"),
            a.taskList(id: "w0a-i15-A:tasks", ord: 1, status: "in_progress",
                       tasks: pendingTasks, allComplete: false, turn: "w0a-i15-A:t1"),
        ])
        await waitUntil { g.coordinator.store.items.contains { $0.type == .taskList } }
        await pumpSettle()

        XCTAssertNil(g.chat.latestTodoList,
            "I15: another session's taskList never mirrors — A's list while B is active (base mirrors it under B)")
        XCTAssertFalse(g.chat.dockShowsTaskBox,
            "I15: the pill never renders for a list the active session does not own")

        // PHASE 2 — switch to A mid-turn: the list re-delivers (the relay
        // replays on open/resync; zero-refetch once entries are warm — I14).
        _ = try await g.coordinator.open("w0a-i15-A")
        g.sessions.activeRuntimeId = "w0a-i15-A"
        deliver(g, [
            a.userCompleted(id: "w0a-i15-A:u1", ord: 0, text: "A-q"),
            a.turnStarted("w0a-i15-A:t1"),
            a.taskList(id: "w0a-i15-A:tasks", ord: 1, status: "in_progress",
                       tasks: pendingTasks, allComplete: false, turn: "w0a-i15-A:t1"),
        ])
        await waitUntil { g.chat.latestTodoList != nil && g.chat.isStreaming }
        XCTAssertTrue(g.chat.dockShowsTaskBox,
            "I15: switching to the owning session mid-turn shows the pill")

        // PHASE 3 — turn end dismisses (terminal list + settle).
        deliver(g, [
            a.taskList(id: "w0a-i15-A:tasks", ord: 1, status: "completed",
                       tasks: [["id": "t1", "text": "First thing", "status": "completed"],
                               ["id": "t2", "text": "Second thing", "status": "completed"]],
                       allComplete: true, turn: "w0a-i15-A:t1"),
            a.turnCompleted("w0a-i15-A:t1"),
        ])
        await waitUntil { !g.chat.isStreaming }
        XCTAssertFalse(g.chat.dockShowsTaskBox, "I15: turn end dismisses the pill")

        // PHASE 4 — the next turn goes live; a resync replay of the OLD
        // (non-terminal) list frames must NOT re-raise the dismissed pill.
        _ = await g.chat.send(text: "turn two")
        XCTAssertTrue(g.chat.isStreaming, "precondition: turn 2 live")
        deliver(g, [
            a.taskList(id: "w0a-i15-A:tasks", ord: 1, status: "in_progress",
                       tasks: pendingTasks, allComplete: false, turn: "w0a-i15-A:t1"),
        ])
        await pumpSettle()
        XCTAssertFalse(g.chat.dockShowsTaskBox,
            "I15: a resync replay never re-raises a dismissed list past its turn (base re-mirrors the replayed list under turn 2)")
    }

    // MARK: - I21 — Idempotency

    /// I21: re-applying a frame sequence (resync replay) converges to the
    /// byte-identical transcript AND side-effect set — drains fire once per
    /// turn, never per replay. The transcript half PINS on r4/base
    /// (RelayItemStore is idempotent by construction); the side-effect half
    /// FAILS: the second `turn.completed` fires `onTurnComplete` AGAIN (base's
    /// completion seam is not latched per turn — double LA-end / double drain).
    func testI21_FixtureReplayConverges_TranscriptAndSideEffects() async throws {
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open("w0a-i21-A")
        g.sessions.activeStoredId = "w0a-i21-A"
        g.sessions.activeRuntimeId = "w0a-i21-A"

        let drains = Counter()
        g.chat.onTurnComplete = { drains.value += 1 }

        // Fixture F — one full turn.
        func fixtureF() -> [String] {
            var f = Frames("w0a-i21-A")
            return [
                f.userCompleted(id: "w0a-i21-A:u1", ord: 0, text: "q1", cmid: "cmid-21"),
                f.turnStarted("w0a-i21-A:t1"),
                f.agentStarted(id: "w0a-i21-A:a1", ord: 1, turn: "w0a-i21-A:t1"),
                f.agentDelta(id: "w0a-i21-A:a1", "Pa"),
                f.agentDelta(id: "w0a-i21-A:a1", "ris."),
                f.agentCompleted(id: "w0a-i21-A:a1", ord: 1, text: "Paris.", turn: "w0a-i21-A:t1"),
                f.usageCompleted(id: "w0a-i21-A:usage", ord: 2, turn: "w0a-i21-A:t1"),
                f.turnCompleted("w0a-i21-A:t1", extra: ["duration_s": 3.0]),
            ]
        }

        deliver(g, fixtureF())
        await waitUntil { !g.chat.isStreaming && g.chat.messages.last?.text == "Paris." }
        let m1 = g.chat.messages
        let d1 = drains.value
        XCTAssertEqual(d1, 1, "one turn.completed ⇒ one drain seam")

        // Re-apply F+F (resync replay + snapshot redelivery shape).
        deliver(g, fixtureF())
        deliver(g, fixtureF())
        await pumpSettle()

        let m2 = g.chat.messages
        XCTAssertEqual(m2, m1,
            "I21: apply F, then F+F ⇒ byte-identical transcript (union-by-(sid,item_id), delta at-most-once)")
        XCTAssertEqual(drains.value, d1,
            "I21: …identical side-effect set — the replayed turn.completed fires ZERO extra drains/LA-ends (base fires onTurnComplete on every turn.completed frame)")
    }

    /// I21: gates fire once per `request_id` within a process lifetime — a
    /// resync re-delivery of an ANSWERED gate never re-raises the card (the
    /// `resolvedRelayGateIDs` idempotency plumbing). PIN: expected GREEN on
    /// r4/base — guards the seam I23's cross-restart half depends on.
    func testI21_GateOncePerRequestID_InLifetime() async throws {
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open("w0a-i21g-A")
        g.sessions.activeRuntimeId = "w0a-i21g-A"

        var f = Frames("w0a-i21g-A")
        deliver(g, [f.clarifyRequest(requestID: "r-i21", question: "Pick one.",
                                     choices: ["x", "y"])])
        await waitUntil { g.chat.pendingClarification != nil }
        // Re-delivery while pending: the card state converges (one card).
        deliver(g, [f.clarifyRequest(requestID: "r-i21", question: "Pick one.",
                                     choices: ["x", "y"])])
        await pumpSettle()
        XCTAssertEqual(g.chat.pendingClarification?.request.requestId, "r-i21")

        await g.chat.respondClarification("x")
        let clarify = g.transport.upstreams().first { $0.method == "clarify" }
        XCTAssertEqual(clarify?.params["session_id"] as? String, "w0a-i21g-A")
        XCTAssertEqual(clarify?.params["request_id"] as? String, "r-i21")
        XCTAssertNil(g.chat.pendingClarification, "answered ⇒ cleared")

        // Resync replays the answered gate ⇒ no re-raise.
        deliver(g, [f.clarifyRequest(requestID: "r-i21", question: "Pick one.",
                                     choices: ["x", "y"])])
        await pumpSettle()
        XCTAssertNil(g.chat.pendingClarification,
            "I21: the resolved-id set suppresses resync re-delivery of an answered gate")
    }

    // MARK: - I23 — Pending-gate recovery across restart (amendment G3)

    /// I23: a gate left UNANSWERED at force-close re-raises on cold-open
    /// resume — the resync ring replays the `clarify.request`, the card
    /// re-parks on the owning session's entry, and the answer routes by the
    /// original `(session_id, request_id)`. PIN: expected GREEN on r4/base
    /// (fresh state folds the re-delivery).
    func testI23_UnansweredGateReRaisesOnColdOpen_AnswerRoutes() async throws {
        let rid = "clar-w0a-23"
        // ---- First launch: the gate raises, UNANSWERED, then force-close. ---
        let g1 = try await makeGraph()
        _ = try await g1.coordinator.open("w0a-i23-A")
        g1.sessions.activeRuntimeId = "w0a-i23-A"
        var f1 = Frames("w0a-i23-A")
        deliver(g1, [
            f1.userCompleted(id: "w0a-i23-A:u1", ord: 0, text: "gate q"),
            f1.turnStarted("w0a-i23-A:t1"),
            f1.clarifyRequest(requestID: rid, question: "Which path?",
                              choices: ["left", "right"], turn: "w0a-i23-A:t1"),
        ])
        await waitUntil { g1.chat.pendingClarification != nil }
        await g1.coordinator.stop()   // force-close: the gate is still pending

        // ---- Cold relaunch: resume re-delivers the ring (dense from 1). ----
        let g2 = try await makeGraph()
        defer { Task { await g2.coordinator.stop() } }
        _ = try await g2.coordinator.open("w0a-i23-A")
        g2.sessions.activeRuntimeId = "w0a-i23-A"
        var f2 = Frames("w0a-i23-A")
        deliver(g2, [
            f2.userCompleted(id: "w0a-i23-A:u1", ord: 0, text: "gate q"),
            f2.turnStarted("w0a-i23-A:t1"),
            f2.clarifyRequest(requestID: rid, question: "Which path?",
                              choices: ["left", "right"], turn: "w0a-i23-A:t1"),
        ])
        await waitUntil { g2.chat.pendingClarification != nil }

        let card = try XCTUnwrap(g2.chat.pendingClarification,
            "I23/G3: an unanswered gate re-raises on cold-open resume")
        XCTAssertEqual(card.request.question, "Which path?")
        XCTAssertEqual(card.sessionId, "w0a-i23-A",
            "I23: the re-raised gate parks on the OWNING session's entry")

        // The answer routes by the original (session_id, request_id).
        await g2.chat.respondClarification("left")
        let clarify = g2.transport.upstreams().first { $0.method == "clarify" }
        XCTAssertNotNil(clarify)
        XCTAssertEqual(clarify?.params["session_id"] as? String, "w0a-i23-A",
            "I23/I18: the answer targets the gate's session")
        XCTAssertEqual(clarify?.params["request_id"] as? String, rid,
            "I23: the answer carries the original request_id")
        XCTAssertNil(g2.chat.pendingClarification)
    }

    /// I23 contrast: a gate ANSWERED before the kill stays DOWN on cold open —
    /// durable resolution suppresses the re-delivery. FAILS on r4/base:
    /// `resolvedRelayGateIDs` is in-memory only (CS:1633, dropped at reset /
    /// relaunch — CS:4934), so the cold-relaunched store re-raises the
    /// answered card — the durable-relay-side resolution G3 requires.
    func testI23_AnsweredGateStaysDownOnColdOpen() async throws {
        let rid = "clar-w0a-23b"
        // ---- First launch: raise → ANSWER → force-close. -------------------
        let g1 = try await makeGraph()
        _ = try await g1.coordinator.open("w0a-i23b-A")
        g1.sessions.activeRuntimeId = "w0a-i23b-A"
        var f1 = Frames("w0a-i23b-A")
        deliver(g1, [
            f1.userCompleted(id: "w0a-i23b-A:u1", ord: 0, text: "gate q"),
            f1.turnStarted("w0a-i23b-A:t1"),
            f1.clarifyRequest(requestID: rid, question: "Confirm?",
                              choices: ["yes", "no"], turn: "w0a-i23b-A:t1"),
        ])
        await waitUntil { g1.chat.pendingClarification != nil }
        await g1.chat.respondClarification("yes")
        XCTAssertNotNil(g1.transport.upstreams().first { $0.method == "clarify" },
            "precondition: the answer left over the relay")
        XCTAssertNil(g1.chat.pendingClarification)
        // In-lifetime re-delivery is suppressed (the I21 seam, green on base):
        deliver(g1, [f1.clarifyRequest(requestID: rid, question: "Confirm?",
                                       choices: ["yes", "no"], turn: "w0a-i23b-A:t1")])
        await pumpSettle()
        XCTAssertNil(g1.chat.pendingClarification,
            "I21 seam: in-lifetime re-delivery of an answered gate is suppressed")
        await g1.coordinator.stop()   // force-close

        // ---- Cold relaunch: the ring replays the answered gate. ------------
        let g2 = try await makeGraph()
        defer { Task { await g2.coordinator.stop() } }
        _ = try await g2.coordinator.open("w0a-i23b-A")
        g2.sessions.activeRuntimeId = "w0a-i23b-A"
        var f2 = Frames("w0a-i23b-A")
        deliver(g2, [
            f2.userCompleted(id: "w0a-i23b-A:u1", ord: 0, text: "gate q"),
            f2.turnStarted("w0a-i23b-A:t1"),
            f2.clarifyRequest(requestID: rid, question: "Confirm?",
                              choices: ["yes", "no"], turn: "w0a-i23b-A:t1"),
        ])
        await pumpSettle()

        XCTAssertNil(g2.chat.pendingClarification,
            "I23/G3: a gate answered before the kill does NOT re-raise on cold open — durable resolution suppresses re-delivery (base's resolved-id set is in-memory only — CS:1633/4934)")
    }
}
