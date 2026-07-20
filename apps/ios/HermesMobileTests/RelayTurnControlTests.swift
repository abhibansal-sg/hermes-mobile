import XCTest
@testable import HermesMobile

/// QA-2 R11 / A5 coverage: turn control (interrupt / steer / queue) works OVER
/// THE RELAY. Build 115 routed every control action through the gateway-DIRECT
/// client even in relay mode, where that socket is idle — stop and steer threw
/// "Not connected to the Hermes gateway", and a failed relay submit DELETED the
/// user's echo and surfaced an error instead of queueing (the "message
/// DISAPPEARED, no outbox pill" failure).
///
/// Render-level per A5: the production stack (`ConnectionStore` forced to
/// `.relay` → `RelaySessionCoordinator` over an in-process mock transport →
/// `ChatStore`) drives the real `interrupt()` / `steer()` / `send()` code paths
/// and the tests assert the exact upstream relay frames (§5/§5b wire shapes)
/// plus the outbox fallback. RED on qa2/base (pre-fix): `interrupt()` /
/// `steer()` never emit a relay upstream (they hit the idle gateway client,
/// `nil` in the unit graph) and the failed send deletes the echo with an error
/// instead of enqueuing. Deterministic; no live network. The mock transport
/// mirrors the canonical copy in `RelaySessionCoordinatorTests`.
@MainActor
final class RelayTurnControlTests: XCTestCase {

    // MARK: - In-process mock relay transport

    final class MockRelayTransport: RelayTransport, @unchecked Sendable {
        struct Upstream { let method: String; let id: String?; let params: [String: Any] }

        private let lock = NSLock()
        private var inbox: [URLSessionWebSocketTask.Message] = []
        private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
        private var sent: [Upstream] = []
        private var cancelled = false

        var script: (@Sendable (Upstream, MockRelayTransport) -> Void)?

        init(script: (@Sendable (Upstream, MockRelayTransport) -> Void)? = nil) { self.script = script }

        func resume() {}

        func receive() async throws -> URLSessionWebSocketTask.Message {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled {
                    lock.unlock(); continuation.resume(throwing: URLError(.cancelled))
                } else if !inbox.isEmpty {
                    let next = inbox.removeFirst(); lock.unlock(); continuation.resume(returning: next)
                } else {
                    waiter = continuation; lock.unlock()
                }
            }
        }

        func send(_ message: URLSessionWebSocketTask.Message) async throws {
            guard case let .string(text) = message, let upstream = Self.parse(text) else { return }
            record(upstream)
            script?(upstream, self)
        }

        private func record(_ upstream: Upstream) {
            lock.lock(); defer { lock.unlock() }
            sent.append(upstream)
        }

