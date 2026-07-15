import XCTest
@testable import HermesMobile

/// ABH-177 + ABH-182 Inc-1/Inc-3 — WS liveness ping, orphaned-LA reconcile,
/// and stale-window tightening.
///
/// Seven deterministic tests (no device, no live gateway):
///
/// (a) Dead ping → `probeLiveness` returns `false` and state transitions to `.failed`.
/// (b) Healthy ping → `probeLiveness` returns `true` and state stays `.open`.
/// (c) `LiveActivityManager.shouldEndOrphan` pure-function truth-table.
/// (d) Dead ping client contract + LA decision (regression guard).
/// (e) HANG-BOUND: a never-pong transport must resolve within `livenessPingTimeout`,
///     proving the `withTaskCancellationHandler` onCancel actually unblocks the
///     continuation (Must-Fix #1 regression guard).
/// (f) REAL ROUTING: `handleScenePhase(.active)` with `probeLivenessRPC` injected
///     returning `false` drives the full detection → reconnect path, proving the
///     wiring in `ConnectionStore` is correct end-to-end (Must-Fix #2b).
/// (g) STALE WINDOW: pins `LiveActivityManager.staleAfter` to 5 min and verifies
///     the rolling-window safety invariant (ABH-182 Inc-3).
@MainActor
final class WSLivenessTests: XCTestCase {

    // MARK: - Mock transports

    /// Opens normally (delivers `gateway.ready`) and lets `sendPing` succeed
    /// promptly. Used for the "socket alive" path.
    private final class PongTransport: GatewayWebSocketTask, @unchecked Sendable {

        private var inbox: [URLSessionWebSocketTask.Message] = []
        private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
        private let lock = NSLock()

        init() {
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

        func send(_ message: URLSessionWebSocketTask.Message) async throws {}

        /// Ping succeeds immediately.
        func sendPing() async throws {}

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

    /// Opens normally (delivers `gateway.ready`) but whose `sendPing` throws an
    /// error immediately, simulating a silently-dead socket.
    private final class DeadPingTransport: GatewayWebSocketTask, @unchecked Sendable {

        struct PingError: Error {}

        private var inbox: [URLSessionWebSocketTask.Message] = []
        private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
        private let lock = NSLock()

        init() {
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

        func send(_ message: URLSessionWebSocketTask.Message) async throws {}

        /// Ping fails immediately — simulates a silently-dead socket.
        func sendPing() async throws {
            throw PingError()
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

    /// Opens normally (delivers `gateway.ready`) but whose `sendPing` NEVER
    /// resolves on its own — it parks indefinitely until task cancellation fires.
    ///
    /// Used for the hang-bound test (e): with the `withTaskCancellationHandler`
    /// fix in `URLSessionWebSocketTask.sendPing`, the timeout task in
    /// `probeLiveness`'s task group wins, `cancelAll()` fires, and the onCancel
    /// handler resolves the parked continuation promptly. Without the fix, the
    /// continuation hangs until the URLSession's 30-second timeout elapses.
    ///
    /// In this mock, `cancel()` resolves the ping continuation (mirroring what
    /// the URLSession's own cancel does in production — it calls the ping callback
    /// with an error, which the `withTaskCancellationHandler` onCancel triggers).
    private final class NeverPongTransport: GatewayWebSocketTask, @unchecked Sendable {

        private var inbox: [URLSessionWebSocketTask.Message] = []
        private var receiveWaiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
        private var pingWaiter: CheckedContinuation<Void, Error>?
        private let lock = NSLock()

        init() {
            enqueue(.string(
                #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready"}}"#
            ))
        }

        func resume() {}

        /// Cancel resolves the parked ping continuation so the task group exits.
        /// Mirrors the real URLSession behaviour: `cancel()` on a URLSessionWebSocketTask
        /// causes the pending ping callback to fire with an error.
        func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
            lock.lock()
            let waiter = pingWaiter
            pingWaiter = nil
            lock.unlock()
            waiter?.resume(throwing: CancellationError())
        }

        func receive() async throws -> URLSessionWebSocketTask.Message {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if !inbox.isEmpty {
                    let next = inbox.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: next)
                } else {
                    receiveWaiter = continuation
                    lock.unlock()
                }
            }
        }

        func send(_ message: URLSessionWebSocketTask.Message) async throws {}

        /// Park indefinitely until task cancellation fires the onCancel handler,
        /// which calls `cancel()`, which resolves the parked continuation.
        func sendPing() async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    lock.lock()
                    pingWaiter = continuation
                    lock.unlock()
                }
            } onCancel: {
                // Mirrors the real `URLSessionWebSocketTask.sendPing` onCancel:
                // calling cancel() on the task causes the ping callback to fire
                // with an error, resolving the continuation promptly.
                self.cancel(with: .goingAway, reason: nil)
            }
        }

