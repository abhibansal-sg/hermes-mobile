import XCTest
@testable import HermesMobile

/// QA-1 TRANSCRIPT FAMILY (B5/B6/B7/B13, B15 guard) — render-level gate.
///
/// The structural gap QA-1 closes (spec A2/A9): the wire-level E2E proved the
/// relay protocol, but NOTHING exercised the iOS render layer
/// (`RelayItemStore` → `ChatStore.applyRelayItems` → view-model timeline). These
/// tests replay recorded-shape relay frame sequences through exactly that seam
/// and assert the transcript view model:
///
/// * B7/B6 — cached/settled history + a live streaming turn COEXIST: the relay
///   projection APPENDS to the painted history (anchored bottom), never replaces
///   the transcript; scrollback intact during AND after streaming.
/// * B5 — the optimistic user echo renders immediately on submit, survives live
///   projection, and RECONCILES with the relay `userMessage` item in place —
///   exactly one bubble, no duplication, identity preserved (no flicker).
/// * B13 — the brand-new-chat flow (no session id yet): echo visible before any
///   server ack, the relay-created session id lands, and the first turn renders.
/// * B15 — force-close/cold-open recovery stays green: the cache paint is the
///   initial source of truth; zero relay frames must never disturb it, and a
///   session switch must not blank the incoming painted transcript.
///
/// Every B-test FAILS on the unfixed tree (wholesale `messages = rebuilt`
/// replace + no echo) and PASSES with the merged-timeline fix. Frame builders
/// mirror the shapes the relay's reframer emits (RELAY-PHONE-PROTOCOL §2/§3)
/// plus the SUBMIT-synthesized `userMessage` item (§5, QA-1).
@MainActor
final class RelayTranscriptMergeTests: XCTestCase {

    private typealias MockTransport = RelaySessionCoordinatorTests.MockRelayTransport
    private let url = URL(string: "ws://127.0.0.1:9999/relay")!

    // MARK: - Frame / item builders (mirror the relay reframer's wire shapes)

    private func itemFrame(
        _ seq: Int, kind: String, id: String, _ type: ChatItemType,
        status: String, ord: Int, body: JSONValue, sid: String = "s", turn: String? = "t"
    ) -> RelayFrame {
        RelayFrame(seq: seq, sid: sid, turn: turn, kind: RelayFrameKind(wire: kind), body: .object([
            "item_id": .string(id), "type": .string(type.rawValue),
            "status": .string(status), "ord": .number(Double(ord)), "body": body,
        ]))
    }

    private func agentStartedFrame(_ seq: Int, id: String, ord: Int) -> RelayFrame {
        itemFrame(seq, kind: "item.started", id: id, .agentMessage,
                  status: "in_progress", ord: ord, body: ["text": ""])
    }

    private func agentDeltaFrame(_ seq: Int, id: String, text: String) -> RelayFrame {
        RelayFrame(seq: seq, sid: "s", turn: "t", kind: .itemDelta,
                   body: .object(["item_id": .string(id),
                                  "patch": .object(["text": .string(text)])]))
    }

    private func agentCompletedFrame(_ seq: Int, id: String, ord: Int, text: String) -> RelayFrame {
        itemFrame(seq, kind: "item.completed", id: id, .agentMessage,
                  status: "completed", ord: ord, body: ["text": .string(text)])
    }

    /// The SUBMIT-synthesized `userMessage` item (QA-1: the relay emits one so
    /// the echo reconciles and cold-resume snapshots carry the prompt).
    private func userItemFrame(
        _ seq: Int, id: String, ord: Int, text: String,
        clientMessageID: String? = nil, sid: String = "s"
    ) -> RelayFrame {
        var body: [String: JSONValue] = ["text": .string(text)]
        if let clientMessageID { body["client_message_id"] = .string(clientMessageID) }
        return itemFrame(seq, kind: "item.completed", id: id, .userMessage,
                         status: "completed", ord: ord, body: .object(body), sid: sid)
    }

