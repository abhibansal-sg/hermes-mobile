import Foundation

/// The subset of `URLSessionWebSocketTask` the gateway client drives. Abstracted
/// to a protocol so a test can inject a transport that delivers a response
/// *during* `send` (proving the store-before-send ordering closes the RPC race).
/// `URLSessionWebSocketTask` conforms to this with zero behavioural change.
protocol GatewayWebSocketTask: AnyObject, Sendable {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    /// The server's close code/reason once the socket has closed. Used to
    /// surface ACTIONABLE application closes (the gateway's accepted-then-
    /// closed 4403 "chat disabled: start dashboard with --tui …", R1 #19)
    /// instead of a generic transport error. `URLSessionWebSocketTask`
    /// satisfies both natively; mocks fall back to the inert defaults.
    var closeCode: URLSessionWebSocketTask.CloseCode { get }
    var closeReason: Data? { get }
    /// Send a WebSocket ping. Used by `HermesGatewayClient.probeLiveness` to
    /// check whether the socket is still alive without sending application data.
    /// `URLSessionWebSocketTask` satisfies this natively; mocks fall back to the
    /// default no-op-success extension below so existing tests compile unchanged.
    func sendPing() async throws
}

extension GatewayWebSocketTask {
    var closeCode: URLSessionWebSocketTask.CloseCode { .invalid }
    var closeReason: Data? { nil }
    /// Default: succeed immediately (no-op). Mocks that do not override this
    /// report a live socket — override in tests that need a failing ping.
    func sendPing() async throws {}
}

extension URLSessionWebSocketTask: GatewayWebSocketTask {
    func sendPing() async throws {
        // MUST use withTaskCancellationHandler: when `probeLiveness` times out
        // and `cancelAll()` fires on the task group, the Swift task is cancelled
        // but the underlying URLSession ping callback would never fire without an
        // explicit cancel — leaving the continuation permanently suspended for up
        // to `timeoutIntervalForRequest` (30 s). Cancelling the task here causes
        // URLSession to call the callback with an error immediately, so the
        // continuation resolves and `probeLiveness` returns within ~livenessPingTimeout.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.sendPing { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            // Abort the underlying URLSession task so the ping callback fires
            // immediately with a cancellation error rather than hanging until the
            // session's own timeout elapses.
            self.cancel(with: .goingAway, reason: nil)
        }
    }
}

/// Builds the WebSocket transport for a given request. The default factory hands
/// back a real `URLSessionWebSocketTask`; tests substitute a mock.
typealias GatewayTransportFactory = @Sendable (URLRequest) -> GatewayWebSocketTask

