import XCTest
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
        return Fixture(
            name: (raw["name"] as? String) ?? resource,
            sessionID: try XCTUnwrap(raw["session_id"] as? String),
            submitText: (submit["text"] as? String) ?? "",
            submitClientMessageID: submit["client_message_id"] as? String,
            cachedHistory: cached.compactMap { row in
                guard let role = row["role"] as? String, let text = row["content"] as? String
                else { return nil }
                return (role, text)
            },
            frames: frames,
            settled: (raw["settled"] as? [String: Any]) ?? [:]
        )
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
}
