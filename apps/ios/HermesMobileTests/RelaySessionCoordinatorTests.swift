import XCTest
@testable import HermesMobile

/// Wave-2 convergence wiring coverage (docs/RELAY-PHONE-PROTOCOL.md). Proves the
/// three acceptance properties of wiring the app to the relay BEHIND A FLAG:
///
/// 1. the transport flag defaults OFF (`.gatewayDirect`) and parses correctly;
/// 2. `ChatStore.applyRelayItems` projects reconciled relay items into the
///    transcript (user bubble + assistant item parts, streaming while live);
/// 3. `RelaySessionCoordinator`, driven by a MOCK relay transport, streams
///    decoded item frames into `ChatStore` AND routes upstream session ops to
///    the relay.
///
/// No live network — the coordinator's `RelayClient` is built over an in-process
/// fake relay, mirroring `RelayClientMockTests`.
@MainActor
final class RelaySessionCoordinatorTests: XCTestCase {

    // MARK: - In-process mock relay transport

    /// Minimal fake relay: `receive()` hands back queued downstream messages;
    /// `send` records the upstream frame and runs an optional `script`.
    final class MockRelayTransport: RelayTransport, @unchecked Sendable {
        struct Upstream { let method: String; let id: String?; let params: [String: Any] }

        private let lock = NSLock()
        private var inbox: [URLSessionWebSocketTask.Message] = []
        private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
        private var sent: [Upstream] = []
        private var cancelled = false
        private var failed = false

        var script: (@Sendable (Upstream, MockRelayTransport) -> Void)?

        init(script: (@Sendable (Upstream, MockRelayTransport) -> Void)? = nil) { self.script = script }

        func resume() {}

        func receive() async throws -> URLSessionWebSocketTask.Message {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled {
                    lock.unlock(); continuation.resume(throwing: URLError(.cancelled))
                } else if failed {
                    failed = false; lock.unlock()
                    continuation.resume(throwing: URLError(.networkConnectionLost))
                } else if !inbox.isEmpty {
                    let next = inbox.removeFirst(); lock.unlock(); continuation.resume(returning: next)
                } else {
                    waiter = continuation; lock.unlock()
                }
            }
        }

        /// Simulate an unexpected transport drop: the parked `receive()` throws a
        /// NON-cancelled error, which the client maps to `.failed` (a real drop,
        /// distinct from an intentional `cancel` → `.closed`).
        func fail() {
            lock.lock()
            if let parked = waiter {
                waiter = nil; lock.unlock()
                parked.resume(throwing: URLError(.networkConnectionLost))
            } else {
                failed = true; lock.unlock()
            }
        }

