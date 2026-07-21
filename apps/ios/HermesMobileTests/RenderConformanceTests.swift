import XCTest
import SwiftUI
import GRDB
@testable import HermesMobile

/// QA-1 A9 — the RENDER half of the device-shaped gate (spec A9; the wire half
/// is `tests/e2e_daily_driver` + `tests/conformance`).
///
/// THE STRUCTURAL GAP QA-1 CLOSES: every E2E scenario drove the relay protocol
/// with a Python phone-driver — nothing exercised the iOS render lane
/// (RelayItemStore → ChatStore → view state). Build 114 passed all wire gates
/// yet failed device QA in relay mode. This suite replays REAL relay frame
/// streams — recorded by the E2E harness
/// (`tests/e2e_daily_driver/test_z_record_render_fixtures.py`, committed under
/// `tests/render_conformance/fixtures/`, bundled into this target via
/// project.yml) — through the real render lane and asserts the RENDER-MODEL
/// invariants the spec contracts:
///
///  • user echo present immediately after a relay submit (B5/B13, A2);
///  • cached/settled history preserved during AND after a live turn — live
///    items append, never replace the transcript (B6/B7, A2);
///  • clarify/approval frames produce the interactive card model
///    (pendingClarification/pendingApproval) and the answer round-trips over
///    the relay transport (B10, A3);
///  • taskList items surface on the SAME dock accessor the Turn Dock reads
///    (A3/A4);
///  • no standalone Working-pill state on the relay path while a streaming
///    assistant bubble renders the cursor — the dock is only for
///    tasks/approvals/clarifies (B8, A4);
///  • blank screen is impossible: cache → skeleton → content, never void
///    (B4/B15, A7).
///
/// The invariants are written for the CONTRACT, not the buggy present: on the
/// unfixed `qa1/base` the shipped-bug tests FAIL (evidence:
/// /Volumes/MainData/Developer/hermes-tmp/evidence/daily-driver-qa1/) and go
/// green as the fix lanes land. Frames are replayed byte-for-byte through the
/// production decoders; no live network — the coordinator's `RelayClient` runs
/// over the in-process fake relay `RelaySessionCoordinatorTests` uses.
@MainActor
final class RenderConformanceTests: XCTestCase {

    private typealias MockRelayTransport = RelaySessionCoordinatorTests.MockRelayTransport

    private let relayURL = URL(string: "ws://127.0.0.1:9999/relay")!

    // MARK: - Fixture loading

    private struct Fixture {
        let name: String
        let sessionID: String
        let submitText: String
        /// The `client_message_id` the recording harness sent on SUBMIT (the
        /// phone always sends one; the relay folds it into the synthesized
        /// `userMessage` item body — the identity the echo adoption reconciles).
        let submitClientMessageID: String?
        /// The transcript the GRDB cache paints before any relay frame lands.
        let cachedHistory: [(role: String, text: String)]
        /// The recorded downstream envelopes, in arrival order (replayed verbatim).
        let frames: [[String: Any]]
        let settled: [String: Any]
        /// QA-3 incident extensions (ADDITIVE; absent/empty on the QA-1/QA-2
        /// fixtures — the format stays backward-compatible). The driver's local
        /// actions on the shared t_ms clock (`switch_to` / `resync` /
        /// `enter_draft`…): the S6 session switch and the S11 New-Chat entry
        /// have NO downstream frame, so the replay performs them as local
        /// store calls at the recorded instant.
        let scriptSteps: [[String: Any]]
        /// Secondary sessions' streams (S6: the switched-to session's paint
        /// metadata + frames on the shared clock).
        let extraSessions: [String: ExtraSession]
    }

    /// A secondary session recorded beside the primary (QA-3 S6): its cache
    /// paint, its `open` RPC result messages, and its downstream frames.
    struct ExtraSession {
        let sessionID: String
        let cachedHistory: [(role: String, text: String)]
        let openResultMessages: [[String: Any]]
        let frames: [[String: Any]]
    }

    private static func historyRows(_ raw: [[String: Any]]) -> [(role: String, text: String)] {
        raw.compactMap { row in
            guard let role = row["role"] as? String, let text = row["content"] as? String
            else { return nil }
            return (role, text)
        }
    }

    private func loadFixture(_ resource: String) throws -> Fixture {
        let url = try XCTUnwrap(
            Bundle(for: type(of: self)).url(forResource: resource, withExtension: "json"),
            "\(resource).json must be bundled into the test target (project.yml)"
        )
        let data = try Data(contentsOf: url)
        let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let frames = try XCTUnwrap(raw["frames"] as? [[String: Any]], "\(resource): frames")
        let cached = (raw["cached_history"] as? [[String: Any]]) ?? []
        let submit = (raw["submit"] as? [String: Any]) ?? [:]
        // QA-3 incident extensions — parsed only when present; the QA-1/QA-2
        // fixtures carry neither key and load exactly as before.
        let scriptSteps = (raw["script"] as? [[String: Any]]) ?? []
        var extraSessions: [String: ExtraSession] = [:]
        if let extras = raw["extra_sessions"] as? [String: [String: Any]] {
            for (sid, meta) in extras {
                extraSessions[sid] = ExtraSession(
                    sessionID: sid,
                    cachedHistory: Self.historyRows(
                        (meta["cached_history"] as? [[String: Any]]) ?? []),
                    openResultMessages: (meta["open_result_messages"] as? [[String: Any]]) ?? [],
                    frames: (meta["frames"] as? [[String: Any]]) ?? []
                )
            }
        }
        return Fixture(
            name: (raw["name"] as? String) ?? resource,
            sessionID: try XCTUnwrap(raw["session_id"] as? String),
            submitText: (submit["text"] as? String) ?? "",
            submitClientMessageID: submit["client_message_id"] as? String,
            cachedHistory: Self.historyRows(cached),
            frames: frames,
            settled: (raw["settled"] as? [String: Any]) ?? [:],
            scriptSteps: scriptSteps,
            extraSessions: extraSessions
        )
    }

    // MARK: - QA-3 timing-aware replay helpers (ordering/liveness lanes)

    /// The per-frame arrival offset in ms (the recorder's `t_ms`; nil on the
    /// pre-QA-3 fixtures, which carry no timing — the ordering/liveness lanes
    /// key their silence windows off these).
    private func frameTMs(_ fx: Fixture) -> [Double?] {
        fx.frames.map { ($0["t_ms"] as? NSNumber)?.doubleValue }
    }

    /// Replay the recorded frames through the real pump with their ARRIVAL
    /// GAPS preserved (scaled down — the gate must not sit through the 2.5 s
    /// S8 silence window at wall-clock speed; a lane testing a real-time
    /// watchdog passes `scale: 1` and a matching timeout). Gaps are capped so
    /// a single fixture can never stall the suite.
    private func deliverTimed(
        _ g: Graph, _ fx: Fixture,
        scale: Double = 0.02, capMs: Double = 80
    ) async {
        var previous: Double?
        for frame in fx.frames {
            let tMs = (frame["t_ms"] as? NSNumber)?.doubleValue
            if let t = tMs, let prev = previous {
                let gapMs = min(max(0, (t - prev) * scale), capMs)
                if gapMs > 0 {
                    try? await Task.sleep(for: .milliseconds(gapMs))
                }
            }
            previous = tMs ?? previous
            g.transport.deliver(frameText(frame))
        }
    }

    // MARK: - Relay store graph (flag ON, mock transport, RPC-answering script)

    private struct Graph {
        let chat: ChatStore
        let sessions: SessionStore
        let connection: ConnectionStore
        let transport: MockRelayTransport
        let coordinator: RelaySessionCoordinator
    }

    /// An RPC-answering fake relay: every upstream request gets a result;
    /// `submit` echoes a session id like the real relay. Downstream frames are
    /// NOT scripted here — the tests replay the recorded fixtures explicitly.
    private func makeGraph() async throws -> Graph {
        UserDefaults.standard.set(TransportPath.relay.rawValue, forKey: DefaultsKeys.transportPath)
        let transport = MockRelayTransport(script: { upstream, relay in
            guard let id = upstream.id else { return }
            if upstream.method == "submit" {
                let sid = (upstream.params["session_id"] as? String) ?? "render-new-1"
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
        XCTAssertEqual(connection.transportPath, .relay)
        let edgesBefore = coordinator.readinessEdgeCount
        try await coordinator.start(url: relayURL)
        // A9 determinism: `start()` stamps `.open` optimistically, but the state
        // observer then replays the buffered `.connecting → .open` pair the socket
        // yielded, transiently regressing `isOpen` to false mid-replay. A send
        // racing that window skips the relay branch and returns false — the A9
        // gate's one residual flake. Await the readiness EDGE (the replay's
        // `.open` crossing) so the phase is stably open before any test sends —
        // event-driven off the observer, not a wall-clock sleep, so the gate is
        // byte-reproducible.
        await waitUntil { coordinator.readinessEdgeCount > edgesBefore }
        return Graph(chat: chat, sessions: sessions, connection: connection,
                     transport: transport, coordinator: coordinator)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.transportPath)
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.activeProfile)
        // W2e/I23 hygiene: the DURABLE answered-gate record persists across
        // stores by design — clear it so a rid this suite answered (the
        // fixture gates) never suppresses the next test's re-delivery.
        ChatStore._debugClearDurableResolvedGates()
        super.tearDown()
    }

    // MARK: - Replay plumbing

    private func frameText(_ frame: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: frame)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Deliver every recorded frame of the fixture through the real pump.
    private func deliverAll(_ g: Graph, _ fx: Fixture) {
        for frame in fx.frames { g.transport.deliver(frameText(frame)) }
    }

    /// Deliver frames up to AND INCLUDING the first one matching `stop`.
    private func deliver(_ g: Graph, _ fx: Fixture, through stop: ([String: Any]) -> Bool) {
        for frame in fx.frames {
            g.transport.deliver(frameText(frame))
            if stop(frame) { return }
        }
    }

    private func kind(_ frame: [String: Any]) -> String { (frame["kind"] as? String) ?? "" }
    private func itemType(_ frame: [String: Any]) -> String {
        ((frame["body"] as? [String: Any])?["type"] as? String) ?? ""
    }

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("waitUntil timed out")
    }

    private func cachedRows(_ fx: Fixture) -> [ChatMessage] {
        fx.cachedHistory.map { row in
            ChatMessage(role: row.role == "user" ? .user : .assistant, text: row.text)
        }
    }

    // MARK: - QA-3 cache harness (in-memory CacheStore, hermetic open())

    private static let qa3ServerURL = "https://qa3.render.test:9443"

    private func makeInMemoryCache() throws -> CacheStore {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(configuration: config)
        return try CacheStore(testDB: queue)
    }

    private func qa3Summary(_ id: String, messageCount: Int? = 3) -> SessionSummary {
        SessionSummary(
            id: id, title: "T-\(id)", preview: nil, startedAt: 1_000,
            messageCount: messageCount, source: nil, lastActive: nil, cwd: nil
        )
    }

    private func qa3CacheIdentity(_ g: Graph, _ sessionId: String) throws -> CacheIdentity {
        // Resolve the identity the OPEN path itself resolves (profile fold
        // included) — a hand-built identity can mismatch the store's profile
        // selection and silently miss the cache.
        try XCTUnwrap(g.sessions.cacheIdentity(sessionId))
    }

    /// Attach an in-memory transcript cache + a no-op network fetch (phase 2
    /// reconciles empty) so `open(summary, bindRuntime: false)` exercises the
    /// REAL cache-first paint lane hermetically. Returns the cache for staging.
    private func stageCacheFirstOpen(_ g: Graph) async throws -> CacheStore {
        let cache = try makeInMemoryCache()
        g.chat.attachCache(cache)
        g.sessions.attachCache(cache)
        // makeGraph does not attach the connection to the SessionStore (the
        // frame-replay tests never needed it) — the cache-first paint lane
        // resolves its CacheIdentity off `currentCacheScope`, which reads
        // `connection.serverURLString`; attach + bind the server URL.
        g.sessions.attach(connection: g.connection, chat: g.chat)
        g.connection.serverURLString = Self.qa3ServerURL
        g.sessions.transcriptFetchShaped = { _, _, _ in [] }
        return cache
    }

    /// Assert every cached-history row's text appears, IN ORDER, in the
    /// transcript texts (the history-preservation half of the contract —
    /// implementation-agnostic: ids/projection may differ, order may not).
    private func assertHistoryPresent(_ texts: [String], _ fx: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        var cursor = 0
        for row in fx.cachedHistory {
            guard let found = texts[cursor...].firstIndex(of: row.text) else {
                XCTFail("cached history row lost from the transcript: \(row.role): \(row.text.prefix(48))… — rendered: \(texts.map { String($0.prefix(32)) })", file: file, line: line)
                return
            }
            cursor = found + 1
        }
    }

    // MARK: - Submit/stream replay (B5/B6/B7/B13, A2)

    /// B5: after a relay submit the user's own message must render IMMEDIATELY
    /// (optimistic echo) — the relay emits NO `userMessage` item (recorded
    /// fixtures prove it: zero emitters), so the echo is local or nowhere.
    /// FAILS on qa1/base (ChatStore.send's relay branch appends nothing).
    func testReplay_UserEchoPresentImmediatelyAfterRelaySend() async throws {
        let fx = try loadFixture("render_submit_stream")
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open(fx.sessionID)

        let ok = await g.chat.send(text: fx.submitText)
        XCTAssertTrue(ok, "relay submit must be accepted")

        // NO relay frames delivered yet — the echo is local or nowhere.
        XCTAssertTrue(
            g.chat.messages.contains { $0.role == .user && $0.text == fx.submitText },
            "spec B5/A2: the sent message must render immediately on a relay submit (optimistic echo); the relay emits no userMessage item to reconcile against"
        )
    }

