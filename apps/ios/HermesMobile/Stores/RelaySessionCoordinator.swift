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
    /// Fired on EVERY relay connection-state transition so ``ConnectionStore``
    /// can mirror it to ``phase`` (the banner + composer read ``phase``, not the
    /// coordinator's internal state). Without this bridge the UI is frozen at
    /// whatever ``phase`` was stamped at startup — the relay can drop and recover
    /// invisibly, leaving the user "not sure if it's connected."
    var onPhaseChange: ((Phase) -> Void)?

    /// The session whose entry currently holds the WRITE-GATE (contract I2):
    /// the ONLY session whose item stream may project into ``ChatStore``.
    /// `nil` while drafting — a draft is the ABSENCE of a session (contract
    /// I6); with no active entry nothing can project, structurally.
    private(set) var activeSessionID: String?
    /// The STORED (durable/origin) id of the session the coordinator is currently
    /// driving — set whenever a session is opened/resumed/started by its stored
    /// id, and (unlike ``activeSessionID``) never remapped to the live id a
    /// `submit` returns. This is the stable identity the durable-outbox drain
    /// resolves to ``activeSessionID``: a queued prompt may drain over the
    /// relay only when its destination IS the session the relay is driving, so a
    /// prompt queued for A never leaks into B just because B is now on screen.
    private(set) var activeStoredSessionID: String?
    // MARK: - Session entry map (R1, contract §1.2 — one store per session)

    /// One render-lane reconciled item store PER SESSION (the D3 kill: the old
    /// single shared store folded ANY `sid` into one transcript). Frames route
    /// to the entry named by `frame.sid` (contract I1); only the ACTIVE entry
    /// — the one holding the write-gate (contract I2) — projects into
    /// ``ChatStore``. Background sessions keep folding into their OWN entry:
    /// nothing stream-side is cancelled, reset, or torn down on a switch, so
    /// switch-back repaints from the warm entry with ZERO refetch (I14).
    private struct SessionEntry: Sendable {
        var store: RelayItemStore
        /// Monotonic last-touch stamp — the LRU eviction order (RR4).
        var touch: UInt64
    }
    private var entries: [String: SessionEntry] = [:]
    private var lruClock: UInt64 = 0
    /// Bounded LRU cap (contract §1.2): eviction writes through to `CacheStore`
    /// first and drops only SETTLED, non-active entries (RR4 — the map never
    /// grows unbounded nor resurrects stale entries).
    private static let maxEntries = 8

    /// R3 (ROUND-4 W2d): the session already established (open/resume/adopt
    /// RPC issued) on the CURRENT connection. The `.open`-edge re-establishment
    /// in `applyState` exists to rebind the session on a FRESH PhoneConnection
    /// after a reconnect (the relay's new connection has no foreground) — it
    /// must NOT fire a duplicate `open` when the buffered `.connecting → .open`
    /// state replay re-crosses the edge after the bind RPC already ran (the
    /// third read of the D6 cold-open triple-fetch). Cleared on every
    /// non-`.open` transition + teardown, so a genuine reconnect re-establishes
    /// exactly once.
    private var establishedSessionID: String?

    /// R3 (I14) gap-fill-once: whether the CURRENT turn delivered any payload
    /// through the stream (reset at `turn.started`, set on item frames and on a
    /// non-empty snapshot baseline). A `turn.completed` with NO delivered
    /// payload fires exactly ONE relay-local `resync{last_seq}` — the desktop
    /// `shouldHydrate` rule; a turn end with a payload costs zero refetches.
    private var currentTurnDeliveredPayload = false
    // (R1 deleted the S11 `projectionSuppressed` flag here — a draft is the
    // ABSENCE of an entry (I6): with no active entry nothing can project,
    // structurally. There is nothing to suppress or resume.)

    /// The render-lane reconciled item view, reconciled to the entry map
    /// (R1; RR7): the UNION of every parked entry's items — the read-only
    /// observation surface (tests, the resync watermark). The REDUCER unit is
    /// the per-session entry (``store(forSession:)``); the render AUTHORITY is
    /// the active entry alone (write-gate, I2).
    var store: RelayItemStore {
        RelayItemStore.merged(entries.values.map(\.store))
    }

    /// One parked session's reconciled items — the zero-refetch switch-back
    /// read (I14), and the per-session unit the W0a oracle observes.
    func store(forSession sessionID: String) -> RelayItemStore? {
        entries[sessionID]?.store
    }

    /// The live runtime id holding the write-gate. Relay frames are stamped with
    /// this id; the separate stored id is only the durable drawer/cache key.
    private var activeWriteGateSessionID: String? { activeSessionID }

    private let chatStore: ChatStore
    private let clientFactory: @Sendable () -> RelayClient
    /// Injectable backoff sleep between reconnect attempts. Defaults to
    /// `Task.sleep`; tests substitute a recording/zero-delay sleep so the
    /// reconnect timing is deterministic (prompt first attempt, tight early
    /// backoff — §4 driver policy).
    private let backoffSleep: @Sendable (Duration) async -> Void

    private var client: RelayClient?
    private var pumpTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?

    // MARK: Transport-ready waiters (QA-1 B1/B2)

    /// Continuations suspended in ``waitUntilOpen(timeout:)``, resolved when the
    /// socket crosses INTO `.open` (true) or their bounded timeout fires (false).
    /// Session ops queue on transport readiness through these instead of racing
    /// the phase bridge and failing fast with `notConnected`.
    private var openWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var openWaiterTimeouts: [UUID: Task<Void, Never>] = [:]

    #if DEBUG
    /// Test-only count of readiness edges (each crossing INTO `.open` the state
    /// observer applies — see ``applyState``). A render/conformance harness that
    /// sends the instant `start()` returns can race the observer's buffered
    /// `.connecting → .open` replay, whose transient `.connecting` blip flips
    /// `isOpen` false; awaiting `readinessEdgeCount` growth deterministically
    /// parks the harness until that replay has settled instead of wall-clock
    /// sleeping (QA-1 A9 gate determinism). Zero release-build footprint.
    private(set) var readinessEdgeCount = 0
    #endif

    /// Suspend until the relay socket reports `.open`, or `timeout` elapses.
    /// Returns `true` when open. Callers (session resume/open, the transcript
    /// network seed) use this to QUEUE on the relay phase bridge instead of
    /// racing it: a cold-start resume that lands mid-connect waits the fraction
    /// of a second until the socket is up rather than throwing `notConnected`
    /// into a modal alert channel (QA-1 B1 north-star: retryable conditions
    /// self-heal silently). Bounded so a genuinely dead relay surfaces as a
    /// `false` return the caller turns into a silent retry-on-ready, never a
    /// hang.
    @discardableResult
    func waitUntilOpen(timeout: Duration = .seconds(10)) async -> Bool {
        if phase == .open { return true }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            openWaiters[id] = continuation
            openWaiterTimeouts[id] = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.resolveOpenWaiter(id: id, opened: false)
            }
        }
    }

    private func resolveOpenWaiter(id: UUID, opened: Bool) {
        openWaiterTimeouts.removeValue(forKey: id)?.cancel()
        guard let continuation = openWaiters.removeValue(forKey: id) else { return }
        continuation.resume(returning: opened)
    }

    /// Resolve every pending ``waitUntilOpen(timeout:)`` with `opened`. Called on
    /// the crossing into `.open` (true) and on teardown (false).
    private func resolveAllOpenWaiters(opened: Bool) {
        let waiters = openWaiters
        openWaiters.removeAll()
        for (_, timeout) in openWaiterTimeouts { timeout.cancel() }
        openWaiterTimeouts.removeAll()
        for (_, continuation) in waiters { continuation.resume(returning: opened) }
    }

    /// Rebind the driven session on a FRESH connection (the relay's new
    /// PhoneConnection has no foreground set and no seen_sids — without this
    /// the Notifier fires spurious APNs and the resync snapshot is empty).
    /// EXACTLY ONCE per connection cycle: ``establishedSessionID`` guards it
    /// (set by the bind RPC itself — `resume`/`open`/`adoptCreatedSession` —
    /// or by the first rebind; invalidated at every genuine connection-cycle
    /// start). Best-effort: a failure is non-fatal.
    private func reestablishDrivenSession() {
        guard let runtimeID = activeSessionID, let client else { return }
        let storedID = activeStoredSessionID ?? runtimeID
        guard establishedSessionID != storedID else { return }
        establishedSessionID = storedID
        Task {
            await client.setForeground(runtimeID)
        }
    }

    /// Adopt `sessionID` as the session to (re-)open the moment the socket is
    /// ready, WITHOUT issuing the RPC now (QA-1 B1). A cold-start resume /
    /// session open that arrives before the relay phase bridge is up queues
    /// here; the crossing INTO `.open` then re-establishes the session (the
    /// existing `applyState` re-open) — silent queue-and-drain instead of a
    /// retryable alert. Already open ⇒ fire the re-establishment now (covers
    /// the race where the phase crossed between the caller's check and adopt).
    func adoptPendingSession(_ sessionID: String) {
        guard activeStoredSessionID != sessionID else { return }
        touchEntry(sessionID)
        moveWriteGate(to: sessionID)
        if phase == .open, let client {
            establishedSessionID = sessionID   // R3: this adopt IS the rebind
            Task {
                await client.setForeground(sessionID)
            }
        }
    }

    // MARK: Reconnect driver state (§4)

    /// The URL/token the live session was started with, retained so the auto
    /// reconnect driver can re-dial without a caller round-trip.
    private var reconnectURL: URL?
    private var reconnectToken: String?
    /// Consecutive reconnect attempts since the stream was last healthy. Reset to
    /// 0 on `start` and on the first live frame after a reconnect (proof the
    /// stream resumed), so the tight early backoff only escalates while a relay
    /// stays unreachable — never hammering, never stale-slow after a real heal.
    private var reconnectAttempt = 0
    /// The in-flight reconnect attempt, if any. Single-owner: a new attempt is
    /// only armed when this is `nil`, so overlapping `.failed` transitions cannot
    /// spawn parallel reconnect storms.
    private var reconnectTask: Task<Void, Never>?

    /// - Parameters:
    ///   - chatStore: the transcript owner the reconciled items are projected into.
    ///   - clientFactory: builds the relay client; tests inject one wired to a
    ///     mock relay transport. Production builds a real WS client with a modest
    ///     periodic ack cadence (§4).
    ///   - backoffSleep: the delay applied between reconnect attempts; tests
    ///     inject a deterministic/zero-delay sleep to assert timing.
    init(
        chatStore: ChatStore,
        clientFactory: @escaping @Sendable () -> RelayClient = { RelayClient(ackInterval: .seconds(2)) },
        backoffSleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.chatStore = chatStore
        self.clientFactory = clientFactory
        self.backoffSleep = backoffSleep
    }

    /// Tight early reconnect backoff for the relay driver (§4). Attempt 0 fires
    /// immediately (the loop skips the sleep); attempt n≥1 waits
    /// `min(0.25·2^(n-1), 8)s` plus 0…0.25s jitter — off the mark faster than the
    /// gateway's `0.5·2^n` schedule, yet bounded so a persistently-dead relay is
    /// retried at most ~every 8s rather than hammered.
    static func reconnectBackoff(attempt: Int) -> Duration {
        guard attempt > 0 else { return .zero }
        let base = min(0.25 * pow(2.0, Double(attempt - 1)), 8.0)
        let jitter = Double.random(in: 0...0.25)
        return .milliseconds(Int((base + jitter) * 1000))
    }

    var isOpen: Bool { phase == .open }

    // MARK: Lifecycle

    /// Connect to the relay, start the frame pump, and (optionally) open a session
    /// so its snapshot streams in. Any prior connection is stopped first. Throws a
    /// `RelayError` only if the optional `open` RPC fails; the socket itself opens
    /// eagerly (the ratified contract has no `ready` handshake — §1).
    func start(url: URL, token: String? = nil, sessionID: String? = nil) async throws {
        // QA-1 B1: a `start()` is a (re)dial, NOT a teardown — preserve any
        // session ops queued on ``waitUntilOpen`` across the pre-connect cleanup
        // so they DRAIN (resolve `true`) the moment this socket opens, instead
        // of being failed (`false`) by the cleanup and silently abandoned. The
        // prior `stop()` here resolved every queued waiter `false`, so a resume /
        // open that landed while the socket was mid-connect gave up before the
        // dial it was waiting on completed — the queue-and-drain path behind the
        // cold-start "Resume Session Failed" alert never bound.
        await tearDown(preservingOpenWaiters: true)

        let client = clientFactory()
        self.client = client
        reconnectURL = url
        reconnectToken = token
        reconnectAttempt = 0
        entries.removeAll(); lruClock = 0
        phase = .connecting

        await client.connect(url: url, token: token)
        phase = .open
        // `start` stamps `.open` directly (the state observer replays the edge
        // later, but a resume queued on readiness must not wait for the replay).
        resolveAllOpenWaiters(opened: true)
        // The readiness edge side-effects fire HERE (integration, I14): the
        // observer's buffered `.connecting → .open` replay is stale relative
        // to this direct stamp and no longer produces an edge — start owns the
        // initial-connect readiness itself (outbox wake + APNs re-wake).
        #if DEBUG
        readinessEdgeCount += 1
        #endif
        onReady?()

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
            // The write-gate moves at INTENT, pre-await (contract I4): snapshot
            // frames the pump delivers during the open await land on the fresh
            // entry and project.
            touchEntry(sessionID)
            moveWriteGate(to: sessionID)
            _ = try await client.open(sessionID)
            establishedSessionID = sessionID   // R3: this open IS the rebind — the replayed edge must not re-open it
        }
    }

    /// Reconnect after a drop and `resync` from the retained watermark (§4). The
    /// replay/snapshot arrives as frames the pump reconciles. This is the explicit
    /// (caller-driven) entry point — it cancels any in-flight auto-reconnect and
    /// treats the attempt as fresh (backoff reset), then re-dials immediately.
    ///
    /// Foreground re-establishment + session re-open happen in `applyState` when
    /// the state crosses into `.open`, so they fire on both manual and auto
    /// reconnects without duplication.
    func reconnect(url: URL, token: String? = nil) async {
        guard let client else { return }
        reconnectTask?.cancel(); reconnectTask = nil
        reconnectAttempt = 0
        reconnectURL = url
        reconnectToken = token
        phase = .connecting
        // A fresh connection cycle: establishment is per-connection (the new
        // PhoneConnection has no foreground) — invalidate so the genuine
        // `.open` edge rebinds the driven session exactly once. The readiness
        // edge itself (waiter resolve + `onReady`) is owned by the OBSERVER
        // here — exactly like the `scheduleReconnect` auto-driver: the new
        // socket's real `.connecting → .open` cycle flows through
        // `stateChanges` (unlike `start()`'s buffered replay, which is stale
        // relative to start's direct stamps and is skipped in `applyState`).
        establishedSessionID = nil
        currentTurnDeliveredPayload = false
        await client.reconnect(url: url, token: token)
    }

    /// Tear down the socket, cancel the pump/state observers + reconnect driver,
    /// and clear the render store. Idempotent. A genuine teardown can never bring
    /// the socket up, so it FAILS every queued ``waitUntilOpen`` waiter (`false`)
    /// — callers take their silent-retry-on-ready path instead of suspending
    /// until their bounded timeout.
    func stop() async {
        await tearDown(preservingOpenWaiters: false)
    }

    /// Shared cleanup for ``stop()`` (a real teardown) and ``start()`` (a
    /// (re)dial). They differ ONLY in the queued transport-readiness waiters: a
    /// teardown fails them (`preservingOpenWaiters: false`), while a dial keeps
    /// them parked so they drain when the fresh socket opens
    /// (`preservingOpenWaiters: true`) — the QA-1 B1 queue-and-drain contract.
    private func tearDown(preservingOpenWaiters: Bool) async {
        reconnectTask?.cancel(); reconnectTask = nil
        reconnectURL = nil; reconnectToken = nil; reconnectAttempt = 0
        pumpTask?.cancel(); pumpTask = nil
        stateTask?.cancel(); stateTask = nil
        if let client { await client.disconnect() }
        client = nil
        entries.removeAll(); lruClock = 0
        activeSessionID = nil
        activeStoredSessionID = nil
        establishedSessionID = nil          // R3: establishment is per-connection
        currentTurnDeliveredPayload = false // R3: gap-fill-once state dies with the store
        phase = .idle
        if !preservingOpenWaiters {
            resolveAllOpenWaiters(opened: false)
        }
    }

    // MARK: Auto-reconnect driver (§4)

    /// Arm a single reconnect attempt after an unexpected socket drop. Attempt 0
    /// fires immediately (no pre-delay) so recovery starts the instant the drop is
    /// observed; subsequent attempts wait the tight early backoff. Single-owner:
    /// a new attempt is armed only when none is in flight, so a burst of `.failed`
    /// transitions cannot spawn parallel reconnect storms.
    ///
    /// Each attempt calls `client.reconnect`, which re-opens the socket and sends
    /// `resync{last_seq}` immediately (the retained watermark resumes the stream
    /// fast — §4). The relay has no `ready` handshake, so the socket is treated as
    /// open optimistically; if it is in fact dead the receive loop posts `.failed`
    /// again, which re-arms this driver with an incremented attempt (the backoff
    /// escalates, bounded — never hammering). The attempt counter resets to 0 the
    /// moment a live frame lands (`ingest`), proving the stream truly resumed.
    private func scheduleReconnect() {
        guard reconnectTask == nil, let client, let url = reconnectURL else { return }
        let token = reconnectToken
        let attempt = reconnectAttempt
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            if attempt > 0 {
                await self.backoffSleep(Self.reconnectBackoff(attempt: attempt))
            }
            // stop()/an explicit reconnect may have raced the backoff sleep.
            guard !Task.isCancelled,
                  self.reconnectURL == url,
                  self.client === client else {
                self.reconnectTask = nil
                return
            }
            self.phase = .connecting
            await client.reconnect(url: url, token: token)   // re-open + immediate resync{last_seq}
            self.reconnectAttempt += 1
            self.reconnectTask = nil
            // Insurance for the narrow window where the socket failed again
            // *during* the reconnect await (the `.failed` observer was suppressed
            // while this task held ownership): re-arm from the settled state.
            if case .failed = await client.state, self.client === client {
                self.scheduleReconnect()
            }
        }
    }

    // MARK: Frame ingestion → transcript projection

    private func ingest(_ frame: RelayFrame) {
        // A live frame proves the stream resumed: clear the backoff so a later
        // drop reconnects promptly instead of inheriting a stale attempt count.
        if reconnectAttempt != 0 { reconnectAttempt = 0 }
        route(frame)
    }

    /// Route one downstream frame by the `sid` the relay STAMPED on it — the
    /// whole leak-prevention substrate (contract I1): the client never guesses
    /// "active session"; it routes by the stamped id. The frame folds into the
    /// entry named by its sid; an entry is CREATED on first touch when the
    /// session is KNOWN (opened/resumed/adopted/created by this phone) or the
    /// frame is TURN-BEARING — the relay forwards only turns bound to this
    /// connection, so a turn-naming frame for a locally-unknown sid is a
    /// background turn of a session the phone drives: fold it into its own
    /// entry for a zero-refetch switch-back (I14) instead of losing it to a
    /// refetch. A frame that names NO turn and NO known session is
    /// UNATTRIBUTABLE: DROPPED — never folded into the active session, no
    /// phantom entry created (I1).
    ///
    /// Only the ACTIVE entry (the write-gate, I2) projects into the
    /// transcript; a background entry folds in silence — its `turn.completed`
    /// still expires ITS OWN gate (amendment G1: turn end expires a gate, a
    /// switch never does), and nothing it does can touch the active session.
    private func route(_ frame: RelayFrame) {
        let sid = frame.sid
        if entries[sid] == nil {
            guard frame.turn != nil else { return }   // unattributable ⇒ drop (I1)
            entries[sid] = SessionEntry(store: RelayItemStore(), touch: 0)
        }
        entries[sid]!.store.apply(frame)
        lruClock += 1
        entries[sid]!.touch = lruClock
        evictSettledInactiveEntries()

        // Gate frames are NOT items (the store drops them by design) — they
        // bridge to ChatStore regardless of focus: dropping a one-shot
        // request for an unfocused session is UNRECOVERABLE (I12). ChatStore
        // slots the active session's gate and parks any other sid's. For the
        // active session the gate also refreshes the liveness clock (the
        // agent is waiting on the USER — a resync must not false-settle a
        // turn parked on an unanswered gate).
        switch frame.kind {
        case .approvalRequest:
            chatStore.applyRelayApprovalRequest(frame)
            if sid == activeWriteGateSessionID {
                chatStore.noteTurnLivenessFrame(isCurrentTurn: true)
            }
            return
        case .clarifyRequest:
            chatStore.applyRelayClarifyRequest(frame)
            if sid == activeWriteGateSessionID {
                chatStore.noteTurnLivenessFrame(isCurrentTurn: true)
            }
            return
        default: break
        }

        guard sid == activeWriteGateSessionID else {
            // BACKGROUND entry: fold-only. The turn-end seam fires for ITS OWN
            // session — that session's gate expires (amendment G1) — and by
            // construction touches nothing on the active session (I1/I2).
            if frame.kind == .turnCompleted {
                chatStore.expireRelayPendingGates(sessionID: sid)
            }
            return
        }
        projectActiveEntry(frame, items: entries[sid]!.store.items)
    }

    /// Project the ACTIVE entry's items + fire its turn-lifecycle seams — the
    /// body of the old session-agnostic ingest, now scoped to the one session
    /// the write-gate admits (contract I2).
    private func projectActiveEntry(_ frame: RelayFrame, items: [ChatItem]) {
        // R5/W2e (contract I9/B1): a local STOP settled the current turn — its
        // LATE ITEM frames (crossed the interrupt in flight; a resync ring
        // replay) keep the seq spine honest (folded in `route` above) but
        // project NOTHING and never refresh the liveness clock: the local
        // settlement is the render truth until the authoritative boundary
        // arrives. Everything else falls through: a snapshot is an
        // authoritative re-baseline (clears the mark — server truth wins, I3);
        // `turn.started` / `turn.completed` drive the turn state machine
        // below; a gate that arrives in the stop→completion window still
        // parks and is expired (and resolved-marked — I12/I23) by the turn
        // boundary as usual.
        if chatStore.relayTurnSettling {
            switch frame.kind {
            case .snapshot:
                chatStore.noteAuthoritativeRebaseline()
            case .itemStarted, .itemDelta, .itemCompleted:
                return
            default:
                break
            }
        }
        // QA-3 S8/A4 — per-turn liveness: refresh the silence clock ONLY for
        // frames of the CURRENT turn. Frames of a superseded turn (late tool
        // results) must never mask a dead current turn's silence, nor keep a
        // dead prior turn's rows "live" — the IMG_2591 re-arm-by-other-turn
        // bug that left "Working… · ToolCall 5s" up forever. Relay-native for
        // EVERY owner: the clock baselines off the relay frames themselves
        // (`turn.started` / snapshot-with-in-progress classify current-turn
        // here), so a foreign or cold-resumed turn is watched exactly like a
        // send-started local one (contract I10/A3 — the send-only baseline
        // was the D11 arming gap).
        chatStore.noteTurnLivenessFrame(isCurrentTurn: frameBelongsToCurrentTurn(frame, items: items))
        // QA-2 R4/A2: `turn.completed` is the authoritative settle the
        // turn-scoped `relayTurnLive` flag clears on — plumbed through so the
        // SAME projection that sees the terminal items also ends the turn
        // (item terminality alone must not, the build-115 bug).
        //
        // QA-3 S2/A1: `turn.completed` additionally carries the relay's
        // authoritative turn wall-clock (`body.duration_s`, reframer-measured
        // from the turn open) — the settled "Worked for Ns" label reconciles
        // to it (the live per-turn timer starts LOCALLY at send). Absent on
        // older relays → the projection falls back to the local measurement.
        chatStore.applyRelayItems(
            items,
            turnSettled: frame.kind == .turnCompleted,
            serverTurnDuration: frame.kind == .turnCompleted
                ? frame.body["duration_s"]?.doubleValue
                : nil
        )
        // QA-1 B10 / A3: gate frames bridge in `route` (they park per-session
        // on ChatStore for BOTH the active and background entries — contract
        // I12, never dropped because unfocused). `turn.completed` settles the
        // turn → expire that session's pending gate (parity with the direct
        // path's message.complete expiry — a gate answered elsewhere or
        // abandoned must not linger inviting a reply against a dead runtime).
        switch frame.kind {
        case .turnStarted:
            currentTurnDeliveredPayload = false   // R3 (I14): new turn, fresh budget
            // QA-2 R12/R13: a new turn is the authoritative "clear the dock for
            // a fresh seed" edge — the relay item store accumulates the prior
            // turn's `taskList` item (stable `<sid>:tasks` id, replaced in
            // place only when THIS turn emits its own), so without this clear
            // the next `applyRelayItems` would re-mirror the previous turn's
            // list and the pill would briefly show stale data when the new
            // turn starts streaming.
            chatStore.handleRelayTurnStarted()
        case .turnCompleted:
            // R3 (I14) — GAP-FILL-ONCE (desktop `shouldHydrate`): the stream is
            // the authority on relay. A turn that delivered payload costs ZERO
            // refetches; a turn end with NO payload gets exactly ONE reconcile
            // — and it is relay-LOCAL: a `resync{last_seq}` the relay answers
            // from its ring/store snapshot, never a gateway transcript read.
            if !currentTurnDeliveredPayload {
                Task { [weak self] in await self?.requestLivenessResync() }
            }
            currentTurnDeliveredPayload = false
            chatStore.expireRelayPendingGates(sessionID: frame.sid)
            // R5 (contract I9, lane L3): the relay wire's EXPLICIT turn
            // boundary, split on its wire-truth `reason` (reframer-stamped,
            // L3): `completed` ⇒ Live Activity end + queue drain; `interrupted`
            // (user stop) / `error` ⇒ Live Activity end, queue HOLD — stopped
            // ≠ completed. The turn id latches the seam once per turn (I21:
            // a resync replay of the settled turn fires zero extra seams).
            chatStore.notifyRelayTurnCompleted(
                turnID: frame.turn,
                reason: frame.body["reason"]?.stringValue
            )
            // (R1 deleted the `handleRelayTurnCompleted` no-op here — task-list
            // dismissal at turn end rides the write-gate record, I15.)
        case .itemStarted, .itemDelta, .itemCompleted:
            currentTurnDeliveredPayload = true   // R3 (I14): the stream delivered payload
        case .snapshot:
            // A non-empty snapshot baseline counts as delivered payload — a
            // turn.completed that immediately follows a resume/open snapshot
            // must not fire a redundant gap-fill resync (shouldHydrate false).
            if frame.snapshot.map({ !$0.items.isEmpty }) == true {
                currentTurnDeliveredPayload = true
            }
        default: break
        }
        // R5: a failed `.error` item is a turn TERMINAL on the relay wire
        // (parity with the direct path's `error` event → `handleGatewayError`).
        // Fire the DISCARD seam — not a completion, so the queue does NOT
        // auto-drain into a session that just errored; the trailing
        // `turn.completed` is suppressed by the once-per-turn latch (I21).
        // Only item-bearing frames carry a `ChatItem`; delta/approval/etc.
        // frames have `nil`.
        if let item = frame.item, item.type == .error, item.status == .failed {
            chatStore.notifyRelayTurnDiscarded(turnID: frame.turn)
        }
    }

    /// QA-3 S8/A4 — whether a just-folded frame belongs to the CURRENT (latest)
    /// turn, for the per-turn liveness clock. Turn-boundary frames, snapshots
    /// (an authoritative baseline) and active gates refresh the clock; an ITEM
    /// frame refreshes it only when the item sits at/after the last
    /// `userMessage` item (the relay allocates the userMessage's ord at
    /// SUBMIT, before that turn's agent items, so render order is strictly
    /// `[U1,A1…][U2,A2…]` — anything before the last userMessage is a prior
    /// turn's late traffic and must not refresh the clock).
    private func frameBelongsToCurrentTurn(_ frame: RelayFrame, items: [ChatItem]) -> Bool {
        switch frame.kind {
        case .turnStarted, .turnCompleted, .snapshot,
             .approvalRequest, .clarifyRequest, .status, .title:
            return true
        case .itemStarted, .itemDelta, .itemCompleted:
            guard let item = frame.item else { return true }
            guard let lastUserIdx = items.lastIndex(where: { $0.type == .userMessage }),
                  let itemIdx = items.lastIndex(where: { $0.itemID == item.itemID })
            else { return true }   // no known turn boundary — treat as current
            return itemIdx >= lastUserIdx
        case .unknown:
            return false
        }
    }

    // MARK: - Write-gate + entry lifecycle (contract I2 / §1.2)

    /// Move the WRITE-GATE (contract I2): a session switch atomically moves
    /// (projected sid, gate membership, per-turn timer, Live Activity
    /// ownership) — delegated to ``ChatStore/relayWriteGateMoved(toSession:
    /// items:)``. The outgoing entry is NOT reset or cancelled: it keeps
    /// folding its own frames (a parked entry — zero-refetch switch-back,
    /// I14). `nil` = the draft surface: the ABSENCE of a session (I6) — no
    /// entry projects, no suppression flag exists to fail.
    private func moveWriteGate(to sessionID: String?) {
        activeSessionID = sessionID
        activeStoredSessionID = sessionID
        chatStore.relayWriteGateMoved(
            toSession: sessionID,
            items: sessionID.flatMap { entries[$0]?.store.items } ?? []
        )
    }

    /// Draft surface (contract I6): the write-gate moves OFF. Replaces the S11
    /// `projectionSuppressed` flag — parked entries keep folding, and nothing
    /// can project because no session is active (structural isolation; the
    /// durable outbox re-routes the moment a real session binds).
    func enterDraft() {
        moveWriteGate(to: nil)
    }

    /// First-touch the entry for a session this phone intentionally drives
    /// (open/resume/adopt/submit-create) — as opposed to entries a
    /// turn-bearing frame creates in the background (``route``).
    private func touchEntry(_ sessionID: String) {
        lruClock += 1
        if entries[sessionID] != nil {
            entries[sessionID]!.touch = lruClock
        } else {
            entries[sessionID] = SessionEntry(store: RelayItemStore(), touch: lruClock)
        }
    }

    /// Bounded LRU (≤8 — contract §1.2 / RR4): when the map outgrows the cap,
    /// evict the least-recently-touched entry that is SETTLED (no
    /// `.inProgress` items) AND not the active entry — writing through to
    /// `CacheStore` FIRST (I3: the cache is a seed), so the next open paints
    /// from disk and the relay snapshot reconciles over it (I14). An all-live
    /// map holds (bounded by live turns — a running turn is never evicted).
    private func evictSettledInactiveEntries() {
        guard entries.count > Self.maxEntries else { return }
        let active = activeWriteGateSessionID
        let victim = entries
            .filter { $0.key != active && $0.value.store.items.allSatisfy(\.isTerminal) }
            .min { $0.value.touch < $1.value.touch }
        guard let (sid, entry) = victim else { return }
        chatStore.relayEntryEvictedWriteThrough(sessionID: sid, items: entry.store.items)
        entries[sid] = nil
    }

    // MARK: - QA-3 S8/A4 turn liveness fallback

    /// Stage 1 — the ChatStore liveness watchdog detected the driven turn went
    /// silent past the resync window. Ask the relay for a `resync{last_seq}`
    /// replay (a snapshot when the gap exceeds the ring): a dropped terminal
    /// frame heals here and the turn settles naturally. SILENT + idempotent +
    /// best-effort (nothing to do when the socket is down — the auto-reconnect
    /// driver already resyncs on re-open); the user sees nothing (C3).
    func requestLivenessResync() async {
        guard phase == .open, let client else { return }
        await client.resync()
    }

    /// Stage 2 — the watchdog concluded the driven turn is DEAD (silent past
    /// the settle window even after the stage-1 resync, so the authority has
    /// nothing more). Locally settle every stuck `.inProgress` item (marked
    /// ``ChatItem/locallyInterrupted`` → the projection folds them as muted
    /// "Interrupted" rows, never an error banner — C3) and re-project with
    /// `turnSettled: true` so the turn-scoped live flag clears. Eternal
    /// double-working is unreachable past this point; any later authoritative
    /// frame (item.completed / snapshot) replaces the items by id and heals.
    func settleStaleTurnLocally() {
        guard let sid = activeWriteGateSessionID, entries[sid] != nil else { return }
        entries[sid]!.store.settleInProgressLocally()
        chatStore.applyRelayItems(entries[sid]!.store.items, turnSettled: true)
    }

    private func applyState(_ state: RelayConnectionState) {
        let wasOpen = (phase == .open)
        switch state {
        case .idle:          phase = .idle
        case .connecting:
            // A `.connecting` delivered while we are ALREADY `.open` is the
            // buffered initial-connect state replay: `start()` / `reconnect(url:)`
            // stamp `.connecting → .open` directly before this observer drains
            // the socket's buffered pair. A genuine connection cycle can never
            // reach `.connecting` from `.open` without a `.failed` / `.closed`
            // in between (a socket does not re-dial while established), so
            // applying it here would (a) flicker the mirrored UI phase and
            // (b) invalidate `establishedSessionID`, letting the replayed
            // `.open` below re-establish a session a bind RPC already
            // established — the duplicate `open` read contract I14 forbids.
            guard phase != .open else { break }
            phase = .connecting
        case .open:          phase = .open
        case .closed(let r): phase = .closed(reason: r)
        case .failed(let m):
            phase = .failed(m)
            // An unexpected transport drop (a real error, not an intentional
            // teardown — those cancel and yield `.closed`). Kick the tight
            // auto-reconnect driver so the stream recovers without waiting on a
            // coarse app-level trigger.
            scheduleReconnect()
        }
        // R3 (I14): any non-`.open` transition starts a fresh connection cycle
        // — invalidate the establishment marker so the NEXT `.open` edge
        // re-establishes the session exactly once (a genuine reconnect), while
        // the buffered initial-connect state replay can never fire a duplicate
        // `open` over a bind RPC that already ran (the third read of the D6
        // cold-open triple-fetch).
        if phase != .open { establishedSessionID = nil }
        // Mirror EVERY relay transition to the app's connection state so the
        // banner + composer reflect the real socket, not a stale startup stamp.
        onPhaseChange?(phase)
        // Crossing INTO `.open` is the relay's readiness edge — kick the outbox so
        // a prompt queued while disconnected drains now, over the relay. Both the
        // initial connect and a reconnect surface here as a buffered
        // `.connecting` → `.open` pair (the socket yields both; `start`/`reconnect`
        // set `phase` before this observer drains them), so this fires exactly once
        // per connect. Edge-triggered — a redundant same-state yield does not
        // re-fire, and `wake()` coalesces regardless.
        if phase == .open, !wasOpen {
            // Release every session op queued on transport readiness (QA-1 B1).
            resolveAllOpenWaiters(opened: true)
            #if DEBUG
            readinessEdgeCount += 1
            #endif
            onReady?()
            // Re-establish the session the phone was driving on the fresh
            // connection. The relay's new PhoneConnection has no foreground set
            // and no seen_sids, so without this the Notifier fires spurious APNs
            // and the resync snapshot is empty. Best-effort: a failure here is
            // non-fatal — the resync already ran inside client.reconnect.
            // R3 (I14): EXACTLY ONCE per connection — skip when this session
            // was already established on the current connection (the bind RPC
            // or a prior edge fired it); the marker resets on every genuine
            // connection-cycle start, so a genuine reconnect still
            // re-establishes.
            reestablishDrivenSession()
        }
    }

    // MARK: Upstream session ops (§5)

    private func requireClient() throws -> RelayClient {
        guard let client, phase == .open else { throw RelayError.notConnected }
        return client
    }

    /// Start a new turn (or send into `activeSessionID`) and, on success, return
    /// the relay's result (its `session_id` is the created/echoed id).
    /// `clientMessageID` carries the durable outbox row's stable id so the relay
    /// SUBMIT handler can dedupe a retry that follows a socket-flap-ambiguous
    /// submit (the RPC result was lost after the relay already ran
    /// `prompt_submit`) instead of running a second turn.
    ///
    /// R2 / contract I5 — the wire target is EXACTLY the pinned stored id the
    /// caller passes: **nil when nothing is selected** (a true draft). There is
    /// NO fallback to a previously-driven session — the deleted
    /// `?? activeSessionID` submitted a draft into the PREVIOUS session (D2). A
    /// nil target makes the relay CREATE the session (downstream.py:759-763);
    /// the caller adopts the returned id via ``adoptCreatedSession(_:)`` AFTER
    /// its drift re-check (amendment S4), so a mid-await navigation never binds
    /// the minted session to a surface the user already left.
    @discardableResult
    func submit(
        prompt: String,
        sessionID: String? = nil,
        clientMessageID: String? = nil
    ) async throws -> JSONValue {
        let target = sessionID
        // Sending to a session IS driving it: first-touch its entry (the
        // deep-link resume-to-send and `bindRuntime: false` opens bind the
        // session here, not via open/resume — contract §1.3 first-touch).
        if let target { touchEntry(target) }
        let result = try await requireClient().submit(
            sessionID: target, prompt: prompt, clientMessageID: clientMessageID
        )
        if let sid = result["session_id"]?.stringValue {
            touchEntry(sid)
            activeSessionID = sid
            if activeStoredSessionID != nil {
                chatStore.relayCreatedSessionAdopted(sid)
            }
            // A nil-target submit created the session at the relay (QA-1 B13 /
            // contract I6). Adoption is NOT inline here (integration, R1×R2):
            // amendment S4 gates it on the CALLER's drift re-check — ChatStore
            // adopts via ``adoptCreatedSession(_:)`` ONLY when the nil pin did
            // not drift (ChatStore.swift:2889-2910); a drifted nil pin drops
            // the echo and leaves the minted orphan unbound. A background
            // outbox drain (submitOutboxPrompt, D10) submits nil WITHOUT
            // adopting — the write-gate never moves behind the user's back.
        } else if activeSessionID == nil, let target {
            activeSessionID = target
        }
        return result
    }

    /// R2 / contract A4 + I6 — atomic adoption of a session the relay CREATED on
    /// a nil-target SUBMIT (downstream.py:759-763). The draft surface has NO
    /// entry; this makes it a real one in a single code path (not a suppression
    /// flag plus a patch): re-bind the item store to the minted id so the
    /// previous session's parked items never project into it (I6 isolation),
    /// adopt its distinct stored and live identities (so
    /// ``outboxRuntimeID(forStored:)`` maps it and the immediately-following
    /// send targets it), move the write-gate to it (projection resumes), and
    /// foreground it so the relay forwards its frames and push suppresses while
    /// the phone holds it.
    func adoptCreatedSession(runtimeID: String, storedID: String) {
        // R1 machinery (integration): the draft had NO entry — first-touch
        // creates a fresh one, so the previous session's parked items stay in
        // THEIR entry and can never project here (I6 isolation, structural).
        // Adopting stored+live identity makes `outboxRuntimeID(forStored:)`
        // map it and the immediately-following send target it; the write-gate
        // MOVES via the R1 seam (projection is live for the gate session —
        // R1 deleted the suppression flag R2 originally resumed here).
        touchEntry(runtimeID)
        activeSessionID = runtimeID
        activeStoredSessionID = storedID
        establishedSessionID = storedID
        chatStore.relayCreatedSessionAdopted(runtimeID)
        // Creation already owns the runtime at the relay. Foreground that live
        // id; transcript persistence is awaited by SessionStore, and a later
        // genuine cache miss uses the single relay-history fallback.
        guard let client else { return }
        Task {
            await client.setForeground(runtimeID)
        }
    }

    /// The relay runtime id a durable-outbox row destined for `storedID` must
    /// drain to, or `nil` to HOLD the row for a later wake. It resolves only
    /// when that durable destination IS the session the relay is currently
    /// driving. Returning a runtime for any other destination would
    /// mis-route the prompt into the active session (drain-into-wrong-session);
    /// holding instead defers the drain until that session is on the relay,
    /// mirroring the gateway path's "no runtime mapped ⇒ hold".
    func outboxRuntimeID(forStored storedID: String) -> String? {
        activeStoredSessionID == storedID ? activeSessionID : nil
    }

    /// Resume + own an idle/terminal session: the write-gate MOVES to its
    /// entry (contract I2 — the projection, gate membership, per-turn timer
    /// and Live Activity ownership move atomically at INTENT, pre-await, so
    /// snapshot frames the pump delivers during the RPC await project; the
    /// outgoing entry is NOT reset — it keeps folding for a zero-refetch
    /// switch-back, I14). R1 deleted the old `resetItemStoreForSessionSwitch`
    /// dance here: per-session entries make the cross-session leak
    /// impossible by construction (I1), its gate-expiry-on-switch deletes
    /// OUTRIGHT (amendment G1 — gates MOVE with their session), and its
    /// task-list/LA clears move to the write-gate seam.
    @discardableResult
    func resume(_ sessionID: String) async throws -> JSONValue {
        let client = try requireClient()
        // R3 (I14/A12): re-opening a session whose entry is ALREADY warm and
        // gate-holding is a cheap re-focus — ZERO RPCs (the relay's foreground
        // binding is already this session; the warm entry re-projects). Post-R1
        // the entry persists across switches, so a warm switch-back also never
        // needs the rebind RPC — this shortcut is the tap-active budget (A12).
        if sessionID == activeSessionID,
           let entry = entries[sessionID], !entry.store.items.isEmpty {
            return .object(["session_id": .string(sessionID)])
        }
        touchEntry(sessionID)
        moveWriteGate(to: sessionID)
        let result = try await client.resumeSession(sessionID)
        establishedSessionID = sessionID   // R3: the `.open` edge must not re-open it
        if let runtimeID = result["session_id"]?.stringValue {
            touchEntry(runtimeID)
            activeSessionID = runtimeID
            activeStoredSessionID = sessionID
            chatStore.relayCreatedSessionAdopted(runtimeID)
        }
        return result
    }

    /// Open/read a session; its `snapshot` streams into its entry and (the
    /// entry holding the write-gate) into the transcript.
    @discardableResult
    func open(_ sessionID: String) async throws -> JSONValue {
        let client = try requireClient()
        // R3 (I14/A12): warm rebind of the driven session — zero RPCs (see
        // `resume(_:)` above for the budget rationale).
        if sessionID == activeSessionID,
           let entry = entries[sessionID], !entry.store.items.isEmpty {
            return .object(["session_id": .string(sessionID)])
        }
        touchEntry(sessionID)
        moveWriteGate(to: sessionID)
        let result = try await client.open(sessionID)
        establishedSessionID = sessionID   // R3: the `.open` edge must not re-open it
        return result
    }

    func list() async throws -> JSONValue { try await requireClient().list() }

    func history(sessionID: String, limit: Int? = nil) async throws -> JSONValue {
        try await requireClient().history(sessionID: sessionID, limit: limit)
    }

    /// Answer an approval gate over the relay (§5). The relay resolves the gate
    /// by SESSION, so the session id is REQUIRED on the wire — it defaults to
    /// the session this coordinator is driving, or pass the gate's own session
    /// explicitly (e.g. an inbox item from another chat). `decision` is one of
    /// `approve`/`once`/`session`/`always`/`deny` (mapped to the gateway's
    /// `choice` by the relay); the wire shape is asserted by tests/conformance.
    @discardableResult
    func approve(
        sessionID: String? = nil,
        requestID: String = "",
        decision: String,
        resolveAll: Bool = false
    ) async throws -> JSONValue {
        guard let sid = sessionID ?? activeSessionID else { throw RelayError.notConnected }
        return try await requireClient().approve(
            sessionID: sid, requestID: requestID, decision: decision, resolveAll: resolveAll
        )
    }

    /// Convenience for the common approve/deny choice.
    @discardableResult
    func approve(sessionID: String? = nil, requestID: String = "", approved: Bool) async throws -> JSONValue {
        try await approve(
            sessionID: sessionID,
            requestID: requestID,
            decision: approved ? "approve" : "deny"
        )
    }

    /// Answer a clarify gate over the relay (§5). `requestID` MUST be the id
    /// from the `clarify.request` frame body — the gateway routes the answer by
    /// it; the relay additionally requires the session id (defaults to the
    /// driven session). Wire shape asserted by tests/conformance.
    @discardableResult
    func clarify(sessionID: String? = nil, requestID: String, response: String) async throws -> JSONValue {
        guard let sid = sessionID ?? activeSessionID else { throw RelayError.notConnected }
        return try await requireClient().clarify(sessionID: sid, requestID: requestID, response: response)
    }

    /// Attach inlined bytes through the relay (B9 / A5). The relay drives the
    /// gateway's base64 RPCs — `file.attach` (`kind: "file"`, arbitrary bytes →
    /// `@file:` ref) or `image.attach_bytes` (`kind: "image"`, photo → vision
    /// tile) — so photo/camera/file attach works IDENTICALLY on the relay
    /// transport, with no gateway-REST `POST /api/upload` round-trip (the
    /// relay-only reach the direct attach flow cannot make).
    ///
    /// Session resolution mirrors `submit`: a `nil` target passes `nil` on the
    /// wire and the relay CREATES + owns a new chat, returning its id — so an
    /// image-first send in a brand-new chat attaches, then submits to the SAME
    /// session (the returned `session_id` is adopted as `activeSessionID`,
    /// which a following `submit(sessionID: nil)` targets). Wire shape is
    /// asserted by RelayAttachWireTests + tests/e2e_daily_driver/test_h.
    @discardableResult
    func attach(
        sessionID: String? = nil,
        kind: String,
        name: String,
        dataURL: String
    ) async throws -> JSONValue {
        let target = sessionID ?? activeSessionID
        if let target { touchEntry(target) }   // attach drives the session too
        let result = try await requireClient().attach(
            sessionID: target, kind: kind, name: name, dataURL: dataURL
        )
        if let sid = result["session_id"]?.stringValue {
            touchEntry(sid)
            activeSessionID = sid
        }
        return result
    }

    @discardableResult
    func interrupt(_ sessionID: String? = nil) async throws -> JSONValue {
        guard let sid = sessionID ?? activeSessionID else { throw RelayError.notConnected }
        return try await requireClient().interrupt(sid)
    }

    /// Inject steering text into the live turn over the relay (§5b, QA-2 R11).
    /// Session resolution mirrors `interrupt`: an explicit target wins, else the
    /// driven session. The relay passes the gateway's disposition through
    /// VERBATIM — `{status: "queued" | "rejected", text}` — so `ChatStore.steer`
    /// maps it identically to the gateway-direct path. Wire shape asserted by
    /// tests/conformance (upstream `steer` payload).
    @discardableResult
    func steer(sessionID: String? = nil, text: String) async throws -> JSONValue {
        guard let sid = sessionID ?? activeSessionID else { throw RelayError.notConnected }
        return try await requireClient().steer(sessionID: sid, text: text)
    }

    // MARK: Push token registration (§6a)

    /// Register the APNs device token over the relay socket (§6a). The relay
    /// writes its OWN push registry — the one the relay Notifier reads — so a
    /// relay-mode phone's token reaches the notifier without any gateway-REST
    /// reachability or shared-HERMES_HOME coincidence. Throws when the relay
    /// socket is not open; ``PushRegistrar`` retries on the next launch /
    /// foreground, exactly like the gateway-direct path.
    @discardableResult
    func registerPushToken(
        _ token: String,
        env: String,
        events: [String]?,
        deviceID: String? = nil
    ) async throws -> JSONValue {
        try await requireClient().registerPushToken(
            token, env: env, events: events, deviceID: deviceID
        )
    }

    /// Remove the APNs device token from the relay's push registry (§6a).
    @discardableResult
    func unregisterPushToken(_ token: String) async throws -> JSONValue {
        try await requireClient().unregisterPushToken(token)
    }

    /// Clear the §6 foreground declaration (the app left the foreground). The
    /// relay suppresses turn_complete/task_complete/error pushes while a live
    /// phone WS holds the session foregrounded; iOS does not kill the socket
    /// the instant the app backgrounds, so without this clear a turn finishing
    /// seconds after backgrounding would be silently gated. Best-effort:
    /// fire-and-forget on the client (a closed socket is itself the clear).
    func clearForeground() async {
        guard let client else { return }
        await client.setForeground(nil)
    }

    /// Re-declare the driven session as foregrounded after returning to the
    /// foreground (§6a; mirrors :meth:`clearForeground`). When the relay socket
    /// is NOT up this is a no-op — the `onReady` re-establishment already
    /// re-asserts foreground on the fresh connection.
    func reassertForeground() async {
        guard let client else { return }
        guard let sid = activeStoredSessionID ?? activeSessionID else { return }
        await client.setForeground(sid)
    }
}