        func send(_ message: URLSessionWebSocketTask.Message) async throws {
            guard case let .string(text) = message, let upstream = Self.parse(text) else { return }
            record(upstream)   // sync helper: NSLock is unavailable directly in an async context
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

        func deliverFrame(_ frame: RelayFrame) {
            guard let data = try? JSONEncoder().encode(frame) else { return }
            deliver(String(decoding: data, as: UTF8.self))
        }

        func deliverFrames(_ frames: [RelayFrame]) { frames.forEach(deliverFrame) }

        func deliverResult(id: String, result: JSONValue) {
            let payload: JSONValue = .object([
                "jsonrpc": .string("2.0"), "id": .string(id), "result": result,
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

    // MARK: - Frame builders

    private func itemFrame(_ seq: Int, kind: String, id: String, _ type: ChatItemType,
                           status: String, ord: Int, body: JSONValue) -> RelayFrame {
        RelayFrame(seq: seq, sid: "s", turn: "t", kind: RelayFrameKind(wire: kind), body: .object([
            "item_id": .string(id), "type": .string(type.rawValue),
            "status": .string(status), "ord": .number(Double(ord)), "body": body,
        ]))
    }

    /// A turn: user prompt → agent message (started, delta, completed) → a tool
    /// call (a special-render `.item`) between them.
    private func sampleTurn() -> [RelayFrame] {
        [
            itemFrame(1, kind: "item.completed", id: "user-1", .userMessage,
                      status: "completed", ord: 0, body: ["text": "Refactor the parser"]),
            itemFrame(2, kind: "item.started", id: "msg-1", .agentMessage,
                      status: "in_progress", ord: 1, body: ["text": ""]),
            RelayFrame(seq: 3, sid: "s", turn: "t", kind: .itemDelta,
                       body: .object(["item_id": .string("msg-1"), "patch": .object(["text": .string("Working…")])])),
            itemFrame(4, kind: "item.completed", id: "tool-1", .toolCall,
                      status: "completed", ord: 2, body: ["name": "read_file"]),
            itemFrame(5, kind: "item.completed", id: "msg-1", .agentMessage,
                      status: "completed", ord: 1, body: ["text": "Done."]),
        ]
    }

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("waitUntil timed out")
    }

    // MARK: - (1) Flag defaults OFF

    func testTransportFlagDefaultsToGatewayDirect() {
        let suite = UserDefaults(suiteName: "relay.flag.default.\(UUID().uuidString)")!
        // Absent key ⇒ gateway-direct (default OFF).
        XCTAssertEqual(DefaultsKeys.transportPathValue(suite), .gatewayDirect)
        // Unrecognised value ⇒ still gateway-direct.
        suite.set("garbage", forKey: DefaultsKeys.transportPath)
        XCTAssertEqual(DefaultsKeys.transportPathValue(suite), .gatewayDirect)
        // Explicit relay is honoured.
        suite.set(TransportPath.relay.rawValue, forKey: DefaultsKeys.transportPath)
        XCTAssertEqual(DefaultsKeys.transportPathValue(suite), .relay)
    }

    func testRelayControlURLUsesHTTPSiblingAndDropsWebSocketPath() {
        let key = DefaultsKeys.transportPath
        let previous = UserDefaults.standard.string(forKey: key)
        let previousOverride = UserDefaults.standard.string(forKey: DefaultsKeys.relayURLOverride)
        UserDefaults.standard.set(TransportPath.relay.rawValue, forKey: key)
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.relayURLOverride)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
            if let previousOverride {
                UserDefaults.standard.set(previousOverride, forKey: DefaultsKeys.relayURLOverride)
            } else {
                UserDefaults.standard.removeObject(forKey: DefaultsKeys.relayURLOverride)
            }
        }
        let connection = ConnectionStore(sessionStore: SessionStore(), chatStore: ChatStore())
        let url = connection.relayControlURL(
            forGateway: URL(string: "https://gateway.example:9119")!
        )
        XCTAssertEqual(url?.absoluteString, "https://gateway.example:9119")
    }

    // MARK: - (2) ChatStore projection

    func testApplyRelayItemsProjectsTranscript() {
        let store = RelayItemStore()
        var mutable = store
        mutable.apply(sampleTurn())
        let chat = ChatStore()

        chat.applyRelayItems(mutable.items)

        // A user bubble, then an assistant segment carrying the tool `.item` and
        // the completed agent text.
        XCTAssertEqual(chat.messages.count, 2)
        XCTAssertEqual(chat.messages[0].role, .user)
        XCTAssertEqual(chat.messages[0].text, "Refactor the parser")

        let assistant = chat.messages[1]
        XCTAssertEqual(assistant.role, .assistant)
        XCTAssertFalse(assistant.isStreaming, "a fully-completed turn is not streaming")
        // The tool item projects to a `.item` part; the agent message to `.text`.
        let hasToolItem = assistant.parts.contains { if case .item(_, let i) = $0 { return i.itemID == "tool-1" }; return false }
        let agentText = assistant.parts.contains { if case .text(_, let t) = $0 { return t == "Done." }; return false }
        XCTAssertTrue(hasToolItem, "special-render toolCall must project to a .item part")
        XCTAssertTrue(agentText, "agentMessage must project to a .text part")
    }

    func testApplyRelayItemsIsStableAcrossReprojection() {
        let chat = ChatStore()
        var store = RelayItemStore()
        store.apply(Array(sampleTurn().prefix(3)))   // through the in-progress delta
        chat.applyRelayItems(store.items)
        let firstIDs = chat.messages.map(\.id)
        XCTAssertTrue(chat.isStreaming, "an in-progress trailing item keeps the turn streaming")

        store.apply(Array(sampleTurn().suffix(2)))   // tool + completion land
        chat.applyRelayItems(store.items)
        // Message identities are derived from stable relay ids, so the same rows
        // keep their ids across re-projection (no SwiftUI churn).
        XCTAssertEqual(chat.messages.map(\.id).prefix(firstIDs.count), ArraySlice(firstIDs))
        XCTAssertFalse(chat.isStreaming, "after the completion lands the turn settles")
    }

    // MARK: - (3) Coordinator streams into ChatStore + routes ops

    func testCoordinatorStreamsFramesIntoTranscript() async throws {
        let transport = MockRelayTransport()
        let chat = ChatStore()
        let coordinator = RelaySessionCoordinator(
            chatStore: chat,
            clientFactory: { RelayClient { _ in transport } }
        )

        try await coordinator.start(url: url)
        transport.deliverFrames(sampleTurn())

        await waitUntil { chat.messages.count == 2 && chat.messages.last?.role == .assistant }
        XCTAssertEqual(chat.messages.first?.role, .user)
        XCTAssertEqual(coordinator.store.items.map(\.itemID), ["user-1", "msg-1", "tool-1"])
        let assistant = chat.messages[1]
        XCTAssertTrue(assistant.parts.contains { if case .item = $0 { return true }; return false })

        await coordinator.stop()
        XCTAssertEqual(coordinator.phase, .idle)
    }

    /// Switching the projected session via `open` must NOT leak the previous
    /// session's items. `RelayItemStore.reconcile(snapshot:)` retains items
    /// absent from the snapshot, so without a reset on switch, session B's
    /// snapshot would fold on top of session A's and the transcript would render
    /// both. The coordinator clears the render store on a session switch.
    func testOpenDifferentSessionDoesNotLeakPreviousSessionItems() async throws {
        // Each `open` delivers a snapshot scoped to the opened session id.
        let transport = MockRelayTransport(script: { upstream, relay in
            guard let id = upstream.id, upstream.method == "open",
                  let sid = upstream.params["session_id"] as? String else { return }
            let itemID = "\(sid)-item"
            let snapshot = RelayFrame(
                seq: sid == "A" ? 1 : 2, sid: sid, turn: nil, kind: .snapshot,
                body: .object([
                    "items": .array([.object([
                        "item_id": .string(itemID),
                        "type": .string(ChatItemType.userMessage.rawValue),
                        "status": .string("completed"),
                        "ord": .number(0),
                        "body": .object(["text": .string("hello from \(sid)")]),
                    ])]),
                    "cursor": .number(Double(sid == "A" ? 1 : 2)),
                ]))
            relay.deliverFrame(snapshot)
            relay.deliverResult(id: id, result: .object(["ok": .bool(true)]))
        })
        let chat = ChatStore()
        let coordinator = RelaySessionCoordinator(
            chatStore: chat,
            clientFactory: { RelayClient { _ in transport } }
        )
        try await coordinator.start(url: url)

        _ = try await coordinator.open("A")
        await waitUntil { coordinator.store.items.map(\.itemID) == ["A-item"] }

        _ = try await coordinator.open("B")
        // The store must hold ONLY session B's item — A's must be gone.
        await waitUntil { coordinator.store.items.map(\.itemID) == ["B-item"] }
        XCTAssertEqual(coordinator.store.items.map(\.itemID), ["B-item"],
                       "opening session B must not retain session A's items")
        XCTAssertFalse(chat.messages.contains { $0.text.contains("hello from A") },
                       "transcript must not still show session A's projected content")
        XCTAssertEqual(coordinator.activeSessionID, "B")

        await coordinator.stop()
    }

    // MARK: - (4) Relay reliability: drain-on-(re)connect

    /// Thread-safe vendor of fresh mock transports, one per `connect` — a
    /// reconnect tears the prior socket down and dials a new one, so reusing a
    /// single (now-cancelled) mock would wedge the second dial.
    private final class TransportVendor: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var made: [MockRelayTransport] = []
        func make() -> MockRelayTransport {
            lock.lock(); defer { lock.unlock() }
            let transport = MockRelayTransport()
            made.append(transport)
            return transport
        }
    }

