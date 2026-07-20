import XCTest
@testable import HermesMobile

/// A2/N1 wire conformance — the Swift half of the cross-language suite.
///
/// Consumes the SAME shared fixture the pytest side asserts against
/// (`tests/conformance/wire_contract.json`, bundled into this target via
/// project.yml) and proves, BEHAVIORALLY, that the real `RelayClient` builders
/// put exactly the contracted keys on the wire for every upstream method, and
/// that the real `RelayFrame` / `ChatItem` decoders consume every sample frame
/// the relay emits. The pytest side mirrors this against the relay's real
/// `handle_upstream` readers — so a field mismatch between the phone and the
/// relay fails a build on BOTH sides (the prompt/text, decision/choice,
/// text/answer bug class becomes structurally impossible).
final class WireConformanceTests: XCTestCase {

    // MARK: - Fixture loading

    private var contract: [String: Any]!

    override func setUpWithError() throws {
        let url = try XCTUnwrap(
            Bundle(for: type(of: self)).url(forResource: "wire_contract", withExtension: "json"),
            "wire_contract.json must be bundled into the test target (project.yml)"
        )
        let data = try Data(contentsOf: url)
        contract = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private var upstreamPayloads: [String: [String: Any]] {
        ((contract["upstream"] as? [String: Any])?["payloads"] as? [String: [String: Any]]) ?? [:]
    }

    private var samples: [[String: Any]] {
        ((contract["downstream"] as? [String: Any])?["samples"] as? [[String: Any]]) ?? []
    }

    private func expectedKeys(_ method: String) throws -> (required: Set<String>, optional: Set<String>) {
        let spec = try XCTUnwrap(upstreamPayloads[method], "fixture missing method \(method)")
        let sends = try XCTUnwrap(spec["ios_sends"] as? [String: Any])
        return (
            Set((sends["required"] as? [String]) ?? []),
            Set((sends["optional"] as? [String]) ?? [])
        )
    }

    // MARK: - Capture transport

    /// Records every upstream frame the client puts on the wire and answers
    /// every request with an empty-object result (the reply content is
    /// irrelevant here — the sent PAYLOADS are what the contract constrains).
    private final class CaptureTransport: RelayTransport, @unchecked Sendable {
        struct Sent {
            let envelopeKeys: Set<String>
            let method: String
            let id: String?
            let paramKeys: Set<String>
        }

        private let lock = NSLock()
        private var inbox: [URLSessionWebSocketTask.Message] = []
        private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
        private var sent: [Sent] = []
        private var cancelled = false

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
                  let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return }
            let params = object["params"] as? [String: Any] ?? [:]
            // Sync helpers: NSLock is unavailable directly in an async context.
            record(Sent(
                envelopeKeys: Set(object.keys),
                method: method,
                id: object["id"].map { "\($0)" },
                paramKeys: Set(params.keys)
            ))
            // Answer requests (they carry an id) so the client's await returns.
            if let id = object["id"] {
                let payload: JSONValue = .object([
                    "jsonrpc": .string("2.0"),
                    "id": .string("\(id)"),
                    "result": .object(["session_id": .string("sess-1")]),
                ])
                if let responseData = try? JSONEncoder().encode(payload) {
                    deliver(String(decoding: responseData, as: UTF8.self))
                }
            }
        }

        private func record(_ sent: Sent) {
            lock.lock(); self.sent.append(sent); lock.unlock()
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

        func sentFrames() -> [Sent] {
            lock.lock(); defer { lock.unlock() }
            return sent
        }

        func last(_ method: String) -> Sent? { sentFrames().last { $0.method == method } }
    }

    private func makeClient() -> (RelayClient, CaptureTransport) {
        let mock = CaptureTransport()
        let client = RelayClient(transportFactory: { _ in mock })
        return (client, mock)
    }

    // MARK: - Upstream: method set + payload keys (behavioral)

    func testUpstreamMethodSetMatchesContract() throws {
        let swift = Set(RelayUpstreamMethod.allCases.map(\.rawValue))
        let fixture = Set(upstreamPayloads.keys)
        XCTAssertEqual(swift, fixture, "RelayUpstreamMethod and the wire contract diverged")
    }