/// Actor-isolated JSON-RPC-over-WebSocket client for the hermes gateway.
///
/// One client instance lives for the lifetime of the app. It owns a single
/// `URLSessionWebSocketTask` per connection, a monotonic request-id counter,
/// and a table of pending request continuations. Server-push events and
/// connection-state transitions are published on two long-lived `AsyncStream`s
/// that survive disconnect/reconnect cycles — the consumer (`ConnectionStore`)
/// subscribes once and the streams are never finished while the client is alive.
///
/// Reconnection policy is intentionally *not* implemented here: the session is
/// configured to fail fast (no `waitsForConnectivity`) and an external
/// `ReconnectController` drives retry with backoff by calling `connect` again.
actor HermesGatewayClient {
    /// Single-consumer stream of server-push events. Survives reconnects.
    nonisolated let events: AsyncStream<GatewayEvent>
    /// Single-consumer stream of connection-state transitions. Survives reconnects.
    nonisolated let stateChanges: AsyncStream<GatewayConnectionState>

    private nonisolated let eventsContinuation: AsyncStream<GatewayEvent>.Continuation
    private nonisolated let stateContinuation: AsyncStream<GatewayConnectionState>.Continuation

    /// Current connection lifecycle state.
    private(set) var state: GatewayConnectionState = .idle {
        didSet { stateContinuation.yield(state) }
    }

    private let session: URLSession
    private let transportFactory: GatewayTransportFactory
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private var task: GatewayWebSocketTask?
    /// Identifies the active receive loop so a stale loop from a prior
    /// connection cannot mutate state after a reconnect.
    private var generation: UInt64 = 0
    private var requestCounter: UInt64 = 0
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    /// Resolved by the first `gateway.ready` frame to unblock `connect`.
    private var readyContinuation: CheckedContinuation<Void, Error>?

    /// - Parameter transportFactory: builds the WebSocket transport for a
    ///   request. Defaults to a real `URLSessionWebSocketTask`; tests inject a
    ///   mock. When omitted the session is the actor's own ephemeral session.
    init(transportFactory: GatewayTransportFactory? = nil) {
        (events, eventsContinuation) = AsyncStream<GatewayEvent>.makeStream()
        (stateChanges, stateContinuation) = AsyncStream<GatewayConnectionState>.makeStream()

        let config = URLSessionConfiguration.ephemeral
        // Fail fast: the ReconnectController owns retry, not URLSession.
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config)
        self.session = session
        self.transportFactory = transportFactory ?? { request in
            session.webSocketTask(with: request)
        }
    }

    // MARK: - Liveness probe (ABH-177)

    /// How long `probeLiveness` waits for the ping pong before declaring the
    /// socket dead. Kept as a named constant so tests can reason about its value
    /// without depending on a magic number.
    static let livenessPingTimeout: Duration = .seconds(4)

    /// Probe whether the current socket is still alive by sending a WebSocket
    /// ping and waiting for the pong (or a timeout). Read-only: if the ping
    /// succeeds we return `true` and leave the connection untouched; if it
    /// fails or times out we call `handleSocketFailure` so the transport
    /// transitions to `.failed` and the existing state-observer–driven
    /// reconnect loop takes over — reusing the EXISTING drop→reconnect
    /// machinery rather than adding a parallel path.
    ///
    /// Returns `true` when the socket is alive, `false` when it is dead (the
    /// failure has already been fed to `handleSocketFailure` by this point).
    func probeLiveness(timeout: Duration = livenessPingTimeout) async -> Bool {
        guard let task, state == .open else {
            // Not in a connected state — treat as dead so callers skip backfill.
            return false
        }
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await task.sendPing() }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw GatewayError.timeout(method: "ping")
                }
                // First to finish wins; the other is cancelled.
                try await group.next()
                group.cancelAll()
            }
            return true
        } catch {
            // Ping failed (transport error) or timed out: feed the EXISTING
            // failure handler so state → .failed and the state-observer
            // starts the reconnect loop. Do NOT add a second reconnect path.
            handleSocketFailure(error)
            return false
        }
    }

    // MARK: - Connection lifecycle

    /// Open the socket, send the WS upgrade, and wait for the gateway's first
    /// frame (`gateway.ready`). Resolves once the connection is `open`; throws
    /// `GatewayError` on transport failure or if no ready frame arrives within
    /// 15 seconds. Any existing connection is torn down first.
    ///
    /// - Parameter mode: the active connection mode, used to derive the correct
    ///   `Host` header (loopback for Serve/sharedDashboard; real host for a
    ///   non-loopback remoteURL target). Defaults to `.remoteURL` so callers that
    ///   do not supply a mode keep the conservative real-host behaviour.
    func connect(baseURL: URL, token: String, mode: ConnectionMode = .remoteURL) async throws {
        // Drop any prior connection (and its receive loop) cleanly.
        teardown(state: .connecting, failPendingWith: GatewayError.notConnected)

        generation &+= 1
        let myGeneration = generation

        let request = WSURLBuilder.wsRequest(baseURL: baseURL, token: token, mode: mode)
        let task = transportFactory(request)
        self.task = task
        task.resume()

        // Start the receive loop detached from `connect`'s lifetime.
        Task { await self.receiveLoop(task: task, generation: myGeneration) }

        do {
            try await awaitReady(timeout: .seconds(15))
        } catch {
            // Timed out or failed before ready: tear down and surface the error.
            let message = (error as? GatewayError)?.errorDescription ?? error.localizedDescription
            teardown(state: .failed(message), failPendingWith: GatewayError.notConnected)
            throw error
        }
    }

    /// Suspend until the first `gateway.ready` frame resolves `readyContinuation`,
    /// or `timeout` elapses. The continuation is stored synchronously on the
    /// actor (this method is actor-isolated), so storing it and observing a
    /// ready frame can never interleave incorrectly. A detached task arms the
    /// timeout and fails the continuation if it fires first.
    private func awaitReady(timeout: Duration) async throws {
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.failReady(with: GatewayError.timeout(method: "gateway.ready"))
        }
        defer { timeoutTask.cancel() }
        try await withCheckedThrowingContinuation { continuation in
            self.readyContinuation = continuation
        }
    }

    /// Fail the pending ready continuation (used by the connect timeout).
    private func failReady(with error: Error) {
        if let continuation = readyContinuation {
            readyContinuation = nil
            continuation.resume(throwing: error)
        }
    }

    /// Close the socket normally, fail any in-flight requests, and move to
    /// `.closed`. The event/state streams are *not* finished and are reused by
    /// the next `connect`.
    func disconnect() async {
        teardown(state: .closed(reason: nil), failPendingWith: GatewayError.notConnected)
    }

    // MARK: - Requests

    /// JSON-RPC call decoding `result` into `T` via `JSONValue.decoded(as:)`.
    /// Throws `GatewayError.decoding` if the result is present but undecodable.
    func request<T: Decodable & Sendable>(
        _ method: String,
        params: JSONValue = .object([:]),
        timeout: Duration = .seconds(30)
    ) async throws -> T {
        let result = try await requestRaw(method, params: params, timeout: timeout)
        guard let decoded = result.decoded(as: T.self) else {
            throw GatewayError.decoding(
                method: method,
                underlying: "result did not match \(T.self)"
            )
        }
        return decoded
    }

    /// JSON-RPC call returning the untyped `result` JSON value.
    /// Throws `GatewayError.rpc` on an error frame, `.timeout` after `timeout`,
    /// `.notConnected` if the socket drops, `.transport` on send failure.
    func requestRaw(
        _ method: String,
        params: JSONValue = .object([:]),
        timeout: Duration = .seconds(30)
    ) async throws -> JSONValue {
        guard let task else { throw GatewayError.notConnected }

        requestCounter &+= 1
        let id = "r\(requestCounter)"
        let rpc = JSONRPCRequest(id: id, method: method, params: params)

        let data: Data
        do {
            data = try encoder.encode(rpc)
        } catch {
            throw GatewayError.transport("Failed to encode request: \(error.localizedDescription)")
        }
        let text = String(decoding: data, as: UTF8.self)

        // Arm a timeout task that fails the pending request if no response
        // arrives in time; cancellation propagates the same way.
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.failPending(id: id, with: GatewayError.timeout(method: method))
        }
        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // CRITICAL ORDERING (RPC response race): register the pending
                // continuation on the actor BEFORE the socket send. `send` is
                // `await`-suspendable, and the receive loop runs on this SAME
                // actor — so a fast server can deliver the response frame while
                // `send` is suspended. If the continuation were stored after the
                // send (as it was), `resolveResponse` would find no pending entry,
                // drop the frame, and the caller would hang until timeout. Storing
                // first guarantees `resolveResponse` always finds us. The send is
                // then performed in a detached actor-hop task; if it throws, we
                // fail+remove the very entry we just stored.
                self.storePending(id: id, continuation: continuation)
                self.sendOrFailPending(id: id, text: text, task: task)
            }
        } onCancel: {
            Task { await self.failPending(id: id, with: CancellationError()) }
        }
    }

    /// Send the encoded request on the socket, failing the matching pending entry
    /// if the send throws. Runs as an actor-isolated task so it interleaves
    /// correctly with the receive loop: the pending entry is already installed by
    /// `storePending` before this suspends on `send`, so a response that lands
    /// mid-send is resolved against a live continuation rather than dropped.
    private func sendOrFailPending(id: String, text: String, task: GatewayWebSocketTask) {
        Task { [weak self] in
            do {
                try await task.send(.string(text))
            } catch {
                await self?.failPending(
                    id: id,
                    with: GatewayError.transport(error.localizedDescription)
                )
            }
        }
    }

    // MARK: - Receive loop

    /// Pump `URLSessionWebSocketTask.receive()` until it errors. Each delivered
    /// message is one complete JSON frame.
    private func receiveLoop(task: GatewayWebSocketTask, generation: UInt64) async {
        while generation == self.generation {
            do {
                let message = try await task.receive()
                guard generation == self.generation else { return }
                handle(message: message)
            } catch {
                // Ignore errors from a superseded connection.
                guard generation == self.generation else { return }
                handleSocketFailure(error)
                return
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let string): data = Data(string.utf8)
        case .data(let bytes): data = bytes
        @unknown default: return
        }

        guard let frame = try? decoder.decode(JSONRPCInboundFrame.self, from: data) else {
            // Unparseable / unknown frame shape: ignore per contract.
            return
        }

        if frame.isResponse {
            resolveResponse(frame)
        } else if frame.isEvent {
            handleEvent(frame)
        }
    }

    private func resolveResponse(_ frame: JSONRPCInboundFrame) {
        guard let id = frame.id?.stringValue,
              let continuation = pending.removeValue(forKey: id) else { return }
        if let error = frame.error {
            continuation.resume(throwing: GatewayError.rpc(code: error.code, message: error.message))
        } else {
            continuation.resume(returning: frame.result ?? .null)
        }
    }

    private func handleEvent(_ frame: JSONRPCInboundFrame) {
        guard let event = GatewayEvent(
            params: frame.params ?? .null,
            broadcastGap: frame.broadcastGap
        ) else { return }

        // The first `gateway.ready` event marks the connection open and
        // unblocks `connect`.
        if event.type == .gatewayReady, let continuation = readyContinuation {
            readyContinuation = nil
            state = .open
            continuation.resume()
        }
        eventsContinuation.yield(event)
    }

    /// The socket dropped or the receive call errored: fail everything in-flight
    /// and move to a terminal state, but keep the streams alive for reconnect.
    private func handleSocketFailure(_ error: Error) {
        var message = error.localizedDescription
        // A server-side APPLICATION close can carry an actionable reason — the
        // gateway accepts then closes 4403 + "chat disabled: start dashboard
        // with --tui or set HERMES_DASHBOARD_TUI=1" when embedded chat is off
        // (R1 #19). Pre-fix the app surfaced "Request timed out: gateway.ready"
        // for that, a network-sounding dead end. `CloseCode` cannot represent
        // custom 4xxx codes (the enum stops at 1015), so detect via the reason
        // payload, with the code as best-effort corroboration.
        if let task,
           let reasonData = task.closeReason,
           let reason = String(data: reasonData, encoding: .utf8),
           !reason.isEmpty {
            if reason.localizedCaseInsensitiveContains("chat disabled")
                || reason.contains("--tui")
                || reason.contains("HERMES_DASHBOARD_TUI") {
                message = "Live chat is disabled on this server. Start the dashboard "
                    + "with --tui or set HERMES_DASHBOARD_TUI=1, then reconnect."
            } else {
                // Any other application close reason still beats a generic
                // transport error.
                message = reason
            }
        }
        if let ready = readyContinuation {
            readyContinuation = nil
            ready.resume(throwing: GatewayError.transport(message))
        }
        failAllPending(with: GatewayError.notConnected)
        task = nil
        // `cancelled` maps to a graceful close; anything else is a failure.
        if (error as NSError).code == NSURLErrorCancelled {
            state = .closed(reason: nil)
        } else {
            state = .failed(message)
        }
    }

    // MARK: - Pending bookkeeping

    private func storePending(id: String, continuation: CheckedContinuation<JSONValue, Error>) {
        // If the socket already died, fail immediately rather than hang.
        guard task != nil else {
            continuation.resume(throwing: GatewayError.notConnected)
            return
        }
        pending[id] = continuation
    }

    private func failPending(id: String, with error: Error) {
        if let continuation = pending.removeValue(forKey: id) {
            continuation.resume(throwing: error)
        }
    }

    private func failAllPending(with error: Error) {
        let continuations = pending
        pending.removeAll()
        for continuation in continuations.values {
            continuation.resume(throwing: error)
        }
    }

    /// Cancel the current task, fail in-flight work, and set a new state.
    /// Bumping `generation` orphans the running receive loop.
    private func teardown(state newState: GatewayConnectionState, failPendingWith error: Error) {
        generation &+= 1
        if let ready = readyContinuation {
            readyContinuation = nil
            ready.resume(throwing: GatewayError.notConnected)
        }
        failAllPending(with: error)
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        state = newState
    }
}