    /// The `onReady` hook is the relay analogue of the gateway's `gateway.ready`
    /// wake: it must fire once when the socket first comes up AND again on every
    /// reconnect after a drop/flap, so the durable outbox drains the message the
    /// user queued while the relay was mid-connect. Exactly-once per connect (no
    /// double-fire from the buffered `.connecting`→`.open` pair).
    func testOnReadyFiresOnceOnConnectAndAgainOnReconnect() async throws {
        let vendor = TransportVendor()
        let coordinator = RelaySessionCoordinator(
            chatStore: ChatStore(),
            clientFactory: { RelayClient { _ in vendor.make() } }
        )
        var readyCount = 0
        coordinator.onReady = { readyCount += 1 }

        try await coordinator.start(url: url)
        await waitUntil { readyCount >= 1 }
        XCTAssertEqual(readyCount, 1, "the initial connect fires the readiness edge exactly once")

        // Simulate a drop + reconnect (the gateway mid-flap the bug reproduces).
        await coordinator.reconnect(url: url)
        await waitUntil { readyCount >= 2 }
        XCTAssertEqual(readyCount, 2, "a reconnect after a drop fires the readiness edge again")

        await coordinator.stop()
    }

    #if DEBUG
    /// End-to-end of the fix: on the relay path the durable outbox drains OVER
    /// THE RELAY (the gateway client is idle), and the drain gate tracks the live
    /// relay socket. A send that lands while the relay is down enqueues quietly
    /// (gate closed) and delivers once the relay is open — over the relay submit
    /// RPC, exactly once, with an accepted receipt so it never stays pending.
    func testOutboxDrainRoutesSubmitOverRelayAndGateTracksSocket() async throws {
        let key = DefaultsKeys.transportPath
        let previous = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(TransportPath.relay.rawValue, forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        let transport = MockRelayTransport(script: { upstream, relay in
            guard let id = upstream.id, upstream.method == "submit" else { return }
            relay.deliverResult(id: id, result: .object(["session_id": .string("sess-9")]))
        })
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        connection.relayCoordinatorFactory = {
            RelaySessionCoordinator(
                chatStore: chat,
                clientFactory: { RelayClient { _ in transport } }
            )
        }
        let coordinator = connection.ensureRelayCoordinator()
        XCTAssertEqual(connection.transportPath, .relay)

        // Relay not connected yet ⇒ the drain gate is CLOSED (a send here would
        // enqueue, not churn a failed submit against a dead socket).
        XCTAssertFalse(connection.isTransportReady, "a closed relay ⇒ transport not ready")

        try await coordinator.start(url: url)

        // Enqueue a durable prompt while draining is otherwise idle. The awaits
        // below also let the coordinator's state observer settle on `.open`.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayOutbox-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try WorkRepository(
            configuration: WorkRepositoryConfiguration(containerURL: directory),
            observation: WorkRepositoryObservation()
        )
        let scope = try WorkScope(serverID: "https://gateway.test", profileID: "default")
        let job = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, text: "hello over relay", storedSessionID: "sess-9"
        ))

        // Relay open ⇒ the gate is OPEN.
        XCTAssertTrue(connection.isTransportReady, "an open relay ⇒ transport ready")

        // The outbox submit routes to the relay submit RPC (NOT the idle gateway
        // client) and comes back accepted so the job completes — no permanent
        // pending.
        let receipt = try await chat.submitOutboxPrompt(
            job: job, runtimeSessionID: "sess-9", remotePaths: []
        )
        XCTAssertTrue(receipt.accepted)
        XCTAssertTrue(OutboxProcessor.acceptedDispositions.contains(receipt.status))
        XCTAssertEqual(receipt.clientMessageID, job.clientMessageID)

        let submitFrames = transport.upstreams().filter { $0.method == "submit" }
        XCTAssertEqual(submitFrames.count, 1, "the prompt delivers over the relay exactly once (no dup)")
        XCTAssertEqual(submitFrames.first?.params["prompt"] as? String, "hello over relay")
        XCTAssertEqual(submitFrames.first?.params["session_id"] as? String, "sess-9")
        // The row's stable id rides the submit so the relay handler can dedupe an
        // ambiguous-flap retry into a single turn (no duplicate).
        XCTAssertEqual(
            submitFrames.first?.params["client_message_id"] as? String,
            job.clientMessageID
        )

        // Losing the relay closes the gate again.
        await coordinator.stop()
        XCTAssertFalse(connection.isTransportReady, "a stopped relay ⇒ transport not ready")
    }
    #endif

    /// The durable-outbox drain must route PER JOB to its own destination, never
    /// collapse to whatever session is currently active. A prompt queued for A
    /// resolves only while the relay is driving A; once the user opens B it holds
    /// (nil) rather than leaking into B, and the remap `submit` applies to
    /// `activeSessionID` must not knock the active session's own drain off its
    /// stored id.
    func testOutboxRuntimeResolvesPerDestinationNotActiveSession() async throws {
        let transport = MockRelayTransport(script: { upstream, relay in
            guard let id = upstream.id else { return }
            if upstream.method == "submit" {
                // Model the origin->live remap: the relay hands back a DISTINCT
                // live id for the origin session it drove.
                relay.deliverResult(id: id, result: .object(["session_id": .string("A-live")]))
            } else {
                relay.deliverResult(id: id, result: .object(["ok": .bool(true)]))
            }
        })
        let coordinator = RelaySessionCoordinator(
            chatStore: ChatStore(),
            clientFactory: { RelayClient { _ in transport } }
        )
        try await coordinator.start(url: url)

        // No session driven yet ⇒ every destination holds.
        XCTAssertNil(coordinator.outboxRuntimeID(forStored: "A"))

        // Relay resumes (drives) A ⇒ only A resolves, to A itself; B holds.
        _ = try await coordinator.resume("A")
        XCTAssertEqual(coordinator.outboxRuntimeID(forStored: "A"), "A")
        XCTAssertNil(coordinator.outboxRuntimeID(forStored: "B"),
                     "a prompt queued for B must not drain into the active session A")

        // A submit remaps `activeSessionID` to the live id, but the stored-id
        // routing for A's own follow-up drain must survive that remap.
        _ = try await coordinator.submit(prompt: "hi", sessionID: "A")
        XCTAssertEqual(coordinator.activeSessionID, "A-live")
        XCTAssertEqual(coordinator.outboxRuntimeID(forStored: "A"), "A",
                       "the remapped live id must not strand A's next queued prompt")

        // Opening B moves the driven session ⇒ A now holds, B resolves.
        _ = try await coordinator.open("B")
        XCTAssertNil(coordinator.outboxRuntimeID(forStored: "A"))
        XCTAssertEqual(coordinator.outboxRuntimeID(forStored: "B"), "B")

        await coordinator.stop()
        XCTAssertNil(coordinator.outboxRuntimeID(forStored: "B"),
                     "a stopped relay drives nothing ⇒ all destinations hold")
    }

    func testCoordinatorRoutesUpstreamOpsToRelay() async throws {
        let transport = MockRelayTransport(script: { upstream, relay in
            guard let id = upstream.id else { return }
            if upstream.method == "submit" {
                relay.deliverResult(id: id, result: .object(["session_id": .string("sess-42")]))
            } else {
                relay.deliverResult(id: id, result: .object(["ok": .bool(true)]))
            }
        })
        let coordinator = RelaySessionCoordinator(
            chatStore: ChatStore(),
            clientFactory: { RelayClient { _ in transport } }
        )
        try await coordinator.start(url: url)

        let submit = try await coordinator.submit(prompt: "Hello relay")
        XCTAssertEqual(submit["session_id"]?.stringValue, "sess-42")
        // The coordinator adopts the returned session id for subsequent ops.
        XCTAssertEqual(coordinator.activeSessionID, "sess-42")

        _ = try await coordinator.interrupt()

        let methods = transport.upstreams().map(\.method)
        XCTAssertTrue(methods.contains("submit"))
        XCTAssertTrue(methods.contains("interrupt"))
        let submitFrame = transport.upstreams().first { $0.method == "submit" }
        XCTAssertEqual(submitFrame?.params["prompt"] as? String, "Hello relay")
        let interruptFrame = transport.upstreams().first { $0.method == "interrupt" }
        XCTAssertEqual(interruptFrame?.params["session_id"] as? String, "sess-42")

        await coordinator.stop()
    }

    // MARK: - (4) Auto-reconnect driver: prompt first attempt + resync-on-open

    /// Hands out a scripted transport per `connect`, so a reconnect gets a fresh
    /// relay instance (mirrors `RelayClientMockTests.TransportQueue`).
    private final class TransportQueue: @unchecked Sendable {
        private let transports: [MockRelayTransport]
        private let lock = NSLock()
        private var index = 0
        init(_ transports: [MockRelayTransport]) { self.transports = transports }
        func next() -> MockRelayTransport {
            lock.lock(); defer { lock.unlock() }
            let t = transports[min(index, transports.count - 1)]
            index += 1
            return t
        }
    }

    /// Records the delays the reconnect driver asks for, returning immediately so
    /// the test never actually sleeps (the injected clock seam).
    private actor SleepRecorder {
        private(set) var recorded: [Duration] = []
        func record(_ d: Duration) { recorded.append(d) }
        func durations() -> [Duration] { recorded }
    }

    /// HEADLINE: an unexpected drop auto-reconnects with NO pre-delay (attempt 0
    /// is immediate) and sends `resync{last_seq}` immediately on the re-opened
    /// socket, anchored on the retained watermark — the stream resumes fast.
    func testAutoReconnectIsPromptAndResyncsFromWatermark() async throws {
        let recorder = SleepRecorder()
        let live = MockRelayTransport()
        let resumed = MockRelayTransport(script: { upstream, _ in
            _ = upstream   // the resumed relay only needs to record the resync
        })
        let queue = TransportQueue([live, resumed])
        let coordinator = RelaySessionCoordinator(
            chatStore: ChatStore(),
            clientFactory: { RelayClient { _ in queue.next() } },
            backoffSleep: { await recorder.record($0) }
        )
        try await coordinator.start(url: url)

        // Stream two dense frames so the resync watermark is 2.
        live.deliverFrames(Array(sampleTurn().prefix(2)))
        await waitUntil { coordinator.store.lastSeq == 2 }

        // Drop the live socket (non-cancelled error → `.failed` → auto-reconnect).
        live.fail()

        // The driver re-dials the resumed transport and sends resync immediately.
        await waitUntil { resumed.upstreams().contains { $0.method == "resync" } }
        let resync = resumed.upstreams().first { $0.method == "resync" }
        XCTAssertEqual((resync?.params["last_seq"] as? NSNumber)?.intValue, 2,
                       "resync must anchor on the retained watermark")

        // Prompt: the first (attempt 0) reconnect fired with NO backoff sleep.
        let sleeps = await recorder.durations()
        XCTAssertTrue(sleeps.isEmpty, "the first reconnect attempt must be immediate (no pre-delay)")

        await coordinator.stop()
    }

    /// The backoff schedule: attempt 0 immediate, tight early growth, bounded so a
    /// persistently-dead relay is retried at ~8s — fast off the mark, never
    /// hammering.
    func testReconnectBackoffIsImmediateThenTightAndBounded() {
        XCTAssertEqual(RelaySessionCoordinator.reconnectBackoff(attempt: 0), .zero,
                       "attempt 0 must be immediate")
        // base 0.25·2^(n-1) + jitter(0…0.25): attempt 1 ∈ [0.25,0.5]s, 2 ∈ [0.5,0.75]s.
        let a1 = RelaySessionCoordinator.reconnectBackoff(attempt: 1)
        let a2 = RelaySessionCoordinator.reconnectBackoff(attempt: 2)
        XCTAssertGreaterThanOrEqual(a1, .milliseconds(250))
        XCTAssertLessThanOrEqual(a1, .milliseconds(500))
        XCTAssertGreaterThanOrEqual(a2, .milliseconds(500))
        XCTAssertLessThanOrEqual(a2, .milliseconds(750))
        // Bounded cap: base saturates at 8s.
        let big = RelaySessionCoordinator.reconnectBackoff(attempt: 20)
        XCTAssertGreaterThanOrEqual(big, .milliseconds(8000))
        XCTAssertLessThanOrEqual(big, .milliseconds(8250))
    }
}