    func testEveryBuilderSendsExactlyTheContractedKeys() async throws {
        let (client, mock) = makeClient()
        await client.connect(url: URL(string: "ws://conformance.invalid/relay")!)

        // Drive every upstream method with ALL optional params populated so the
        // sent key set is the full required ∪ optional the contract declares.
        _ = try await client.submit(sessionID: "sess-1", prompt: "Hello", clientMessageID: "cmid-1")
        _ = try await client.resumeSession("sess-1")
        _ = try await client.open("sess-1")
        _ = try await client.list()
        _ = try await client.history(sessionID: "sess-1", limit: 50)
        _ = try await client.approve(
            sessionID: "sess-1", requestID: "req-1", decision: "approve", resolveAll: true
        )
        _ = try await client.clarify(sessionID: "sess-1", requestID: "clr-1", response: "staging")
        _ = try await client.interrupt("sess-1")
        await client.setForeground("sess-1")
        // §6a (QA-1 B14): relay-local push token registry RPCs.
        _ = try await client.registerPushToken(
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            env: "production",
            events: ["approval", "turn_complete"]
        )
        _ = try await client.unregisterPushToken(
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        )

        // ack needs an advanced watermark; resync reads it. Deliver one frame so
        // the client's store folds seq 1, then flush the ack.
        let frame: JSONValue = .object([
            "seq": .number(1), "sid": .string("sess-1"), "turn": .string("sess-1:t1"),
            "kind": .string("status"),
            "body": .object(["kind": .string("heartbeat"), "text": .string("")]),
        ])
        if let data = try? JSONEncoder().encode(frame) {
            mock.deliver(String(decoding: data, as: UTF8.self))
        }
        try await Task.sleep(for: .milliseconds(100))
        await client.flushAck()
        await client.resync()

        let notifications = Set(
            ((contract["upstream"] as? [String: Any])?["notifications"] as? [String]) ?? []
        )
        let requestEnvelope = Set(
            (((contract["upstream"] as? [String: Any])?["envelope"] as? [String: Any])?["request"] as? [String]) ?? []
        )
        let notificationEnvelope = Set(
            (((contract["upstream"] as? [String: Any])?["envelope"] as? [String: Any])?["notification"] as? [String]) ?? []
        )

        for method in RelayUpstreamMethod.allCases.map(\.rawValue) {
            let sent = try XCTUnwrap(mock.last(method), "client never sent \(method)")
            let expected = try expectedKeys(method)
            let declared = expected.required.union(expected.optional)

            // REQUIRED keys are always on the wire; nothing undeclared ever is.
            XCTAssertTrue(
                expected.required.isSubset(of: sent.paramKeys),
                "\(method): missing required keys \(expected.required.subtracting(sent.paramKeys))"
            )
            XCTAssertEqual(
                sent.paramKeys, declared,
                "\(method): builder sent \(sent.paramKeys.sorted()), contract declares \(declared.sorted())"
            )

            // Envelope: requests carry jsonrpc/id/method/params; notifications
            // (ack/resync/foreground) must NOT carry an id.
            if notifications.contains(method) {
                XCTAssertEqual(sent.envelopeKeys, notificationEnvelope, "\(method) envelope")
                XCTAssertNil(sent.id, "\(method) must be a notification (no id)")
            } else {
                XCTAssertEqual(sent.envelopeKeys, requestEnvelope, "\(method) envelope")
                XCTAssertNotNil(sent.id, "\(method) must be a request (id-matched)")
            }
        }
    }

    func testApproveCarriesDecisionNotApproved() async throws {
        // The decision/choice kill: the wire payload must name the phone's
        // answer `decision` (the relay maps it to the gateway's `choice`); a
        // regression to `approved` means every approval resolves to the
        // gateway's silent default DENY.
        let (client, mock) = makeClient()
        await client.connect(url: URL(string: "ws://conformance.invalid/relay")!)
        _ = try await client.approve(sessionID: "sess-1", requestID: "req-1", approved: true)
        let sent = try XCTUnwrap(mock.last("approve"))
        XCTAssertTrue(sent.paramKeys.contains("decision"), "approve must send decision")
        XCTAssertTrue(sent.paramKeys.contains("session_id"), "approve must send session_id")
        XCTAssertFalse(sent.paramKeys.contains("approved"), "approved is not on the wire contract")
    }

    func testClarifyCarriesTextNotResponse() async throws {
        // The text/answer kill: the wire payload must name the answer `text`
        // (the relay maps it to the gateway's `answer`); a regression to
        // `response` delivers an EMPTY answer to the blocked agent.
        let (client, mock) = makeClient()
        await client.connect(url: URL(string: "ws://conformance.invalid/relay")!)
        _ = try await client.clarify(sessionID: "sess-1", requestID: "clr-1", response: "staging")
        let sent = try XCTUnwrap(mock.last("clarify"))
        XCTAssertTrue(sent.paramKeys.contains("text"), "clarify must send text")
        XCTAssertTrue(sent.paramKeys.contains("session_id"), "clarify must send session_id")
        XCTAssertFalse(sent.paramKeys.contains("response"), "response is not on the wire contract")
    }

    // MARK: - Downstream: every sample frame decodes through the real types

