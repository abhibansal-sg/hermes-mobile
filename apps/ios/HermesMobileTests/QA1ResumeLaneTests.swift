import XCTest
@testable import HermesMobile

/// QA-1 resume lane (B1 cold-start resume alert · B2 session-switch latency ·
/// B3 drawer dismissal race · B4 blank-screen impossibility).
///
/// Every test is a REGRESSION test: it FAILS on `qa1/base` (the build-114
/// behavior) and PASSES with the lane's fixes. The relay cases drive a real
/// `RelaySessionCoordinator` + `RelayClient` against an in-process mock relay
/// transport (the `RelayClientMockTests` pattern) — no live gateway/relay is
/// touched. Transport is forced to `.relay` via the persisted flag (restored
/// after each test) so the store graph runs the production relay branches.
@MainActor
final class QA1ResumeLaneTests: XCTestCase {

    // MARK: - Mock relay transport

    /// In-process fake relay (mirrors RelayClientMockTests.MockRelayTransport):
    /// `script` reacts to each upstream frame and enqueues the JSON-RPC result.
    private final class MockRelay: RelayTransport, @unchecked Sendable {
        struct Upstream {
            let method: String
            let id: String?
            let params: [String: Any]
        }

        private let lock = NSLock()
        private var inbox: [URLSessionWebSocketTask.Message] = []
        private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
        private var sent: [Upstream] = []
        private var cancelled = false

        var script: (@Sendable (Upstream, MockRelay) -> Void)?

        func resume() {}