/// LANE 4 — deep-link resume-to-send over the Wave-2 relay coordinator.
///
/// Repro (convergence device-QA finding): in relay-only mode the notification
/// deep link `hermesapp://session/<id>` opened the transcript (history streamed
/// via the relay), but the resume-to-send raised "Not connected to the Hermes
/// gateway" because `SessionStore.open`'s `session.resume` and `ChatStore.send`'s
/// `prompt.submit` both drove the gateway-direct RPC socket, which is idle when
/// only the relay transport is up.
///
/// These tests prove the router's session-open-and-send path now routes through
/// the relay coordinator when `transportPath == .relay`, and that the default
/// gateway-direct path is untouched (no relay op is emitted with the flag OFF).
/// No live network — the coordinator's `RelayClient` runs over the same in-process
/// fake relay `RelaySessionCoordinatorTests` uses.
@MainActor
final class RelayDeepLinkResumeTests: XCTestCase {

    private typealias MockRelayTransport = RelaySessionCoordinatorTests.MockRelayTransport

    private let relayURL = URL(string: "ws://127.0.0.1:9999/relay")!

    private struct Stores {
        let connection: ConnectionStore
        let sessions: SessionStore
        let chat: ChatStore
        let inbox: InboxStore
        let transport: MockRelayTransport
        let coordinator: RelaySessionCoordinator
    }