// MARK: - Nous credits / billing JSON-RPC surface (ABH-237)

/// View-only credits payload from `credits.view`.
///
/// The server owns all money-moving behavior; mobile only renders these display
/// lines and opens `topupURL` in the browser when present.
struct NousCreditsView: Sendable, Equatable {
    let balanceLines: [String]
    let identityLine: String?
    let topupURL: URL?
    let depleted: Bool

    init(json: JSONValue) {
        self.balanceLines = json["balance_lines"]?.arrayValue?.compactMap(\.stringValue) ?? []
        self.identityLine = json["identity_line"]?.stringValue
        if let rawURL = json["topup_url"]?.stringValue, !rawURL.isEmpty {
            self.topupURL = URL(string: rawURL)
        } else {
            self.topupURL = nil
        }
        self.depleted = json["depleted"]?.boolValue ?? false
    }
}

/// Auto-reload status from `billing.state` / `billing.auto_reload`.
struct BillingState: Sendable, Equatable {
    let autoReloadEnabled: Bool
    let billingState: String?

    init(json: JSONValue) {
        self.autoReloadEnabled = json["auto_reload"]?.boolValue
            ?? json["auto_reload_enabled"]?.boolValue
            ?? json["enabled"]?.boolValue
            ?? false
        self.billingState = json["billing_state"]?.stringValue
            ?? json["state"]?.stringValue
    }
}

extension HermesGatewayClient {
    /// `credits.view` → display-only Nous credits snapshot.
    func viewCredits() async throws -> NousCreditsView {
        let result = try await requestRaw("credits.view", timeout: .seconds(30))
        return NousCreditsView(json: result)
    }

    /// `billing.state` → current auto-reload state.
    func billingState() async throws -> BillingState {
        let result = try await requestRaw("billing.state", timeout: .seconds(30))
        return BillingState(json: result)
    }

    /// `billing.auto_reload {enabled}` → updated auto-reload state.
    @discardableResult
    func setBillingAutoReload(_ enabled: Bool) async throws -> BillingState {
        let result = try await requestRaw(
            "billing.auto_reload",
            params: .object(["enabled": .bool(enabled)]),
            timeout: .seconds(30)
        )
        return BillingState(json: result)
    }
}