    /// B6/B7: a live turn must APPEND to the painted history, never replace
    /// it — mid-stream AND after completion. FAILS on qa1/base
    /// (`applyRelayItems` does `messages = rebuilt` from relay items only).
    func testReplay_HistoryPreservedDuringAndAfterLiveTurn() async throws {
        let fx = try loadFixture("render_submit_stream")
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open(fx.sessionID)

        // The GRDB cache painted the settled transcript before any relay frame.
        g.chat.messages = cachedRows(fx)
        let ok = await g.chat.send(text: fx.submitText)
        XCTAssertTrue(ok)

        // PHASE 1 — mid-stream: the live turn streams BELOW the cached history.
        deliver(g, fx, through: { self.kind($0) == "item.delta" })
        await waitUntil { g.chat.isStreaming }
        assertHistoryPresent(g.chat.messages.map(\.text), fx)
        XCTAssertTrue(
            g.chat.messages.contains { $0.role == .user && $0.text == fx.submitText },
            "spec B5: the user echo must be present during streaming"
        )

        // PHASE 2 — settled: history + echo + reply, in order, nothing dropped.
        deliverAll(g, fx)
        let agentText = try XCTUnwrap(fx.settled["agent_text"] as? String)
        await waitUntil { !g.chat.isStreaming && g.chat.messages.last?.text == agentText }
        assertHistoryPresent(g.chat.messages.map(\.text), fx)
        let texts = g.chat.messages.map(\.text)
        XCTAssertTrue(texts.contains(fx.submitText), "the user bubble survives turn completion")
        XCTAssertEqual(g.chat.messages.last?.role, .assistant)
        XCTAssertEqual(g.chat.messages.last?.text, agentText,
                       "spec B6/A2: the reply streams in below intact history, anchored last")
    }

    /// B5 reconciliation: after the turn settles there must be EXACTLY ONE
    /// user bubble for the prompt — the optimistic echo and any relay
    /// `userMessage` item must reconcile, never double-render. FAILS on
    /// qa1/base (zero bubbles — there is no echo and no item).
    func testReplay_UserBubbleExactlyOnceAfterTurnCompletes() async throws {
        let fx = try loadFixture("render_submit_stream")
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open(fx.sessionID)

        let ok = await g.chat.send(text: fx.submitText)
        XCTAssertTrue(ok)
        // PRODUCTION IDENTITY REPLAY: live, the optimistic echo carries the
        // `client_message_id` the relay's synthesized `userMessage` item echoes
        // back (downstream.py folds the SUBMIT's cmid into the item body), and
        // `adoptRelayEcho` folds the item onto the echo row in place. A static
        // fixture replay cannot join the live submit's fresh UUID, so re-stamp
        // the echo with the fixture's recorded cmid before replaying —
        // reconstructing exactly the identity chain production establishes.
        if let cmid = fx.submitClientMessageID,
           let idx = g.chat.messages.firstIndex(where: {
               $0.role == .user && $0.text == fx.submitText && $0.clientMessageID != nil
           }) {
            let echo = g.chat.messages[idx]
            g.chat.messages[idx] = ChatMessage(
                id: echo.id, role: .user, clientMessageID: cmid,
                parts: echo.parts, timestamp: echo.timestamp
            )
        }
        deliverAll(g, fx)
        let agentText = try XCTUnwrap(fx.settled["agent_text"] as? String)
        await waitUntil { !g.chat.isStreaming && g.chat.messages.last?.text == agentText }

        let promptBubbles = g.chat.messages.filter { $0.role == .user && $0.text == fx.submitText }
        XCTAssertEqual(promptBubbles.count, 1,
                       "spec B5/A2: exactly one user bubble for the prompt after the turn settles (echo reconciles with any relay userMessage item)")
    }

    /// PIN (green on qa1/base): the relay projection reconstructs the settled
    /// agent prose from the recorded `started → delta* → completed` lifecycle,
    /// and the turn is not streaming after `turn.completed`. This is the
    /// existing reconstruction contract the gate keeps honest.
    func testReplay_SettledAgentTextAndTurnNotStreaming() async throws {
        let fx = try loadFixture("render_submit_stream")
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open(fx.sessionID)
        deliverAll(g, fx)

        let agentText = try XCTUnwrap(fx.settled["agent_text"] as? String)
        await waitUntil { g.chat.messages.last?.text == agentText }
        XCTAssertFalse(g.chat.isStreaming, "turn.completed must settle the streaming state")
        XCTAssertEqual(g.chat.messages.last?.role, .assistant)
        XCTAssertEqual(g.chat.messages.last?.text, agentText)
    }

    /// B13: brand-new chat (no session id yet) — the first send must show the
    /// user bubble immediately; "nothing visible" is the bug. FAILS on
    /// qa1/base (same missing echo; the relay submit result is discarded too).
    func testNewChat_FirstSendShowsUserBubbleImmediately() async throws {
        let fx = try loadFixture("render_submit_stream")   // reuse the reply stream
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        // No open/resume: a fresh chat has no session yet.

        let ok = await g.chat.send(text: "hello")
        XCTAssertTrue(ok, "a new-chat relay send must be accepted")
        XCTAssertTrue(
            g.chat.messages.contains { $0.role == .user && $0.text == "hello" },
            "spec B13: the first send in a new chat must show the user bubble immediately"
        )

        // The streamed reply lands below the bubble; both survive completion.
        deliverAll(g, fx)
        let agentText = try XCTUnwrap(fx.settled["agent_text"] as? String)
        await waitUntil { !g.chat.isStreaming && g.chat.messages.last?.text == agentText }
        XCTAssertEqual(
            g.chat.messages.filter { $0.role == .user && $0.text == "hello" }.count, 1,
            "the new-chat bubble persists through the turn, exactly once"
        )
    }

    // MARK: - Approval gate replay (B10, A3)

    /// B10: a recorded `approval.request` frame must produce the interactive
    /// card model (`pendingApproval`) — the sole input of the Turn Dock's
    /// approval card. FAILS on qa1/base (the frame is dropped in
    /// `RelayItemStore.apply` and nothing bridges it to ChatStore).
    func testReplay_ApprovalRequestProducesInteractiveCardModel() async throws {
        let fx = try loadFixture("render_approval_gate")
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open(fx.sessionID)
        g.chat.messages = cachedRows(fx)
        _ = await g.chat.send(text: fx.submitText)

        deliver(g, fx, through: { self.kind($0) == "approval.request" })
        await waitUntil(timeout: .seconds(2)) { g.chat.pendingApproval != nil }

        let pending = try XCTUnwrap(g.chat.pendingApproval,
            "spec B10/A3: the relay approval.request frame must surface the interactive approval card model")
        XCTAssertEqual(pending.id, "appr-render-1", "the gate must carry the frame's request_id")
        XCTAssertEqual(pending.request.command, "rm -rf build/")
        XCTAssertEqual(pending.sessionId, fx.sessionID, "the answer must route back to the gate's session")
    }

    /// B10/A4: while the approval gate is up the dock resolves `.approval`
    /// (the ratified TurnDock priority). FAILS on qa1/base (no card model ⇒
    /// `.none` forever — the user sees only the generic tool row).
    func testReplay_ApprovalDockResolvesApproval() async throws {
        let fx = try loadFixture("render_approval_gate")
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open(fx.sessionID)
        _ = await g.chat.send(text: fx.submitText)
        deliver(g, fx, through: { self.kind($0) == "approval.request" })
        await waitUntil(timeout: .seconds(2)) { g.chat.pendingApproval != nil }

        let dock = TurnDockContent.resolve(
            hasApproval: g.chat.pendingApproval != nil,
            hasClarification: g.chat.pendingClarification != nil,
            hasTasks: g.chat.latestTodoList != nil,
            hasQueued: false
        )
        XCTAssertEqual(dock, .approval, "spec B10/A3: the dock must show the approval card on a relay approval.request")
    }

    /// B10 egress: answering the card must round-trip over the RELAY
    /// transport (the gateway socket is idle in relay mode). FAILS on
    /// qa1/base (respondApproval is hardwired to the gateway client).
    func testReplay_ApprovalAnswerRoundTripsOverRelayTransport() async throws {
        let fx = try loadFixture("render_approval_gate")
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open(fx.sessionID)
        _ = await g.chat.send(text: fx.submitText)
        deliver(g, fx, through: { self.kind($0) == "approval.request" })
        await waitUntil(timeout: .seconds(2)) { g.chat.pendingApproval != nil }
        guard g.chat.pendingApproval != nil else { return }   // reported above

        await g.chat.respondApproval(approve: true, all: false)

        let approve = g.transport.upstreams().first { $0.method == "approve" }
        XCTAssertNotNil(approve, "spec B10: the approval answer must travel over the relay transport")
        XCTAssertEqual(approve?.params["session_id"] as? String, fx.sessionID)
        XCTAssertEqual(approve?.params["request_id"] as? String, "appr-render-1")
        XCTAssertEqual(approve?.params["decision"] as? String, "approve")
        XCTAssertNil(g.chat.pendingApproval, "the card clears once answered")
    }

    // MARK: - Clarify gate replay (B10, A3)

    /// B10: a recorded `clarify.request` frame must produce the interactive
    /// card model (`pendingClarification`) with question + choices. FAILS on
    /// qa1/base (frame dropped; the user sees a spinner row forever).
    func testReplay_ClarifyRequestProducesInteractiveCardModel() async throws {
        let fx = try loadFixture("render_clarify_gate")
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open(fx.sessionID)
        _ = await g.chat.send(text: fx.submitText)

        deliver(g, fx, through: { self.kind($0) == "clarify.request" })
        await waitUntil(timeout: .seconds(2)) { g.chat.pendingClarification != nil }

        let pending = try XCTUnwrap(g.chat.pendingClarification,
            "spec B10/A3: the relay clarify.request frame must surface the interactive clarification card model")
        XCTAssertEqual(pending.request.question, "Do you like the clarifications UI?")
        XCTAssertEqual(pending.request.choices, ["yes", "no", "later"])
        XCTAssertEqual(pending.request.requestId, "clar-render-1")
        XCTAssertEqual(pending.sessionId, fx.sessionID)
    }

    /// B10/A4: while the clarify gate is up the dock resolves `.clarify`.
    /// FAILS on qa1/base (`.none` forever).
    func testReplay_ClarifyDockResolvesClarify() async throws {
        let fx = try loadFixture("render_clarify_gate")
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open(fx.sessionID)
        _ = await g.chat.send(text: fx.submitText)
        deliver(g, fx, through: { self.kind($0) == "clarify.request" })
        await waitUntil(timeout: .seconds(2)) { g.chat.pendingClarification != nil }

        let dock = TurnDockContent.resolve(
            hasApproval: g.chat.pendingApproval != nil,
            hasClarification: g.chat.pendingClarification != nil,
            hasTasks: g.chat.latestTodoList != nil,
            hasQueued: false
        )
        XCTAssertEqual(dock, .clarify, "spec B10/A3: the dock must show the clarification card on a relay clarify.request")
    }

    /// B10 egress: the clarify answer must round-trip over the relay
    /// transport, echoing the frame's request_id (the gateway routes by it).
    /// FAILS on qa1/base (respondClarification is hardwired to the gateway).
    func testReplay_ClarifyAnswerRoundTripsOverRelayTransport() async throws {
        let fx = try loadFixture("render_clarify_gate")
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open(fx.sessionID)
        _ = await g.chat.send(text: fx.submitText)
        deliver(g, fx, through: { self.kind($0) == "clarify.request" })
        await waitUntil(timeout: .seconds(2)) { g.chat.pendingClarification != nil }
        guard g.chat.pendingClarification != nil else { return }   // reported above

        await g.chat.respondClarification("yes")

        let clarify = g.transport.upstreams().first { $0.method == "clarify" }
        XCTAssertNotNil(clarify, "spec B10: the clarify answer must travel over the relay transport")
        XCTAssertEqual(clarify?.params["session_id"] as? String, fx.sessionID)
        XCTAssertEqual(clarify?.params["request_id"] as? String, "clar-render-1")
        XCTAssertEqual(clarify?.params["text"] as? String, "yes")
        XCTAssertNil(g.chat.pendingClarification, "the card clears once answered")
    }

    // MARK: - Task list replay (A3/A4)

    /// PIN (green on qa1/base): recorded taskList lifecycle frames surface on
    /// the SAME dock accessor the Turn Dock's task box reads. The N4 bridge
    /// already satisfies this; the gate keeps it from regressing.
    func testReplay_TaskListPopulatesDockAccessor() async throws {
        let fx = try loadFixture("render_tasklist")
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open(fx.sessionID)
        _ = await g.chat.send(text: fx.submitText)
        deliverAll(g, fx)

        await waitUntil { g.chat.latestTodoList != nil }
        let list = try XCTUnwrap(g.chat.latestTodoList)
        XCTAssertEqual(list.items.count, 3, "the settled taskList has three tasks")
        XCTAssertTrue(list.items.allSatisfy { $0.status == .completed },
                      "after the lifecycle completes every task is done")
    }

    /// PIN (green on qa1/base): with a taskList live, the dock resolves
    /// `.tasks` — the ratified dock priority (approval > clarify > tasks).
    func testReplay_TaskListDockResolvesTasks() async throws {
        let fx = try loadFixture("render_tasklist")
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open(fx.sessionID)
        _ = await g.chat.send(text: fx.submitText)
        deliverAll(g, fx)

        await waitUntil { g.chat.latestTodoList != nil }
        let dock = TurnDockContent.resolve(
            hasApproval: g.chat.pendingApproval != nil,
            hasClarification: g.chat.pendingClarification != nil,
            hasTasks: g.chat.latestTodoList != nil,
            hasQueued: false
        )
        XCTAssertEqual(dock, .tasks)
    }