    /// An RPC-answering fake relay: every upstream request gets a result. `submit`
    /// echoes a `session_id` so the coordinator adopts it, exactly like the real
    /// relay's submit reply.
    private func makeTransport() -> MockRelayTransport {
        MockRelayTransport(script: { upstream, relay in
            guard let id = upstream.id else { return }
            if upstream.method == "submit" {
                let sid = (upstream.params["session_id"] as? String) ?? "abc123"
                relay.deliverResult(id: id, result: .object(["session_id": .string(sid)]))
            } else {
                relay.deliverResult(id: id, result: .object(["ok": .bool(true)]))
            }
        })
    }

    private func makeStores(relay: Bool) async throws -> Stores {
        UserDefaults.standard.set(
            (relay ? TransportPath.relay : TransportPath.gatewayDirect).rawValue,
            forKey: DefaultsKeys.transportPath
        )

        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        let inbox = InboxStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        inbox.attach(connection: connection)

        let transport = makeTransport()
        let coordinator = RelaySessionCoordinator(
            chatStore: chat,
            clientFactory: { RelayClient { _ in transport } }
        )
        try await coordinator.start(url: relayURL)
        connection.relayCoordinatorFactory = { coordinator }
        _ = connection.ensureRelayCoordinator()

        return Stores(
            connection: connection, sessions: sessions, chat: chat,
            inbox: inbox, transport: transport, coordinator: coordinator
        )
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.transportPath)
        super.tearDown()
    }

    private func summary(id: String) -> SessionSummary {
        SessionSummary(
            id: id, title: "Session \(id)", preview: nil, startedAt: nil,
            messageCount: nil, source: nil, lastActive: nil, cwd: nil
        )
    }

    private func waitUntil(
        _ condition: @escaping () -> Bool, timeout: TimeInterval = 2.0
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Relay-active deep-link open + send

    func testRelayDeepLinkOpenResumesOverRelayNotGateway() async throws {
        let s = try await makeStores(relay: true)
        s.sessions.sessions = [summary(id: "abc123")]

        HermesURLRouter.route(
            URL(string: "hermesapp://session/abc123")!,
            connection: s.connection, sessions: s.sessions,
            chat: s.chat, inbox: s.inbox
        )

        // The session activates synchronously; the relay resume binds the runtime
        // on its Task hop.
        XCTAssertEqual(s.sessions.activeStoredId, "abc123")
        await waitUntil { s.sessions.activeRuntimeId == "abc123" }
        XCTAssertEqual(s.sessions.activeRuntimeId, "abc123",
                       "relay resume must bind the runtime so the composer unlocks")

        // The gateway-direct "Not connected to the Hermes gateway" must NOT surface.
        XCTAssertNil(s.sessions.lastError)
        XCTAssertNil(s.sessions.sessionActionError)

        // The resume travelled over the relay transport, not the gateway socket.
        let methods = s.transport.upstreams().map(\.method)
        XCTAssertTrue(methods.contains("resume"),
                      "the deep-link open must resume via the relay coordinator")
        let resume = s.transport.upstreams().first { $0.method == "resume" }
        XCTAssertEqual(resume?.params["session_id"] as? String, "abc123")
    }

    func testRelaySendAfterDeepLinkOpenSubmitsOverRelay() async throws {
        let s = try await makeStores(relay: true)
        s.sessions.sessions = [summary(id: "abc123")]

        HermesURLRouter.route(
            URL(string: "hermesapp://session/abc123")!,
            connection: s.connection, sessions: s.sessions,
            chat: s.chat, inbox: s.inbox
        )
        await waitUntil { s.sessions.activeRuntimeId == "abc123" }

        let ok = await s.chat.send(text: "resume and send me")
        XCTAssertTrue(ok, "a relay-active send must succeed via the relay coordinator")
        XCTAssertNil(s.chat.lastError)

        let submit = s.transport.upstreams().first { $0.method == "submit" }
        XCTAssertNotNil(submit, "the send must route prompt.submit over the relay")
        XCTAssertEqual(submit?.params["prompt"] as? String, "resume and send me")
        XCTAssertEqual(submit?.params["session_id"] as? String, "abc123")
    }

    // MARK: - Gateway-direct unchanged (flag OFF)

    func testGatewayDirectDeepLinkNeverTouchesRelay() async throws {
        let s = try await makeStores(relay: false)
        s.sessions.sessions = [summary(id: "abc123")]

        HermesURLRouter.route(
            URL(string: "hermesapp://session/abc123")!,
            connection: s.connection, sessions: s.sessions,
            chat: s.chat, inbox: s.inbox
        )

        // Activation is synchronous (unchanged gateway-direct behaviour); give any
        // stray relay Task a budgeted chance to (incorrectly) fire before asserting.
        XCTAssertEqual(s.sessions.activeStoredId, "abc123")
        await waitUntil { !s.transport.upstreams().isEmpty }

        XCTAssertFalse(
            s.transport.upstreams().contains { $0.method == "resume" || $0.method == "submit" },
            "with the flag OFF the deep-link open must NOT drive the relay coordinator"
        )
    }
}