        func receive() async throws -> URLSessionWebSocketTask.Message {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: URLError(.cancelled))
                } else if !inbox.isEmpty {
                    let next = inbox.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: next)
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        }

        func send(_ message: URLSessionWebSocketTask.Message) async throws {
            guard case let .string(text) = message,
                  let upstream = Self.parse(text) else { return }
            recordUpstream(upstream)
            script?(upstream, self)
        }

        /// NSLock is unavailable from async contexts (Swift 6 strict) — the
        /// `send(_:)` above is async, so hop the critical section through a
        /// synchronous helper.
        private func recordUpstream(_ upstream: Upstream) {
            lock.lock(); sent.append(upstream); lock.unlock()
        }

        func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
            lock.lock()
            cancelled = true
            let parked = waiter
            waiter = nil
            lock.unlock()
            parked?.resume(throwing: URLError(.cancelled))
        }

        func deliver(_ text: String) {
            lock.lock()
            if let parked = waiter {
                waiter = nil
                lock.unlock()
                parked.resume(returning: .string(text))
            } else {
                inbox.append(.string(text))
                lock.unlock()
            }
        }

        func deliverResult(id: String, result: JSONValue) {
            let payload: JSONValue = .object([
                "jsonrpc": .string("2.0"), "id": .string(id), "result": result,
            ])
            guard let data = try? JSONEncoder().encode(payload) else { return }
            deliver(String(decoding: data, as: UTF8.self))
        }

        func deliverError(id: String, code: Int, message: String) {
            let payload: JSONValue = .object([
                "jsonrpc": .string("2.0"),
                "id": .string(id),
                "error": .object(["code": .number(Double(code)), "message": .string(message)]),
            ])
            guard let data = try? JSONEncoder().encode(payload) else { return }
            deliver(String(decoding: data, as: UTF8.self))
        }

        func upstreams() -> [Upstream] {
            lock.lock(); defer { lock.unlock() }
            return sent
        }

        private static func parse(_ text: String) -> Upstream? {
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return nil }
            return Upstream(
                method: method,
                id: object["id"] as? String,
                params: object["params"] as? [String: Any] ?? [:]
            )
        }
    }

    /// Default relay behavior: answer every session RPC with a well-formed
    /// empty result (resume/open/history/list); notifications need no reply.
    /// `historyRows` seeds the `history` answer for the B2 case.
    /// Bounded poll (mirrors the other contract suites) — the snapshot the
    /// resume RPC carries lands on the pump task, a tick after the bind.
    private func waitUntil(
        _ condition: @escaping () -> Bool, timeout: TimeInterval = 3.0
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func defaultScript(historyRows: [JSONValue] = []) -> @Sendable (MockRelay.Upstream, MockRelay) -> Void {
        { up, relay in
            guard let id = up.id else { return }
            let sid = up.params["session_id"] as? String ?? ""
            switch up.method {
            case "resume":
                relay.deliverResult(id: id, result: .object([
                    "session_id": .string(sid), "result": .object([:]),
                ]))
            case "open":
                relay.deliverResult(id: id, result: .object([
                    "session_id": .string(sid), "messages": .array([]),
                ]))
            case "history":
                relay.deliverResult(id: id, result: .object([
                    "session_id": .string(sid), "messages": .array(historyRows),
                ]))
            default:
                relay.deliverResult(id: id, result: .object([:]))
            }
        }
    }

    // MARK: - Graph helpers

    private let relayURL = URL(string: "ws://127.0.0.1:9999/relay")!
    private var savedTransportPath: String?

    override func setUp() {
        super.setUp()
        savedTransportPath = UserDefaults.standard.string(forKey: DefaultsKeys.transportPath)
        UserDefaults.standard.set(TransportPath.relay.rawValue, forKey: DefaultsKeys.transportPath)
    }

    override func tearDown() {
        if let savedTransportPath {
            UserDefaults.standard.set(savedTransportPath, forKey: DefaultsKeys.transportPath)
        } else {
            UserDefaults.standard.removeObject(forKey: DefaultsKeys.transportPath)
        }
        super.tearDown()
    }

    /// A wired store graph with the relay coordinator injected over a mock
    /// transport (the DEBUG `relayCoordinatorFactory` seam). The coordinator is
    /// NOT started — tests start it when they want the socket "up".
    #if DEBUG
    private func makeRelayGraph(
        historyRows: [JSONValue] = []
    ) -> (ConnectionStore, SessionStore, ChatStore, RelaySessionCoordinator, MockRelay) {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)

        let transport = MockRelay()
        transport.script = defaultScript(historyRows: historyRows)
        let coordinator = RelaySessionCoordinator(
            chatStore: chat,
            clientFactory: {
                RelayClient(ackInterval: nil, transportFactory: { _ in transport })
            }
        )
        connection.relayCoordinatorFactory = { coordinator }
        _ = connection.ensureRelayCoordinator()  // wire onReady/onPhaseChange bridges
        return (connection, sessions, chat, coordinator, transport)
    }
    #endif

    private func summary(_ id: String) -> SessionSummary {
        SessionSummary(
            id: id, title: nil, preview: nil, startedAt: nil,
            messageCount: nil, source: nil, lastActive: nil, cwd: nil
        )
    }

    private func storedRow(_ role: String, _ text: String, id: Int) -> JSONValue {
        .object([
            "id": .number(Double(id)),
            "role": .string(role),
            "content": .string(text),
            "timestamp": .number(1_720_000_000),
        ])
    }

    /// A latch that holds the open-seed's first-paint path until released
    /// (mirrors ChatStoreBatchBTests.Gate).
    private final class Gate: @unchecked Sendable {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        private let lock = NSLock()

        func wait() async {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                lock.lock()
                if released {
                    lock.unlock()
                    cont.resume()
                    return
                }
                continuation = cont
                lock.unlock()
            }
        }

        func release() {
            lock.lock()
            released = true
            let parked = continuation
            continuation = nil
            lock.unlock()
            parked?.resume()
        }
    }

    // MARK: - B1 — cold-start resume: relay transport, zero alerts

    /// REGRESSION (B1): a cold-start resume in relay mode must bind over the
    /// RELAY coordinator and NEVER stamp `sessionActionError`. On qa1/base the
    /// gateway-direct resume fired against the idle gateway socket and threw
    /// "Not connected to the Hermes gateway" into the modal alert channel on
    /// every cold open (the "Resume Session Failed" alert, IMG_2510).
    #if DEBUG
    func testRelayColdStartResumeBindsOverRelayAndNeverAlerts() async throws {
        let (_, sessions, _, coordinator, transport) = makeRelayGraph()
        try await coordinator.start(url: relayURL)
        // Cold cache restore selects/paints without binding (bindRuntime: false),
        // exactly like the launch path's `open(summary, bindRuntime: false)`.
        sessions.open(summary("stored-A"), bindRuntime: false)

        let runtimeId = await sessions.resumeActiveAfterReconnect()
        // The re-establishment (setForeground+open) is a best-effort Task —
        // wait for its RPC to land on the socket before pinning the wire.
        await waitUntil { transport.upstreams().contains { $0.method == "resume" || $0.method == "open" } }

        XCTAssertEqual(runtimeId, "stored-A", "relay resume must bind the stored id")
        XCTAssertEqual(sessions.activeRuntimeId, "stored-A")
        XCTAssertNil(sessions.sessionActionError, "relay resume must never raise a modal alert")
        XCTAssertTrue(
            transport.upstreams().contains { $0.method == "resume" || $0.method == "open" },
            "the rebind must travel the relay socket, not the idle gateway client (R3/W2d: the coordinator's adopt+open re-establishment IS the single per-reconnect reconcile — no separate resume RPC)"
        )
    }
    #endif

    /// REGRESSION (B1): a resume that lands while the relay socket is still
    /// connecting must QUEUE on transport readiness and drain when the socket
    /// opens — never fail fast, never alert. On qa1/base this either threw
    /// notConnected (alert) or waited on the gateway's readiness machinery that
    /// never re-resolves in relay mode.
    #if DEBUG
    func testRelayResumeQueuesOnTransportReadyAndDrainsOnConnect() async throws {
        let (_, sessions, _, coordinator, _) = makeRelayGraph()
        sessions.open(summary("stored-Q"), bindRuntime: false)

        let resumeTask = Task { await sessions.resumeActiveAfterReconnect() }
        // The socket is not up yet: the resume must be WAITING, not failed.
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(sessions.activeRuntimeId, "nothing can bind before the socket opens")
        XCTAssertNil(sessions.sessionActionError, "mid-connect resume is self-healing, never an alert")

        // Bring the relay up: the queued resume must drain and bind.
        try await coordinator.start(url: relayURL)
        let runtimeId = await resumeTask.value

        XCTAssertEqual(runtimeId, "stored-Q")
        XCTAssertEqual(sessions.activeRuntimeId, "stored-Q")
        XCTAssertNil(sessions.sessionActionError)
    }
    #endif

    /// REGRESSION (B1/B3-adjacent): tapping a session while the relay socket is
    /// mid-connect must wait for readiness and bind silently. On qa1/base
    /// `bindRelayRuntime` failed fast with `RelayError.notConnected` and stamped
    /// an "Open Session Failed" alert over a self-healing condition.
    #if DEBUG
    func testRelaySessionOpenWaitsForTransportInsteadOfAlerting() async throws {
        let (_, sessions, _, coordinator, _) = makeRelayGraph()

        sessions.open(summary("stored-S"))  // relay branch → bindRelayRuntime

        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(
            sessions.sessionActionError,
            "a socket still connecting is self-healing — no modal alert"
        )

        try await coordinator.start(url: relayURL)
        #if DEBUG
        await sessions.waitForPendingOpenForTesting()
        #endif
        XCTAssertEqual(sessions.activeRuntimeId, "stored-S", "the tap must bind once the relay is up")
        XCTAssertNil(sessions.sessionActionError)
    }
    #endif

    /// REGRESSION (B1 north star): even a genuine relay resume REJECTION must
    /// not raise a modal alert from the reconnect-resume path — it records
    /// `lastError` and self-heals on the next ready edge. On qa1/base every
    /// failure of `resumeActiveAfterReconnect` stamped `sessionActionError`.
    #if DEBUG
    func testRelayResumeRejectionRecordsButNeverAlerts() async throws {
        let (_, sessions, _, coordinator, transport) = makeRelayGraph()
        let fallback = defaultScript()
        transport.script = { up, relay in
            guard let id = up.id else { return }
            if up.method == "resume" {
                relay.deliverError(id: id, code: 4007, message: "session not found")
            } else {
                fallback(up, relay)
            }
        }
        try await coordinator.start(url: relayURL)
        sessions.open(summary("stored-E"), bindRuntime: false)

        let runtimeId = await sessions.resumeActiveAfterReconnect()

        // A durable id is not a runtime id. The reconnect path must ask the
        // relay to resume and return nil when that bind is rejected, while the
        // QA-1 north star still forbids a modal alert for this self-healing path.
        XCTAssertNil(runtimeId)
        await waitUntil { transport.upstreams().contains { $0.method == "resume" } }
        XCTAssertNil(
            sessions.sessionActionError,
            "relay resume failures self-heal on the next ready edge — never an alert"
        )
        XCTAssertTrue(
            transport.upstreams().contains { $0.method == "resume" },
            "the rebind traveled the relay socket, not the idle gateway client"
        )
    }
    #endif

    // MARK: - B4 — blank-screen impossible (cache → skeleton → content)

    /// REGRESSION (B4): an EMPTY relay projection must fall back to the painted
    /// transcript instead of blanking it. On qa1/base `applyRelayItems([])`
    /// assigned `messages = []` — the session-switch reset raced the cache seed
    /// and left a fully blank screen (IMG_2513/2516).
    func testApplyRelayItemsEmptyFallsBackToPaintedTranscript() {
        let chat = ChatStore()
        let row = StoredMessage(json: .object([
            "role": .string("assistant"), "content": .string("CACHE-PAINTED"),
        ]))!
        chat.seed(from: [row])
        XCTAssertFalse(chat.messages.isEmpty)

        chat.applyRelayItems([])  // the session-switch reset projects an empty store

        XCTAssertEqual(
            chat.messages.map(\.text), ["CACHE-PAINTED"],
            "an empty relay store must fall back to the painted (cached) transcript, never void"
        )
    }

    /// REGRESSION (B4, coordinator seam): opening a different session resets
    /// the render store, but must NOT blank the cache-painted transcript while
    /// the new session's content is in flight. On qa1/base the reset's
    /// `applyRelayItems([])` wiped `messages` mid-open.
    #if DEBUG
    func testSessionSwitchResetKeepsPaintedTranscriptUntilNewContent() async throws {
        let chat = ChatStore()
        let transport = MockRelay()
        transport.script = defaultScript()
        let coordinator = RelaySessionCoordinator(
            chatStore: chat,
            clientFactory: { RelayClient(ackInterval: nil, transportFactory: { _ in transport }) }
        )
        try await coordinator.start(url: relayURL)

        // The cache seed paints the new session's transcript first (cache-first
        // open), THEN the relay open's reset lands — the painted rows must
        // survive the empty projection until relay content arrives.
        let row = StoredMessage(json: .object([
            "role": .string("assistant"), "content": .string("CACHE-PAINTED"),
        ]))!
        chat.seed(from: [row])

        _ = try await coordinator.open("session-B")

        XCTAssertEqual(
            chat.messages.map(\.text), ["CACHE-PAINTED"],
            "the open-path reset must not blank the cache-painted transcript"
        )
    }
    #endif

    /// REGRESSION (B4 view hole): `transcriptPlaceholder` must return the
    /// skeleton — never an empty `.transcript` — for an empty transcript at
    /// generation > 0 UNLESS an authoritative seed confirmed the session is
    /// genuinely empty. On qa1/base this state rendered `.transcript` (a blank
    /// screen: no skeleton, no content). NOTE: the `transcriptConfirmedEmpty`
    /// parameter does not exist on qa1/base, so this test is red there by
    /// compilation as well as by the first assertion's expectation.
    func testTranscriptPlaceholderNeverRendersVoidAtBumpedGeneration() {
        // Wiped-mid-open state (the B4 race): skeleton fallback, never void.
        XCTAssertEqual(
            ChatView.transcriptPlaceholder(
                isDraft: false,
                messagesEmpty: true,
                transcriptGeneration: 1,
                transcriptConfirmedEmpty: false,
                isGatewayOffline: false,
                loadError: nil
            ),
            .skeleton,
            "empty at generation>0 without confirmation must fall back to the skeleton"
        )
        // Honest empty (authoritative seed landed zero rows): renders rows.
        XCTAssertEqual(
            ChatView.transcriptPlaceholder(
                isDraft: false,
                messagesEmpty: true,
                transcriptGeneration: 1,
                transcriptConfirmedEmpty: true,
                isGatewayOffline: false,
                loadError: nil
            ),
            .transcript,
            "a seed-confirmed empty session is an honest empty transcript"
        )
        // Pristine (never seeded): unchanged skeleton chain.
        XCTAssertEqual(
            ChatView.transcriptPlaceholder(
                isDraft: false,
                messagesEmpty: true,
                transcriptGeneration: 0,
                isGatewayOffline: false,
                loadError: nil
            ),
            .skeleton
        )
    }

    /// Pins the `transcriptConfirmedEmpty` lifecycle that the placeholder hole
    /// fix relies on: an empty authoritative seed confirms; any content
    /// (seed or relay projection) and every reset unconfirms.
    func testTranscriptConfirmedEmptyLifecycle() {
        let chat = ChatStore()
        XCTAssertFalse(chat.transcriptConfirmedEmpty)

        chat.seed(from: [])
        XCTAssertTrue(chat.transcriptConfirmedEmpty, "an empty seed is an honest empty")

        let row = StoredMessage(json: .object([
            "role": .string("assistant"), "content": .string("x"),
        ]))!
        chat.seed(from: [row])
        XCTAssertFalse(chat.transcriptConfirmedEmpty, "content unconfirms")

        chat.seed(from: [])
        XCTAssertTrue(chat.transcriptConfirmedEmpty)
        chat.reset()
        XCTAssertFalse(chat.transcriptConfirmedEmpty, "reset re-opens the unconfirmed state")
    }

    // MARK: - B2 — cache-miss switch seeds over the relay, not gateway REST

    /// REGRESSION (B2): a cache-miss open in relay mode must seed from the
    /// relay `history` RPC (the transport that is UP) instead of gateway REST
    /// (unreachable in relay-only mode → 15s timeout → skeleton "forever",
    /// IMG_2511/2512). On qa1/base the fetch went to `connection.rest` and the
    /// transcript stayed empty/errored.
    #if DEBUG
    func testRelayCacheMissOpenFetchesHistoryExactlyOnce() async throws {
        // No cache is attached and RESUME deliberately emits no snapshot — the
        // physical-device cold shape. Correctness comes from exactly one relay
        // history result, never gateway REST and never another session's rows.
        let (_, sessions, chat, coordinator, transport) = makeRelayGraph()
        let history = [storedRow("assistant", "RELAY-HISTORY-A", id: 1)]
        transport.script = { up, relay in
            guard let id = up.id else { return }
            let sid = (up.params["session_id"] as? String) ?? ""
            if up.method == "history" {
                relay.deliverResult(id: id, result: .object([
                    "session_id": .string(sid), "messages": .array(history),
                ]))
            } else {
                relay.deliverResult(id: id, result: .object([
                    "session_id": .string(sid),
                ]))
            }
        }
        try await coordinator.start(url: relayURL)

        sessions.open(summary("stored-miss"))  // no cache attached → cache-miss path
        await sessions.waitForPendingOpenForTesting()
        await waitUntil { chat.messages.map(\.text).contains("RELAY-HISTORY-A") }

        XCTAssertTrue(
            chat.messages.map(\.text).contains("RELAY-HISTORY-A"),
            "the unavailable-cache seed must come from relay history"
        )
        XCTAssertFalse(chat.messages.map(\.text).contains("OTHER-SESSION"))
        XCTAssertEqual(
            transport.upstreams().filter { $0.method == "history" }.count, 1,
            "I14: a genuine cache miss gets exactly one history fetch"
        )
    }
    #endif

    /// The relay history result decoder must map the proxied gateway rows
    /// (`{"session_id", "messages": […]}`) to `StoredMessage` verbatim — the
    /// same rows `RestClient.messages` would decode off gateway REST.
    func testRelayHistoryDecoderMapsProxiedGatewayRows() {
        let result: JSONValue = .object([
            "session_id": .string("s"),
            "messages": .array([storedRow("assistant", "row-one", id: 1),
                                storedRow("user", "row-two", id: 2)]),
        ])
        let decoded = SessionStore.relayHistoryMessages(from: result)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded.map(\.role), ["assistant", "user"])
        XCTAssertEqual(decoded.compactMap(\.wireId), [1, 2])
        XCTAssertTrue(SessionStore.relayHistoryMessages(from: .object([:])).isEmpty)
    }

    // MARK: - B3 — drawer closes on session tap 100%

    /// REGRESSION (B3): a reveal-LESS `open()` rotating `openToken` inside the
    /// reveal window (cold cache restore, cross-session review, land/recovery)
    /// must NOT strand the drawer open — the tap's dismissal intent survives
    /// the rotation and the liveness deadline fires it. On qa1/base the
    /// rotation cleared `openRevealToken` and gated the deadline on the dead
    /// token, so nothing ever closed the drawer (IMG_2511/2514).
    #if DEBUG
    func testRevealLessOpenRotationCannotStrandDrawerOpen() async {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        let gate = Gate()
        sessions.beforeOpenSeedForTesting = { await gate.wait() }

        var revealCount = 0
        sessions.open(summary("stored-A")) { revealCount += 1 }   // drawer tap
        sessions.open(summary("stored-B"))                        // reveal-less rotation

        try? await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(
            revealCount, 1,
            "the drawer tap's close must survive a reveal-less open() rotation"
        )

        gate.release()
        await sessions.waitForPendingOpenForTesting()
        XCTAssertEqual(revealCount, 1, "the close is exactly-once")
    }
    #endif

    /// Pins the existing R40 contract still holds after the B3 rework: a
    /// SECOND drawer tap supersedes the first tap's close (only the latest
    /// reveal fires), and first paint still consumes the intent before the
    /// deadline when nothing rotates the token.
    #if DEBUG
    func testSecondDrawerTapSupersedesFirstRevealExactlyOnce() async {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        let gate = Gate()
        sessions.beforeOpenSeedForTesting = { await gate.wait() }

        var reveals: [String] = []
        sessions.open(summary("stored-A")) { reveals.append("A") }
        sessions.open(summary("stored-B")) { reveals.append("B") }

        try? await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(reveals, ["B"], "only the latest drawer tap owns the close")

        gate.release()
        await sessions.waitForPendingOpenForTesting()
        XCTAssertEqual(reveals, ["B"], "stale first paint must not double-close")
    }
    #endif
}