    // MARK: - Working pill (B8, A4)

    /// B8: on the relay path the streaming cursor IS the working signal — the
    /// standalone inline Working row must NOT show while a streaming assistant
    /// bubble renders. FAILS on qa1/base (`shouldShowInlineTurnActivity` is
    /// transport-agnostic and trips the moment `isStreaming` is set, over a
    /// wiped transcript — the owner's "big working bar above the composer").
    ///
    /// The decision is the pure static `ChatView.shouldShowInlineTurnActivity(…)`,
    /// which carries the B8 fix lane's relay-path suppression clause (chrome
    /// lane); this call site was reconciled to that signature at qa1 integration.
    func testRelay_StreamingBubbleSuppressesInlineWorkingPill() async throws {
        let fx = try loadFixture("render_submit_stream")
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open(fx.sessionID)
        g.chat.messages = cachedRows(fx)
        _ = await g.chat.send(text: fx.submitText)

        // Stream through the first agentMessage delta: the assistant bubble is
        // now rendering the breathing cursor.
        deliver(g, fx, through: { self.kind($0) == "item.delta" })
        await waitUntil {
            g.chat.messages.contains { $0.role == .assistant && $0.isStreaming }
        }
        let hasStreamingBubble = g.chat.messages.contains { $0.role == .assistant && $0.isStreaming }
        XCTAssertTrue(hasStreamingBubble, "precondition: the fixture drives a streaming assistant bubble")

        XCTAssertFalse(
            ChatView.shouldShowInlineTurnActivity(
                isStreaming: g.chat.isStreaming,
                hasPendingGate: g.chat.pendingApproval != nil
                    || g.chat.pendingClarification != nil
                    || g.chat.pendingSecurePrompt != nil,
                isRelayTransport: g.connection.transportPath == .relay,
                lastMessage: g.chat.messages.last
            ),
            "spec B8/A4: while a streaming assistant bubble renders the cursor on the relay path, the standalone inline Working pill must be suppressed"
        )
    }

    /// PIN (green on qa1/base): the dock has NO working case — a streaming
    /// turn with no gate/task/queued row resolves `.none`. The dock is only
    /// for tasks/approvals/clarifies (ratified TurnDock rules); working state
    /// is never a dock surface.
    func testDock_NeverResolvesAWorkingSurface() {
        // Streaming with no interactive surface ⇒ nothing docks.
        XCTAssertEqual(
            TurnDockContent.resolve(hasApproval: false, hasClarification: false,
                                    hasTasks: false, hasQueued: false),
            .none
        )
        // Priority order of the interactive surfaces.
        XCTAssertEqual(
            TurnDockContent.resolve(hasApproval: true, hasClarification: true,
                                    hasTasks: true, hasQueued: true),
            .approval
        )
        XCTAssertEqual(
            TurnDockContent.resolve(hasApproval: false, hasClarification: true,
                                    hasTasks: true, hasQueued: true),
            .clarify
        )
    }

    // MARK: - Blank-screen fallback chain (B4/B15, A7)

    /// B4: a seeded-then-emptied transcript (generation > 0, messages empty)
    /// must render skeleton-or-cache — NEVER `.transcript` (the empty void the
    /// owner photographed). FAILS on qa1/base (the placeholder returns
    /// `.transcript` for any generation > 0 — ChatView's skeleton branch
    /// requires generation == 0).
    func testPlaceholder_SeededThenEmptiedNeverRendersVoid() {
        let state = ChatView.transcriptPlaceholder(
            isDraft: false,
            messagesEmpty: true,
            transcriptGeneration: 2,
            isGatewayOffline: false,
            loadError: nil
        )
        XCTAssertNotEqual(state, .transcript,
            "spec B4/A7: an empty transcript that was seeded at least once must fall back to skeleton-or-cache, never the void")

        // QA-1 integration reconciliation: the resume lane's blank-screen
        // contract (ChatView.transcriptPlaceholder + QA1ResumeLaneTests) makes
        // the skeleton WIN over the named terminals at generation > 0 — an
        // empty-at-generation state is a mid-open race until an authoritative
        // seed confirms honest-empty, and offline/load-error surfaces own their
        // own chrome (connection banner, lastBackfillError retry state). The
        // named placeholder terminals apply to the PRISTINE (generation == 0)
        // empty transcript, asserted below.
        XCTAssertEqual(
            ChatView.transcriptPlaceholder(isDraft: false, messagesEmpty: true,
                                           transcriptGeneration: 2, isGatewayOffline: true,
                                           loadError: nil),
            .skeleton
        )
        XCTAssertEqual(
            ChatView.transcriptPlaceholder(isDraft: false, messagesEmpty: true,
                                           transcriptGeneration: 2, isGatewayOffline: false,
                                           loadError: "boom"),
            .skeleton
        )
        // Pristine terminals stay honest: offline-with-no-cache and a
        // recoverable load error are named states, not the void.
        XCTAssertEqual(
            ChatView.transcriptPlaceholder(isDraft: false, messagesEmpty: true,
                                           transcriptGeneration: 0, isGatewayOffline: true,
                                           loadError: nil),
            .offlineNoCache
        )
        XCTAssertEqual(
            ChatView.transcriptPlaceholder(isDraft: false, messagesEmpty: true,
                                           transcriptGeneration: 0, isGatewayOffline: false,
                                           loadError: "boom"),
            .loadError("boom")
        )
        // A pristine empty transcript still skeletons.
        XCTAssertEqual(
            ChatView.transcriptPlaceholder(isDraft: false, messagesEmpty: true,
                                           transcriptGeneration: 0, isGatewayOffline: false,
                                           loadError: nil),
            .skeleton
        )
    }

    /// B4: switching sessions must NEVER transiently void a painted
    /// transcript — content → content, never content → void → content. FAILS
    /// on qa1/base (`resetItemStoreForSessionSwitch` calls
    /// `applyRelayItems([])` mid-open, emptying the cache-painted transcript
    /// until the new session's first frame lands).
    func testSessionSwitch_NeverVoidsPaintedTranscript() async throws {
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }

        // Session A: an idle session — the relay sends NO frames; the
        // transcript is cache-painted.
        let transport = g.transport
        transport.script = { upstream, relay in
            guard let id = upstream.id else { return }
            if upstream.method == "open",
               (upstream.params["session_id"] as? String) == "B" {
                // Session B answers with a one-item snapshot.
                relay.deliverFrame(RelayFrame(
                    seq: 1, sid: "B", turn: nil, kind: .snapshot,
                    body: .object([
                        "items": .array([.object([
                            "item_id": .string("B-item"),
                            "type": .string(ChatItemType.userMessage.rawValue),
                            "status": .string("completed"),
                            "ord": .number(0),
                            "body": .object(["text": .string("hello from B")]),
                        ])]),
                        "cursor": .number(1),
                    ])
                ))
            }
            if upstream.method == "submit" {
                relay.deliverResult(id: id, result: .object(["session_id": .string("A")]))
            } else {
                relay.deliverResult(id: id, result: .object(["ok": .bool(true)]))
            }
        }

        _ = try await g.coordinator.open("A")
        // The GRDB cache paints session A's settled transcript.
        g.chat.messages = [
            ChatMessage(role: .user, text: "A question"),
            ChatMessage(role: .assistant, text: "A answer"),
        ]

        // Watch the transcript while the user taps session B.
        let chat = g.chat
        let watcher = Task { @MainActor in
            var sawEmpty = false
            for _ in 0..<400 {                      // ~2 s budget in 5 ms ticks
                if chat.messages.isEmpty { sawEmpty = true; break }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return sawEmpty
        }
        _ = try await g.coordinator.open("B")
        await waitUntil { g.chat.messages.contains { $0.text == "hello from B" } }
        let sawEmpty = await watcher.value

        XCTAssertFalse(sawEmpty,
            "spec B4/A7: a session switch must never void the painted transcript (cache → skeleton → content, never the void)")
    }

    /// B4/B15: opening an idle session (zero relay frames) on top of a
    /// cache-painted transcript must keep the transcript NON-EMPTY. FAILS on
    /// qa1/base (the open-path reset wipes `messages` to [] and an idle
    /// session snapshots empty — the intermittent blank screen).
    func testIdleSessionOpen_KeepsTranscriptNonEmpty() async throws {
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }

        g.chat.messages = [
            ChatMessage(role: .user, text: "Settled question"),
            ChatMessage(role: .assistant, text: "Settled answer"),
        ]
        // Idle session: the relay answers `open` with no frames at all.
        _ = try await g.coordinator.open("render-idle")
        try? await Task.sleep(for: .milliseconds(100))   // let any (buggy) wipe land