    private func userItem(
        _ id: String, ord: Int, text: String, clientMessageID: String? = nil
    ) -> ChatItem {
        var body: [String: JSONValue] = ["text": .string(text)]
        if let clientMessageID { body["client_message_id"] = .string(clientMessageID) }
        return ChatItem(itemID: id, type: .userMessage, status: .completed,
                        ord: ord, body: .object(body))
    }

    private func agentItem(
        _ id: String, ord: Int, text: String, status: ChatItemStatus = .completed
    ) -> ChatItem {
        ChatItem(itemID: id, type: .agentMessage, status: status, ord: ord,
                 body: ["text": .string(text)])
    }

    /// Two settled turns painted the way the GRDB cache seed paints them
    /// (deterministic ids, untagged — NOT relay projections). Returns the ids.
    @discardableResult
    private func seedHistory(_ chat: ChatStore) -> [UUID] {
        let rows: [(ChatRole, String)] = [
            (.user, "What is the relay protocol?"),
            (.assistant, "It is the Wave-2 phone protocol."),
            (.user, "Summarize section 4."),
            (.assistant, "Seq, ack, and resync."),
        ]
        let messages = rows.enumerated().map { index, row in
            ChatMessage(
                id: ChatMessage.deterministicID(seedKey: "hist-\(index)-\(row.0)"),
                role: row.0, text: row.1
            )
        }
        chat.messages = messages
        return messages.map(\.id)
    }

