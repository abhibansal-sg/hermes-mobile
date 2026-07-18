import SwiftUI

// Wave-2 convergence wiring (docs/RELAY-PHONE-PROTOCOL.md §2/§4/§5/§7). This is
// the seam that makes the app actually TALK to the relay, BEHIND A FLAG. It owns
// a live `RelayClient`, pumps its decoded item frames into a render-lane
// `RelayItemStore`, and projects the reconciled items into `ChatStore` so the
// item layer (`MessageBubble` item dispatch + `Views/Chat/Items/*`) draws them.
// Upstream session ops (submit/resume/open/list/history/approve/clarify/
// interrupt) route through the relay client. ADDITIVE + reversible: nothing here
// runs unless the transport flag is `.relay` (default OFF = gateway-direct).

// MARK: - Transport flag (default OFF)

/// The transport the app uses to reach the agent.
///
/// `.gatewayDirect` (default) is today's behaviour — the legacy gateway blob
/// stream (`HermesGatewayClient`), byte-identical to every existing install.
/// `.relay` routes through the Wave-2 `RelayClient` item stream. An absent or
/// unrecognised persisted value decodes to `.gatewayDirect`, so the flag is
/// **OFF by default** and flipping it is fully reversible.
enum TransportPath: String, Sendable, CaseIterable {
    case gatewayDirect
    case relay

    /// Human-readable label for a Settings picker/row.
    var label: String {
        switch self {
        case .gatewayDirect: return "Gateway (direct)"
        case .relay:         return "Relay (Wave 2)"
        }
    }
}

extension DefaultsKeys {
    // MARK: Transport path (Wave-2 convergence)

    /// `String` (raw value of ``TransportPath``) — the selected transport.
    /// Absent/unrecognised ⇒ `.gatewayDirect` (the legacy default: every
    /// existing install stays byte-identical). Owned by ``ConnectionStore``.
    static let transportPath = "hermes.transportPath"

    /// Read + decode the persisted ``TransportPath``. Returns `.gatewayDirect`
    /// when unset (default OFF — existing behaviour unchanged).
    static func transportPathValue(_ defaults: UserDefaults = .standard) -> TransportPath {
        let raw = defaults.string(forKey: transportPath) ?? ""
        return TransportPath(rawValue: raw) ?? .gatewayDirect
    }

    /// `String` — an explicit relay WS URL the user enters in Settings. On a
    /// physical device the simulator's `HERMES_RELAY_URL` launch env var is
    /// unavailable, so the device reads THIS UserDefaults value instead (the env
    /// var stays a DEBUG-only override that still wins for the simulator E2E).
    /// When non-empty it overrides the gateway-derived `/relay` URL, letting the
    /// phone dial a relay that is NOT co-located with the gateway (e.g. a Mac on
    /// the tailnet). Empty/absent ⇒ derive from the gateway base URL. Owned by
    /// ``ConnectionStore`` (reader) + ``SettingsView`` (writer).
    static let relayURLOverride = "hermes.relayURLOverride"

    /// The trimmed relay-URL override, or `nil` when unset/blank (derive from the
    /// gateway instead).
    static func relayURLOverrideValue(_ defaults: UserDefaults = .standard) -> String? {
        let raw = defaults.string(forKey: relayURLOverride)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }
}

// MARK: - Coordinator