/// QA-1 B8/B12 — the relay working-signal lifecycle.
///
/// Build-114 relay QA: the inline "Working" row read a dishonest static
/// "Working · 0s" for the whole turn because the relay path never drove the
/// direct-path `turnStartedAt`/`activeToolName` event internals. These pin the
/// relay turn-chrome lifecycle that makes the row honest in its sole remaining
/// relay window (pre-first-item) and keeps it out of the cursor phase:
///
///  1. relay submit stamps `turnStartedAt` (the pre-first-item row ticks from
///     the user's send);
///  2. the first streaming relay item stamps it too (a turn this phone did not
///     send — mid-turn resume) AND flips the view-model gate OFF (the streaming
///     bubble's cursor is the working signal — A4);
///  3. settle clears the chrome so the next turn never inherits a stale start;
///  4. a failed submit clears the chrome (no stranded "Working" state).
///
/// Render-model assertions feed recorded relay frames through the real
/// RelayItemStore → ChatStore projection and evaluate the production
/// `ChatView.shouldShowInlineTurnActivity` gate (QA-1 A9's render-level shape).
/// Same in-process mock relay as `RelayDeepLinkResumeTests` — no live network.
@MainActor
final class RelayWorkingSignalLifecycleTests: XCTestCase {

    private typealias MockRelayTransport = RelaySessionCoordinatorTests.MockRelayTransport