    /// Append an optimistic user echo exactly the way the relay send path does
    /// (role `.user`, `clientMessageID`, appended).
    @discardableResult
    private func appendEcho(_ chat: ChatStore, text: String, clientMessageID: String? = nil) -> UUID {
        let echo = ChatMessage(role: .user, clientMessageID: clientMessageID, text: text)
        chat.messages.append(echo)
        return echo.id
    }

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("waitUntil timed out")
    }

    // MARK: - B7/B6 — history + live turn coexist (append, never replace)

    /// THE core B7 regression: the first live frame of a new turn must APPEND to
    /// the cached/settled transcript, not replace it. Owner: "every time I sent
    /// the message the previous history of that session just disappeared."
    func testLiveTurnAppendsToCachedHistoryInsteadOfReplacingIt() {
        let chat = ChatStore()
        let historyIDs = seedHistory(chat)

        var store = RelayItemStore()
        store.apply(agentStartedFrame(1, id: "msg-1", ord: 0))
        store.apply(agentDeltaFrame(2, id: "msg-1", text: "Live answer "))
        chat.applyRelayItems(store.items)

        XCTAssertEqual(
            chat.messages.count, historyIDs.count + 1,
            "live turn must APPEND to cached history, not replace the transcript (B7)"
        )
        XCTAssertEqual(
            Array(chat.messages.prefix(historyIDs.count)).map(\.id), historyIDs,
            "scrollback ids must be byte-stable under a live turn"
        )
        XCTAssertEqual(chat.messages.last?.role, .assistant)
        XCTAssertTrue(chat.messages.last?.isStreaming ?? false, "the live turn streams")
        XCTAssertTrue(chat.isStreaming)
    }

    /// B6 + A2: scrollback stays intact DURING streaming AND AFTER the turn
    /// completes — the live turn never floats mid-viewport without its context.
    func testScrollbackIntactDuringStreamingAndAfterCompletion() {
        let chat = ChatStore()
        let historyIDs = seedHistory(chat)

        var store = RelayItemStore()
        store.apply(agentStartedFrame(1, id: "msg-1", ord: 0))
        chat.applyRelayItems(store.items)
        store.apply(agentDeltaFrame(2, id: "msg-1", text: "Working…"))
        chat.applyRelayItems(store.items)
        XCTAssertEqual(
            Array(chat.messages.prefix(historyIDs.count)).map(\.id), historyIDs,
            "history intact mid-stream (B6)"
        )

        store.apply(agentCompletedFrame(3, id: "msg-1", ord: 0, text: "Done."))
        chat.applyRelayItems(store.items)

        XCTAssertEqual(chat.messages.count, historyIDs.count + 1)
        XCTAssertEqual(chat.messages.prefix(historyIDs.count).map(\.id), historyIDs,
                       "history intact after completion")
        XCTAssertEqual(chat.messages.last?.text, "Done.")
        XCTAssertFalse(chat.messages.last?.isStreaming ?? true)
        XCTAssertFalse(chat.isStreaming, "the turn settles")
    }

    // MARK: - B5 — optimistic echo + reconciliation without duplication

    /// B5: the user's own message must appear immediately on send and SURVIVE
    /// the live projection that follows (pre-fix it was wiped by the replace).
    func testOptimisticEchoSurvivesLiveProjection() {
        let chat = ChatStore()
        let historyIDs = seedHistory(chat)
        let echoID = appendEcho(chat, text: "hello", clientMessageID: "cmid-1")

        var store = RelayItemStore()
        store.apply(agentStartedFrame(1, id: "msg-1", ord: 0))
        store.apply(agentDeltaFrame(2, id: "msg-1", text: "Hi!"))
        chat.applyRelayItems(store.items)

        XCTAssertEqual(chat.messages.count, historyIDs.count + 2,
                       "echo + live turn must coexist with history (B5)")
        XCTAssertEqual(chat.messages[historyIDs.count].id, echoID,
                       "echo renders right after history")
        XCTAssertEqual(chat.messages[historyIDs.count].role, .user)
        XCTAssertEqual(chat.messages.last?.role, .assistant)
        XCTAssertTrue(chat.messages.last?.isStreaming ?? false)
    }

    /// B5/A2: when the relay's synthesized `userMessage` item lands, it must
    /// RECONCILE with the optimistic echo — exactly one bubble, in place (the
    /// echo keeps its identity, no flicker, no duplicate), during the stream
    /// AND after completion.
    func testEchoReconcilesWithRelayUserMessageWithoutDuplication() {
        let chat = ChatStore()
        let historyIDs = seedHistory(chat)
        let echoID = appendEcho(chat, text: "hello", clientMessageID: "cmid-1")

        var store = RelayItemStore()
        store.apply(userItemFrame(1, id: "u-1", ord: 0, text: "hello", clientMessageID: "cmid-1"))
        store.apply(agentStartedFrame(2, id: "msg-1", ord: 1))
        store.apply(agentDeltaFrame(3, id: "msg-1", text: "Hi!"))
        chat.applyRelayItems(store.items)

        var userRows = chat.messages.filter { $0.role == .user && $0.text == "hello" }
        XCTAssertEqual(userRows.count, 1,
                       "echo + userMessage item = exactly one bubble, never two (B5)")
        XCTAssertEqual(userRows.first?.id, echoID, "the echo is adopted in place (no flicker)")
        XCTAssertEqual(chat.messages[historyIDs.count].id, echoID,
                       "the reconciled bubble stays right after history")
        XCTAssertEqual(chat.messages.count, historyIDs.count + 2)

        // The turn completes: still exactly one user bubble, same identity.
        store.apply(agentCompletedFrame(4, id: "msg-1", ord: 1, text: "Hi!"))
        chat.applyRelayItems(store.items)
        userRows = chat.messages.filter { $0.role == .user && $0.text == "hello" }
        XCTAssertEqual(userRows.count, 1, "no duplication after turn.completed")
        XCTAssertEqual(userRows.first?.id, echoID)
        XCTAssertFalse(chat.isStreaming)
    }

    /// Re-projecting on every frame must be churn-free: the adopted echo keeps
    /// the SAME message id across projections (SwiftUI diffs cleanly).
    func testEchoAdoptionIsIdStableAcrossReprojection() {
        let chat = ChatStore()
        seedHistory(chat)
        appendEcho(chat, text: "hello", clientMessageID: "cmid-1")

        var store = RelayItemStore()
        store.apply(userItemFrame(1, id: "u-1", ord: 0, text: "hello", clientMessageID: "cmid-1"))
        store.apply(agentStartedFrame(2, id: "msg-1", ord: 1))
        chat.applyRelayItems(store.items)
        let firstIDs = chat.messages.map(\.id)

        store.apply(agentDeltaFrame(3, id: "msg-1", text: "Hi!"))
        chat.applyRelayItems(store.items)
        store.apply(agentCompletedFrame(4, id: "msg-1", ord: 1, text: "Hi!"))
        chat.applyRelayItems(store.items)

        XCTAssertEqual(chat.messages.map(\.id).prefix(firstIDs.count), ArraySlice(firstIDs),
                       "message identities stable across re-projection")
    }

    /// Two rapid sends of the SAME text carry DISTINCT client message ids; the
    /// reconciliation must correlate by id, never collapse both echoes into one.
    func testDistinctClientMessageIDsNeverCollapseIntoOneBubble() {
        let chat = ChatStore()
        let echoA = appendEcho(chat, text: "hello", clientMessageID: "cmid-A")
        let echoB = appendEcho(chat, text: "hello", clientMessageID: "cmid-B")

        chat.applyRelayItems([
            userItem("u-1", ord: 0, text: "hello", clientMessageID: "cmid-A"),
            userItem("u-2", ord: 1, text: "hello", clientMessageID: "cmid-B"),
            agentItem("msg-1", ord: 2, text: "Hi twice!"),
        ])

        let userRows = chat.messages.filter { $0.role == .user && $0.text == "hello" }
        XCTAssertEqual(userRows.count, 2, "distinct sends stay distinct bubbles")
        XCTAssertEqual(userRows.map(\.id), [echoA, echoB], "each echo adopts its own item, in order")
        XCTAssertEqual(chat.messages.last?.role, .assistant)
    }

    /// An item WITHOUT a client message id (e.g. a prompt sent by another
    /// client) still correlates by text against an unmatched echo.
    func testUserMessageItemWithoutClientIDAdoptsByText() {
        let chat = ChatStore()
        let echoID = appendEcho(chat, text: "hello")

        chat.applyRelayItems([
            userItem("u-1", ord: 0, text: "hello"),   // no client_message_id
            agentItem("msg-1", ord: 1, text: "Hi!"),
        ])

        let userRows = chat.messages.filter { $0.role == .user && $0.text == "hello" }
        XCTAssertEqual(userRows.count, 1)
        XCTAssertEqual(userRows.first?.id, echoID)
    }

    // MARK: - B13 — brand-new chat (no session id yet)

    /// B13: fresh chat, sent "hello" — pre-fix the greeting stayed, no user
    /// bubble, nothing streamed. The merged timeline: the echo paints first,
    /// survives an empty first projection tick (a non-item frame before any
    /// item), then reconciles with the relay `userMessage` item and the reply.
    func testNewChatFirstSendTimelineCoheres() {
        let chat = ChatStore()          // brand-new chat: empty transcript
        let echoID = appendEcho(chat, text: "hello", clientMessageID: "c-1")

        // The first downstream frame is a non-item kind (status/thinking): the
        // store is still EMPTY — the echo must not be wiped by that tick.
        chat.applyRelayItems([])
        XCTAssertEqual(chat.messages.count, 1, "echo visible before any item lands (B13)")
        XCTAssertEqual(chat.messages.first?.id, echoID)

        var store = RelayItemStore()
        store.apply(userItemFrame(1, id: "u-1", ord: 0, text: "hello", clientMessageID: "c-1"))
        store.apply(agentStartedFrame(2, id: "msg-1", ord: 1))
        store.apply(agentDeltaFrame(3, id: "msg-1", text: "Hey"))
        chat.applyRelayItems(store.items)

        XCTAssertEqual(chat.messages.count, 2, "user bubble + streaming reply, nothing else")
        XCTAssertEqual(chat.messages.first?.id, echoID, "the user's message is first")
        XCTAssertEqual(chat.messages.first?.role, .user)
        XCTAssertTrue(chat.messages.last?.isStreaming ?? false)

        store.apply(agentCompletedFrame(4, id: "msg-1", ord: 1, text: "Hey there!"))
        chat.applyRelayItems(store.items)
        XCTAssertEqual(chat.messages.count, 2, "no duplication on completion")
        XCTAssertEqual(chat.messages.first?.id, echoID)
        XCTAssertEqual(chat.messages.last?.text, "Hey there!")
        XCTAssertFalse(chat.isStreaming)
    }

    // MARK: - B15 guard — cold-cache paint is the initial truth

    /// B15: force-close recovery works because the cold relaunch paints from
    /// GRDB BEFORE any relay frame. Zero relay frames must NEVER disturb the
    /// painted transcript (an empty-store projection is a no-op on history).
    func testCachedPaintPreservedWhenRelayStoreIsEmpty() {
        let chat = ChatStore()
        let historyIDs = seedHistory(chat)

        chat.applyRelayItems([])        // session bound, no frames yet
        XCTAssertEqual(chat.messages.map(\.id), historyIDs,
                       "cold-cache paint survives zero relay frames (B15)")
        chat.applyRelayItems([])        // idempotent
        XCTAssertEqual(chat.messages.map(\.id), historyIDs)
    }

    // MARK: - Coordinator level: session switch must not blank the paint (B4/B15)

    /// Build a coordinator over an in-process mock relay. `script` answers RPCs.
    private func makeCoordinator(
        script: (@Sendable (MockTransport.Upstream, MockTransport) -> Void)? = nil
    ) -> (ChatStore, RelaySessionCoordinator, MockTransport) {
        let transport = MockTransport(script: script)
        let chat = ChatStore()
        let coordinator = RelaySessionCoordinator(
            chatStore: chat,
            clientFactory: { RelayClient { _ in transport } }
        )
        return (chat, coordinator, transport)
    }

    /// The session-switch reset clears the render store but must NOT blank the
    /// incoming session's cache-painted transcript while awaiting the relay.
    func testSessionSwitchDoesNotBlankIncomingCachePaint() async throws {
        let (chat, coordinator, transport) = makeCoordinator(script: { upstream, relay in
            guard let id = upstream.id else { return }
            if upstream.method == "open", let sid = upstream.params["session_id"] as? String, sid == "A" {
                relay.deliverFrame(RelayFrame(
                    seq: 1, sid: "A", turn: nil, kind: .snapshot,
                    body: .object([
                        "items": .array([.object([
                            "item_id": .string("A-item"),
                            "type": .string(ChatItemType.userMessage.rawValue),
                            "status": .string("completed"),
                            "ord": .number(0),
                            "body": .object(["text": .string("hello from A")]),
                        ])]),
                        "cursor": .number(1),
                    ])
                ))
            }
            // Answer every RPC (A and B) so the awaits resolve.
            relay.deliverResult(id: id, result: .object(["ok": .bool(true)]))
        })
        try await coordinator.start(url: url)

        _ = try await coordinator.open("A")
        await waitUntil { coordinator.store.items.map(\.itemID) == ["A-item"] }
        XCTAssertTrue(chat.messages.contains { $0.text == "hello from A" })

        // The incoming session's cache paint lands (SessionStore seed) BEFORE
        // session B streams any relay content.
        let bPaint = [
            ChatMessage(id: ChatMessage.deterministicID(seedKey: "B-hist-0"),
                        role: .user, text: "B history question"),
            ChatMessage(id: ChatMessage.deterministicID(seedKey: "B-hist-1"),
                        role: .assistant, text: "B history answer"),
        ]
        chat.messages = bPaint

        _ = try await coordinator.open("B")     // resets the store; NO snapshot for B
        XCTAssertEqual(chat.messages.map(\.id), bPaint.map(\.id),
                       "session switch must not blank the painted transcript (B4/B15)")

        await coordinator.stop()
        _ = transport
    }

    /// After a switch, the new session's live turn appends to ITS OWN cache
    /// paint — full coexistence on the switched-in session, no leak of A.
    func testSwitchedSessionLiveTurnAppendsToItsOwnCachePaint() async throws {
        let (chat, coordinator, transport) = makeCoordinator(script: { upstream, relay in
            guard let id = upstream.id else { return }
            if upstream.method == "open", let sid = upstream.params["session_id"] as? String, sid == "A" {
                relay.deliverFrame(RelayFrame(
                    seq: 1, sid: "A", turn: nil, kind: .snapshot,
                    body: .object([
                        "items": .array([.object([
                            "item_id": .string("A-item"),
                            "type": .string(ChatItemType.userMessage.rawValue),
                            "status": .string("completed"),
                            "ord": .number(0),
                            "body": .object(["text": .string("hello from A")]),
                        ])]),
                        "cursor": .number(1),
                    ])
                ))
            }
            relay.deliverResult(id: id, result: .object(["ok": .bool(true)]))
        })
        try await coordinator.start(url: url)

        _ = try await coordinator.open("A")
        await waitUntil { coordinator.store.items.map(\.itemID) == ["A-item"] }

        let bHistory = [
            ChatMessage(id: ChatMessage.deterministicID(seedKey: "B-hist-0"),
                        role: .user, text: "B history question"),
            ChatMessage(id: ChatMessage.deterministicID(seedKey: "B-hist-1"),
                        role: .assistant, text: "B history answer"),
        ]
        chat.messages = bHistory
        _ = try await coordinator.open("B")

        // The user sends in B: echo + relay items stream in.
        let echoID = appendEcho(chat, text: "hi from B", clientMessageID: "c-B")
        transport.deliverFrames([
            userItemFrame(2, id: "u-B", ord: 0, text: "hi from B",
                          clientMessageID: "c-B", sid: "B"),
            RelayFrame(seq: 3, sid: "B", turn: "t", kind: .itemStarted, body: .object([
                "item_id": .string("msg-B"), "type": .string(ChatItemType.agentMessage.rawValue),
                "status": .string("in_progress"), "ord": .number(1),
                "body": .object(["text": ""]),
            ])),
            RelayFrame(seq: 4, sid: "B", turn: "t", kind: .itemDelta, body: .object([
                "item_id": .string("msg-B"), "patch": .object(["text": .string("B reply")]),
            ])),
        ])

        await waitUntil { chat.messages.last?.isStreaming == true }

        // B's cache paint intact, the echo reconciled right after it, the live
        // reply last — and NOTHING from session A.
        XCTAssertEqual(chat.messages.prefix(2).map(\.id), bHistory.map(\.id),
                       "B's history leads the timeline")
        XCTAssertEqual(chat.messages[2].id, echoID, "echo reconciled after B's history")
        XCTAssertEqual(chat.messages[2].text, "hi from B")
        XCTAssertEqual(chat.messages.last?.role, .assistant)
        XCTAssertFalse(chat.messages.contains { $0.text.contains("hello from A") },
                       "no leak of the previous session's content")
        XCTAssertEqual(chat.messages.filter { $0.text == "hi from B" }.count, 1,
                       "exactly one user bubble for the send")

        await coordinator.stop()
    }

    // MARK: - B13 end-to-end: relay send echoes before ack + lands the session

    /// Build a full store graph in relay mode with a mock relay socket.
    private func makeRelayGraph(
        script: (@Sendable (MockTransport.Upstream, MockTransport) -> Void)? = nil
    ) throws -> (chat: ChatStore, sessions: SessionStore, connection: ConnectionStore,
                 coordinator: RelaySessionCoordinator, transport: MockTransport) {
        UserDefaults.standard.set(TransportPath.relay.rawValue, forKey: DefaultsKeys.transportPath)
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)

        let transport = MockTransport(script: script)
        connection.relayCoordinatorFactory = {
            RelaySessionCoordinator(chatStore: chat, clientFactory: { RelayClient { _ in transport } })
        }
        let coordinator = connection.ensureRelayCoordinator()
        return (chat, sessions, connection, coordinator, transport)
    }

    private func restoreTransportDefault() {
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.transportPath)
    }

    /// B13/B5 end-to-end on the real send path: the optimistic echo paints
    /// BEFORE the relay acks the submit (WhatsApp bar), the submit carries a
    /// `client_message_id`, the relay-created session id LANDS in SessionStore
    /// (draft → real), and the echoed bubble reconciles with the relay
    /// `userMessage` item into exactly one row under the streamed reply.
    func testRelaySendEchoesBeforeServerAckAndLandsNewChatSession() async throws {
        // Thread-safe parking of the submit RPC so the test can observe the
        // echo BEFORE the server ack.
        let parked = SubmitPark()
        let (chat, sessions, _, coordinator, transport) = try makeRelayGraph(
            script: { upstream, _ in
                if upstream.method == "submit" {
                    parked.park(id: upstream.id, params: upstream.params)
                }
                // Every other RPC (none expected here) resolves immediately.
            }
        )
        defer { restoreTransportDefault() }
        try await coordinator.start(url: url)

        sessions.startDraft()                     // brand-new chat: no session id
        XCTAssertTrue(sessions.isDraft)

        let sendTask = Task { await chat.send(text: "hello") }

        // 1) The echo renders BEFORE any server ack (B5/B13 WhatsApp bar).
        await waitUntil { chat.messages.contains { $0.role == .user && $0.text == "hello" } }
        XCTAssertEqual(chat.messages.first?.text, "hello", "user bubble first, immediately")

        // 2) The submit carries a client_message_id (flap-dedup identity).
        let parkedSubmit = try await parked.wait()
        let cmid = parkedSubmit.params["client_message_id"] as? String
        XCTAssertNotNil(cmid, "relay submit must carry a client_message_id")

        // 3) Relay acks with the created session id + emits the user item and
        //    the streamed reply.
        transport.deliverResult(
            id: parkedSubmit.id ?? "1",
            result: .object(["session_id": .string("new-sid")])
        )
        transport.deliverFrames([
            userItemFrame(1, id: "u-1", ord: 0, text: "hello", clientMessageID: cmid),
            agentStartedFrame(2, id: "msg-1", ord: 1),
            agentDeltaFrame(3, id: "msg-1", text: "Hey "),
            agentCompletedFrame(4, id: "msg-1", ord: 1, text: "Hey there!"),
            // QA-2 R4/A2 contract: `isStreaming` is TURN-scoped — it settles on
            // the authoritative `turn.completed` frame (the real relay always
            // sends it; every render_conformance fixture ends with one), NOT on
            // per-item terminality. The QA-1 shape of this test predated that
            // contract and stopped at `item.completed`.
            RelayFrame(seq: 5, sid: "s", turn: "t", kind: .turnCompleted,
                       body: .object(["usage": .object([:])])),
        ])

        let accepted = await sendTask.value
        XCTAssertTrue(accepted, "the relay accepted the prompt")

        // 4) New-chat bookkeeping landed: the draft became a real session.
        XCTAssertFalse(sessions.isDraft, "relay-created session must land (B13)")
        XCTAssertEqual(sessions.activeStoredId, "new-sid")
        XCTAssertEqual(coordinator.activeSessionID, "new-sid")

        // 5) One user bubble (echo reconciled in place) + one settled reply.
        await waitUntil { !chat.isStreaming }
        let userRows = chat.messages.filter { $0.role == .user && $0.text == "hello" }
        XCTAssertEqual(userRows.count, 1, "echo + userMessage item = one bubble")
        XCTAssertEqual(chat.messages.first?.role, .user)
        XCTAssertEqual(chat.messages.last?.role, .assistant)
        XCTAssertEqual(chat.messages.last?.text, "Hey there!")
        XCTAssertFalse(chat.isStreaming)
    }

    /// Sending into an EXISTING session: the echo reconciles under full history
    /// and the session id is untouched (no draft re-landing).
    func testRelaySendIntoExistingSessionKeepsHistoryAndIdentity() async throws {
        let parked = SubmitPark()
        let (chat, sessions, _, coordinator, transport) = try makeRelayGraph(
            script: { upstream, _ in
                if upstream.method == "submit" { parked.park(id: upstream.id, params: upstream.params) }
            }
        )
        defer { restoreTransportDefault() }
        try await coordinator.start(url: url)

        XCTAssertFalse(sessions.isDraft, "precondition: not a draft")
        sessions.activeStoredId = "existing-1"
        let historyIDs = seedHistory(chat)

        let sendTask = Task { await chat.send(text: "follow-up") }
        await waitUntil { chat.messages.contains { $0.role == .user && $0.text == "follow-up" } }
        // History intact the instant the echo paints.
        XCTAssertEqual(chat.messages.prefix(historyIDs.count).map(\.id), historyIDs)

        let parkedSubmit = try await parked.wait()
        let cmid = parkedSubmit.params["client_message_id"] as? String
        XCTAssertEqual(parkedSubmit.params["session_id"] as? String, "existing-1",
                       "submit targets the active stored session")
        transport.deliverResult(id: parkedSubmit.id ?? "1",
                                result: .object(["session_id": .string("existing-1")]))
        transport.deliverFrames([
            userItemFrame(1, id: "u-9", ord: 0, text: "follow-up", clientMessageID: cmid),
            agentCompletedFrame(2, id: "msg-9", ord: 1, text: "Answer."),
            // QA-2 R4/A2: settle the turn with the authoritative boundary frame
            // (see the sibling test) — item terminality no longer clears the
            // store-level `isStreaming`.
            RelayFrame(seq: 3, sid: "s", turn: "t", kind: .turnCompleted,
                       body: .object(["usage": .object([:])])),
        ])

        let acceptedExisting = await sendTask.value
        XCTAssertTrue(acceptedExisting)
        await waitUntil { !chat.isStreaming }

        XCTAssertEqual(chat.messages.prefix(historyIDs.count).map(\.id), historyIDs,
                       "prior history fully intact after the turn (B7)")
        XCTAssertEqual(chat.messages.filter { $0.text == "follow-up" }.count, 1)
        XCTAssertEqual(chat.messages.last?.text, "Answer.")
        XCTAssertEqual(sessions.activeStoredId, "existing-1", "no session churn")
        XCTAssertFalse(sessions.isDraft)
    }

    // MARK: - RelayItemStore folds userMessage items (relay-synthesis guard)

    /// The store must fold a SUBMIT-synthesized `userMessage` item so snapshots
    /// carry the prompt (replay fidelity). This always held — the gap was the
    /// missing EMITTER — pinned here so a regression in either half is caught.
    func testRelayItemStoreFoldsUserMessageItems() {
        var store = RelayItemStore()
        store.apply(userItemFrame(1, id: "u-1", ord: 0, text: "hello", clientMessageID: "c-1"))
        store.apply(agentStartedFrame(2, id: "msg-1", ord: 1))

        XCTAssertEqual(store.items.map(\.itemID), ["u-1", "msg-1"])
        XCTAssertEqual(store.items.first?.type, .userMessage)
        XCTAssertEqual(store.items.first?.textBody, "hello")
        XCTAssertTrue(store.items.first?.isTerminal ?? false)
        XCTAssertEqual(store.items.first?.body["client_message_id"]?.stringValue, "c-1")
    }
}

/// Thread-safe one-shot park for a single upstream submit RPC: the mock
/// transport's script parks the request (from the client's send task) and the
/// test waits on it, asserts the pre-ack echo, then answers.
private final class SubmitPark: @unchecked Sendable {
    /// `@unchecked` because the `[String: Any]` params cannot express
    /// Sendability; every hand-off is serialized by the enclosing NSLock and
    /// each value is resumed exactly once (same pattern as MockRelayTransport).
    struct Parked: @unchecked Sendable { let id: String?; let params: [String: Any] }
    private let lock = NSLock()
    private var parked: Parked?
    private var waiter: CheckedContinuation<Parked, Never>?

    func park(id: String?, params: [String: Any]) {
        lock.lock()
        let value = Parked(id: id, params: params)
        let pending = waiter
        waiter = nil
        if pending == nil { parked = value }
        lock.unlock()
        pending?.resume(returning: value)
    }

    func wait() async -> Parked {
        await withCheckedContinuation { continuation in
            lock.lock()
            let existing = parked
            parked = nil
            if existing == nil { waiter = continuation }
            lock.unlock()
            if let existing { continuation.resume(returning: existing) }
        }
    }
}
