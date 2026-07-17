import XCTest
@testable import HermesMobile

/// Shared verbatim with the Python gateway tests. The one source fixture is
/// copied into the XCTest bundle so server and iOS decode the same examples.
private enum SessionStatusResponseFixtures {
    private static let frames: [String: JSONValue] = {
        let bundle = Bundle(for: SessionStatusFixtureBundleToken.self)
        let url = bundle.url(
            forResource: "session_status_responses",
            withExtension: "json"
        )!
        let data = try! Data(contentsOf: url)
        return try! JSONDecoder().decode([String: JSONValue].self, from: data)
    }()

    static func frame(named name: String, id: String = "fixture") -> JSONValue {
        guard case .object(var frame) = frames[name] else {
            preconditionFailure("Missing session.status fixture: \(name)")
        }
        frame["id"] = .string(id)
        return .object(frame)
    }

    static func wireFrame(named name: String, id: String) -> String {
        let data = try! JSONEncoder().encode(frame(named: name, id: id))
        return String(decoding: data, as: UTF8.self)
    }

    static func result(named name: String) -> SessionStatusResult {
        guard let result = frame(named: name)["result"]?.decoded(as: SessionStatusResult.self) else {
            preconditionFailure("Fixture \(name) has no SessionStatusResult")
        }
        return result
    }
}

private final class SessionStatusFixtureBundleToken: NSObject {}

/// ABH-371 — live re-entry.
///
/// A stored transcript seed is not enough to decide the UI is idle: a session can
/// be resumed while its runtime is already running. Re-entry must reconcile
/// against the live `session.status`, restore the in-flight chat affordances, and
/// avoid showing completed-turn action rows while the runtime is still working.
@MainActor
final class LiveTurnReentryTests: XCTestCase {
    private let storedId = "stored-live-reentry"
    private let runtimeId = "rt-live-reentry"

    private final class SessionStatusTransport: GatewayWebSocketTask, @unchecked Sendable {
        private var inbox: [URLSessionWebSocketTask.Message] = []
        private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
        private let lock = NSLock()

        private(set) var sentMethods: [String] = []
        private(set) var sentParams: [[String: Any]] = []
        private let fixtureName: String

        init(fixtureName: String = "running") {
            self.fixtureName = fixtureName
            enqueue(.string(
                #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready"}}"#
            ))
        }

        func resume() {}
        func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}

        func receive() async throws -> URLSessionWebSocketTask.Message {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if !inbox.isEmpty {
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
                  let id = object["id"] as? String,
                  let method = object["method"] as? String
            else { return }

            record(method: method, params: object["params"] as? [String: Any] ?? [:])
            enqueue(.string(SessionStatusResponseFixtures.wireFrame(named: fixtureName, id: id)))
            await Task.yield()
        }

        private func record(method: String, params: [String: Any]) {
            lock.lock()
            sentMethods.append(method)
            sentParams.append(params)
            lock.unlock()
        }

        private func enqueue(_ message: URLSessionWebSocketTask.Message) {
            lock.lock()
            if let waiter {
                self.waiter = nil
                lock.unlock()
                waiter.resume(returning: message)
            } else {
                inbox.append(message)
                lock.unlock()
            }
        }

    }

    private func makeStore() -> (ChatStore, SessionStore) {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        sessions.activeStoredId = storedId
        sessions.activeRuntimeId = runtimeId
        return (chat, sessions)
    }

    private func storedMessage(role: String, text: String) -> StoredMessage {
        StoredMessage(json: .object([
            "role": .string(role),
            "content": .string(text),
        ]))!
    }

    private func status(running: Bool) -> SessionStatusResult {
        SessionStatusResponseFixtures.result(named: running ? "running" : "idle")
    }

