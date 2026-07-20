import XCTest
@testable import HermesMobile

/// QA-1 B10 / A3 coverage: the relay `clarify.request` + `approval.request`
/// frames render the SAME interactive cards + dock the direct path uses, and
/// the answers round-trip upstream over the relay — closing the render-layer
/// gap build 114 shipped with (the frames decoded — conformance proved the
/// wire — but nothing bridged them into `ChatStore.pendingApproval` /
/// `pendingClarification`, the SOLE input of ``TurnDockContent/resolve``, and
/// the card responders were hardwired to the idle gateway client).
///
/// Render-level per A3: RECORDED relay frames (the shared conformance fixture
/// `tests/conformance/wire_contract.json` `downstream.samples`, replayed by the
/// XCTest conformance consumer too) flow through the production funnel —
/// `RelayClient` → `RelaySessionCoordinator.ingest` → `RelayItemStore` +
/// `ChatStore` — and the tests assert the view-model state the SwiftUI cards
/// read (`pendingClarification` / `pendingApproval` → ``TurnDockContent``) plus
/// the exact upstream answer frames the ratified protocol §5 requires.
///
/// RED on qa1/base (pre-fix): the ingest-bridge + relay-responder tests fail —
/// the pending state stays `nil` forever and no relay upstream is emitted.
/// Deterministic; no live network — the coordinator's `RelayClient` runs over
/// an in-process mock transport (canonical copy in `RelaySessionCoordinatorTests`).
@MainActor
final class RelayGateBridgeTests: XCTestCase {

    // MARK: - In-process mock relay transport

    /// Minimal fake relay: `receive()` hands back queued downstream messages;
    /// `send` records the upstream frame and runs an optional `script`. Mirrors
    /// the canonical mock in `RelaySessionCoordinatorTests`.
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

        func deliverFrame(_ frame: RelayFrame) {
            guard let data = try? JSONEncoder().encode(frame) else { return }
            deliver(String(decoding: data, as: UTF8.self))
        }

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

    /// Restores the persisted transport flag; tests that flip it to `.relay`
    /// install one in `defer` so a failure never leaks the flag to other suites.
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