/// Bridges a live ``RelayClient`` to ``ChatStore`` for the active relay session.
///
/// The client owns the reliability spine (seq/ack/resync) and its own reconciled
/// store; this coordinator keeps a PARALLEL render-lane ``RelayItemStore`` fed by
/// the same `seq`-ordered frame stream (idempotent + deterministic, so the two
/// stores converge identically — §4/§7) and projects it into the transcript on
/// every frame. Reconnect policy stays external, exactly as with the gateway.
@MainActor
@Observable
final class RelaySessionCoordinator {
    /// Coordinator lifecycle, mirrored from the client's connection state so the
    /// app can observe relay health the same way it observes the gateway.
    enum Phase: Sendable, Equatable {
        case idle
        case connecting
        case open
        case closed(reason: String?)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Fired each time the relay connection crosses INTO `.open` — the initial
    /// connect and every reconnect after a drop/flap. This is the relay analogue
    /// of the gateway's `gateway.ready`: ``ConnectionStore`` wires it to
    /// `queueStore.wake()` so a prompt the user queued while the relay was
    /// mid-connect drains the moment the socket is live again, over the relay,
    /// mirroring the gateway-direct reconnect drain. `nil` in unit tests that do
    /// not exercise the outbox. Reconnect POLICY stays external (§4) — this hook
    /// only reacts to a connection that has already come up.
    var onReady: (() -> Void)?

    /// The session whose item stream is currently projected into ``ChatStore``.
    private(set) var activeSessionID: String?
    /// The render-lane reconciled item set (mirrors the client store; the source
    /// of truth the transcript is projected from).
    private(set) var store = RelayItemStore()

    private let chatStore: ChatStore
    private let clientFactory: @Sendable () -> RelayClient

    private var client: RelayClient?
    private var pumpTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?

    /// - Parameters:
    ///   - chatStore: the transcript owner the reconciled items are projected into.
    ///   - clientFactory: builds the relay client; tests inject one wired to a
    ///     mock relay transport. Production builds a real WS client with a modest
    ///     periodic ack cadence (§4).
    init(
        chatStore: ChatStore,
        clientFactory: @escaping @Sendable () -> RelayClient = { RelayClient(ackInterval: .seconds(2)) }
    ) {
        self.chatStore = chatStore
        self.clientFactory = clientFactory
    }

    var isOpen: Bool { phase == .open }

    // MARK: Lifecycle

    /// Connect to the relay, start the frame pump, and (optionally) open a session
    /// so its snapshot streams in. Any prior connection is stopped first. Throws a
    /// `RelayError` only if the optional `open` RPC fails; the socket itself opens
    /// eagerly (the ratified contract has no `ready` handshake — §1).
    func start(url: URL, token: String? = nil, sessionID: String? = nil) async throws {
        await stop()

        let client = clientFactory()
        self.client = client
        store = RelayItemStore()
        phase = .connecting

        await client.connect(url: url, token: token)
        phase = .open

        // Observe connection-state transitions so a drop/failure surfaces.
        stateTask = Task { [weak self] in
            for await state in client.stateChanges {
                await self?.applyState(state)
            }
        }

        // Pump decoded frames (delivered on the main actor) into the render store
        // and re-project the transcript. The client drives its own ack/resync off
        // the same stream, so this lane is pure rendering.
        pumpTask = Task { [weak self] in
            await client.run { [weak self] frame in
                self?.ingest(frame)
            }
        }

        if let sessionID {
            activeSessionID = sessionID
            _ = try await client.open(sessionID)
        }
    }

    /// Reconnect after a drop and `resync` from the retained watermark (§4). The
    /// replay/snapshot arrives as frames the pump reconciles.
    func reconnect(url: URL, token: String? = nil) async {
        guard let client else { return }
        phase = .connecting
        await client.reconnect(url: url, token: token)
        phase = .open
    }

    /// Tear down the socket, cancel the pump/state observers, and clear the
    /// render store. Idempotent.
    func stop() async {
        pumpTask?.cancel(); pumpTask = nil
        stateTask?.cancel(); stateTask = nil
        if let client { await client.disconnect() }
        client = nil
        store = RelayItemStore()
        activeSessionID = nil
        phase = .idle
    }

    // MARK: Frame ingestion → transcript projection

    private func ingest(_ frame: RelayFrame) {
        store.apply(frame)
        chatStore.applyRelayItems(store.items)
    }