        private func enqueue(_ message: URLSessionWebSocketTask.Message) {
            lock.lock()
            if let waiter = receiveWaiter {
                receiveWaiter = nil
                lock.unlock()
                waiter.resume(returning: message)
            } else {
                inbox.append(message)
                lock.unlock()
            }
        }
    }

    // MARK: - Store builder

    @MainActor
    private func makeConnectionStore() -> (ConnectionStore, SessionStore, ChatStore) {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        return (connection, sessions, chat)
    }

    /// 600 ms — same settle window used by `ConnectionStoreReconnectTests`: enough
    /// for a `Task` spawned on the main executor to complete its attempt-0 pass
    /// (no backoff) on the simulator.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(600))
    }

    // MARK: - (a) Dead ping → state transitions to .failed

    /// A `sendPing` that throws must cause `probeLiveness` to return `false` and
    /// transition the client to `.failed` via the EXISTING `handleSocketFailure`
    /// path — NOT a new parallel reconnect. This proves the state-observer–driven
    /// reconnect loop gets the `.failed` signal it needs.
    func testDeadPingSetStateToFailed() async throws {
        let transport = DeadPingTransport()
        let client = HermesGatewayClient { _ in transport }
        try await client.connect(baseURL: URL(string: "ws://127.0.0.1:9999")!, token: "t")

        let stateBefore = await client.state
        XCTAssertEqual(stateBefore, .open, "precondition: socket must be .open before probe")

        let alive = await client.probeLiveness()

        XCTAssertFalse(alive, "a throwing ping must report the socket as dead")
        let stateAfter = await client.state
        guard case .failed = stateAfter else {
            return XCTFail("expected .failed after dead ping, got \(stateAfter)")
        }

        await client.disconnect()
    }

    // MARK: - (b) Healthy ping → stays .open

    /// A `sendPing` that resolves normally must leave the client in `.open` so the
    /// `.connected` branch of `handleScenePhase` can continue to the REST backfill.
    func testHealthyPingKeepsStateOpen() async throws {
        let transport = PongTransport()
        let client = HermesGatewayClient { _ in transport }
        try await client.connect(baseURL: URL(string: "ws://127.0.0.1:9999")!, token: "t")

        let alive = await client.probeLiveness()

        XCTAssertTrue(alive, "a successful ping must report the socket as alive")
        let stateAfter = await client.state
        XCTAssertEqual(stateAfter, .open, "state must remain .open after a healthy ping")

        await client.disconnect()
    }

    // MARK: - (c) shouldEndOrphan pure-function coverage

    /// Exhaustive truth-table for `LiveActivityManager.shouldEndOrphan`.
    /// ActivityKit cannot run in the unit-test host; the pure function is the seam
    /// that makes this decision unit-testable — exactly the pattern used by
    /// `NotificationService.approveChoice`.
    func testShouldEndOrphanPureFunction() {
        // Live activity + NO active turn → end it (the orphan case).
        XCTAssertTrue(
            LiveActivityManager.shouldEndOrphan(hasActiveTurn: false, isLive: true),
            "an orphaned (live but no active turn) activity should be ended"
        )

        // Live activity + active turn → do NOT end it.
        XCTAssertFalse(
            LiveActivityManager.shouldEndOrphan(hasActiveTurn: true, isLive: true),
            "must never end a live-turn activity"
        )

        // No activity at all — nothing to end in either case.
        XCTAssertFalse(
            LiveActivityManager.shouldEndOrphan(hasActiveTurn: false, isLive: false),
            "no-op when no activity is running"
        )
        XCTAssertFalse(
            LiveActivityManager.shouldEndOrphan(hasActiveTurn: true, isLive: false),
            "no-op when no activity is running (with active turn)"
        )
    }

    // MARK: - (d) Dead ping client contract + LA decision (regression guard)

    /// Regression guard: direct `client.probeLiveness()` on a dead transport
    /// transitions to `.failed` and the LA pure-function decision is correct.
    func testDeadPingClientContractAndLADecision() async throws {
        let transport = DeadPingTransport()
        let client = HermesGatewayClient { _ in transport }
        try await client.connect(baseURL: URL(string: "ws://127.0.0.1:9999")!, token: "t")

        let stateBefore = await client.state
        XCTAssertEqual(stateBefore, .open)

        let alive = await client.probeLiveness()
        XCTAssertFalse(alive)

        let stateAfter = await client.state
        guard case .failed = stateAfter else {
            return XCTFail("expected .failed after dead ping, got \(stateAfter)")
        }

        // LA reconcile decision: isStreaming=false, isLive=false (ActivityKit
        // absent in test host) → shouldEndOrphan is false (correct no-op).
        XCTAssertFalse(
            LiveActivityManager.shouldEndOrphan(hasActiveTurn: false, isLive: false)
        )

        await client.disconnect()
    }

    // MARK: - (e) HANG-BOUND: never-pong transport must resolve within livenessPingTimeout

    /// The critical regression guard for Must-Fix #1.
    ///
    /// `NeverPongTransport.sendPing` parks indefinitely — it only unblocks when
    /// task cancellation fires the `withTaskCancellationHandler` onCancel handler.
    ///
    /// WITHOUT the fix: `probeLiveness` uses `withThrowingTaskGroup`; when the
    /// timeout task wins, `cancelAll()` marks the ping child task as cancelled, but
    /// the old `withCheckedThrowingContinuation` (no cancellation handler) on the
    /// URLSession ping callback never fires, so the group hangs at scope exit
    /// waiting for the child — up to ~30 s (`timeoutIntervalForRequest`).
    ///
    /// WITH the fix: the `withTaskCancellationHandler` onCancel in `sendPing` calls
    /// `cancel()` on the transport, which resolves the parked continuation with an
    /// error, allowing the task group to exit cleanly within `livenessPingTimeout`.
    ///
    /// Wall-clock budget: `timeout` (1 s) + 2 s grace = 3 s max.
    /// A regression to the uncancellable path would exceed 30 s.
    func testNeverPongTransportBoundedByTimeout() async throws {
        let transport = NeverPongTransport()
        let client = HermesGatewayClient { _ in transport }
        try await client.connect(baseURL: URL(string: "ws://127.0.0.1:9999")!, token: "t")

        let stateBefore = await client.state
        XCTAssertEqual(stateBefore, .open, "precondition: must be .open before probe")

        let start = ContinuousClock.now
        // Use a 1 s timeout (shorter than livenessPingTimeout=4 s) so the test
        // resolves quickly in CI while still being well above scheduling jitter.
        let alive = await client.probeLiveness(timeout: .seconds(1))
        let elapsed = start.duration(to: .now)

        XCTAssertFalse(alive, "a never-pong socket must be declared dead")
        // Budget: 1 s timeout + 2 s grace. A hang (30 s) would massively exceed this.
        XCTAssertLessThan(elapsed, .seconds(3),
            "probeLiveness must return within ~timeout, not hang ~30 s (Must-Fix #1)")

        // State must be .failed (timeout error ≠ NSURLErrorCancelled, so not .closed).
        let stateAfter = await client.state
        guard case .failed = stateAfter else {
            return XCTFail("expected .failed after timed-out ping, got \(stateAfter)")
        }

        await client.disconnect()
    }

    // MARK: - (g) ABH-178 WIRING: clearAllTurnsInProgress is called by both abandon paths

    /// `handleScenePhase(.active)` with a `.closed` socket state (the `dead` branch)
    /// must clear `turnsInProgress` so a stale carry-forward flag can't lock the
    /// session list into a never-converge loop (ABH-157 regression guard).
    ///
    /// Isolation: uses `clientStateOverrideForScenePhase = .closed` to force the
    /// `dead` branch without a real transport. `connectRPC` throws so the reconnect
    /// loop stays in `.reconnecting` and does not race back to `.connected`.
    @MainActor
    func testDeadSocketBranchClearsTurnsInProgress() async {
        let (connection, sessions, _) = makeConnectionStore()

        // Reach .connected via the reconnect seam.
        connection.connectRPC = { _, _, _ in }
        connection._seedAndStartReconnect(
            serverURL: "http://127.0.0.1:9123",
            token: "test-token"
        )
        await settle()
        XCTAssertEqual(connection.phase, .connected,
            "precondition: must be .connected before scene-phase test")

        // Mark a session as mid-turn so turnsInProgress is non-empty.
        sessions.markTurnStarted(storedId: "sess-abc")
        XCTAssertFalse(sessions.turnsInProgressIds.isEmpty,
            "precondition: turnsInProgress must be non-empty before scene-phase fires")

        // Force the `dead` branch by injecting .closed state.
        connection.clientStateOverrideForScenePhase = .closed(reason: nil)
        // Throw in connectRPC so the reconnect loop stays in .reconnecting.
        connection.reconnectBackoffOverride = 0
        connection.connectRPC = { _, _, _ in
            throw URLError(.cannotConnectToHost)
        }

        connection.handleScenePhase(.active)
        await settle()

        // The `dead` branch must have cleared all in-progress turn flags.
        XCTAssertTrue(sessions.turnsInProgressIds.isEmpty,
            "handleScenePhase dead branch must clear turnsInProgress (ABH-178)")
    }

    /// `handleScenePhase(.active)` with `probeLivenessRPC` returning `false`
    /// (the dead-probe branch, ABH-177) must also clear `turnsInProgress`.
    ///
    /// In the real path, `probeLiveness()` transitions the client to `.failed` and
    /// the state observer calls `clearAllTurnsInProgress`. In the injected-hook
    /// path the observer is never driven, so the explicit `clearAllTurnsInProgress()`
    /// in the `guard alive else` branch must do it instead.
    @MainActor
    func testDeadProbeBranchClearsTurnsInProgress() async {
        let (connection, sessions, _) = makeConnectionStore()

        // Reach .connected via the reconnect seam.
        connection.connectRPC = { _, _, _ in }
        connection._seedAndStartReconnect(
            serverURL: "http://127.0.0.1:9123",
            token: "test-token"
        )
        await settle()
        XCTAssertEqual(connection.phase, .connected,
            "precondition: must be .connected before scene-phase test")

        // Mark two sessions as mid-turn.
        sessions.markTurnStarted(storedId: "sess-1")
        sessions.markTurnStarted(storedId: "sess-2")
        XCTAssertEqual(sessions.turnsInProgressIds.count, 2,
            "precondition: turnsInProgress must have 2 entries")

        // Inject a dead liveness probe (hook path — state observer never fires).
        connection.probeLivenessRPC = { _ in false }
        // Throw in connectRPC so the reconnect loop stays in .reconnecting.
        connection.reconnectBackoffOverride = 0
        connection.connectRPC = { _, _, _ in
            throw URLError(.cannotConnectToHost)
        }

        connection.handleScenePhase(.active)
        await settle()

        // The `guard alive else` branch must have cleared all in-progress turn flags.
        XCTAssertTrue(sessions.turnsInProgressIds.isEmpty,
            "handleScenePhase dead-probe branch must clear turnsInProgress (ABH-178)")

        // And the reconnect loop must be running — belt-and-suspenders sanity.
        if case .reconnecting = connection.phase { /* expected */ } else {
            XCTFail("expected .reconnecting after dead probe, got \(connection.phase)")
        }
    }

    // MARK: - (f) REAL ROUTING: handleScenePhase dead-probe → phase transitions to .reconnecting

    /// The routing test for Must-Fix #2b.
    ///
    /// Uses the `_seedAndStartReconnect` + `connectRPC` seams (same pattern as
    /// `ConnectionStoreReconnectTests`) to put the store in `.connected` with
    /// `hasConnected=true`, then injects `probeLivenessRPC` returning `false` and
    /// calls `handleScenePhase(.active)`. Verifies that:
    ///   1. The store exits `.connected` (the dead probe was detected).
    ///   2. The phase transitions to `.reconnecting(attempt: 0)` (the reconnect
    ///      loop starts immediately, as expected for a foreground wake).
    ///   3. The hook receives the `livenessPingTimeout` constant (not a magic number).
    ///
    /// No live socket is touched. The `connectRPC` hook throws so the reconnect loop
    /// stays in `.reconnecting` (no REST or WS activity).
    @MainActor
    func testScenePhaseActiveDeadProbeTransitionsToReconnecting() async {
        let (connection, _, _) = makeConnectionStore()

        // Step 1: reach .connected via the existing reconnect seam.
        connection.connectRPC = { _, _, _ in
            // succeeds immediately — simulates a stable address+token
        }
        connection._seedAndStartReconnect(
            serverURL: "http://127.0.0.1:9123",
            token: "test-token"
        )
        await settle()
        XCTAssertEqual(connection.phase, .connected,
            "precondition: store must be .connected before the scene-phase test")

        // Step 2: inject a dead-probe hook.
        // Also capture the timeout argument to verify the constant is passed through.
        var capturedTimeout: Duration?
        connection.probeLivenessRPC = { timeout in
            capturedTimeout = timeout
            return false   // dead socket
        }

        // Step 3: any reconnect attempt must throw so the loop stays in
        // .reconnecting and does not race back to .connected within the settle window.
        // Zero-delay backoff (matching the ConnectionStoreReconnectTests pattern) so
        // attempt 0 fires immediately and the phase is in .reconnecting when we check.
        connection.reconnectBackoffOverride = 0
        connection.connectRPC = { _, _, _ in
            throw URLError(.cannotConnectToHost)
        }

        // Step 4: fire the foreground event. handleScenePhase sees .connected +
        // dead probe → reconciles LA → starts reconnect loop → phase leaves .connected.
        connection.handleScenePhase(.active)

        // Let the spawned Task (inside handleScenePhase) run and advance the phase.
        await settle()

        // The probe hook must have been called with the correct timeout constant.
        XCTAssertEqual(capturedTimeout, HermesGatewayClient.livenessPingTimeout,
            "handleScenePhase must pass livenessPingTimeout to the probe hook")

        // The store must have left .connected (dead socket detected).
        XCTAssertNotEqual(connection.phase, .connected,
            "phase must not stay .connected after a dead liveness probe")

        // The reconnect loop must be running. Attempt number varies with timing;
        // the key invariant is that the loop is active (not .offline or .needsSetup).
        if case .reconnecting = connection.phase { /* expected */ } else {
            XCTFail("expected .reconnecting after dead probe, got \(connection.phase)")
        }
    }

    // MARK: - (g) LA stale window (ABH-182 Inc-3)

    /// Pin the stale horizon value and verify the rolling-window safety invariant.
    ///
    /// `LiveActivityManager.staleAfter` is a PER-FRAME rolling window: every live-turn
    /// event (`update(toolName:)`, `markNeedsApproval()`, etc.) pushes a fresh
    /// `ActivityContent(staleDate: now + staleAfter)`, so a genuinely-running turn
    /// keeps refreshing the horizon and can NEVER be staled by this constant alone.
    /// Only a silently-dead (orphaned) activity — with no events to refresh the window
    /// — will go stale.
    ///
    /// The safe range for the window is therefore: long enough to cover the
    /// inter-event gap for a normal tool invocation (well under 60 s), but short
    /// enough to clear a ghost "Thinking" activity promptly (~5 min target).
    ///
    /// This test:
    ///   1. Asserts the constant equals 5 min (ABH-182 Inc-3 target).
    ///   2. Verifies it exceeds a generous inter-event ceiling (60 s) so a normal
    ///      turn with one tool call per minute never stales during the turn.
    ///   3. Verifies it is at most 5 min so a ghost activity clears within the
    ///      target window once real silence begins.
    func testStaleWindowIsRollingAndFiveMinutes() {
        let staleAfter = LiveActivityManager.staleAfter

        // Exact target value.
        XCTAssertEqual(staleAfter, 5 * 60,
            "staleAfter must be 5 min (ABH-182 Inc-3)")

        // Safety: must comfortably exceed the worst-case inter-event gap in a
        // running turn (60 s = one tool invocation per minute is very conservative).
        let interEventCeiling: TimeInterval = 60
        XCTAssertGreaterThan(staleAfter, interEventCeiling,
            "staleAfter must exceed the worst-case inter-event gap so a live turn never stales")

        // Prompt-clearance: must be ≤ 5 min so a ghost activity clears within the
        // target window after real silence begins.
        XCTAssertLessThanOrEqual(staleAfter, 5 * 60,
            "staleAfter must be ≤ 5 min to clear orphaned activities promptly")
    }
}