    /// The full production relay stack over a mock transport: `ConnectionStore`
    /// (flag forced to `.relay`) → `RelaySessionCoordinator` (injected client)
    /// → `ChatStore` attached. Returns the transport so tests can deliver
    /// recorded frames downstream and assert the upstream answers.
    private func makeRelayStack(
        script: (@Sendable (MockRelayTransport.Upstream, MockRelayTransport) -> Void)? = nil
    ) async throws -> (transport: MockRelayTransport, chat: ChatStore, coordinator: RelaySessionCoordinator) {
        let transport = MockRelayTransport(script: script)
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        chat.attach(connection: connection, sessions: sessions, attachments: AttachmentStore())
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

    // MARK: - Recorded fixtures (shared conformance contract)

    /// A downstream frame RECORDED into the shared wire contract the pytest
    /// conformance suite asserts against (`downstream.samples`) — the same
    /// bytes both test stacks agree on, replayed here through the render lane.
    private func recordedFrame(named name: String) throws -> RelayFrame {
        let url = try XCTUnwrap(
            Bundle(for: type(of: self)).url(forResource: "wire_contract", withExtension: "json"),
            "wire_contract.json must be bundled into the test target (project.yml)"
        )
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let downstream = try XCTUnwrap(json["downstream"] as? [String: Any])
        let samples = try XCTUnwrap(downstream["samples"] as? [[String: Any]])
        let entry = try XCTUnwrap(
            samples.first { ($0["name"] as? String) == name },
            "wire_contract.json downstream.samples has no frame named \(name)"
        )
        let frameData = try JSONSerialization.data(withJSONObject: try XCTUnwrap(entry["frame"]))
        return try JSONDecoder().decode(RelayFrame.self, from: frameData)
    }

    private func turnCompletedFrame(seq: Int, sid: String) -> RelayFrame {
        RelayFrame(seq: seq, sid: sid, turn: "\(sid):t1", kind: .turnCompleted,
                   body: .object(["usage": .object(["input": .number(1), "output": .number(1), "total": .number(2)])]))
    }

    // MARK: - Ingest bridge: frames → card view-models

    /// THE B10 contract (clarify half): a recorded `clarify.request` frame
    /// replayed through the production funnel surfaces `pendingClarification` —
    /// the SOLE input of the dock resolver — with the fields the `ClarifyBanner`
    /// renders (question, tappable choices, the `request_id` the answer echoes).
    /// RED on qa1/base: `RelayItemStore` drops the kind and no bridge exists.
    func testRecordedClarifyFrameSurfacesPendingClarificationAndDock() async throws {
        let frame = try recordedFrame(named: "clarify.request")
        let (transport, chat, coordinator) = try await makeRelayStack()

        XCTAssertNil(chat.pendingClarification, "baseline: no gate before the frame lands")
        transport.deliverFrame(frame)
        await waitUntil { chat.pendingClarification != nil }

        let pending = try XCTUnwrap(chat.pendingClarification)
        XCTAssertEqual(pending.sessionId, frame.sid, "the gate binds to the frame's session")
        XCTAssertEqual(pending.request.question, "Which environment?")
        XCTAssertEqual(pending.request.choices, ["staging", "production"])
        XCTAssertEqual(pending.request.requestId, "clr-1", "the answer must echo this id")
        // The dock resolver — the ONE function ChatView/TurnDock ask — sees it.
        XCTAssertEqual(
            TurnDockContent.resolve(hasApproval: chat.pendingApproval != nil,
                                    hasClarification: chat.pendingClarification != nil,
                                    hasTasks: false, hasQueued: false),
            .clarify, "the dock must resolve the clarify card"
        )
        await coordinator.stop()
    }

    /// THE B10 contract (approval half): a recorded `approval.request` frame
    /// surfaces `pendingApproval` with the fields `ApprovalCard` renders (the
    /// command-derived title + description), and wins the dock priority over a
    /// clarify exactly as on the direct path (approval > clarify > tasks).
    func testRecordedApprovalFrameSurfacesPendingApprovalAndDock() async throws {
        let approval = try recordedFrame(named: "approval.request")
        let clarify = try recordedFrame(named: "clarify.request")
        let (transport, chat, coordinator) = try await makeRelayStack()

        transport.deliverFrame(approval)
        await waitUntil { chat.pendingApproval != nil }
        let pending = try XCTUnwrap(chat.pendingApproval)
        XCTAssertEqual(pending.sessionId, approval.sid)
        XCTAssertEqual(pending.request.command, "git push origin main")
        XCTAssertEqual(pending.request.title, "git push origin main",
                       "no explicit title on the wire → the command IS the card title (ProtocolTypes fallback)")
        XCTAssertEqual(pending.request.descriptionText, "Push the release branch")
        XCTAssertEqual(
            TurnDockContent.resolve(hasApproval: true, hasClarification: false,
                                    hasTasks: false, hasQueued: false),
            .approval
        )

        // A clarify arriving while an approval is pending must NOT steal the
        // dock — ratified priority is approval > clarify (TurnDock.resolve).
        transport.deliverFrame(clarify)
        await waitUntil { chat.pendingClarification != nil }
        XCTAssertEqual(
            TurnDockContent.resolve(hasApproval: chat.pendingApproval != nil,
                                    hasClarification: chat.pendingClarification != nil,
                                    hasTasks: false, hasQueued: false),
            .approval, "approval outranks clarify in the dock"
        )
        await coordinator.stop()
    }

    /// The recorded frame bodies decode into the exact view-models the cards
    /// bind to (payload-contract guard, transport-independent).
    func testRecordedFrameBodiesDecodeIntoCardViewModels() throws {
        let clarifyBody = try recordedFrame(named: "clarify.request").body
        let clarify = ClarifyRequestPayload(payload: clarifyBody)
        XCTAssertEqual(clarify.question, "Which environment?")
        XCTAssertEqual(clarify.choices, ["staging", "production"])
        XCTAssertEqual(clarify.requestId, "clr-1")

        let approvalBody = try recordedFrame(named: "approval.request").body
        let approval = ApprovalRequestPayload(payload: approvalBody)
        XCTAssertEqual(approval.command, "git push origin main")
        XCTAssertEqual(approval.descriptionText, "Push the release branch")
    }

    // MARK: - Egress: answers round-trip over the relay (§5 wire shapes)

    /// Tapping a clarify answer routes `clarify` OVER THE RELAY with the §5
    /// shape (`session_id` + `text` + echoed `request_id`) — NOT the idle
    /// gateway client — and clears the card. RED on qa1/base: the responder is
    /// hardwired to the gateway `client`, so no relay upstream is ever emitted.
    func testClarifyAnswerEmitsRelayUpstreamAndClearsCard() async throws {
        let frame = try recordedFrame(named: "clarify.request")
        let (transport, chat, coordinator) = try await makeRelayStack { upstream, relay in
            if let id = upstream.id, upstream.method == "clarify" {
                relay.deliverResult(id: id, result: .object(["ok": .bool(true)]))
            }
        }
        transport.deliverFrame(frame)
        await waitUntil { chat.pendingClarification != nil }

        await chat.respondClarification("staging")

        let clarifies = transport.upstreams().filter { $0.method == "clarify" }
        XCTAssertEqual(clarifies.count, 1, "the answer must go OUT over the relay")
        let params = clarifies[0].params
        XCTAssertEqual(params["session_id"] as? String, frame.sid, "relay requires the session id")
        XCTAssertEqual(params["text"] as? String, "staging", "§5: the relay maps text→answer")
        XCTAssertEqual(params["request_id"] as? String, "clr-1", "the gateway matches the waiter by request_id")
        XCTAssertNil(chat.pendingClarification, "answering clears the card")
        XCTAssertEqual(transport.upstreams().filter { $0.method == "clarify.respond" }.count, 0,
                       "clarify.respond is the GATEWAY rpc — never sent to the relay")
        await coordinator.stop()
    }

    /// Tapping approve routes `approve` over the relay with `session_id` +
    /// `decision` (the relay maps decision→choice; the silent-deny bug class
    /// was sending the wrong key). `all` is omitted when false per the iOS
    /// builder, echoed when true.
    func testApprovalAnswerEmitsRelayUpstreamAndClearsCard() async throws {
        let frame = try recordedFrame(named: "approval.request")
        let (transport, chat, coordinator) = try await makeRelayStack { upstream, relay in
            if let id = upstream.id, upstream.method == "approve" {
                relay.deliverResult(id: id, result: .object(["ok": .bool(true)]))
            }
        }
        transport.deliverFrame(frame)
        await waitUntil { chat.pendingApproval != nil }

        await chat.respondApproval(approve: true, all: false)

        let approves = transport.upstreams().filter { $0.method == "approve" }
        XCTAssertEqual(approves.count, 1, "the answer must go OUT over the relay")
        let params = approves[0].params
        XCTAssertEqual(params["session_id"] as? String, frame.sid)
        XCTAssertEqual(params["decision"] as? String, "approve", "§5: decision, relay maps → choice")
        XCTAssertNil(params["all"], "all=false is omitted by the iOS builder")
        XCTAssertNil(chat.pendingApproval, "answering clears the card")
        await coordinator.stop()
    }

    /// Deny maps to `decision: "deny"`; `all: true` is carried for the
    /// resolve-all action on the card.
    func testApprovalDenyAndResolveAllCarryOnTheRelayWire() async throws {
        let frame = try recordedFrame(named: "approval.request")
        let (transport, chat, coordinator) = try await makeRelayStack { upstream, relay in
            if let id = upstream.id, upstream.method == "approve" {
                relay.deliverResult(id: id, result: .object(["ok": .bool(true)]))
            }
        }
        // Deny.
        transport.deliverFrame(frame)
        await waitUntil { chat.pendingApproval != nil }
        await chat.respondApproval(approve: false, all: false)
        var approves = transport.upstreams().filter { $0.method == "approve" }
        XCTAssertEqual(approves.last?.params["decision"] as? String, "deny")

        // Resolve-all on a fresh gate (the answered one is suppression-keyed).
        let frame2 = RelayFrame(seq: frame.seq + 1, sid: frame.sid, turn: frame.turn,
                                kind: .approvalRequest,
                                body: .object(["approval_id": .string("appr-2"),
                                               "command": .string("rm -rf build/")]))
        transport.deliverFrame(frame2)
        await waitUntil { chat.pendingApproval?.id == "appr-2" }
        await chat.respondApproval(approve: true, all: true)
        approves = transport.upstreams().filter { $0.method == "approve" }
        XCTAssertEqual(approves.last?.params["decision"] as? String, "approve")
        XCTAssertEqual(approves.last?.params["all"] as? Bool, true, "resolve-all carries on the wire")
        XCTAssertEqual(approves.last?.params["request_id"] as? String, "appr-2")
        await coordinator.stop()
    }

    // MARK: - Lifecycle: gates settle with the turn, never stale

    /// A `turn.completed` frame expires a pending gate — the relay analogue of
    /// the direct path's message.complete expiry (R1 #51/#52): the turn settled
    /// (answered elsewhere, or the agent moved on), so a stale card must not
    /// linger inviting an answer against a dead runtime.
    func testTurnCompletedClearsPendingGates() async throws {
        let frame = try recordedFrame(named: "clarify.request")
        let (transport, chat, coordinator) = try await makeRelayStack()
        transport.deliverFrame(frame)
        await waitUntil { chat.pendingClarification != nil }

        transport.deliverFrame(turnCompletedFrame(seq: 10, sid: frame.sid))
        await waitUntil { chat.pendingClarification == nil }
        XCTAssertNil(chat.pendingApproval)
        XCTAssertEqual(
            TurnDockContent.resolve(hasApproval: false, hasClarification: false,
                                    hasTasks: false, hasQueued: false),
            .none, "the dock collapses once the turn settles"
        )
        await coordinator.stop()
    }

    /// A `resync` after a socket flap re-sends frames the phone already folded
    /// (the ring replay). An ANSWERED gate must not be resurrected by its replay
    /// — the store's per-frame idempotency has no meaning for one-shot gates, so
    /// the bridge suppresses resolved ids.
    func testAnsweredGateIsNotResurrectedByFrameReplay() async throws {
        let frame = try recordedFrame(named: "clarify.request")
        let (transport, chat, coordinator) = try await makeRelayStack { upstream, relay in
            if let id = upstream.id, upstream.method == "clarify" {
                relay.deliverResult(id: id, result: .object(["ok": .bool(true)]))
            }
        }
        transport.deliverFrame(frame)
        await waitUntil { chat.pendingClarification != nil }
        await chat.respondClarification("staging")
        XCTAssertNil(chat.pendingClarification)

        // The flap replay re-delivers the same frame (same seq, same body).
        transport.deliverFrame(frame)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(chat.pendingClarification,
                     "a replayed frame for an ANSWERED gate must not resurrect the card")
        await coordinator.stop()
    }

    /// Switching the projected session clears the previous session's gate —
    /// parity with the direct path's `reset()` on open (a gate belongs to its
    /// session's turn; answering session A's card while viewing B is a mis-route).
    func testSessionSwitchClearsPendingGates() async throws {
        let frame = try recordedFrame(named: "clarify.request")
        let (transport, chat, coordinator) = try await makeRelayStack { upstream, relay in
            guard let id = upstream.id, upstream.method == "open" else { return }
            relay.deliverFrame(RelayFrame(
                seq: 1, sid: "other-session", turn: nil, kind: .snapshot,
                body: .object(["items": .array([]), "cursor": .number(1)])))
            relay.deliverResult(id: id, result: .object(["ok": .bool(true)]))
        }
        transport.deliverFrame(frame)
        await waitUntil { chat.pendingClarification != nil }

        _ = try await coordinator.open("other-session")
        await waitUntil { chat.pendingClarification == nil }
        XCTAssertNil(chat.pendingApproval)
        _ = transport
        await coordinator.stop()
    }

    // MARK: - Transport isolation

    /// With the flag OFF (gateway-direct, the default install) the responders
    /// never touch the relay — the new branch is flag-gated, so the byte-exact
    /// direct path is untouched.
    func testGatewayDirectTransportDoesNotRouteAnswersThroughRelay() async throws {
        let transport = MockRelayTransport()
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        chat.attach(connection: connection, sessions: sessions, attachments: AttachmentStore())
        restoreTransportFlagAfterTest()
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.transportPath)
        XCTAssertEqual(connection.transportPath, .gatewayDirect)
        connection.relayCoordinatorFactory = {
            RelaySessionCoordinator(chatStore: chat, clientFactory: { RelayClient { _ in transport } })
        }
        _ = connection.ensureRelayCoordinator()

        // Seed a gate the way the direct-path gateway router does today.
        chat.pendingClarification = PendingClarification(
            sessionId: "s",
            request: ClarifyRequestPayload(payload: .object([
                "question": .string("Q"), "choices": .array([]), "request_id": .string("r"),
            ])))
        XCTAssertNotNil(chat.pendingClarification)

        await chat.respondClarification("answer")
        XCTAssertEqual(transport.upstreams().filter { $0.method == "clarify" }.count, 0,
                       "gateway-direct must never emit a relay clarify upstream")
    }
}
