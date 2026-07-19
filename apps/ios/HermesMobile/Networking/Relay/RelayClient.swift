import Foundation

// Wave-2 relay client — the transport + reliability orchestrator
// (docs/RELAY-PHONE-PROTOCOL.md §1/§4/§5). ADDITIVE and parallel to
// `HermesGatewayClient`: it speaks the NEW relay item stream (RelayFrame
// downstream envelope + JSON-RPC upstream), owns the item store, drives
// seq/ack/resync, and is wired to a MOCK today. The app is NOT rewired to it —
// a later convergence wave flips the live transport onto this path.

/// Errors surfaced to callers of the relay client's upstream RPCs.
enum RelayError: Error, LocalizedError, Sendable {
    /// The socket is not connected (or dropped before the response arrived).
    case notConnected
    /// No response within the per-call timeout.
    case timeout(method: String)
    /// The relay answered with a JSON-RPC error frame.
    case rpc(code: Int, message: String)
    /// Transport-level failure (URLSession error / send failure).
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to the relay"
        case .timeout(let method): return "Relay request timed out: \(method)"
        case .rpc(let code, let message): return "Relay error \(code): \(message)"
        case .transport(let message): return "Relay connection error: \(message)"
        }
    }
}

/// Relay connection lifecycle. Mirrors the gateway's state model so an external
/// reconnect driver can observe transitions identically.
enum RelayConnectionState: Sendable, Equatable {
    case idle
    case connecting
    case open
    case closed(reason: String?)
    case failed(String)
}