    func testEverySampleFrameDecodesWithKnownKind() throws {
        let kinds = Set(
            ((contract["downstream"] as? [String: Any])?["kinds"] as? [String]) ?? []
        )
        let decoder = JSONDecoder()
        for sample in samples {
            let name = (sample["name"] as? String) ?? "<unnamed>"
            let wire = try XCTUnwrap(sample["frame"] as? [String: Any], "\(name): no frame")
            let data = try JSONSerialization.data(withJSONObject: wire)
            let frame = try decoder.decode(RelayFrame.self, from: data)

            // Envelope survives the round-trip.
            XCTAssertEqual(frame.seq, wire["seq"] as? Int, "\(name): seq")
            XCTAssertEqual(frame.sid, wire["sid"] as? String, "\(name): sid")

            // The kind is one the contract declares — never an accidental
            // .unknown (the phone would fold it to no store mutation).
            XCTAssertFalse(
                isUnknown(frame.kind),
                "\(name): kind '\(wire["kind"] ?? "?")' decoded as unknown — not in the contract"
            )
            XCTAssertTrue(kinds.contains(frame.kind.wire), "\(name): kind not in contract")
        }
    }

    func testSampleItemFramesProjectToChatItems() throws {
        let decoder = JSONDecoder()
        for sample in samples {
            let name = (sample["name"] as? String) ?? "<unnamed>"
            let wire = try XCTUnwrap(sample["frame"] as? [String: Any])
            let kind = wire["kind"] as? String
            let data = try JSONSerialization.data(withJSONObject: wire)
            let frame = try decoder.decode(RelayFrame.self, from: data)
            let body = (wire["body"] as? [String: Any]) ?? [:]

            if kind == "item.started" || kind == "item.completed" {
                let item = try XCTUnwrap(frame.item, "\(name): item projection returned nil")
                XCTAssertEqual(item.itemID, body["item_id"] as? String, "\(name): item_id")
                // Every contract-declared item field is present on the wire.
                let shape = try XCTUnwrap(
                    (contract["downstream"] as? [String: Any])?["item_shape"] as? [String: Any]
                )
                for key in (shape["required"] as? [String] ?? []) + (shape["optional"] as? [String] ?? []) {
                    XCTAssertTrue(body.keys.contains(key), "\(name): item body lacks \(key)")
                }
            }
            if kind == "item.delta" {
                let delta = try XCTUnwrap(frame.itemDelta, "\(name): delta projection nil")
                XCTAssertEqual(delta.itemID, body["item_id"] as? String)
            }
            if kind == "snapshot" {
                let snapshot = try XCTUnwrap(frame.snapshot, "\(name): snapshot projection nil")
                XCTAssertFalse(snapshot.items.isEmpty, "\(name): snapshot items empty")
                XCTAssertEqual(snapshot.cursor, body["cursor"] as? Int)
            }
            if kind == "turn.completed", body["usage"] != nil {
                XCTAssertNotNil(frame.usage, "\(name): usage projection nil")
            }
        }
    }

    func testItemTypeFoldMatchesContract() throws {
        let types = try XCTUnwrap(
            (contract["downstream"] as? [String: Any])?["item_types"] as? [String: Any]
        )
        let native = Set(types["ios_native"] as? [String] ?? [])
        let fold = Set(types["generic_fold"] as? [String] ?? [])
        XCTAssertEqual(Set(ChatItemType.allCases.map(\.rawValue)), native)
        for raw in types["relay_all"] as? [String] ?? [] {
            if native.contains(raw) {
                XCTAssertEqual(ChatItemType(wire: raw).rawValue, raw)
            } else {
                // §2 forward-compat: a relay type with no native case folds to
                // the generic tool card, and MUST be on the declared allowlist.
                XCTAssertEqual(ChatItemType(wire: raw), .toolCall, "\(raw) should fold to toolCall")
                XCTAssertTrue(fold.contains(raw), "\(raw) folds to toolCall but is not in generic_fold")
            }
        }
    }

    func testGateSampleBodiesFeedTheSharedDecoders() throws {
        for sample in samples {
            let wire = try XCTUnwrap(sample["frame"] as? [String: Any])
            let kind = wire["kind"] as? String
            let body = (wire["body"] as? [String: Any]) ?? [:]
            let payload = JSONValue(body)
            if kind == "approval.request" {
                let decoded = ApprovalRequestPayload(payload: payload)
                XCTAssertEqual(decoded.command, body["command"] as? String)
            }
            if kind == "clarify.request" {
                let decoded = ClarifyRequestPayload(payload: payload)
                XCTAssertEqual(decoded.question, body["question"] as? String)
                XCTAssertEqual(decoded.requestId, body["request_id"] as? String)
                XCTAssertEqual(
                    decoded.choices,
                    (body["choices"] as? [String]) ?? []
                )
            }
        }
    }

    // MARK: - Helpers

    private func isUnknown(_ kind: RelayFrameKind) -> Bool {
        if case .unknown = kind { return true }
        return false
    }
}

// MARK: - JSONValue convenience

private extension JSONValue {
    /// Build a JSONValue from a serialized JSON object (sample frame bodies).
    init(_ object: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        self = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
    }
}
