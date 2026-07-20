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
}