/// Actor-isolated relay↔phone client (RELAY-PHONE-PROTOCOL §1/§4/§5).
///
/// Responsibilities:
/// - connect to a relay WS and pump decoded downstream `RelayFrame`s (§1/§3);
/// - own the `RelayItemStore`, folding `started/delta/completed` by `item_id`
///   (`completed` authoritative, §2/§4);
/// - stamp the ack watermark and send `ack{through:seq}` periodically (§4);
/// - on reconnect send `resync{last_seq}` and reconcile the returned replay /
///   `snapshot` by `item_id` — idempotent + gap-free (§4);
/// - expose the upstream session ops (submit/resume/open/list/history/approve/
///   clarify/interrupt) as async methods that map to relay RPCs (§5).
///
/// Reconnect *policy* is intentionally external (as with `HermesGatewayClient`):
/// the session fails fast and a driver calls `reconnect` again with backoff.
actor RelayClient {
    /// Single-consumer stream of decoded downstream frames, in receive order.
    /// Survives reconnects (never finished while the client is alive).
    nonisolated let frames: AsyncStream<RelayFrame>
    /// Single-consumer stream of connection-state transitions. Survives reconnects.
    nonisolated let stateChanges: AsyncStream<RelayConnectionState>

    private nonisolated let framesContinuation: AsyncStream<RelayFrame>.Continuation
    private nonisolated let stateContinuation: AsyncStream<RelayConnectionState>.Continuation

    private(set) var state: RelayConnectionState = .idle {
        didSet { stateContinuation.yield(state) }
    }

    private let session: URLSession
    private let transportFactory: RelayTransportFactory
    // Plain coders: the relay envelope + item model use EXPLICIT snake_case
    // CodingKeys (item_id, last_seq), so `.convertFromSnakeCase` must NOT be set
    // — it would rewrite the key and break the explicit mapping.
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var task: RelayTransport?
    /// Identifies the active receive loop so a stale loop from a prior connection
    /// cannot mutate state after a reconnect.
    private var generation: UInt64 = 0
    private var requestCounter: UInt64 = 0
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]

    /// The reconciled item store. Retained across reconnect so `resync` anchors on
    /// the real watermark and the replay reconciles gap-free.
    private(set) var store = RelayItemStore()
    private var lastAckedSeq = 0
    /// The dense watermark a live-gap `resync` was last fired from. A gap leaves
    /// `store.lastSeq` pinned at the last in-order seq, so every subsequent live
    /// frame classifies as a gap too; this guard fires ONE `resync` per hole
    /// instead of one per frame, avoiding a resync storm while the backfill lands.
    private var lastGapResyncSeq = -1
    /// Coalescing threshold: ack once the watermark has advanced this many frames
    /// past the last ack (§4 "periodically" — count-based so tests are deterministic).
    let ackEvery: Int
    /// Optional wall-clock ack cadence. `nil` disables the timer (tests drive ack
    /// via the threshold or `flushAck()` for determinism).
    private let ackInterval: Duration?
    private var ackTimerTask: Task<Void, Never>?

    /// - Parameters:
    ///   - ackEvery: frames-advanced threshold that triggers an ack (default 8).
    ///   - ackInterval: optional periodic ack cadence; `nil` disables the timer.
    ///   - transportFactory: builds the WS transport; tests inject a mock relay.
    init(
        ackEvery: Int = 8,
        ackInterval: Duration? = nil,
        transportFactory: RelayTransportFactory? = nil
    ) {
        (frames, framesContinuation) = AsyncStream<RelayFrame>.makeStream()
        (stateChanges, stateContinuation) = AsyncStream<RelayConnectionState>.makeStream()
        self.ackEvery = max(1, ackEvery)
        self.ackInterval = ackInterval

        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config)
        self.session = session
        self.transportFactory = transportFactory ?? { request in
            session.webSocketTask(with: request)
        }
    }

    // MARK: - Reconciled state (read)

    /// The current reconciled items in render order.
    var items: [ChatItem] { store.items }
    /// The current ack / replay watermark.
    var lastSeq: Int { store.lastSeq }

    // MARK: - Connection lifecycle

    /// Open the relay socket and start pumping frames. Unlike the gateway there is
    /// no `ready` handshake in the ratified contract (§1–§4), so the connection is
    /// `open` as soon as the socket is resumed. Any prior connection is torn down
    /// first; the item store is preserved so a following `resync` reconciles.
    func connect(url: URL, token: String? = nil) {
        teardown(state: .connecting)
        store.beginConnectionEpoch()
        lastAckedSeq = 0
        lastGapResyncSeq = -1

        generation &+= 1
        let myGeneration = generation

        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let task = transportFactory(request)
        self.task = task
        task.resume()
        state = .open

        Task { await self.receiveLoop(task: task, generation: myGeneration) }
        startAckTimer()
    }

    /// Reconnect after a drop, then `resync` from the retained watermark (§4). The
    /// relay replays `last_seq+1..head` (gap-free) or, if the gap exceeds the ring,
    /// sends a fresh `snapshot`; either arrives as downstream frames the receive
    /// loop reconciles by `item_id`.
    func reconnect(url: URL, token: String? = nil) async {
        let previousSeq = store.lastSeq
        connect(url: url, token: token)
        await resync(from: previousSeq)
    }

    /// Send `resync{last_seq}` (§4). Fire-and-forget: the replay / snapshot returns
    /// as downstream frames, not as an RPC result.
    func resync() async {
        await resync(from: store.lastSeq)
    }

    private func resync(from lastSeq: Int) async {
        await notify(.resync, params: .object(["last_seq": .number(Double(lastSeq))]))
    }

    /// Close the socket, fail in-flight requests, move to `.closed`. Streams and
    /// the item store are preserved for the next `connect`/`reconnect`.
    func disconnect() {
        teardown(state: .closed(reason: nil))
    }

    // MARK: - Upstream session ops (§5)

    /// Start a NEW chat, or send into an existing session when `sessionID` is set.
    /// `clientMessageID` (the durable outbox row's stable id) is forwarded so the
    /// relay SUBMIT handler can dedupe an ambiguous-flap retry into a single turn.
    @discardableResult
    func submit(
        sessionID: String? = nil,
        prompt: String,
        clientMessageID: String? = nil
    ) async throws -> JSONValue {
        var params: [String: JSONValue] = ["prompt": .string(prompt)]
        if let sessionID { params["session_id"] = .string(sessionID) }
        if let clientMessageID { params["client_message_id"] = .string(clientMessageID) }
        return try await request(.submit, params: .object(params))
    }

    /// Resume + own an idle (possibly terminal) session before driving it (§5).
    @discardableResult
    func resumeSession(_ sessionID: String) async throws -> JSONValue {
        try await request(.resume, params: .object(["session_id": .string(sessionID)]))
    }

    /// Open/read a session (incl. foreign). The relay answers the RPC and emits a
    /// `snapshot` frame the receive loop reconciles into the store (§3/§5).
    @discardableResult
    func open(_ sessionID: String) async throws -> JSONValue {
        try await request(.open, params: .object(["session_id": .string(sessionID)]))
    }

    /// List all sessions (read; no ownership effect).
    func list() async throws -> JSONValue {
        try await request(.list)
    }

    /// Store-read a session's history (incl. foreign/idle) (§5).
    func history(sessionID: String, limit: Int? = nil) async throws -> JSONValue {
        var params: [String: JSONValue] = ["session_id": .string(sessionID)]
        if let limit { params["limit"] = .number(Double(limit)) }
        return try await request(.history, params: .object(params))
    }

    /// Answer an `approval.request` gate (§5).
    @discardableResult
    func approve(sessionID: String, requestID: String, approved: Bool) async throws -> JSONValue {
        try await request(.approve, params: .object([
            "session_id": .string(sessionID),
            "request_id": .string(requestID),
            "decision": .string(approved ? "approve" : "deny"),
        ]))
    }

    /// Answer a `clarify.request` gate (§5).
    @discardableResult
    func clarify(sessionID: String, requestID: String, response: String) async throws -> JSONValue {
        try await request(.clarify, params: .object([
            "session_id": .string(sessionID),
            "request_id": .string(requestID),
            "text": .string(response),
        ]))
    }

    /// Stop the active turn (§5).
    @discardableResult
    func interrupt(_ sessionID: String) async throws -> JSONValue {
        try await request(.interrupt, params: .object(["session_id": .string(sessionID)]))
    }

    // MARK: - Ack (§4)

    /// Force-send an `ack{through:lastSeq}` if the watermark has advanced since the
    /// last ack. Called by the periodic timer and available to callers directly.
    func flushAck() async {
        guard state == .open, store.lastSeq > lastAckedSeq else { return }
        let through = store.lastSeq
        await notify(.ack, params: .object(["through": .number(Double(through))]))
        lastAckedSeq = through
    }

    /// Coalescing ack: fire once the watermark is `ackEvery` frames past the last ack.
    private func maybeAck() async {
        if store.lastSeq - lastAckedSeq >= ackEvery { await flushAck() }
    }

    private func startAckTimer() {
        ackTimerTask?.cancel()
        ackTimerTask = nil
        guard let interval = ackInterval else { return }
        ackTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                await self?.flushAck()
            }
        }
    }

    // MARK: - Requests (RPC, store-before-send)

    /// JSON-RPC call returning the untyped `result`. Throws `RelayError`.
    ///
    /// CRITICAL ORDERING (mirrors `HermesGatewayClient`): the receive loop runs on
    /// THIS actor, so a fast relay can deliver the response while `send` is
    /// suspended. The pending continuation is therefore registered BEFORE the send
    /// (`storePending`), guaranteeing `resolveResponse` always finds it.
    func request(
        _ method: RelayUpstreamMethod,
        params: JSONValue = .object([:]),
        timeout: Duration = .seconds(30)
    ) async throws -> JSONValue {
        guard state == .open, let task else { throw RelayError.notConnected }

        requestCounter &+= 1
        let id = "q\(requestCounter)"
        let rpc = JSONRPCRequest(id: id, method: method.rawValue, params: params)

        let data: Data
        do {
            data = try encoder.encode(rpc)
        } catch {
            throw RelayError.transport("Failed to encode request: \(error.localizedDescription)")
        }
        let text = String(decoding: data, as: UTF8.self)

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.failPending(id: id, with: RelayError.timeout(method: method.rawValue))
        }
        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.storePending(id: id, continuation: continuation)
                self.sendOrFailPending(id: id, text: text, task: task)
            }
        } onCancel: {
            Task { await self.failPending(id: id, with: CancellationError()) }
        }
    }

    /// Fire-and-forget JSON-RPC NOTIFICATION (no `id`) — `ack` / `resync` (§4).
    /// Any relay reply arrives as downstream frames, never as a matched response.
    private func notify(_ method: RelayUpstreamMethod, params: JSONValue) async {
        guard state == .open, let task else { return }
        let payload: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "method": .string(method.rawValue),
            "params": params,
        ])
        guard let data = try? encoder.encode(payload) else { return }
        try? await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func sendOrFailPending(id: String, text: String, task: RelayTransport) {
        Task { [weak self] in
            do {
                try await task.send(.string(text))
            } catch {
                await self?.failPending(id: id, with: RelayError.transport(error.localizedDescription))
            }
        }
    }

    // MARK: - Receive loop

    private func receiveLoop(task: RelayTransport, generation: UInt64) async {
        while generation == self.generation {
            do {
                let message = try await task.receive()
                guard generation == self.generation else { return }
                handle(message: message)
            } catch {
                guard generation == self.generation else { return }
                handleSocketFailure(error)
                return
            }
        }
    }

    /// Demux one inbound message. Downstream relay frames carry `seq`+`kind` and
    /// decode as `RelayFrame`; JSON-RPC responses carry `id`+`result|error`. A
    /// relay frame is tried first — a response lacks the non-optional `seq`/`kind`
    /// and so cleanly falls through to the response branch.
    private func handle(message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let string): data = Data(string.utf8)
        case .data(let bytes): data = bytes
        @unknown default: return
        }

        if let frame = try? decoder.decode(RelayFrame.self, from: data) {
            let admission = store.apply(frame)
            framesContinuation.yield(frame)
            // Reliability spine (§4): a live gap means frames were missed. The
            // store left `lastSeq` pinned at the last dense seq (it does not
            // advance past an unfilled gap), so a `resync{last_seq}` now replays
            // from the hole and backfills the skipped middle — including a
            // possibly-dropped `item.completed` that would otherwise strand its
            // item `.inProgress`. A `snapshot` arriving as a gap is itself the
            // authoritative backfill, so it needs no resync. The per-hole guard
            // fires exactly one resync until the watermark advances again.
            if admission.isGap, frame.kind != .snapshot, store.lastSeq > lastGapResyncSeq {
                lastGapResyncSeq = store.lastSeq
                Task { await self.resync() }
            } else {
                Task { await self.maybeAck() }
            }
            return
        }

        if let response = try? decoder.decode(JSONRPCInboundFrame.self, from: data),
           response.isResponse {
            resolveResponse(response)
        }
        // Anything else (an upstream echo, unknown shape) is ignored per contract.
    }

    private func resolveResponse(_ frame: JSONRPCInboundFrame) {
        guard let id = frame.id?.stringValue,
              let continuation = pending.removeValue(forKey: id) else { return }
        if let error = frame.error {
            continuation.resume(throwing: RelayError.rpc(code: error.code, message: error.message))
        } else {
            continuation.resume(returning: frame.result ?? .null)
        }
    }

    private func handleSocketFailure(_ error: Error) {
        let message = error.localizedDescription
        failAllPending(with: RelayError.notConnected)
        task = nil
        if (error as NSError).code == NSURLErrorCancelled {
            state = .closed(reason: nil)
        } else {
            state = .failed(message)
        }
    }

    // MARK: - Pending bookkeeping

    private func storePending(id: String, continuation: CheckedContinuation<JSONValue, Error>) {
        guard state == .open, task != nil else {
            continuation.resume(throwing: RelayError.notConnected)
            return
        }
        pending[id] = continuation
    }

    @discardableResult
    private func failPending(id: String, with error: Error) -> Bool {
        if let continuation = pending.removeValue(forKey: id) {
            continuation.resume(throwing: error)
            return true
        }
        return false
    }

    private func failAllPending(with error: Error) {
        let continuations = pending
        pending.removeAll()
        for continuation in continuations.values {
            continuation.resume(throwing: error)
        }
    }

    /// Cancel the current task, fail in-flight work, set a new state. Bumping
    /// `generation` orphans the running receive loop. The item store + ack
    /// watermark are preserved for reconnect; `lastAckedSeq` is retained so a
    /// reconnect does not re-ack already-acked frames.
    private func teardown(state newState: RelayConnectionState) {
        generation &+= 1
        ackTimerTask?.cancel()
        ackTimerTask = nil
        failAllPending(with: RelayError.notConnected)
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        state = newState
    }
}

// MARK: - Render-lane seam (§7)

extension RelayClient: RelayItemSource {
    /// Stream decoded frames to `onFrame` (on the main actor) as they arrive,
    /// until the surrounding task is cancelled. Lets the render lane consume the
    /// live client through the exact seam the mock harness implements (§7).
    func run(onFrame: @escaping RelayFrameHandler) async {
        for await frame in frames {
            if Task.isCancelled { return }
            await MainActor.run { onFrame(frame) }
        }
    }
}
