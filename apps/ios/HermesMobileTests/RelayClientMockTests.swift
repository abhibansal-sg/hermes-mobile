import XCTest
@testable import HermesMobile

/// Wave-2 relay client — end-to-end coverage against an in-process MOCK relay
/// (RELAY-PHONE-PROTOCOL §7). No live network. Exercises: frame decode + store
/// reconciliation over the transport, the upstream RPC round-trip, periodic
/// `ack{through}`, and the reliability spine's headline scenario — a DROP followed
/// by `resync{last_seq}` reconciling gap-free by `item_id` (§4), via both the
/// within-ring replay path and the snapshot-fallback path.
final class RelayClientMockTests: XCTestCase {

    // MARK: - Mock relay transport

    /// An in-process fake relay. `receive()` hands back queued downstream
    /// messages; `send` records the upstream frame and runs an optional `script`
    /// that can enqueue responses / replays (the relay's reaction). All state is
    /// mutated under a lock, never across an `await`.
    final class MockRelayTransport: RelayTransport, @unchecked Sendable {
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

        /// The relay's reaction to an upstream frame (enqueue a response / replay).
        var script: (@Sendable (Upstream, MockRelayTransport) -> Void)?

        init(script: (@Sendable (Upstream, MockRelayTransport) -> Void)? = nil) {
            self.script = script
        }

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
            record(upstream)   // sync helper: NSLock is unavailable directly in an async context
            // Run the relay reaction OUTSIDE the lock (it re-enters via enqueue).
            script?(upstream, self)
        }

        private func record(_ upstream: Upstream) {
            lock.lock(); defer { lock.unlock() }
            sent.append(upstream)
        }