    private let relayURL = URL(string: "ws://127.0.0.1:9999/relay")!

    private struct Stores {
        let connection: ConnectionStore
        let sessions: SessionStore
        let chat: ChatStore
        let inbox: InboxStore
        let transport: MockRelayTransport
        let coordinator: RelaySessionCoordinator
    }

    /// RPC-answering fake relay; `submitError` makes submit fail with a JSON-RPC
    /// error frame (RelayClient maps it to `RelayError.rpc`).
    private func makeTransport(submitError: Bool = false) -> MockRelayTransport {
        MockRelayTransport(script: { upstream, relay in
            guard let id = upstream.id else { return }
            if upstream.method == "submit" {
                if submitError {
                    let payload: JSONValue = .object([
                        "jsonrpc": .string("2.0"), "id": .string(id),
                        "error": .object(["code": .number(-32000),
                                          "message": .string("relay rejected")]),
                    ])
                    if let data = try? JSONEncoder().encode(payload) {
                        relay.deliver(String(decoding: data, as: UTF8.self))
                    }
                } else {
                    let sid = (upstream.params["session_id"] as? String) ?? "abc123"
                    relay.deliverResult(id: id, result: .object(["session_id": .string(sid)]))
                }
            } else {
                relay.deliverResult(id: id, result: .object(["ok": .bool(true)]))
            }
        })
    }