    private func applyState(_ state: RelayConnectionState) {
        let wasOpen = (phase == .open)
        switch state {
        case .idle:          phase = .idle
        case .connecting:    phase = .connecting
        case .open:          phase = .open
        case .closed(let r): phase = .closed(reason: r)
        case .failed(let m): phase = .failed(m)
        }
        // Crossing INTO `.open` is the relay's readiness edge — kick the outbox so
        // a prompt queued while disconnected drains now, over the relay. Both the
        // initial connect and a reconnect surface here as a buffered
        // `.connecting` → `.open` pair (the socket yields both; `start`/`reconnect`
        // set `phase` before this observer drains them), so this fires exactly once
        // per connect. Edge-triggered — a redundant same-state yield does not
        // re-fire, and `wake()` coalesces regardless.
        if phase == .open, !wasOpen { onReady?() }
    }

    // MARK: Upstream session ops (§5)

    private func requireClient() throws -> RelayClient {
        guard let client, phase == .open else { throw RelayError.notConnected }
        return client
    }

    /// Start a new turn (or send into `activeSessionID`) and, on success, adopt
    /// the returned session id so subsequent ops target it.
    @discardableResult
    func submit(prompt: String, sessionID: String? = nil) async throws -> JSONValue {
        let target = sessionID ?? activeSessionID
        let result = try await requireClient().submit(sessionID: target, prompt: prompt)
        if let sid = result["session_id"]?.stringValue { activeSessionID = sid }
        else if activeSessionID == nil, let target { activeSessionID = target }
        return result
    }

    /// Resume + own an idle/terminal session, then adopt it as active.
    @discardableResult
    func resume(_ sessionID: String) async throws -> JSONValue {
        let client = try requireClient()
        resetItemStoreForSessionSwitch(to: sessionID)
        let result = try await client.resumeSession(sessionID)
        activeSessionID = sessionID
        return result
    }

    /// Open/read a session; its `snapshot` streams into the transcript.
    @discardableResult
    func open(_ sessionID: String) async throws -> JSONValue {
        let client = try requireClient()
        resetItemStoreForSessionSwitch(to: sessionID)
        let result = try await client.open(sessionID)
        activeSessionID = sessionID
        return result
    }

    /// Clear the render-lane item store when the projected session is about to
    /// CHANGE, so the incoming session's `snapshot` reconciles onto a clean
    /// baseline instead of folding on top of the previous session's items.
    ///
    /// `RelayItemStore.reconcile(snapshot:)` is deliberately additive — items
    /// absent from a snapshot are RETAINED (the snapshot is a resumed baseline,
    /// not a delete list). That is correct for a `resync` of the SAME session,
    /// but on a session SWITCH it would leak session A's transcript under
    /// session B's snapshot, so `applyRelayItems` would render both. Resetting
    /// here (and immediately re-projecting the emptied set) makes the switch
    /// clean and is a no-op re-open/re-resume of the already-active session,
    /// whose live items must survive a `resync`. Called BEFORE the open/resume
    /// RPC awaits so any snapshot frames the pump delivers during the await land
    /// on the fresh store.
    private func resetItemStoreForSessionSwitch(to sessionID: String) {
        guard sessionID != activeSessionID else { return }
        store = RelayItemStore()
        chatStore.applyRelayItems(store.items)
    }

    func list() async throws -> JSONValue { try await requireClient().list() }

    func history(sessionID: String, limit: Int? = nil) async throws -> JSONValue {
        try await requireClient().history(sessionID: sessionID, limit: limit)
    }

    @discardableResult
    func approve(requestID: String, approved: Bool) async throws -> JSONValue {
        try await requireClient().approve(requestID: requestID, approved: approved)
    }

    @discardableResult
    func clarify(requestID: String, response: String) async throws -> JSONValue {
        try await requireClient().clarify(requestID: requestID, response: response)
    }

    @discardableResult
    func interrupt(_ sessionID: String? = nil) async throws -> JSONValue {
        guard let sid = sessionID ?? activeSessionID else { throw RelayError.notConnected }
        return try await requireClient().interrupt(sid)
    }
}