        func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
            lock.lock()
            cancelled = true
            let parked = waiter
            waiter = nil
            lock.unlock()
            parked?.resume(throwing: URLError(.cancelled))
        }

        // MARK: Relay-side helpers (called from a script or the test)

        /// Enqueue a raw downstream WS text frame.
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

        /// Encode + enqueue a downstream relay frame.
        func deliverFrame(_ frame: RelayFrame) {
            guard let data = try? JSONEncoder().encode(frame) else { return }
            deliver(String(decoding: data, as: UTF8.self))
        }

        func deliverFrames(_ frames: [RelayFrame]) { frames.forEach(deliverFrame) }

        /// Enqueue a JSON-RPC response for a request id.
        func deliverResult(id: String, result: JSONValue) {
            let payload: JSONValue = .object([
                "jsonrpc": .string("2.0"), "id": .string(id), "result": result,
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

    /// Hands out a scripted sequence of transports (one per `connect`), so a
    /// reconnect gets a distinct relay instance.
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

    private let url = URL(string: "ws://127.0.0.1:9999/relay")!

    // MARK: - Frame builders

    private func frame(_ seq: Int, _ kind: String, _ body: JSONValue) -> RelayFrame {
        RelayFrame(seq: seq, sid: "s", turn: "t", kind: RelayFrameKind(wire: kind), body: body)
    }

    private func itemFrame(_ seq: Int, kind: String, id: String, _ type: ChatItemType,
                           status: String, ord: Int, body: JSONValue) -> RelayFrame {
        frame(seq, kind, .object([
            "item_id": .string(id), "type": .string(type.rawValue),
            "status": .string(status), "ord": .number(Double(ord)), "body": body,
        ]))
    }

    /// A five-frame turn with dense seqs 1…5.
    private func sampleTurn() -> [RelayFrame] {
        [
            itemFrame(1, kind: "item.completed", id: "user-1", .userMessage,
                      status: "completed", ord: 0, body: ["text": "Refactor the parser"]),
            itemFrame(2, kind: "item.started", id: "msg-1", .agentMessage,
                      status: "in_progress", ord: 1, body: ["text": ""]),
            frame(3, "item.delta", .object(["item_id": .string("msg-1"), "patch": ["text": "Working…"]])),
            itemFrame(4, kind: "item.completed", id: "tool-1", .toolCall,
                      status: "completed", ord: 2, body: ["name": "read_file"]),
            itemFrame(5, kind: "item.completed", id: "msg-1", .agentMessage,
                      status: "completed", ord: 1, body: ["text": "Done."]),
        ]
    }

    // MARK: - Polling helper

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @Sendable () async -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("waitUntil timed out")
    }

    // MARK: - Tests

    /// Frames delivered over the transport decode, reduce, and reconcile into the
    /// store in seq order; the `frames` stream observes every seq.
    func testStreamsFramesInOrderAndReconciles() async {
        let transport = MockRelayTransport()
        let client = RelayClient { _ in transport }
        let collector = SeqCollector()
        let consuming = Task { for await f in client.frames { await collector.append(f.seq) } }

        await client.connect(url: url)
        transport.deliverFrames(sampleTurn())

        await waitUntil { await client.lastSeq == 5 }

        let items = await client.items
        XCTAssertEqual(items.map(\.itemID), ["user-1", "msg-1", "tool-1"])
        XCTAssertEqual(items.first { $0.itemID == "msg-1" }?.textBody, "Done.")
        await waitUntil { await collector.seqs() == [1, 2, 3, 4, 5] }

        consuming.cancel()
        await client.disconnect()
    }

    /// An upstream op maps to its relay RPC and resolves against the matching
    /// response. `submit` carries the prompt; `list` returns the scripted result.
    func testUpstreamRPCRoundTrips() async throws {
        let transport = MockRelayTransport()
        transport.script = { upstream, relay in
            guard let id = upstream.id else { return }   // notifications (ack/resync) carry no id
            if upstream.method == "list" {
                relay.deliverResult(id: id, result: .object(["sessions": .array([.string("a"), .string("b")])]))
            } else {
                relay.deliverResult(id: id, result: .object(["ok": .bool(true)]))
            }
        }
        let client = RelayClient { _ in transport }
        await client.connect(url: url)

        let listResult = try await client.list()
        XCTAssertEqual(listResult["sessions"]?.arrayValue?.count, 2)

        let submitResult = try await client.submit(prompt: "Hello")
        XCTAssertEqual(submitResult["ok"]?.boolValue, true)

        let methods = transport.upstreams().map(\.method)
        XCTAssertTrue(methods.contains("list"))
        let submit = transport.upstreams().first { $0.method == "submit" }
        XCTAssertEqual(submit?.params["prompt"] as? String, "Hello")

        await client.disconnect()
    }

    /// The client sends `ack{through:seq}` once the watermark advances past the
    /// coalescing threshold (§4).
    func testAckSentAfterThreshold() async {
        let transport = MockRelayTransport()
        let client = RelayClient(ackEvery: 4) { _ in transport }
        await client.connect(url: url)

        transport.deliverFrames(sampleTurn())   // 5 frames → crosses the 4-frame threshold
        await waitUntil { transport.upstreams().contains { $0.method == "ack" } }

        let ack = transport.upstreams().first { $0.method == "ack" }
        let through = (ack?.params["through"] as? NSNumber)?.intValue ?? -1
        XCTAssertGreaterThanOrEqual(through, 4, "ack must cover at least the threshold watermark")

        // A manual flush acks the tail.
        await client.flushAck()
        let lastAck = transport.upstreams().last { $0.method == "ack" }
        XCTAssertEqual((lastAck?.params["through"] as? NSNumber)?.intValue, 5)

        await client.disconnect()
    }

    /// HEADLINE: drop after seq 2, reconnect, `resync{last_seq:2}`; the relay
    /// replays 3…5 (within-ring). The store reconciles to the exact no-drop state,
    /// gap-free and idempotent (the replay may re-send an already-seen frame).
    func testDropThenResyncReplaysGapFree() async {
        let full = sampleTurn()

        let live = MockRelayTransport()
        let resumed = MockRelayTransport(script: { upstream, relay in
            // On reconnect the phone asks to resume from its last seen seq…
            guard upstream.method == "resync" else { return }
            let lastSeq = (upstream.params["last_seq"] as? NSNumber)?.intValue ?? 0
            XCTAssertEqual(lastSeq, 2, "resync must anchor on the last folded-in seq")
            // …and the relay replays 1…head; seqs <= last_seq are harmless duplicates.
            relay.deliverFrames(full)
        })
        let queue = TransportQueue([live, resumed])
        let client = RelayClient { _ in queue.next() }

        await client.connect(url: url)
        live.deliverFrames(Array(full.prefix(2)))       // only 1–2 arrive before the drop
        await waitUntil { await client.lastSeq == 2 }

        await client.reconnect(url: url)                // teardown live → connect resumed → resync
        await waitUntil { await client.lastSeq == 5 }

        await assertReconciledToFullTurn(client)
        await client.disconnect()
    }

    /// Drop with a gap too big for the ring: `resync` triggers a full `snapshot`
    /// (a single downstream frame) that reconciles by item_id to the no-drop state.
    func testDropThenResyncViaSnapshotFallback() async {
        let full = sampleTurn()

        let snapshot: JSONValue = .object([
            "cursor": .number(5),
            "items": .array([
                .object(["item_id": .string("user-1"), "type": .string("userMessage"),
                         "status": .string("completed"), "ord": .number(0),
                         "body": .object(["text": .string("Refactor the parser")])]),
                .object(["item_id": .string("msg-1"), "type": .string("agentMessage"),
                         "status": .string("completed"), "ord": .number(1),
                         "body": .object(["text": .string("Done.")])]),
                .object(["item_id": .string("tool-1"), "type": .string("toolCall"),
                         "status": .string("completed"), "ord": .number(2),
                         "body": .object(["name": .string("read_file")])]),
            ]),
        ])
        // Precompute the snapshot frame so the @Sendable script captures a value,
        // not the (non-Sendable) test case via `self`.
        let snapshotFrame = frame(6, "snapshot", snapshot)
        let live = MockRelayTransport()
        let resumed = MockRelayTransport(script: { upstream, relay in
            guard upstream.method == "resync" else { return }
            relay.deliverFrame(snapshotFrame)
        })
        let queue = TransportQueue([live, resumed])
        let client = RelayClient { _ in queue.next() }

        await client.connect(url: url)
        live.deliverFrames(Array(full.prefix(2)))
        await waitUntil { await client.lastSeq == 2 }

        await client.reconnect(url: url)
        await waitUntil { await client.lastSeq >= 5 }

        await assertReconciledToFullTurn(client)
        await client.disconnect()
    }

    // MARK: - Shared assertion

    private func assertReconciledToFullTurn(_ client: RelayClient) async {
        let items = await client.items
        XCTAssertEqual(items.map(\.itemID), ["user-1", "msg-1", "tool-1"],
                       "reconciled item set must equal the no-drop set")
        XCTAssertEqual(items.first { $0.itemID == "msg-1" }?.textBody, "Done.")
        XCTAssertEqual(items.first { $0.itemID == "msg-1" }?.status, .completed)
        XCTAssertEqual(items.first { $0.itemID == "tool-1" }?.toolName, "read_file")
    }
}

/// Actor-confined collector for the `frames` stream (the handler is `@Sendable`).
private actor SeqCollector {
    private var collected: [Int] = []
    func append(_ seq: Int) { collected.append(seq) }
    func seqs() -> [Int] { collected }
}