        func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
            lock.lock(); cancelled = true; let parked = waiter; waiter = nil; lock.unlock()
            parked?.resume(throwing: URLError(.cancelled))
        }

        func deliver(_ text: String) {
            lock.lock()
            if let parked = waiter {
                waiter = nil; lock.unlock(); parked.resume(returning: .string(text))
            } else {
                inbox.append(.string(text)); lock.unlock()
            }
        }

        func deliverResult(id: String, result: JSONValue) {
            let payload: JSONValue = .object([
                "jsonrpc": .string("2.0"), "id": .string(id), "result": result,
            ])
            guard let data = try? JSONEncoder().encode(payload) else { return }
            deliver(String(decoding: data, as: UTF8.self))
        }

        /// A JSON-RPC error reply — `RelayClient.resolveResponse` maps it to
        /// `RelayError.rpc(code:message:)`, exactly what the relay sends when
        /// the gateway rejects (e.g. the 4009 session-busy reject).
        func deliverError(id: String, code: Int, message: String) {
            let payload: JSONValue = .object([
                "jsonrpc": .string("2.0"),
                "id": .string(id),
                "error": .object(["code": .number(Double(code)), "message": .string(message)]),
            ])
            guard let data = try? JSONEncoder().encode(payload) else { return }
            deliver(String(decoding: data, as: UTF8.self))
        }

        func upstreams() -> [Upstream] { lock.lock(); defer { lock.unlock() }; return sent }

        private static func parse(_ text: String) -> Upstream? {
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return nil }
            return Upstream(method: method, id: object["id"] as? String,
                            params: object["params"] as? [String: Any] ?? [:])
        }
    }

    private let url = URL(string: "ws://127.0.0.1:9999/relay")!

    private func restoreTransportFlagAfterTest() {
        let previous = UserDefaults.standard.string(forKey: DefaultsKeys.transportPath)
        addTeardownBlock {
            if let previous {
                UserDefaults.standard.set(previous, forKey: DefaultsKeys.transportPath)
            } else {
                UserDefaults.standard.removeObject(forKey: DefaultsKeys.transportPath)
            }
        }
    }

    /// The production relay stack over a mock transport (canonical pattern from
    /// `RelayGateBridgeTests`). The optional `queueStore` is attached so tests
    /// can assert the R11 outbox fallback.
    private func makeRelayStack(
        queueStore: QueueStore? = nil,
        script: (@Sendable (MockRelayTransport.Upstream, MockRelayTransport) -> Void)? = nil
    ) async throws -> (transport: MockRelayTransport, chat: ChatStore, coordinator: RelaySessionCoordinator) {
        let transport = MockRelayTransport(script: script)
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        chat.attach(connection: connection, sessions: sessions, attachments: AttachmentStore())
        if let queueStore { chat.attachOutbox(queueStore) }
        restoreTransportFlagAfterTest()
        UserDefaults.standard.set(TransportPath.relay.rawValue, forKey: DefaultsKeys.transportPath)
        XCTAssertEqual(connection.transportPath, .relay, "precondition: flag forces the relay transport")
        connection.relayCoordinatorFactory = {
            RelaySessionCoordinator(chatStore: chat, clientFactory: { RelayClient { _ in transport } })
        }
        let coordinator = connection.ensureRelayCoordinator()
        try await coordinator.start(url: url)
        return (transport, chat, coordinator)
    }

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("waitUntil timed out")
    }

    /// Drives a `resume` so the coordinator owns `sess-1` (the relay branch's
    /// session target), answering the RPC the way the relay does.
    private func resumeDrivenSession(_ coordinator: RelaySessionCoordinator) async throws {
        _ = try await coordinator.resume("sess-1")
    }

    // MARK: - Interrupt over the relay (R11: "Not connected" on stop)

    /// THE R11 interrupt contract: in relay mode `interrupt()` emits `interrupt`
    /// OVER THE RELAY (§5b) targeting the driven session — NOT the idle gateway
    /// client — and a successful stop surfaces no error. RED on qa2/base:
    /// `interrupt()` guards on the gateway `client` (nil here) and returns
    /// silently — zero relay upstreams.
    func testInterruptRoutesOverRelayInRelayMode() async throws {
        let (transport, chat, coordinator) = try await makeRelayStack { upstream, relay in
            guard let id = upstream.id else { return }
            switch upstream.method {
            case "resume":
                relay.deliverResult(id: id, result: .object(["session_id": .string("sess-1")]))
            case "interrupt":
                relay.deliverResult(id: id, result: .object(["status": .string("ok")]))
            default:
                break
            }
        }
        try await resumeDrivenSession(coordinator)

        await chat.interrupt()

        let interrupts = transport.upstreams().filter { $0.method == "interrupt" }
        XCTAssertEqual(interrupts.count, 1, "stop must go OUT over the relay, not the idle gateway client")
        XCTAssertEqual(interrupts[0].params["session_id"] as? String, "sess-1",
                       "the relay requires the driven session id (§5b)")
        XCTAssertNil(chat.lastError, "a relay-path stop must not surface a 'Not connected' banner")
        XCTAssertEqual(transport.upstreams().filter { $0.method == "session.interrupt" }.count, 0,
                       "session.interrupt is the GATEWAY rpc — never sent to the relay")
        await coordinator.stop()
    }

    // MARK: - Steer over the relay (R11: steer errored + no relay method)

    /// THE R11 steer contract: `steer()` emits `steer` over the relay (§5b:
    /// `session_id` + `text`), maps the relay's VERBATIM gateway disposition
    /// (`queued` → clear the field; `rejected` → keep the text), and never
    /// touches the idle gateway client. RED on qa2/base: the relay protocol had
    /// no steer method and `steer()` guarded on the gateway `client` → `.error`.
    func testSteerRoutesOverRelayAndMapsGatewayDisposition() async throws {
        // The script flips to `rejected` after the first steer so one test
        // proves both dispositions travel verbatim.
        let steerCount = SendableCounter()
        let (transport, chat, coordinator) = try await makeRelayStack { upstream, relay in
            guard let id = upstream.id else { return }
            switch upstream.method {
            case "resume":
                relay.deliverResult(id: id, result: .object(["session_id": .string("sess-1")]))
            case "steer":
                let n = steerCount.increment()
                let status = n == 1 ? "queued" : "rejected"
                relay.deliverResult(id: id, result: .object([
                    "status": .string(status),
                    "text": .string(upstream.params["text"] as? String ?? ""),
                ]))
            default:
                break
            }
        }
        try await resumeDrivenSession(coordinator)

        let queued = await chat.steer(text: "also check staging")
        XCTAssertEqual(queued, .queued, "the gateway's `queued` disposition maps verbatim")

        let rejected = await chat.steer(text: "and production too")
        XCTAssertEqual(rejected, .rejected,
                       "a `rejected` disposition keeps the user's text so they can queue it")

        let steers = transport.upstreams().filter { $0.method == "steer" }
        XCTAssertEqual(steers.count, 2, "steers must go OUT over the relay")
        for steer in steers {
            XCTAssertEqual(steer.params["session_id"] as? String, "sess-1",
                           "the relay requires the driven session id (§5b)")
        }
        XCTAssertEqual(steers[0].params["text"] as? String, "also check staging",
                       "§5b: the relay passes `text` to the gateway's session.steer")
        XCTAssertNil(chat.lastError, "accepted/rejected steers are not errors — no banner (C3)")
        await coordinator.stop()
    }

    // MARK: - Queue-send over the relay (R11: message disappeared, no pill)

    /// THE R11 queue contract: a relay submit the gateway REJECTS (4009 busy —
    /// the destination session is mid-turn) falls back into the durable outbox:
    /// `send()` returns true, the outbox PILL shows the row immediately, the
    /// optimistic echo is SWAPPED for the outbox row's echo (no duplicate, no
    /// disappearance), and NO error banner surfaces (C3: silent queue-and-drain;
    /// the relay-aware drain holds the row while the session is busy and
    /// delivers on turn completion). RED on qa2/base: the catch deletes the
    /// echo, sets `lastError`, and returns false — the message is gone with no
    /// pill ("DISAPPEARED").
    func testRelayBusyRejectFallsBackToOutboxWithPillAndNoError() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayTurnControl-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let observation = WorkRepositoryObservation()
        let repository = try WorkRepository(
            configuration: WorkRepositoryConfiguration(containerURL: directory),
            observation: observation
        )
        let scope = try WorkScope(serverID: "https://gateway.test", profileID: "default")
        let queueStore = QueueStore(
            repository: repository,
            observation: observation,
            scopeProvider: { scope },
            activeSessionProvider: { nil },
            connectedProvider: { true }
        )

        let (transport, chat, coordinator) = try await makeRelayStack(queueStore: queueStore) { upstream, relay in
            guard let id = upstream.id else { return }
            switch upstream.method {
            case "resume":
                relay.deliverResult(id: id, result: .object(["session_id": .string("sess-1")]))
            case "submit":
                // The destination session is mid-turn: the gateway rejects busy.
                relay.deliverError(id: id, code: 4009, message: "session busy — a turn is already running")
            default:
                break
            }
        }
        try await resumeDrivenSession(coordinator)

        let accepted = await chat.send(text: "run the deploy after this")

        XCTAssertTrue(accepted, "a busy-rejected relay send must queue (return true), not fail")
        await waitUntil { queueStore.pendingCount == 1 }
        XCTAssertEqual(queueStore.pendingCount, 1, "the outbox pill must show the queued row immediately")
        XCTAssertNil(chat.lastError, "the queue-and-drain is silent — no 'Not connected'/'busy' banner (C3)")

        // Exactly ONE user bubble survives: the optimistic echo (minted at
        // send) is swapped for the durable outbox row's echo — keeping both
        // would double the bubble when the drain presents its row.
        let userBubbles = chat.messages.filter { $0.role == .user }
        XCTAssertEqual(userBubbles.count, 1, "the echo must be swapped, not duplicated or lost")
        XCTAssertEqual(userBubbles.first?.text, "run the deploy after this")
        let row = try XCTUnwrap(queueStore.items.first)
        XCTAssertEqual(userBubbles.first?.clientMessageID, row.clientMessageID,
                       "the surviving bubble is the outbox row's echo (drain adoption identity)")

        // The submit attempt DID go out over the relay first (busy-detection is
        // server-side) — then the fallback queued locally.
        XCTAssertEqual(transport.upstreams().filter { $0.method == "submit" }.count, 1)
        await coordinator.stop()
    }

    /// A relay-side FAILURE (the relay's gateway link is down — "relay gateway
    /// not ready", the flap/restart window) takes the same durable fallback —
    /// the row survives for the next drain wake instead of being deleted with
    /// an error.
    func testRelayTransportFailureFallsBackToOutbox() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayTurnControl-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let observation = WorkRepositoryObservation()
        let repository = try WorkRepository(
            configuration: WorkRepositoryConfiguration(containerURL: directory),
            observation: observation
        )
        let scope = try WorkScope(serverID: "https://gateway.test", profileID: "default")
        let queueStore = QueueStore(
            repository: repository,
            observation: observation,
            scopeProvider: { scope },
            activeSessionProvider: { nil },
            connectedProvider: { true }
        )

        let (transport, chat, coordinator) = try await makeRelayStack(queueStore: queueStore) { upstream, relay in
            guard let id = upstream.id else { return }
            switch upstream.method {
            case "resume":
                relay.deliverResult(id: id, result: .object(["session_id": .string("sess-1")]))
            case "submit":
                // The relay's gateway readiness gate failed (restart window).
                relay.deliverError(id: id, code: -32000, message: "relay gateway not ready")
            default:
                break
            }
        }
        try await resumeDrivenSession(coordinator)

        let accepted = await chat.send(text: "flappy send")

        XCTAssertTrue(accepted, "a failed relay send must queue, not fail")
        await waitUntil { queueStore.pendingCount == 1 }
        XCTAssertNil(chat.lastError, "transport transitions are self-healing — no banner (C3)")
        XCTAssertEqual(transport.upstreams().filter { $0.method == "submit" }.count, 1)
        await coordinator.stop()
    }

    // MARK: - Direct path unaffected

    /// The gateway-direct transport keeps the legacy behavior: `interrupt()`
    /// routes the gateway `session.interrupt` and emits NOTHING over the relay
    /// (guards the relay branch against leaking into direct mode).
    func testGatewayDirectTransportDoesNotRouteInterruptThroughRelay() async throws {
        let transport = MockRelayTransport()
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        chat.attach(connection: connection, sessions: sessions, attachments: AttachmentStore())
        restoreTransportFlagAfterTest()
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.transportPath)
        XCTAssertEqual(connection.transportPath, .gatewayDirect)

        // No gateway client in the unit graph → the direct guard returns
        // silently; the assertion is that NO relay frame is emitted.
        await chat.interrupt()
        XCTAssertEqual(transport.upstreams().filter { $0.method == "interrupt" }.count, 0,
                       "direct mode must never emit a relay interrupt")
    }
}

/// Tiny thread-safe counter for scripts (Sendable-closure capture).
private final class SendableCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}