    private func makeStores(submitError: Bool = false) async throws -> Stores {
        UserDefaults.standard.set(TransportPath.relay.rawValue,
                                  forKey: DefaultsKeys.transportPath)

        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        let inbox = InboxStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        inbox.attach(connection: connection)

        let transport = makeTransport(submitError: submitError)
        let coordinator = RelaySessionCoordinator(
            chatStore: chat,
            clientFactory: { RelayClient { _ in transport } }
        )
        try await coordinator.start(url: relayURL)
        connection.relayCoordinatorFactory = { coordinator }
        _ = connection.ensureRelayCoordinator()

        return Stores(
            connection: connection, sessions: sessions, chat: chat,
            inbox: inbox, transport: transport, coordinator: coordinator
        )
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.transportPath)
        super.tearDown()
    }

    private func summary(id: String) -> SessionSummary {
        SessionSummary(
            id: id, title: "Session \(id)", preview: nil, startedAt: nil,
            messageCount: nil, source: nil, lastActive: nil, cwd: nil
        )
    }

    private func waitUntil(
        _ condition: @escaping () -> Bool, timeout: TimeInterval = 2.0
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Open the session the relay-active way (deep-link route → relay resume).
    private func openSession(_ s: Stores, id: String = "abc123") async {
        s.sessions.sessions = [summary(id: id)]
        HermesURLRouter.route(
            URL(string: "hermesapp://session/\(id)")!,
            connection: s.connection, sessions: s.sessions,
            chat: s.chat, inbox: s.inbox
        )
        await waitUntil { s.sessions.activeRuntimeId == id }
    }

    private func agentItemFrame(_ seq: Int, id: String, status: String,
                                text: String) -> RelayFrame {
        RelayFrame(seq: seq, sid: "abc123", turn: "t1",
                   kind: RelayFrameKind(wire: status == "in_progress" ? "item.started" : "item.completed"),
                   body: .object([
                       "item_id": .string(id),
                       "type": .string(ChatItemType.agentMessage.rawValue),
                       "status": .string(status),
                       "ord": .number(1),
                       "body": .object(["text": .string(text)]),
                   ]))
    }

    /// The production view-model gate evaluated exactly as `ChatView` does for
    /// the relay transport.
    private func workingRowVisible(_ chat: ChatStore) -> Bool {
        ChatView.shouldShowInlineTurnActivity(
            isStreaming: chat.isStreaming,
            hasPendingGate: chat.pendingApproval != nil
                || chat.pendingClarification != nil
                || chat.pendingSecurePrompt != nil,
            isRelayTransport: true,
            lastMessage: chat.messages.last
        )
    }

    // MARK: - (1) submit stamps the turn start

    /// B8 honesty: the relay submit stamps `turnStartedAt` so the pre-first-item
    /// row's elapsed label ticks from the user's send instead of freezing "0s".
    /// FAILS on qa1/base (the relay branch never stamped it).
    func testRelaySendStampsTurnStartForHonestElapsed() async throws {
        let s = try await makeStores()
        await openSession(s)

        let ok = await s.chat.send(text: "hello")
        XCTAssertTrue(ok)
        XCTAssertTrue(s.chat.isStreaming, "relay send enters the streaming state")
        XCTAssertNotNil(s.chat.turnStartedAt,
            "the relay submit must stamp the turn start so the pre-first-item row ticks")
        // Pre-first-item: nothing streams yet, so the honest row IS visible
        // (mirrors the approved direct path between send and message.start).
        XCTAssertTrue(workingRowVisible(s.chat),
            "pre-first-item relay: the accepted-and-waiting row shows")
    }

    // MARK: - (2) first item → cursor is the working signal (A4)

    /// Feeding a recorded `item.started` through the real projection flips the
    /// gate OFF: the streaming assistant bubble now renders the breathing cursor
    /// (the ratified working signal) — no standalone pill beside it.
    func testFirstStreamingItemSuppressesWorkingRowForCursor() async throws {
        let s = try await makeStores()
        await openSession(s)
        _ = await s.chat.send(text: "hello")

        s.transport.deliverFrame(agentItemFrame(1, id: "msg-1",
                                                status: "in_progress", text: ""))
        await waitUntil { s.chat.messages.last?.isStreaming == true }

        XCTAssertTrue(s.chat.isStreaming)
        XCTAssertNotNil(s.chat.turnStartedAt,
            "a turn this phone did NOT send still gets an honest elapsed start")
        XCTAssertFalse(workingRowVisible(s.chat),
            "A4: while the relay bubble streams, the cursor is the working signal — no pill")
    }

    // MARK: - (3) settle clears the chrome for the next turn

    /// The settle transition clears `turnStartedAt` (parity with the direct
    /// path's `handleMessageComplete`), so a subsequent relay send stamps a
    /// FRESH start — the next turn never inherits the previous turn's elapsed.
    func testRelaySettleClearsChromeSoNextTurnStampsFresh() async throws {
        let s = try await makeStores()
        await openSession(s)
        _ = await s.chat.send(text: "hello")
        let firstStart = s.chat.turnStartedAt
        XCTAssertNotNil(firstStart)

        s.transport.deliverFrame(agentItemFrame(1, id: "msg-1",
                                                status: "in_progress", text: ""))
        await waitUntil { s.chat.messages.last?.isStreaming == true }
        s.transport.deliverFrame(agentItemFrame(2, id: "msg-1",
                                                status: "completed", text: "Done."))
        await waitUntil { !s.chat.isStreaming }

        XCTAssertNil(s.chat.turnStartedAt,
            "the settled relay projection must clear the turn chrome")
        XCTAssertFalse(workingRowVisible(s.chat), "idle transcript: no working row")

        // Next turn: a fresh stamp, strictly after the first turn's start.
        try await Task.sleep(nanoseconds: 5_000_000)
        _ = await s.chat.send(text: "again")
        let secondStart = try XCTUnwrap(s.chat.turnStartedAt)
        XCTAssertGreaterThan(secondStart, firstStart!,
            "the next relay turn stamps a fresh start — never a stale inherited one")
    }

    // MARK: - (4) failed submit clears the chrome

    /// A rejected submit must not strand the "Working" state: streaming clears
    /// AND the just-stamped turn start is dropped.
    func testRelaySendErrorClearsTurnChrome() async throws {
        let s = try await makeStores(submitError: true)
        await openSession(s)

        let ok = await s.chat.send(text: "hello")
        XCTAssertFalse(ok, "the submit error propagates as a failed send")
        XCTAssertFalse(s.chat.isStreaming)
        XCTAssertNil(s.chat.turnStartedAt,
            "a failed submit must not strand a turn start behind")
        XCTAssertFalse(workingRowVisible(s.chat))
    }
}