    private func openResult(
        runtimeId: String,
        storedId: String,
        running: Bool? = nil,
        inflight: JSONValue? = nil
    ) -> SessionOpenResult {
        var payload: [String: JSONValue] = [
            "session_id": .string(runtimeId),
            "resumed": .string(storedId),
        ]
        if let running { payload["running"] = .bool(running) }
        if let inflight { payload["inflight"] = inflight }
        return JSONValue.object(payload).decoded(as: SessionOpenResult.self)!
    }

    private func summary(id: String) -> SessionSummary {
        SessionSummary(
            id: id,
            title: "Live re-entry",
            preview: "previous reply",
            startedAt: 0,
            messageCount: 2,
            source: "cli",
            lastActive: 0,
            cwd: nil
        )
    }

    func testSessionStatusRealWireDecodesStructuredResult() async throws {
        let transport = SessionStatusTransport()
        let client = HermesGatewayClient(transportFactory: { _ in transport })
        try await client.connect(baseURL: URL(string: "ws://127.0.0.1:9999")!, token: "t")

        let status: SessionStatusResult = try await client.request(
            "session.status",
            params: .object(["session_id": .string(runtimeId)]),
            timeout: .seconds(2)
        )

        XCTAssertEqual(transport.sentMethods, ["session.status"])
        XCTAssertEqual(transport.sentParams.first?["session_id"] as? String, runtimeId)
        XCTAssertEqual(status.running, true)
        XCTAssertEqual(status.model, "live-model")
        XCTAssertEqual(status.provider, "live-provider")
        XCTAssertEqual(status.usage?.input, 1234)
        XCTAssertEqual(status.usage?.output, 56)
        XCTAssertEqual(status.usage?.total, 1290)
        XCTAssertEqual(status.usage?.contextUsed, 43_210)
        XCTAssertEqual(status.usage?.contextMax, 128_000)
        XCTAssertEqual(status.usage?.contextPercent, 34)
        XCTAssertEqual(status.usage?.compressions, 1)
        await client.disconnect()
    }