        XCTAssertFalse(g.chat.messages.isEmpty,
            "spec B4/B15: opening an idle session must not blank the cache-painted transcript")
    }

    // MARK: - Reseed eviction guard (QA-2 R15/A8, R3 residue)

    /// Build gateway-shaped wire rows (stable `wireId` → deterministic seed ids,
    /// identical across every refetch — the identity ``reconcileMessages`` keys
    /// on), modeling what the GRDB cache paints and what a relay-history /
    /// backfill snapshot returns.
    private func storedHistory(_ rows: [(role: String, text: String)]) -> [StoredMessage] {
        rows.enumerated().map { index, row in
            StoredMessage(
                role: row.role,
                content: .string(row.text),
                timestamp: 1_700_000_000 + Double(index),
                wireId: index + 1
            )
        }
    }

    /// Assert every row's text appears, IN ORDER, in the rendered texts.
    private func assertRowsPresent(
        _ texts: [String], _ rows: [(role: String, text: String)],
        _ label: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        var cursor = 0
        for row in rows {
            guard let found = texts[cursor...].firstIndex(of: row.text) else {
                XCTFail(
                    "\(label): settled history row lost from the transcript: \(row.role): \(row.text.prefix(48)) — rendered: \(texts.map { String($0.prefix(24)) })",
                    file: file, line: line)
                return
            }
            cursor = found + 1
        }
    }

    /// QA-2 R15 / A8 — THE STUCK-EPISODE SEGMENT DROP. A mid-conversation
    /// segment vanished after a stuck live turn rode a connection flap: the
    /// reconnect `backfill()` reconciled a reseed snapshot SHORTER than the
    /// merged timeline (relay history is a tail window; the relay's per-session
    /// store holds only what it observed — the snapshot is known-partial), and
    /// `reconcileMessages` treated the snapshot as the SOLE truth, EVICTING the
    /// settled rows it did not carry. The cache still had them; switching away
    /// and back (cache-first reseed) repaired the transcript — the owner's
    /// exact recovery path.
    ///
    /// CONTRACT: the merged view NEVER shows less settled history than the
    /// store held before the reseed. FAILS on qa2/base (`reconcileMessages`
    /// does `messages = rebuilt` from the snapshot only — the missing segment
    /// is evicted).
    func testReseed_ShortSnapshotNeverEvictsSettledHistory() async throws {
        let fx = try loadFixture("render_submit_stream")
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open(fx.sessionID)
        g.sessions.activeStoredId = fx.sessionID

        // The GRDB cache painted six settled rows (three turns).
        let history: [(role: String, text: String)] = [
            ("user", "q1"), ("assistant", "a1"),
            ("user", "q2"), ("assistant", "a2"),
            ("user", "q3"), ("assistant", "a3"),
        ]
        let stored = storedHistory(history)
        g.chat.seed(from: stored)
        XCTAssertEqual(g.chat.messages.map(\.text), ["q1", "a1", "q2", "a2", "q3", "a3"])

        // A new turn goes live and gets STUCK mid-stream (no turn.completed —
        // the R11/R12 wedge left it running): recorded fixture frames replayed
        // byte-for-byte through the production pump, stopped mid-delta.
        _ = await g.chat.send(text: fx.submitText)
        deliver(g, fx, through: { self.kind($0) == "item.delta" })
        await waitUntil { g.chat.isStreaming }

        // Connection flap (IMG_2547 "Not connected" banner) → drop handler
        // finalizes the stream so the reconnect recovery backfill can run…
        g.chat.handleConnectionDrop()
        XCTAssertFalse(g.chat.isStreaming)

        // …and the reconnect backfill lands a SHORT snapshot: the mid-
        // conversation segment (q2/a2) is absent — the relay's snapshot is
        // partial, not a deletion list.
        g.chat.backfillFetch = { _ in Array(stored[0...1]) + Array(stored[4...5]) }
        await g.chat.backfill()

        // INVARIANT: zero segment loss — every cached row still renders, in
        // order, even though the snapshot did not carry it.
        assertRowsPresent(g.chat.messages.map(\.text), history, "R15/A8 short-snapshot reseed")

        // The stream resumes after the flap (relay resync replays the frames)
        // and the turn settles: history + prompt + reply, nothing dropped.
        deliverAll(g, fx)
        let agentText = try XCTUnwrap(fx.settled["agent_text"] as? String)
        await waitUntil { !g.chat.isStreaming && g.chat.messages.last?.text == agentText }
        assertRowsPresent(g.chat.messages.map(\.text), history, "R15/A8 post-resume settle")
        XCTAssertTrue(
            g.chat.messages.contains { $0.role == .user && $0.text == fx.submitText },
            "the stuck turn's user prompt survives the flap + reseed + resume"
        )
    }

    /// QA-2 R15 / A8 — TAIL-WINDOW SHIFT. Every reseed source on this tree is a
    /// recent-tail window (relay history honors `limit` with `messages[-limit:]`,
    /// downstream.py; plugin REST serves the 50-row tail): as the conversation
    /// grows, the window slides and a reseed EVICTS the older settled rows the
    /// user had already loaded. FAILS on qa2/base (rows 1–3 evicted by the
    /// 4–6 snapshot).
    func testReseed_TailWindowShiftKeepsOlderLoadedHistory() async throws {
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open("render-tail-window")
        g.sessions.activeStoredId = "render-tail-window"

        let history: [(role: String, text: String)] = [
            ("user", "q1"), ("assistant", "a1"),
            ("user", "q2"), ("assistant", "a2"),
            ("user", "q3"), ("assistant", "a3"),
        ]
        let stored = storedHistory(history)
        g.chat.seed(from: stored)

        // The reconnect/foreground backfill returns only the recent tail
        // (the window slid after newer turns settled on the gateway).
        g.chat.backfillFetch = { _ in Array(stored[3...5]) }
        await g.chat.backfill()

        let texts = g.chat.messages.map(\.text)
        assertRowsPresent(texts, history, "R15/A8 tail-window shift")
        XCTAssertEqual(texts.count, history.count,
                       "the overlapping window rows update in place — no duplicates, no eviction")
    }

    /// QA-2 R15 guard — the optimistic user echo (runtime id + clientMessageID,
    /// untagged) must CONVERGE with its own gateway row on a union reseed,
    /// never double-render. The reseed row adopts the echo's slot exactly like
    /// `adoptRelayEcho` folds the relay `userMessage` item onto it.
    func testReseed_OptimisticEchoConvergesWithItsGatewayRow() async throws {
        let fx = try loadFixture("render_submit_stream")
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open(fx.sessionID)
        g.sessions.activeStoredId = fx.sessionID

        _ = await g.chat.send(text: fx.submitText)
        deliverAll(g, fx)
        let agentText = try XCTUnwrap(fx.settled["agent_text"] as? String)
        await waitUntil { !g.chat.isStreaming && g.chat.messages.last?.text == agentText }

        // The gateway has persisted the turn; the backfill snapshot carries the
        // authoritative user + assistant rows under their WIRE ids — the echo's
        // runtime id never matches them.
        g.chat.backfillFetch = { _ in
            [
                StoredMessage(role: "user", content: .string(fx.submitText),
                              timestamp: 1_700_000_100, wireId: 100),
                StoredMessage(role: "assistant", content: .string(agentText),
                              timestamp: 1_700_000_101, wireId: 101),
            ]
        }
        await g.chat.backfill()

        let promptBubbles = g.chat.messages.filter { $0.role == .user && $0.text == fx.submitText }
        XCTAssertEqual(promptBubbles.count, 1,
                       "the optimistic echo adopts its gateway row's content in place — exactly one prompt bubble")
        XCTAssertTrue(g.chat.messages.contains { $0.text == agentText },
                      "the authoritative reply renders")
    }

    /// QA-2 R3 residue — the session-switch recovery path: switching away and
    /// back paints the FULL settled history from the cache INSTANTLY (the
    /// owner's repair path for R15; QA-1 B2's cache-first phase 1). PIN: green
    /// before and after the R15 fix — the cross-session cache paint replaces
    /// (session isolation), and paints everything the cache holds with zero
    /// relay frames.
    func testSessionSwitchAwayAndBack_RestoresFullHistoryFromCache() async throws {
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }

        // Session A: six settled rows painted from the cache.
        _ = try await g.coordinator.open("render-A")
        g.sessions.activeStoredId = "render-A"
        let historyA: [(role: String, text: String)] = [
            ("user", "qa1"), ("assistant", "aa1"),
            ("user", "qa2"), ("assistant", "aa2"),
            ("user", "qa3"), ("assistant", "aa3"),
        ]
        let storedA = storedHistory(historyA)
        g.chat.seed(from: storedA)

        // Away to B: the cross-session cache paint REPLACES (isolation) —
        // exactly the phase-1 default policy.
        _ = try await g.coordinator.open("render-B")
        g.sessions.activeStoredId = "render-B"
        g.chat.seed(from: storedHistory([("user", "qb1"), ("assistant", "ab1")]))
        XCTAssertEqual(g.chat.messages.map(\.text), ["qb1", "ab1"])

        // Back to A: the cache paint restores the FULL history immediately —
        // no relay frames, no network round-trip in the loop.
        _ = try await g.coordinator.open("render-A")
        g.sessions.activeStoredId = "render-A"
        g.chat.seed(from: storedA)
        XCTAssertEqual(g.chat.messages.map(\.text), historyA.map(\.text),
                       "switching back paints the entire cached transcript instantly (R3 residue / R15 recovery path)")
    }

    /// QA-2 R3 residue — the relay recovery backfill must run over the RELAY
    /// transport (the gateway REST socket is idle/unreachable in relay mode —
    /// a REST-only `backfill()` fails or hangs to the 15s timeout, so the
    /// post-flap reconcile never lands). FAILS on qa2/base
    /// (`resolvedBackfillFetch` resolves only `connection?.rest` — nil here →
    /// the backfill no-ops and the snapshot never seeds).
    func testBackfill_RelayTransportRunsOverRelayHistory() async throws {
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open("render-relay-backfill")
        g.sessions.activeStoredId = "render-relay-backfill"

        // The relay answers `history` with the gateway store rows (proxied
        // verbatim — the same shape `rest_history` returns downstream).
        g.transport.script = { upstream, relay in
            guard let id = upstream.id else { return }
            if upstream.method == "history" {
                relay.deliverResult(id: id, result: .object([
                    "session_id": .string("render-relay-backfill"),
                    "messages": .array([
                        .object(["role": .string("user"), "content": .string("rh-q1"),
                                 "timestamp": .number(1_700_000_000), "id": .number(1)]),
                        .object(["role": .string("assistant"), "content": .string("rh-a1"),
                                 "timestamp": .number(1_700_000_001), "id": .number(2)]),
                    ]),
                ]))
            } else {
                relay.deliverResult(id: id, result: .object(["ok": .bool(true)]))
            }
        }

        // NO `backfillFetch` injection: the store must resolve the relay
        // `history` RPC itself (the production relay wiring under test).
        await g.chat.backfill()

        let history = g.transport.upstreams().first { $0.method == "history" }
        XCTAssertNotNil(history, "the recovery backfill must travel over the relay transport in relay mode")
        XCTAssertEqual(history?.params["session_id"] as? String, "render-relay-backfill")
        XCTAssertEqual(g.chat.messages.map(\.text), ["rh-q1", "rh-a1"],
                       "the relay history rows seed the transcript over the up transport")
    }

    /// PIN (green on qa1/base — B15 regression guard): a cold-open transcript
    /// paints from the cache with ZERO relay frames, and the relay render
    /// store never drives the initial paint. Force-close recovery must keep
    /// working while the B4/B7 fixes land.
    func testColdCachePaint_WithZeroRelayFrames() async throws {
        let seeded = [
            ChatMessage(role: .user, text: "First question"),
            ChatMessage(role: .assistant, text: "First answer"),
            ChatMessage(role: .user, text: "Second question"),
            ChatMessage(role: .assistant, text: "Second answer"),
        ]
        let chat = ChatStore()
        chat.messages = seeded

        // Zero relay frames: the painted transcript is exactly the cache.
        XCTAssertEqual(chat.messages.map(\.text), seeded.map(\.text))
        XCTAssertFalse(chat.isStreaming)

        // And an empty render store projects nothing — the cold paint never
        // routes through the relay projection.
        var store = RelayItemStore()
        store.apply([] as [RelayFrame])
        XCTAssertTrue(store.items.isEmpty)
    }

    // MARK: - QA-3 S4/A2 — resync snapshot re-projection: single copy, strict order

    /// THE S4 DEVICE INCIDENT (IMG_2579-2582): the SAME exchange rendered in
    /// TWO orders at two scroll positions of one view. The relay session store
    /// accumulates ALL items; the 10:46-47 WS reconnect flap (relay.log opens
    /// at 10:46:31 + 10:47:18) re-delivered a snapshot covering turns the GRDB
    /// cache had already painted untagged. The merge consumed only the USER
    /// twins — every cache-painted ANSWER survived above the rebuilt prompts:
    /// an orphan answer preceding the prompt that asked it, plus a correct
    /// copy at the tail. Replayed from the recorded `render_submit_stream`
    /// turn + a hand-authored resync snapshot envelope in the same wire format
    /// (provenance: correlated to relay.log 10:47:19-10:49:02 `/messages`
    /// fetches bracketing the IMG_2579-2583 captures). FAILS on qa3/base.
    func testReplay_ResyncSnapshotNeverDuplicatesNorInvertsTimeline() async throws {
        let fx = try loadFixture("render_submit_stream")
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open(fx.sessionID)
        g.sessions.activeStoredId = fx.sessionID

        // Two settled turns painted the way the GRDB cache paints (wire ids).
        let cachedTurns: [(role: String, text: String)] = [
            ("user", "cq1"), ("assistant", "ca1"),
            ("user", "cq2"), ("assistant", "ca2"),
        ]
        g.chat.seed(from: storedHistory(cachedTurns))

        // The recorded live turn streams + settles below the cached history.
        _ = await g.chat.send(text: fx.submitText)
        // PRODUCTION IDENTITY REPLAY (same as testReplay_UserBubbleExactlyOnce…):
        // the live submit mints a fresh UUID cmid the static fixture cannot
        // know; re-stamp the echo with the fixture's recorded cmid so the
        // fixture's `userMessage` item adopts it — the identity chain
        // production establishes (downstream.py folds the SUBMIT cmid into
        // the synthesized item).
        if let cmid = fx.submitClientMessageID,
           let idx = g.chat.messages.firstIndex(where: {
               $0.role == .user && $0.text == fx.submitText && $0.clientMessageID != nil
           }) {
            let echo = g.chat.messages[idx]
            g.chat.messages[idx] = ChatMessage(
                id: echo.id, role: .user, clientMessageID: cmid,
                parts: echo.parts, timestamp: echo.timestamp
            )
        }
        deliverAll(g, fx)
        let agentText = try XCTUnwrap(fx.settled["agent_text"] as? String)
        await waitUntil { !g.chat.isStreaming && g.chat.messages.last?.text == agentText }

        // The reconnect resync re-delivers EVERY accumulated item — including
        // the two cache-painted turns — under the SAME item ids the store
        // already holds (the relay re-sends its accumulated items verbatim).
        var fixtureUserItemID = ""
        var fixtureAgentItemID = ""
        for frame in fx.frames where kind(frame) == "item.completed" {
            let body = frame["body"] as? [String: Any]
            let id = (body?["item_id"] as? String) ?? ""
            if itemType(frame) == "userMessage" { fixtureUserItemID = id }
            if itemType(frame) == "agentMessage" { fixtureAgentItemID = id }
        }
        func snapshotItem(_ id: String, _ type: String, _ ord: Int, _ text: String,
                          _ cmid: String? = nil) -> [String: Any] {
            var body: [String: Any] = ["text": text]
            if let cmid { body["client_message_id"] = cmid }
            return ["item_id": id, "type": type, "status": "completed",
                    "ord": ord, "body": body]
        }
        let snapshot: [String: Any] = [
            "seq": 900, "sid": fx.sessionID, "turn": NSNull(), "kind": "snapshot",
            "body": [
                "cursor": 900,
                "items": [
                    snapshotItem("snap-u1", "userMessage", 0, "cq1"),
                    snapshotItem("snap-a1", "agentMessage", 1, "ca1"),
                    snapshotItem("snap-u2", "userMessage", 2, "cq2"),
                    snapshotItem("snap-a2", "agentMessage", 3, "ca2"),
                    snapshotItem(fixtureUserItemID, "userMessage", 4, fx.submitText,
                                 fx.submitClientMessageID),
                    snapshotItem(fixtureAgentItemID, "agentMessage", 5, agentText),
                ],
            ],
        ]
        g.transport.deliver(frameText(snapshot))
        // Synchronize on the snapshot projection LANDING: the pump applies it
        // asynchronously, and the cached turns' rows flip from untagged to
        // relayProjected when the re-projection rebuilds them (pre-snapshot
        // they are the cache-painted untagged rows). Without this wait the
        // assertions race the pump and can pass on the PRE-snapshot state —
        // on qa3/base that masked the duplication (false green).
        await waitUntil {
            self.g_chat_messages(g).contains { $0.text == "cq1" && $0.relayProjected }
        }

        let texts = g.chat.messages.map(\.text)
        for text in ["cq1", "ca1", "cq2", "ca2", fx.submitText, agentText] {
            XCTAssertEqual(texts.filter({ $0 == text }).count, 1,
                           "S4/A2: exactly one copy of '\(text)' after the resync — pre-fix every answer doubled")
        }
        XCTAssertEqual(texts, ["cq1", "ca1", "cq2", "ca2", fx.submitText, agentText],
                       "S4/A2: strictly chronological — no orphan answer above its prompt (IMG_2579)")
        let promptIndex = texts.firstIndex(of: fx.submitText)!
        let answerIndex = texts.firstIndex(of: agentText)!
        XCTAssertLessThan(promptIndex, answerIndex,
                          "the answer NEVER renders before the prompt that asked it")
    }

    /// `waitUntil` cannot close over `g` in a sending context — tiny accessor.
    private func g_chat_messages(_ g: Graph) -> [ChatMessage] { g.chat.messages }

    // MARK: - QA-3 S6/A2 — the optimistic echo is durable across a session switch

    /// THE S6 DEVICE INCIDENT (IMG_2585/2591): a sent prompt vanished — working
    /// rows rendering with NO prompt above them. The optimistic echo existed
    /// only in the in-memory transcript; a session switch reseeded it away and
    /// nothing repainted it before the relay's next snapshot. The echo is now
    /// write-through persisted into the session-keyed warm snapshot, so a
    /// switch away and back repaints the prompt BEFORE any relay frame lands,
    /// and the `userMessage` adoption reconciles it into exactly one bubble.
    /// FAILS on qa3/base (the warm snapshot never carried the echo).
    func testReplay_EchoDurableAcrossSessionSwitchAndBack() async throws {
        UserDefaults.standard.set(
            DefaultsKeys.allProfilesScope, forKey: DefaultsKeys.activeProfile)
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        let cache = try await stageCacheFirstOpen(g)

        // Session A paints two settled rows from the disk cache.
        let rowsA = storedHistory([("user", "prior-q"), ("assistant", "prior-a")])
        try await cache.saveSessionList([qa3Summary("render-dur-A")], scope: CacheScope(
            serverId: Self.qa3ServerURL, profileId: DefaultsKeys.allProfilesScope))
        try await cache.saveTranscript(
            identity: try qa3CacheIdentity(g, "render-dur-A"), messages: rowsA)

        g.sessions.open(qa3Summary("render-dur-A"), bindRuntime: false)
        await g.sessions.waitForPendingOpenForTesting()
        XCTAssertEqual(g.chat.messages.map(\.text), ["prior-q", "prior-a"])

        // The user sends; the echo + optimistic bubble render instantly.
        _ = await g.chat.send(text: "durable?")
        await waitUntil {
            g.chat.messages.contains { $0.role == .user && $0.text == "durable?" }
        }
        let cmid = try XCTUnwrap(
            g.chat.messages.first { $0.text == "durable?" }?.clientMessageID)

        // Switch away to B (the transcript reseeds) — then back to A.
        g.sessions.open(qa3Summary("render-dur-B"), bindRuntime: false)
        await g.sessions.waitForPendingOpenForTesting()
        XCTAssertFalse(g.chat.messages.contains { $0.text == "durable?" },
                       "precondition: B's paint replaced the transcript")

        g.sessions.open(qa3Summary("render-dur-A"), bindRuntime: false)
        await g.sessions.waitForPendingOpenForTesting()

        // NO relay frame has re-landed yet — the prompt must repaint anyway.
        XCTAssertTrue(
            g.chat.messages.contains { $0.role == .user && $0.text == "durable?" },
            "S6/A2: the optimistic echo survives a session switch + store rebuild (repainted from the durable warm snapshot before any relay frame)")
        assertRowsPresent(g.chat.messages.map(\.text),
                          [("user", "prior-q"), ("assistant", "prior-a")],
                          "S6: settled history intact after the switch-back")

        // The relay's `userMessage` item lands: the echo reconciles in place —
        // exactly one bubble, the answer strictly after the prompt.
        g.transport.deliverFrames([
            userItemFrameLocal(1, id: "u-dur", ord: 0, text: "durable?",
                               clientMessageID: cmid, sid: "render-dur-A"),
            agentCompletedFrameLocal(2, id: "msg-dur", ord: 1, text: "still here.",
                                     sid: "render-dur-A"),
            RelayFrame(seq: 3, sid: "render-dur-A", turn: "t-dur", kind: .turnCompleted,
                       body: .object(["usage": .object([:])])),
        ])
        await waitUntil {
            g.chat.messages.filter { $0.text == "durable?" }.count == 1
                && g.chat.messages.contains { $0.text == "still here." }
        }
        let texts = g.chat.messages.map(\.text)
        XCTAssertEqual(texts.filter { $0 == "durable?" }.count, 1,
                       "echo + userMessage item = one bubble after reconcile")
        XCTAssertLessThan(texts.firstIndex(of: "durable?")!,
                          texts.firstIndex(of: "still here.")!,
                          "the answer never renders before its prompt")
    }

    // MARK: - QA-3 S7/A3 — scrollback never truncates to the cached window (void impossible)

    /// THE S7 DEVICE INCIDENT (IMG_2589/2590): scrolling up hit PURE VOID. A
    /// re-open of the ALREADY-ACTIVE session (a row re-tap, a notification
    /// deep-link) re-ran the first-frame cache paint, which `.replace`d the
    /// full in-memory transcript with the cached TAIL WINDOW (every cache
    /// source is a 50-row suffix) — the eager bottom-anchored VStack then
    /// rendered the surviving tail at the bottom with void above. The paint
    /// is now provenance-keyed: a same-session repaint skips phase 1 entirely
    /// (the in-memory transcript IS the truth; the phase-2 union reconciles
    /// deltas). FAILS on qa3/base (the 10 backward-paged rows are evicted).
    func testRepaint_SameSessionNeverTruncatesToCachedWindow() async throws {
        UserDefaults.standard.set(
            DefaultsKeys.allProfilesScope, forKey: DefaultsKeys.activeProfile)
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        let cache = try await stageCacheFirstOpen(g)
        try await cache.saveSessionList([qa3Summary("render-void", messageCount: 60)],
                                        scope: CacheScope(
                                            serverId: Self.qa3ServerURL,
                                            profileId: DefaultsKeys.allProfilesScope))

        // The disk cache holds 60 rows; the open window is the 50-row suffix.
        let rows: [StoredMessage] = (1...60).map { i in
            StoredMessage(role: i.isMultiple(of: 2) ? "assistant" : "user",
                          content: .string("m\(i)"),
                          timestamp: 1_700_000_000 + Double(i), wireId: i)
        }
        // Phase-2 network reconcile returns the SAME 50-row tail window the
        // cache holds (the realistic shape — an authoritative tail fetch),
        // so the paging cursor stays honest.
        g.sessions.transcriptFetchShaped = { _, _, _ in Array(rows[10...]) }
        try await cache.saveTranscript(
            identity: try qa3CacheIdentity(g, "render-void"), messages: rows)

        g.sessions.open(qa3Summary("render-void", messageCount: 60), bindRuntime: false)
        await g.sessions.waitForPendingOpenForTesting()
        XCTAssertEqual(g.chat.messages.count, 50, "the open window is the 50-row tail")
        XCTAssertTrue(g.chat.transcriptHasMoreBefore,
                      "the reader can page backward past the window")
        XCTAssertEqual(g.chat.messages.first?.text, "m11")

        // The reader pages backward: 10 older rows prepend (loadEarlierTranscript
        // does exactly `seed(normalized: older + messages)`).
        let older = ChatStore.toChatMessages(Array(rows[0..<10]))
        g.chat.seed(normalized: older + g.chat.messages)
        XCTAssertEqual(g.chat.messages.count, 60, "the full loaded transcript")

        // Re-tap the SAME session (deep-link / drawer re-tap).
        g.sessions.open(qa3Summary("render-void", messageCount: 60), bindRuntime: false)
        await g.sessions.waitForPendingOpenForTesting()

        XCTAssertEqual(g.chat.messages.count, 60,
                       "S7/A3: a same-session repaint must NEVER truncate the transcript to the cached window — the scrollback the reader loaded stays loaded (pre-fix: 50, void on scroll-up)")
        XCTAssertEqual(g.chat.messages.first?.text, "m1",
                       "the backward-paged head survives the repaint")
        XCTAssertEqual(g.chat.messages.last?.text, "m60",
                       "the tail is undisturbed")
    }

    // MARK: - QA-3 frame builders (sid-parameterized for the durability replay)

    private func userItemFrameLocal(
        _ seq: Int, id: String, ord: Int, text: String,
        clientMessageID: String?, sid: String
    ) -> RelayFrame {
        var body: [String: JSONValue] = ["text": .string(text)]
        if let clientMessageID { body["client_message_id"] = .string(clientMessageID) }
        return RelayFrame(seq: seq, sid: sid, turn: "t-dur", kind: .itemCompleted,
                          body: .object([
                            "item_id": .string(id),
                            "type": .string(ChatItemType.userMessage.rawValue),
                            "status": .string("completed"),
                            "ord": .number(Double(ord)),
                            "body": .object(body),
                          ]))
    }

    private func agentCompletedFrameLocal(
        _ seq: Int, id: String, ord: Int, text: String, sid: String
    ) -> RelayFrame {
        RelayFrame(seq: seq, sid: sid, turn: "t-dur", kind: .itemCompleted,
                   body: .object([
                    "item_id": .string(id),
                    "type": .string(ChatItemType.agentMessage.rawValue),
                    "status": .string("completed"),
                    "ord": .number(Double(ord)),
                    "body": .object(["text": .string(text)]),
                   ]))
    }

    // MARK: - QA-2 R4/A2 — instant working mode; Working-pill state deleted

    /// R4/A2: send enters working mode IMMEDIATELY — an optimistic empty
    /// streaming assistant bubble (the breathing caret) renders the instant the
    /// user commits, independent of any relay frame, and `isStreaming` (which
    /// gates the composer's stop button) is true from send. FAILS on qa2/base
    /// (the send appends nothing; the first frame's projection decides).
    func testRelaySend_InstantWorkingAffordance_OptimisticCaretBubble() async throws {
        let fx = try loadFixture("render_submit_stream")
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open(fx.sessionID)

        let ok = await g.chat.send(text: fx.submitText)
        XCTAssertTrue(ok)

        // NO frames delivered — the affordance is local or nowhere.
        XCTAssertTrue(g.chat.isStreaming,
            "spec R4/A2: send → working mode instantly (stop button available)")
        let last = try XCTUnwrap(g.chat.messages.last)
        XCTAssertEqual(last.role, .assistant,
            "spec R4: send appends an optimistic empty streaming assistant bubble")
        XCTAssertTrue(last.isStreaming)
        XCTAssertTrue(last.parts.isEmpty, "the caret bubble is empty until the first delta")
    }

    /// R4/A2: the relay's synthesized TERMINAL `userMessage` first frame must
    /// NOT settle the turn — streaming is turn-scoped (until `turn.completed`),
    /// and the caret bubble persists through the accepted-and-waiting window.
    /// FAILS on qa2/base (`nowStreaming = rebuilt.contains { $0.isStreaming }`
    /// → false → the bar + stop + cursor die for the entire wait window; fast
    /// turns showed no affordance at all).
    func testRelaySend_TerminalUserMessageFrameKeepsTurnStreaming() async throws {
        let fx = try loadFixture("render_submit_stream")
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open(fx.sessionID)

        _ = await g.chat.send(text: fx.submitText)
        deliver(g, fx, through: {
            self.kind($0) == "item.completed" && self.itemType($0) == "userMessage"
        })
        await waitUntil { g.chat.messages.contains { $0.role == .user && $0.text == fx.submitText } }

        XCTAssertTrue(g.chat.isStreaming,
            "spec R4/A2: a terminal userMessage item must not settle a turn-scoped streaming turn")
        XCTAssertTrue(g.chat.messages.contains {
            $0.role == .assistant && $0.isStreaming && $0.parts.isEmpty
        }, "spec R4: the caret bubble survives the terminal userMessage frame")
    }

    /// A2: the Working pill is IMPOSSIBLE on the relay path — in EVERY phase,
    /// including the pre-first-item window the QA-1 B8 clause still showed it
    /// for. That clause (the last state that could flash the pill on relay) is
    /// deleted; the optimistic caret bubble is the pre-first-item affordance.
    /// FAILS on qa2/base (the pre-first-item branch returned `true`).
    func testRelaySend_WorkingPillImpossiblePreFirstItem() async throws {
        let fx = try loadFixture("render_submit_stream")
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open(fx.sessionID)
        g.chat.messages = cachedRows(fx)
        _ = await g.chat.send(text: fx.submitText)

        // Pre-first-item: no relay frame yet; the painted tail is the user echo.
        let last = try XCTUnwrap(g.chat.messages.last(where: { $0.role == .user }))
        XCTAssertEqual(last.text, fx.submitText)
        XCTAssertFalse(
            ChatView.shouldShowInlineTurnActivity(
                isStreaming: true,
                hasPendingGate: false,
                isRelayTransport: true,
                lastMessage: last
            ),
            "spec A2: the relay Working pill is impossible — even pre-first-item (state deleted, not hidden)"
        )
    }

    // MARK: - QA-2 R5/R6/A3 — single collapsed live working line

    /// A3: a live turn with reasoning + tool work projects EXACTLY ONE
    /// assistant row, folding to EXACTLY ONE `.working` node — never the
    /// build-115 stack (inline thinking rows + separate current-tool row +
    /// standalone cursor = 3-4 rows, IMG_2532/2545/2546). The single collapsed
    /// line's label never surfaces the raw pre-resolution tool state (N2).
    func testReplay_LiveTurnExactlyOneWorkingNode() async throws {
        let fx = try loadFixture("render_live_fold")
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open(fx.sessionID)
        _ = await g.chat.send(text: fx.submitText)

        // Through the raw-name tool start: reasoning done, tool in progress,
        // NO agent item yet — the accepted-and-waiting + working window.
        deliver(g, fx, through: {
            self.kind($0) == "item.started" && self.itemType($0) == "tool.generating"
        })
        // Wait for the REAL projection (the optimistic bubble also matches
        // `isStreaming` with EMPTY parts — require parts so a frame-processing
        // hop can't race the assertion).
        await waitUntil { g.chat.messages.contains {
            $0.role == .assistant && $0.isStreaming && !$0.parts.isEmpty
        } }

        XCTAssertTrue(g.chat.isStreaming, "the live turn is streaming (turn-scoped)")
        let live = try XCTUnwrap(
            g.chat.messages.first { $0.role == .assistant && $0.isStreaming && !$0.parts.isEmpty },
            "spec A3: the live turn renders as a streaming assistant row"
        )
        let nodes = WorkingSectionModel.renderNodes(from: live.parts)
        XCTAssertEqual(nodes.count, 1,
            "spec A3: the live turn folds to a SINGLE working node (no stacked rows)")
        guard let only = nodes.first, case .working = only else {
            return XCTFail("spec A3: the single node is the working fold")
        }
        XCTAssertEqual(WorkingSectionModel.liveCollapsedLabel(parts: live.parts), "Working…",
            "spec R5/N2: the raw 'tool.generating' state reads as plain 'Working…' — never the raw token")
    }

    /// A3: once the tool resolves a friendly summary, the single collapsed line
    /// carries it inline — "Working… · ‹current tool›" (ratified Wave-2.5).
    func testReplay_LiveTurnResolvesFriendlyToolInline() async throws {
        let fx = try loadFixture("render_live_fold")
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open(fx.sessionID)
        _ = await g.chat.send(text: fx.submitText)

        // Through the agentMessage start (the tool completed friendly just
        // before it — deltas carry no type, so stop on the agent item.started,
        // NOT the first delta, which is the reasoning delta).
        deliver(g, fx, through: {
            self.kind($0) == "item.started" && self.itemType($0) == "agentMessage"
        })
        await waitUntil { g.chat.messages.contains {
            $0.role == .assistant && !$0.parts.isEmpty && $0.isStreaming
        } }

        let live = try XCTUnwrap(g.chat.messages.first {
            $0.role == .assistant && !$0.parts.isEmpty && $0.isStreaming
        })
        let label = WorkingSectionModel.liveCollapsedLabel(parts: live.parts)
        XCTAssertEqual(label, "Working… · Asked which direction to take",
            "spec R5/A3: the resolved tool rides inline on the single Working line")
        XCTAssertFalse(label.contains("."), "no raw dotted state token in the label")
    }

    /// N2: `liveCollapsedLabel` NEVER renders a raw internal state name —
    /// `tool.generating` / `review.summary` read as plain "Working…" until the
    /// tool resolves (deterministic unit pin, no replay).
    func testLiveCollapsedLabel_NeverRawStateNames() {
        let raw = ChatItem(itemID: "t1", type: ChatItemType(wire: "tool.generating"),
                           rawType: "tool.generating", status: .inProgress, ord: 1,
                           summary: "tool.generating", body: .null)
        XCTAssertEqual(
            WorkingSectionModel.liveCollapsedLabel(parts: [.item(id: "t1", item: raw)]),
            "Working…",
            "a raw pre-resolution tool state must read as plain Working…"
        )
        XCTAssertTrue(WorkingSectionModel.isRawStateName("tool.generating"))
        XCTAssertTrue(WorkingSectionModel.isRawStateName("review.summary"))
        XCTAssertFalse(WorkingSectionModel.isRawStateName("clarify"))
        XCTAssertFalse(WorkingSectionModel.isRawStateName("Read auth.py"))

        let friendly = ChatItem(itemID: "t2", type: .toolCall, status: .inProgress, ord: 1,
                                body: ["name": "read", "args": ["path": "auth.py"]])
        XCTAssertEqual(
            WorkingSectionModel.liveCollapsedLabel(parts: [.item(id: "t2", item: friendly)]),
            "Working… · Read auth.py",
            "a humanized tool name rides inline on the collapsed live line"
        )

        // A friendly SUMMARY over a still-raw wire name is trusted.
        let resolved = ChatItem(itemID: "t3", type: ChatItemType(wire: "clarify"),
                                rawType: "clarify", status: .inProgress, ord: 1,
                                summary: "Asked which direction to take", body: .null)
        XCTAssertEqual(
            WorkingSectionModel.liveCollapsedLabel(parts: [.item(id: "t3", item: resolved)]),
            "Working… · Asked which direction to take"
        )
    }

    /// A3 layout: the LIVE working section renders as ONE line — its measured
    /// height is a single row (≈32pt), never the build-115 reserved 172pt
    /// thinking window + stacked rows (the R6 bands of IMG_2533/2538/2542).
    /// FAILS on qa2/base (the live branch mounted a 172pt ThinkingView).
    @MainActor
    func testLiveWorkingSection_RendersOneLineLayout() throws {
        let raw = ChatItem(itemID: "t1", type: ChatItemType(wire: "tool.generating"),
                           rawType: "tool.generating", status: .inProgress, ord: 1,
                           summary: "tool.generating", body: .null)
        let parts: [ChatMessagePart] = [
            .reasoning(id: "r1", text: "I need to create a clarification card with four options, where each option is meaningful."),
            .item(id: "t1", item: raw),
        ]
        let renderer = ImageRenderer(content:
            WorkingSectionView(parts: parts, streaming: true,
                               liveTurnStartedAt: Date(), settledDuration: nil)
                .frame(width: 360)
                .environment(\.hermesTheme, HermesThemePresets.nousLight)
        )
        renderer.scale = 2
        let height = try XCTUnwrap(renderer.uiImage?.size.height,
            "the live working section must render")
        XCTAssertLessThan(height, 60,
            "spec A3/R6: the live working section is ONE line — no 172pt thinking window, no stacked rows (measured \(height)pt)")
    }

    /// R5/A3: a settled relay turn stamps its per-TURN wall-clock duration so
    /// the row reads "Worked for Ns" (build 115: a bare "Worked" — relay items
    /// carry no timestamps and the projection never stamped one; IMG_2532).
    /// FAILS on qa2/base (`reasoningElapsed` never set on relay rows).
    func testReplay_SettledRelayTurnStampsDuration() async throws {
        let fx = try loadFixture("render_live_fold")
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open(fx.sessionID)
        g.chat.messages = cachedRows(fx)
        _ = await g.chat.send(text: fx.submitText)
        deliverAll(g, fx)

        let agentText = try XCTUnwrap(fx.settled["agent_text"] as? String)
        await waitUntil { !g.chat.isStreaming && g.chat.messages.last?.text == agentText }

        let settledRow = try XCTUnwrap(
            g.chat.messages.first { $0.role == .assistant && $0.text == agentText })
        XCTAssertNotNil(settledRow.reasoningElapsed,
            "spec R5/A3: the settle edge stamps the turn's wall-clock duration on the relay row")
        XCTAssertNotEqual(
            WorkingSectionModel.workedLabel(seconds: settledRow.reasoningElapsed), "Worked",
            "spec R5: the settled relay row reads 'Worked for Ns', never a bare 'Worked'"
        )
    }

    /// R5: the stamped duration SURVIVES later re-projections — the projection
    /// rebuilds every tagged row from the (session-accumulating) item store on
    /// every pass, so the second turn's first frame must not strip the first
    /// turn's "Worked for Ns". FAILS on qa2/base (never stamped at all).
    func testReplay_SettledDurationSurvivesSecondTurnReprojection() async throws {
        let fx = try loadFixture("render_live_fold")
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open(fx.sessionID)
        _ = await g.chat.send(text: fx.submitText)
        deliverAll(g, fx)
        let agentText = try XCTUnwrap(fx.settled["agent_text"] as? String)
        await waitUntil { !g.chat.isStreaming && g.chat.messages.last?.text == agentText }

        // Second turn begins: send + its terminal userMessage frame (seq 14,
        // dense after the fixture's 13) re-projects the WHOLE session timeline.
        _ = await g.chat.send(text: "Second prompt.")
        let secondUserFrame: [String: Any] = [
            "seq": 14, "sid": fx.sessionID, "turn": NSNull(),
            "kind": "item.completed",
            "body": [
                "item_id": "render-sess-fold:u-2",
                "type": "userMessage",
                "status": "completed",
                "ord": 5,
                "body": ["text": "Second prompt.", "client_message_id": "render-cmid-fold-2"],
            ],
        ]
        g.transport.deliver(frameText(secondUserFrame))
        await waitUntil { g.chat.messages.contains { $0.role == .user && $0.text == "Second prompt." } }

        let firstTurnRow = try XCTUnwrap(
            g.chat.messages.first { $0.role == .assistant && $0.text == agentText })
        XCTAssertNotNil(firstTurnRow.reasoningElapsed,
            "spec R5: a later turn's re-projection must not strip the settled turn's stamped duration")
    }

    // MARK: - QA-3 S1/S2/S3 — ONE merged breathing-cursor working line (A1/A10)

    /// Whether any part is an answer-text part (the phase-C boundary; mirrors
    /// `MessageBubble`'s private `lastTextPartID` scan for test purposes).
    private func hasTextPart(_ parts: [ChatMessagePart]) -> Bool {
        parts.contains { if case .text = $0 { return true }; return false }
    }

    /// S2/A1 flagship — the labeled+timed working affordance appears ON SEND,
    /// driven by LOCAL send state, with ALL relay frames held for 10 s (the
    /// device saw ~35 s: build 116's line was gated on the first relay item
    /// frame — IMG_2578 appeared already reading 35 s). ONE affordance in every
    /// phase (S3): the merged line at send (zero parts), the SAME line updated
    /// when work items land, the fold beside the prose once the answer flows,
    /// and nothing once settled. The per-turn timer starts locally at send and
    /// keeps ticking through the whole frame blackout.
    func testRelaySend_MergedWorkingLine_FramesDelayed10s() async throws {
        let fx = try loadFixture("render_live_fold")
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        // HOLD the submit ack: zero downstream traffic for the whole blackout
        // (the 10 s frame delay of spec A1 — unbounded in principle; frames
        // never arrive until this test releases them).
        g.transport.script = { upstream, relay in
            guard let id = upstream.id else { return }
            if upstream.method == "submit" { return }   // answered after the blackout
            relay.deliverResult(id: id, result: .object(["ok": .bool(true)]))
        }
        _ = try await g.coordinator.open(fx.sessionID)

        let t0 = ContinuousClock.now
        let sendTask = Task { await g.chat.send(text: fx.submitText) }
        // ≤100 ms from send: the affordance is up off LOCAL state — no frame
        // has been answered, let alone delivered.
        await waitUntil(timeout: .milliseconds(100)) {
            g.chat.isStreaming && g.chat.messages.last?.role == .assistant
        }
        let appearedIn = ContinuousClock.now - t0
        XCTAssertLessThanOrEqual(appearedIn, .milliseconds(100),
            "spec S2/A1: the working affordance appears ≤100 ms from send (local state)")

        let bubble = try XCTUnwrap(g.chat.messages.last)
        XCTAssertEqual(bubble.role, .assistant)
        XCTAssertTrue(bubble.isStreaming)
        XCTAssertTrue(bubble.parts.isEmpty, "zero relay frames have landed")
        XCTAssertNotNil(g.chat.turnStartedAt,
            "spec S2/A1: the per-turn timer starts LOCALLY at send")
        XCTAssertTrue(
            MessageBubble.showsStandaloneWorkingLine(
                isStreaming: true, liveTurnActive: true, parts: []),
            "the merged line renders at send with zero parts")
        XCTAssertEqual(
            MessageBubble.workingAffordanceCount(
                isStreaming: true, liveTurnActive: true, parts: []),
            1, "spec S3/A1: exactly ONE working affordance pre-first-frame")
        XCTAssertEqual(WorkingSectionModel.liveCollapsedLabel(parts: []), "Working…",
            "the pre-frame line already carries the inline status word")

        // THE 10 s FRAME BLACKOUT: the affordance holds, the timer ticks locally.
        try? await Task.sleep(for: .seconds(10))
        let midParts = g.chat.messages.last?.parts ?? []
        XCTAssertEqual(
            MessageBubble.workingAffordanceCount(
                isStreaming: g.chat.isStreaming, liveTurnActive: true, parts: midParts),
            1, "spec S3/A1: still exactly one working affordance after 10 s of silence")
        let elapsed = ThinkingDisplay.elapsedText(startedAt: g.chat.turnStartedAt, now: Date())
        let elapsedSecs = Int(String(elapsed.prefix(while: \.isNumber))) ?? 0
        XCTAssertGreaterThanOrEqual(elapsedSecs, 9,
            "spec S2/A1: the per-turn timer ran locally through the whole blackout (read '\(elapsed)')")

        // Release the submit ack (still no downstream frames) — send completes.
        let submitID = try XCTUnwrap(
            g.transport.upstreams().first { $0.method == "submit" }?.id)
        g.transport.deliverResult(id: submitID,
                                   result: .object(["session_id": .string(fx.sessionID)]))
        let sent = await sendTask.value
        XCTAssertTrue(sent, "the delayed submit resolves")

        // PHASE B — first work items land: the fold IS the cursor line now;
        // item arrival only updates the status text, never mounts a second
        // surface (S3: build 116 stacked the spinner line + a bare caret).
        deliver(g, fx, through: {
            self.kind($0) == "item.started" && self.itemType($0) == "tool.generating"
        })
        await waitUntil { g.chat.messages.contains {
            $0.role == .assistant && $0.isStreaming && !$0.parts.isEmpty
        } }
        let live = try XCTUnwrap(g.chat.messages.first {
            $0.role == .assistant && $0.isStreaming && !$0.parts.isEmpty
        })
        XCTAssertFalse(hasTextPart(live.parts), "phase B: work parts, no answer text yet")
        XCTAssertEqual(
            MessageBubble.workingAffordanceCount(
                isStreaming: true, liveTurnActive: true, parts: live.parts),
            1, "spec S3/A1: one merged line in phase B — no stacked caret")
        XCTAssertEqual(WorkingSectionModel.liveCollapsedLabel(parts: live.parts), "Working…",
            "the raw pre-resolution tool state still reads plain 'Working…' (N2)")

        // PHASE C — the answer starts flowing: the fold keeps status + timer
        // beside the prose; the prose-tail caret owns the pulse. Still one
        // working surface.
        deliver(g, fx, through: {
            self.kind($0) == "item.started" && self.itemType($0) == "agentMessage"
        })
        await waitUntil { g.chat.messages.contains {
            $0.role == .assistant && self.hasTextPart($0.parts)
        } }
        let flowing = try XCTUnwrap(g.chat.messages.first {
            $0.role == .assistant && self.hasTextPart($0.parts)
        })
        XCTAssertFalse(
            MessageBubble.showsStandaloneWorkingLine(
                isStreaming: true, liveTurnActive: true, parts: flowing.parts),
            "phase C: the standalone merged line yields to the ForEach fold + prose caret")
        XCTAssertEqual(
            MessageBubble.workingAffordanceCount(
                isStreaming: true, liveTurnActive: true, parts: flowing.parts),
            1, "spec S3/A1: one working surface in phase C")

        // SETTLED — no working affordance; the fold reads "Worked for Ns".
        deliverAll(g, fx)
        let agentText = try XCTUnwrap(fx.settled["agent_text"] as? String)
        await waitUntil { !g.chat.isStreaming && g.chat.messages.last?.text == agentText }
        let settled = try XCTUnwrap(
            g.chat.messages.first { $0.role == .assistant && $0.text == agentText })
        XCTAssertEqual(
            MessageBubble.workingAffordanceCount(
                isStreaming: false, liveTurnActive: false, parts: settled.parts),
            0, "settled: zero working affordances")
    }

    /// S3/A1 — the one-affordance contract across EVERY phase (pure pin of the
    /// `MessageBubble` render decision). Build 116 rendered TWO surfaces in
    /// phase B (the fold's spinner line + the standalone bare caret —
    /// IMG_2578/2587/2591); the merged line makes two unreachable.
    func testWorkingAffordance_ExactlyOneSurfaceAcrossAllPhases() {
        let reasoning = ChatMessagePart.reasoning(id: "r1", text: "Thinking about it.")
        let tool = ChatMessagePart.item(id: "t1", item: ChatItem(
            itemID: "t1", type: .toolCall, status: .inProgress, ord: 1,
            body: ["name": "read", "args": ["path": "auth.py"]]))
        let text = ChatMessagePart.text(id: "x1", text: "The answer is…")
        let phaseB: [ChatMessagePart] = [reasoning, tool]
        let phaseC: [ChatMessagePart] = [reasoning, tool, text]

        // Phase A — send → first frame: zero parts, the merged line renders.
        XCTAssertTrue(MessageBubble.showsStandaloneWorkingLine(
            isStreaming: true, liveTurnActive: true, parts: []))
        XCTAssertEqual(MessageBubble.workingAffordanceCount(
            isStreaming: true, liveTurnActive: true, parts: []), 1)

        // Phase B — work parts, no answer text: still exactly ONE surface.
        XCTAssertTrue(MessageBubble.showsStandaloneWorkingLine(
            isStreaming: true, liveTurnActive: true, parts: phaseB),
            "the merged line carries the work parts (the fold IS the cursor line)")
        XCTAssertEqual(MessageBubble.workingAffordanceCount(
            isStreaming: true, liveTurnActive: true, parts: phaseB), 1,
            "spec S3: phase B is one surface — build 116 rendered two")

        // Phase C — answer text flows: the fold rides beside the prose.
        XCTAssertFalse(MessageBubble.showsStandaloneWorkingLine(
            isStreaming: true, liveTurnActive: true, parts: phaseC))
        XCTAssertEqual(MessageBubble.workingAffordanceCount(
            isStreaming: true, liveTurnActive: true, parts: phaseC), 1)

        // A pure-text live turn: the prose-tail caret is the only signal —
        // zero working LINES (the caret is the text's insertion point).
        XCTAssertEqual(MessageBubble.workingAffordanceCount(
            isStreaming: true, liveTurnActive: true, parts: [text]), 0)

        // Settled: zero working affordances in every shape.
        for parts in [[], phaseB, phaseC, [text]] as [[ChatMessagePart]] {
            XCTAssertEqual(MessageBubble.workingAffordanceCount(
                isStreaming: false, liveTurnActive: false, parts: parts), 0)
        }
    }

    /// S2/S3/A1 render proof (fail-before/pass-after — compiles + FAILS on
    /// qa3/base): the optimistic caret bubble (phase A, zero parts) and the
    /// first-item bubble (phase B, work parts) render the SAME single line —
    /// item arrival updates the status text, it does not grow a second row.
    /// Build 116 rendered a bare ~22 pt glyph at A and a STACKED spinner line
    /// + bare caret (~64 pt) at B; the merged line is one ~32 pt row in both.
    @MainActor
    func testMergedLine_PhaseAAndBRenderOneSurface() throws {
        // `MessageBubble` reads the stores off the environment — supply a
        // disconnected graph (the geometry never touches the socket).
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)

        func bubbleHeight(_ message: ChatMessage) throws -> CGFloat {
            let renderer = ImageRenderer(content:
                MessageBubble(
                    message: message,
                    liveTurnStartedAt: Date(),
                    liveTurnActive: true
                )
                .frame(width: 360)
                .environment(\.hermesTheme, HermesThemePresets.nousLight)
                .environment(connection)
                .environment(sessions)
                .environment(chat)
            )
            renderer.scale = 2
            return try XCTUnwrap(renderer.uiImage?.size.height,
                "the streaming bubble must render")
        }

        // Phase A: the optimistic empty streaming bubble exactly as `send`
        // appends it (zero parts, frames delayed).
        let phaseA = ChatMessage(id: UUID(), role: .assistant,
                                 isStreaming: true, relayProjected: true)
        // Phase B: the same bubble once reasoning + a tool item have landed.
        let phaseB = ChatMessage(id: UUID(), role: .assistant, parts: [
            .reasoning(id: "r1", text: "Thinking about it."),
            .item(id: "t1", item: ChatItem(
                itemID: "t1", type: .toolCall, status: .inProgress, ord: 1,
                body: ["name": "read", "args": ["path": "auth.py"]])),
        ], isStreaming: true, relayProjected: true)

        let heightA = try bubbleHeight(phaseA)
        let heightB = try bubbleHeight(phaseB)
        print("=== QA-3 S2/S3 merged working line: phaseA=\(heightA)pt phaseB=\(heightB)pt (build 116: bare glyph ≈22pt → spinner line + caret ≈64pt) ===")

        XCTAssertLessThan(heightB, 50,
            "spec S3/A1: phase B is ONE line — build 116 stacked the spinner line + the bare caret (≈64 pt; IMG_2578)")
        XCTAssertEqual(heightA, heightB, accuracy: 8,
            "spec S2/S3: the affordance at send and after first items is the SAME single line — item arrival only updates the status text, never mounts a second surface")
        XCTAssertGreaterThan(heightA, 26,
            "spec S2/A1: the send-time affordance is the labeled+timer line, not a bare textless glyph")
    }

    /// S1/A10 render proof (fail-before/pass-after — compiles + FAILS on
    /// qa3/base): the streaming cursor's breathe is a pure function of
    /// wall-clock time, so two renders 350 ms apart (~0.3 of the 1.2 s breathe
    /// period) differ. Build 116's `@State` + `onAppear` repeatForever pulse
    /// rendered a STEADY glyph off-screen (the animation only runs inside a
    /// live SwiftUI transaction; any row remount stranded it static — the
    /// motionless bar of IMG_2577/2585/2587).
    @MainActor
    func testStreamingCursor_PulseNeverStrandedStatic() throws {
        func cursorPNG() throws -> Data {
            let renderer = ImageRenderer(content:
                StreamingCursor(isStreaming: true)
                    .environment(\.hermesTheme, HermesThemePresets.nousLight)
            )
            renderer.scale = 2
            return try XCTUnwrap(renderer.uiImage?.pngData(),
                "the streaming cursor must render")
        }
        let first = try cursorPNG()
        Thread.sleep(forTimeInterval: 0.35)   // ~0.29 of the 1.2 s breathe period
        let second = try cursorPNG()
        XCTAssertNotEqual(first, second,
            "spec S1/A10: the cursor breathes off wall-clock time — a remount can never strand it static (build 116's @State pulse rendered steady here)")
    }

    /// S1/A10 — the breathe curve itself (pure, deterministic): the approved
    /// StreamingCursor spec — soft opacity 1.0 → 0.25, 1.2 s period, steady
    /// full opacity settled or under Reduce Motion.
    func testCursorBreathe_SoftOpacityCurve() {
        // Settled / Reduce Motion: steady full opacity (honest presence).
        XCTAssertEqual(CursorBreathe.opacity(at: Date(), streaming: false), 1.0)
        XCTAssertEqual(CursorBreathe.opacity(at: Date(), reduceMotion: true), 1.0)

        // Phase 0 (period boundary): the 1.0 peak.
        let peak = Date(timeIntervalSinceReferenceDate: CursorBreathe.period * 100)
        XCTAssertEqual(CursorBreathe.opacity(at: peak), 1.0, accuracy: 1e-9)
        // Phase 0.5: the 0.25 trough.
        let trough = Date(timeIntervalSinceReferenceDate: CursorBreathe.period * 100
                          + CursorBreathe.period / 2)
        XCTAssertEqual(CursorBreathe.opacity(at: trough), CursorBreathe.minOpacity,
                       accuracy: 1e-9)
        XCTAssertEqual(CursorBreathe.minOpacity, 0.25, "the ratified trough")
        XCTAssertEqual(CursorBreathe.period, 1.2,
                       "the ratified period (easeInOut 0.6 s × 2 autoreverse)")

        // Bounded + periodic everywhere.
        var t = Date(timeIntervalSinceReferenceDate: 0)
        for _ in 0..<240 {
            let o = CursorBreathe.opacity(at: t)
            XCTAssertGreaterThanOrEqual(o, 0.25)
            XCTAssertLessThanOrEqual(o, 1.0)
            XCTAssertEqual(o, CursorBreathe.opacity(
                at: Date(timeIntervalSinceReferenceDate:
                    t.timeIntervalSinceReferenceDate + CursorBreathe.period)),
                accuracy: 1e-9)
            t = Date(timeIntervalSinceReferenceDate: t.timeIntervalSinceReferenceDate + 0.05)
        }
    }

    /// S2/A1 — SETTLE RECONCILIATION: the per-turn timer starts locally at
    /// send and reconciles to the relay's authoritative `turn.completed`
    /// `duration_s`. FAILS on qa3/base (the frame's `duration_s` was ignored;
    /// the settled label read the phone's own ~0 s measurement).
    func testReplay_SettledDurationReconcilesToServerTurnTime() async throws {
        let fx = try loadFixture("render_live_fold")
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open(fx.sessionID)
        _ = await g.chat.send(text: fx.submitText)

        // Through the last item (usage) — stop BEFORE the fixture's own
        // turn.completed so the settle rides a hand-crafted one carrying the
        // relay's authoritative duration.
        deliver(g, fx, through: {
            self.kind($0) == "item.completed" && self.itemType($0) == "usage"
        })
        let settleFrame: [String: Any] = [
            "seq": 13, "sid": fx.sessionID, "turn": NSNull(),
            "kind": "turn.completed",
            "body": ["usage": [String: Any](), "duration_s": 42.0,
                     "started_at": 1_700_000_000.0],
        ]
        g.transport.deliver(frameText(settleFrame))

        let agentText = try XCTUnwrap(fx.settled["agent_text"] as? String)
        await waitUntil { !g.chat.isStreaming && g.chat.messages.last?.text == agentText }
        let settledRow = try XCTUnwrap(
            g.chat.messages.first { $0.role == .assistant && $0.text == agentText })
        let stamped = try XCTUnwrap(settledRow.reasoningElapsed,
            "the settle edge stamps the turn duration")
        XCTAssertEqual(stamped, 42.0, accuracy: 0.001,
            "spec S2/A1: the settled duration reconciles to the relay's turn.completed duration_s — not the phone's local measurement")
        XCTAssertEqual(WorkingSectionModel.workedLabel(seconds: stamped), "Worked for 42s")
    }

    // MARK: - QA-3 renderjury-lane pins (retained at integration)
    // The renderjury lane pinned the SAME single-affordance contract (A1/A10)
    // through its own seams (`WorkingSectionModel.preItemWorkingLineVisible`,
    // fold geometry, the fixture-loader shape contract). Kept alongside the
    // working lane's `showsStandaloneWorkingLine` pins — complementary coverage,
    // both green on the merged architecture.

    // MARK: - QA-3 S2/S3/S1 — the single merged breathing-cursor working line

    /// S2/A1: send → the SINGLE merged working affordance (breathing cursor +
    /// inline "Working…" status + per-turn timer) renders from LOCAL send state
    /// with ZERO relay frames delivered — an INFINITE artificial delay, the
    /// spec's "frames delayed 10 s" made stronger. Build 116 showed only a bare
    /// textless cursor here; the labeled, timed affordance waited for the
    /// model's first item (~35 s in IMG_2578 — the owner's "working appeared
    /// ~35s after send"). FAILS on qa3/base (the pre-item slot rendered a bare
    /// `StreamingCursor` — no label, no timer, no seam).
    func testRelaySend_MergedWorkingAffordanceBeforeAnyFrame() async throws {
        let fx = try loadFixture("render_qa3_delayed_start")
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open(fx.sessionID)

        let ok = await g.chat.send(text: fx.submitText)
        XCTAssertTrue(ok)

        // NO frames delivered — the affordance is local or nowhere.
        let startedAt = try XCTUnwrap(g.chat.turnStartedAt,
            "spec S2/A1: the per-turn timer starts LOCALLY at send")
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 5,
            "the timer start is the send instant, not a later frame")
        XCTAssertTrue(g.chat.isStreaming, "send → working mode (stop button live)")

        // The optimistic caret bubble is the live row — empty parts, streaming.
        let live = try XCTUnwrap(g.chat.messages.last)
        XCTAssertEqual(live.role, .assistant)
        XCTAssertTrue(live.isStreaming)
        XCTAssertTrue(live.parts.isEmpty, "zero parts until the first frame")

        // The caret slot renders the MERGED line (the S2 fix), and its label is
        // the honest pre-first-item status with the timer from the local start.
        XCTAssertTrue(
            WorkingSectionModel.preItemWorkingLineVisible(parts: live.parts, streamingLive: true),
            "spec S2/A1: send → the merged labeled+timed working line, no frames required"
        )
        XCTAssertEqual(WorkingSectionModel.liveCollapsedLabel(parts: live.parts), "Working…")

        // The merged line renders as ONE line (glyph + status + timer), height
        // of a single chrome-less row — never a stacked/boxed surface.
        let renderer = ImageRenderer(content:
            WorkingSectionView(parts: [], streaming: true,
                               liveTurnStartedAt: startedAt, settledDuration: nil)
                .frame(width: 360)
                .environment(\.hermesTheme, HermesThemePresets.nousLight)
        )
        renderer.scale = 2
        let height = try XCTUnwrap(renderer.uiImage?.size.height,
            "the merged pre-item working line must render")
        XCTAssertLessThan(height, 60,
            "spec A1: the merged working line is ONE line at send time")

        // When the first frames DO land late, the line persists and updates —
        // item arrival changes the status text, never mounts a second surface.
        deliver(g, fx, through: {
            self.kind($0) == "item.completed" && self.itemType($0) == "userMessage"
        })
        await waitUntil { g.chat.messages.contains { $0.role == .user && $0.text == fx.submitText } }
        XCTAssertTrue(g.chat.isStreaming, "the turn stays live after the late userMessage frame")
        XCTAssertTrue(g.chat.messages.contains {
            $0.role == .assistant && $0.isStreaming && $0.parts.isEmpty
        }, "the caret bubble (now the merged line) survives the late frame")
    }

    /// S3/A3: once the first work parts land with no answer text yet, the live
    /// turn renders EXACTLY ONE working surface — the fold's own line, which
    /// now IS the breathing-cursor line (its `ProgressView` spinner replaced by
    /// the breathing glyph). The separate bare standalone cursor the build-116
    /// caret slot mounted beside it (the IMG_2578/2587/2591 dual-affordance
    /// stack) is suppressed by the single-affordance seam. FAILS on qa3/base
    /// (`preItemWorkingLineVisible` absent; the view stacked both surfaces).
    func testReplay_SingleAffordanceFoldIsTheCursorLine() async throws {
        let fx = try loadFixture("render_live_fold")
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open(fx.sessionID)
        _ = await g.chat.send(text: fx.submitText)

        // Through the raw-name tool start: reasoning + in-progress tool, NO
        // agent text yet — the exact dual-affordance window of IMG_2578/2587.
        deliver(g, fx, through: {
            self.kind($0) == "item.started" && self.itemType($0) == "tool.generating"
        })
        await waitUntil { g.chat.messages.contains {
            $0.role == .assistant && $0.isStreaming && !$0.parts.isEmpty
        } }

        let live = try XCTUnwrap(g.chat.messages.first {
            $0.role == .assistant && $0.isStreaming && !$0.parts.isEmpty
        })
        XCTAssertEqual(live.parts.lastTextPartID, nil, "no answer text yet — the dual-affordance window")

        // The single-affordance seam: the caret slot mounts NO standalone
        // cursor beside the fold…
        XCTAssertFalse(
            WorkingSectionModel.preItemWorkingLineVisible(parts: live.parts, streamingLive: true),
            "spec S3: with the fold live, no second surface in the caret slot"
        )
        // …and the fold is exactly ONE node (the sole working surface).
        let nodes = WorkingSectionModel.renderNodes(from: live.parts)
        XCTAssertEqual(nodes.count, 1, "spec S3/A3: one fold node — one affordance")

        // That sole line renders as one chrome-less row (< 60 pt) with the
        // breathing glyph in the spinner's former place.
        let renderer = ImageRenderer(content:
            WorkingSectionView(parts: live.parts, streaming: true,
                               liveTurnStartedAt: Date(), settledDuration: nil)
                .frame(width: 360)
                .environment(\.hermesTheme, HermesThemePresets.nousLight)
        )
        renderer.scale = 2
        let height = try XCTUnwrap(renderer.uiImage?.size.height)
        XCTAssertLessThan(height, 60,
            "spec S3/A3: the cursor-fold live line stays ONE line")
    }

    /// S1/A10: the breathe SURVIVES re-projection — two renders of the same
    /// streaming cursor at different instants produce DIFFERENT pixels (the
    /// pulse is a function of the clock, so any mount/re-projection resumes
    /// mid-phase instead of stranding static — the motionless bar of
    /// IMG_2577/2585/2587), while a SETTLED cursor renders byte-identical
    /// static frames (the same paused/static branch Reduce Motion takes —
    /// `\.accessibilityReduceMotion` is read-only and cannot be injected in a
    /// test environment; the Reduce-Motion branch itself is pinned by
    /// `testStreamingCursorStaticWhenSettledOrReduceMotion`). FAILS on
    /// qa3/base (the onAppear-kicked `repeatForever` @State: a fresh mount
    /// without an `isStreaming` edge never started the pulse — re-render the
    /// component and both frames are identical at full opacity).
    @MainActor
    func testStreamingCursor_BreatheSurvivesRemount_Snapshot() async throws {
        func renderCursor(streaming: Bool) -> Data? {
            let renderer = ImageRenderer(content:
                StreamingCursor(isStreaming: streaming)
                    .font(.body)
                    .frame(width: 40, height: 28)
                    .environment(\.hermesTheme, HermesThemePresets.nousLight)
            )
            renderer.scale = 2
            return renderer.uiImage?.pngData()
        }

        let frameA = try XCTUnwrap(renderCursor(streaming: true))
        try await Task.sleep(for: .milliseconds(350))   // ~0.29 of the 1.2 s period
        let frameB = try XCTUnwrap(renderCursor(streaming: true))
        XCTAssertNotEqual(frameA, frameB,
            "spec S1/A10: the breathe is clock-driven — a fresh render at any instant shows the live phase, never a stranded static glyph")

        // Settled (and Reduce Motion, same branch): static full-opacity
        // frames, byte-identical across time.
        let calmA = try XCTUnwrap(renderCursor(streaming: false))
        try await Task.sleep(for: .milliseconds(120))
        let calmB = try XCTUnwrap(renderCursor(streaming: false))
        XCTAssertEqual(calmA, calmB,
            "spec A10: a non-streaming cursor renders static (the Reduce Motion path)")
    }

    // MARK: - QA-3 incident-fixture contract (loader backward-compat + shapes)

    /// The five QA-3 incident fixtures load through the extended loader with
    /// their timing/script/extra-session metadata intact, AND the pre-QA-3
    /// fixtures load with the new fields empty — the additive format stays
    /// backward-compatible (the ordering lane's S4/S6 replays, the liveness
    /// lane's S8 replay and the S11 scoping test consume these same files).
    /// Also pins the recorded incident SHAPES the recorder asserts on the
    /// Python side, so a re-recording that loses the incident (e.g. the
    /// silence gap collapsing) fails here too.
    func testQA3IncidentFixtures_LoadWithExtensions_ShapesPinned() throws {
        // S2 — the recorded silence gap between the submit-time userMessage
        // item and the late turn.started (IMG_2578's ~35 s, recorded at 1.5 s).
        let delayed = try loadFixture("render_qa3_delayed_start")
        let tms = frameTMs(delayed)
        XCTAssertTrue(tms.allSatisfy { $0 != nil },
            "the S2 fixture carries per-frame t_ms (its gap IS the incident)")
        let firstUserIdx = try XCTUnwrap(delayed.frames.firstIndex {
            self.kind($0).hasPrefix("item.") && self.itemType($0) == "userMessage"
        })
        let startedIdx = try XCTUnwrap(delayed.frames.firstIndex { self.kind($0) == "turn.started" })
        XCTAssertLessThan(firstUserIdx, startedIdx,
            "spec S2: the userMessage item lands at submit, BEFORE the late turn.started")
        let gap = try XCTUnwrap(tms[startedIdx]) - XCTUnwrap(tms[firstUserIdx])
        XCTAssertGreaterThanOrEqual(gap, 900,
            "spec S2: the recording preserves the late-first-item silence window")

        // S4 — a cumulative snapshot redelivery on the reconnect socket.
        let reorder = try loadFixture("render_qa3_reconnect_reorder")
        XCTAssertEqual(
            reorder.scriptSteps.compactMap { $0["action"] as? String },
            ["open", "resync", "submit"],
            "the S4 fixture records the reconnect: open -> resync -> live turn")
        XCTAssertTrue(reorder.frames.contains { self.kind($0) == "snapshot" },
            "spec S4: the reconnect redelivery arrives as a cumulative snapshot")

        // S6 — switch markers + the switched-to session's paint metadata.
        let switchFx = try loadFixture("render_qa3_session_switch")
        let switchActions = switchFx.scriptSteps.compactMap { $0["action"] as? String }
        XCTAssertEqual(switchActions.filter { $0 == "switch_to" }.count, 2,
            "spec S6: the fixture records switch-away AND return")
        let bSession = try XCTUnwrap(switchFx.extraSessions["render-sess-qa3-switch-b"],
            "spec S6: the switched-to session's paint metadata rides along")
        XCTAssertFalse(bSession.cachedHistory.isEmpty)
        XCTAssertTrue(bSession.frames.isEmpty, "B is idle — zero frames")

        // S8 — NO turn.completed anywhere; the redelivered items stay
        // in-progress (the eternal-working incident).
        let dead = try loadFixture("render_qa3_dead_turn")
        XCTAssertFalse(dead.frames.contains { self.kind($0) == "turn.completed" },
            "spec S8: the dead-turn fixture carries no completion — that is the incident")
        XCTAssertEqual(dead.settled["completed"] as? Bool, false)
        XCTAssertTrue(frameTMs(dead).allSatisfy { $0 != nil },
            "the liveness lane keys its silence window off the recorded t_ms")

        // S11 — the draft-entry marker (no wire frame — a local store call).
        let draft = try loadFixture("render_qa3_draft_interleave")
        let enterDraft = draft.scriptSteps.first { ($0["action"] as? String) == "enter_draft" }
        XCTAssertNotNil(enterDraft, "spec S11: the draft entry is a recorded script step")
        let draftAt = try XCTUnwrap((enterDraft?["at_t_ms"] as? NSNumber)?.doubleValue)
        XCTAssertGreaterThan(draftAt, 0, "the draft entry lands mid-stream")
        let lastFrameT = try XCTUnwrap(frameTMs(draft).compactMap { $0 }.last)
        XCTAssertLessThan(draftAt, lastFrameT,
                          "the draft entry precedes the turn's final frame (the leak window)")

        // BACKWARD COMPAT — a pre-QA-3 fixture loads with the extensions empty.
        let legacy = try loadFixture("render_submit_stream")
        XCTAssertTrue(legacy.scriptSteps.isEmpty)
        XCTAssertTrue(legacy.extraSessions.isEmpty)
        XCTAssertTrue(frameTMs(legacy).allSatisfy { $0 == nil },
            "pre-QA-3 fixtures carry no t_ms — the loader degrades gracefully")
    }
    // MARK: - QA-3 S8/A4 liveness replay (eternal double-working, killed)

    /// The round-3 set piece (IMG_2591, the "??" Aheli session): turn 1's tool
    /// NEVER completes, then turn 2 submits and streams. The render lane must
    /// self-heal turn 1 the moment turn 2's `userMessage` bounds the new
    /// current turn — turn 1 folds to a muted "Interrupted" non-streaming row
    /// and exactly ONE working surface remains. The watchdog's time-driven
    /// stages are pinned by `TurnLivenessTests`; this replay pins the
    /// DETERMINISTIC render half through the real frame pump. FAILS on
    /// qa3/base (turn 1 keeps `isStreaming` — two working rows forever).
    func testReplay_DeadTurnSelfHealsWhenSecondTurnStreams() async throws {
        let fx = try loadFixture("render_dead_turn_liveness")
        let g = try await makeGraph()
        defer { Task { await g.coordinator.stop() } }
        _ = try await g.coordinator.open(fx.sessionID)
        g.chat.messages = cachedRows(fx)
        let ok = await g.chat.send(text: fx.submitText)
        XCTAssertTrue(ok, "relay submit must be accepted")
        deliverAll(g, fx)

        await waitUntil { g.chat.messages.contains { $0.interrupted } }
        let assistants = g.chat.messages.filter { $0.role == .assistant && $0.relayProjected }
        XCTAssertEqual(
            assistants.filter({ $0.isStreaming }).count, 1,
            "spec A4: exactly ONE live working row — never the eternal double-working"
        )
        let deadTurnRow = try XCTUnwrap(assistants.first { $0.interrupted })
        XCTAssertFalse(deadTurnRow.isStreaming,
            "spec A4: the dead turn's stuck row settles (muted Interrupted fold)")
        // History + both user rows intact; the second prompt renders.
        assertHistoryPresent(g.chat.messages.map { $0.text }, fx)
        XCTAssertTrue(g.chat.messages.contains { $0.role == .user && $0.text == "??" })
        XCTAssertNil(g.chat.lastError, "C3: the self-heal is silent — no error surface")
    }
}