    func testSessionStatusMissingWireReturnsRPCError() async throws {
        let transport = SessionStatusTransport(fixtureName: "missing")
        let client = HermesGatewayClient(transportFactory: { _ in transport })
        try await client.connect(baseURL: URL(string: "ws://127.0.0.1:9999")!, token: "t")

        do {
            let _: SessionStatusResult = try await client.request(
                "session.status",
                params: .object(["session_id": .string("missing")]),
                timeout: .seconds(2)
            )
            XCTFail("a missing runtime must remain an explicit RPC error")
        } catch let GatewayError.rpc(code, message) {
            XCTAssertEqual(code, 4001)
            XCTAssertEqual(message, "session not found")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        await client.disconnect()
    }

    func testStatusRunningRestoresStreamingPlaceholderStopStateAndActionGate() async {
        let (chat, _) = makeStore()
        chat.seed(from: [
            storedMessage(role: "user", text: "previous prompt"),
            storedMessage(role: "assistant", text: "previous reply"),
        ])
        XCTAssertFalse(chat.isStreaming)
        XCTAssertTrue(MessageBubble.shouldShowAssistantActionRow(
            messageIsStreaming: false,
            hasRenderedText: true,
            assistantTurnActionsEnabled: !chat.isStreaming
        ))

        var requestedRuntime: String?
        chat.liveTurnStatusFetch = { runtime in
            requestedRuntime = runtime
            return self.status(running: true)
        }

        await chat.reconcileLiveTurnStatus(runtimeId: runtimeId)

        XCTAssertEqual(requestedRuntime, runtimeId)
        XCTAssertTrue(chat.isStreaming, "live re-entry must show an in-progress turn, not a settled transcript")
        XCTAssertTrue(chat.localTurnInFlight, "live re-entry is owned by the active runtime, so mutable actions stay disabled")
        XCTAssertEqual(chat.interruptTarget, runtimeId, "Stop must target the resumed runtime")
        XCTAssertEqual(chat.messages.filter { $0.role == .assistant }.count, 2)
        XCTAssertTrue(chat.messages.last?.isStreaming == true, "a working placeholder/cursor is appended at the transcript tail")
        XCTAssertFalse(MessageBubble.shouldShowAssistantActionRow(
            messageIsStreaming: false,
            hasRenderedText: true,
            assistantTurnActionsEnabled: !chat.isStreaming
        ), "completed-turn rows are suppressed while the live runtime is still working")
    }

    func testStatusIdleDoesNotInventAStreamingTurn() async {
        let (chat, _) = makeStore()
        chat.seed(from: [
            storedMessage(role: "user", text: "previous prompt"),
            storedMessage(role: "assistant", text: "previous reply"),
        ])
        chat.liveTurnStatusFetch = { _ in self.status(running: false) }

        await chat.reconcileLiveTurnStatus(runtimeId: runtimeId)

        XCTAssertFalse(chat.isStreaming)
        XCTAssertFalse(chat.localTurnInFlight)
        XCTAssertEqual(chat.messages.filter { $0.role == .assistant }.count, 1)
        XCTAssertTrue(MessageBubble.shouldShowAssistantActionRow(
            messageIsStreaming: false,
            hasRenderedText: true,
            assistantTurnActionsEnabled: !chat.isStreaming
        ))
    }

    func testResumeSnapshotRestoresPartialTurnWithoutStatusRoundTrip() async {
        let (chat, _) = makeStore()
        chat.seed(from: [
            storedMessage(role: "user", text: "previous prompt"),
            storedMessage(role: "assistant", text: "previous reply"),
        ])
        var statusRequests = 0
        chat.liveTurnStatusFetch = { _ in
            statusRequests += 1
            return self.status(running: false)
        }

        await chat.reconcileLiveTurnStatus(
            runtimeId: runtimeId,
            snapshotRunning: true,
            inflight: SessionInflightTurn(
                user: "write a long answer",
                assistant: "partial answer",
                streaming: true
            )
        )

        XCTAssertEqual(statusRequests, 0)
        XCTAssertEqual(chat.messages.suffix(2).map(\.role), [.user, .assistant])
        XCTAssertEqual(chat.messages.suffix(2).map(\.text), ["write a long answer", "partial answer"])
        XCTAssertTrue(chat.messages.last?.isStreaming == true)
        XCTAssertTrue(chat.localTurnInFlight)
        XCTAssertEqual(chat.interruptTarget, runtimeId)
    }

    func testRepeatResumeSnapshotDoesNotDuplicateInflightPrompt() async {
        // Regression: reconcileLiveTurnStatus runs once at open and again on every
        // reconnect-recovery resume for the same running turn. The prompt bubble
        // must not multiply across repeat reconciles of one inflight turn.
        let (chat, _) = makeStore()
        chat.seed(from: [
            storedMessage(role: "user", text: "previous prompt"),
            storedMessage(role: "assistant", text: "previous reply"),
        ])
        let inflight = SessionInflightTurn(
            user: "write a long answer",
            assistant: "partial answer",
            streaming: true
        )

        for _ in 0..<3 {
            await chat.reconcileLiveTurnStatus(
                runtimeId: runtimeId,
                snapshotRunning: true,
                inflight: inflight
            )
        }

        XCTAssertEqual(
            chat.messages.map(\.role),
            [.user, .assistant, .user, .assistant],
            "repeat reconciles of the same inflight turn must not append duplicate prompt bubbles"
        )
        XCTAssertEqual(chat.messages.filter { $0.role == .user && $0.text == "write a long answer" }.count, 1)
        XCTAssertTrue(chat.messages.last?.isStreaming == true)
        XCTAssertTrue(chat.localTurnInFlight)
        XCTAssertEqual(chat.interruptTarget, runtimeId)
    }

    func testOpenWaitsForSeedThenRestoresLiveStatus() async {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        sessions.resumeRPC = { [runtimeId, storedId] requested, _ in
            XCTAssertEqual(requested, storedId)
            return self.openResult(
                runtimeId: runtimeId,
                storedId: storedId,
                running: true,
                inflight: .object([
                    "user": .string("current prompt"),
                    "assistant": .string("partial answer"),
                    "streaming": .bool(true),
                ])
            )
        }
        sessions.transcriptFetch = { [storedId] requested in
            XCTAssertEqual(requested, storedId)
            return [
                self.storedMessage(role: "user", text: "previous prompt"),
                self.storedMessage(role: "assistant", text: "previous reply"),
            ]
        }
        chat.liveTurnStatusFetch = { _ in
            XCTFail("a current resume snapshot must avoid the legacy session.status round-trip")
            return self.status(running: false)
        }
        var streamingWhenRuntimeBound: Bool?
        sessions.onActiveRuntimeBound = { streamingWhenRuntimeBound = chat.isStreaming }

        sessions.open(summary(id: storedId))
        #if DEBUG
        await sessions.waitForPendingOpenForTesting()
        #endif

        XCTAssertEqual(sessions.activeRuntimeId, runtimeId)
        XCTAssertTrue(chat.isStreaming)
        XCTAssertTrue(chat.localTurnInFlight)
        XCTAssertEqual(streamingWhenRuntimeBound, true,
                       "the runtime-bound queue drain must see restored busy state, not the pre-status idle gap")
        XCTAssertEqual(chat.messages.map(\.role), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(chat.messages.suffix(2).map(\.text), ["current prompt", "partial answer"])
        XCTAssertTrue(chat.messages.last?.isStreaming == true)
    }
}

/// ABH-443 protocol-shape coverage. These tests deliberately decode the same
/// checked-in fixtures asserted by tests/test_tui_gateway_server.py.
final class ProtocolTypesTests: XCTestCase {
    func testSessionStatusRunningAndIdleFixturesDecodeStableTypes() throws {
        let running = SessionStatusResponseFixtures.result(named: "running")
        XCTAssertEqual(running.running, true)
        XCTAssertEqual(running.model, "live-model")
        XCTAssertEqual(running.provider, "live-provider")
        XCTAssertEqual(running.usage?.total, 1_290)

        let idle = SessionStatusResponseFixtures.result(named: "idle")
        XCTAssertEqual(idle.running, false)
        XCTAssertEqual(idle.model, "idle-model")
        XCTAssertEqual(idle.provider, "idle-provider")
        XCTAssertEqual(idle.usage?.total, 0)
    }

    func testSessionStatusPartialUsageLeavesUnavailableMeasurementsNil() throws {
        let status = SessionStatusResponseFixtures.result(named: "partial_usage")
        XCTAssertEqual(status.running, false)
        XCTAssertEqual(status.usage?.input, 120)
        XCTAssertEqual(status.usage?.total, 120)
        XCTAssertNil(status.usage?.contextUsed)
        XCTAssertNil(status.usage?.contextMax)
        XCTAssertNil(status.usage?.contextPercent)
        XCTAssertNil(status.usage?.compressions)
    }

    func testSessionStatusMissingFixtureIsErrorNotOmittedRunning() throws {
        let frame = SessionStatusResponseFixtures.frame(named: "missing")
        XCTAssertNil(frame["result"])
        XCTAssertEqual(frame["error"]?["code"]?.intValue, 4001)
        XCTAssertEqual(frame["error"]?["message"]?.stringValue, "session not found")
    }

    func testLegacyTextOnlyStatusDoesNotClaimRunning() throws {
        let legacy: JSONValue = .object(["output": .string("Agent Running: Yes")])
        let status = try XCTUnwrap(legacy.decoded(as: SessionStatusResult.self))
        XCTAssertNil(status.running)
        XCTAssertFalse(status.running == true)
    }
}
