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

    /// The session whose item stream is currently projected into ``ChatStore``.
    private(set) var activeSessionID: String?
    /// The STORED (durable/origin) id of the session the coordinator is currently
    /// driving — set whenever a session is opened/resumed/started by its stored
    /// id, and (unlike ``activeSessionID``) never remapped to the live id a
    /// `submit` returns. The relay keys its runtime on the stored session id
    /// (`SessionStore.bindRelayRuntime`), so this is the stable identity the
    /// durable-outbox drain routes against: a queued prompt may drain over the
    /// relay only when its destination IS the session the relay is driving, so a
    /// prompt queued for A never leaks into B just because B is now on screen.
    private(set) var activeStoredSessionID: String?
    /// The render-lane reconciled item set (mirrors the client store; the source
    /// of truth the transcript is projected from).
    private(set) var store = RelayItemStore()

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

    /// Adopt `sessionID` as the session to (re-)open the moment the socket is
    /// ready, WITHOUT issuing the RPC now (QA-1 B1). A cold-start resume /
    /// session open that arrives before the relay phase bridge is up queues
    /// here; the crossing INTO `.open` then re-establishes the session (the
    /// existing `applyState` re-open) — silent queue-and-drain instead of a
    /// retryable alert. Already open ⇒ fire the re-establishment now (covers
    /// the race where the phase crossed between the caller's check and adopt).
    func adoptPendingSession(_ sessionID: String) {
        guard activeStoredSessionID != sessionID else { return }
        activeStoredSessionID = sessionID
        activeSessionID = sessionID
        if phase == .open, let client {
            Task {
                await client.setForeground(sessionID)
                _ = try? await client.open(sessionID)
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
        store = RelayItemStore()
        phase = .connecting

        await client.connect(url: url, token: token)
        phase = .open
        // `start` stamps `.open` directly (the state observer replays the edge
        // later, but a resume queued on readiness must not wait for the replay).
        resolveAllOpenWaiters(opened: true)

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
            activeStoredSessionID = sessionID
            _ = try await client.open(sessionID)
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
        await client.reconnect(url: url, token: token)
        phase = .open
        resolveAllOpenWaiters(opened: true)
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
        store = RelayItemStore()
        activeSessionID = nil
        activeStoredSessionID = nil
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
        store.apply(frame)
        // QA-3 S8/A4 — per-turn liveness: refresh the silence clock ONLY for
        // frames of the CURRENT turn. Frames of a superseded turn (late tool
        // results) must never mask a dead current turn's silence, nor keep a
        // dead prior turn's rows "live" — the IMG_2591 re-arm-by-other-turn
        // bug that left "Working… · ToolCall 5s" up forever.
        chatStore.noteTurnLivenessFrame(isCurrentTurn: frameBelongsToCurrentTurn(frame))
        // QA-2 R4/A2: `turn.completed` is the authoritative settle the
        // turn-scoped `relayTurnLive` flag clears on — plumbed through so the
        // SAME projection that sees the terminal items also ends the turn
        // (item terminality alone must not, the build-115 bug).
        chatStore.applyRelayItems(store.items, turnSettled: frame.kind == .turnCompleted)
        // QA-1 B10 / A3: the interactive gate frames are NOT items — the render
        // store drops them by design — yet they are the sole input of the Turn
        // Dock's cards. Bridge them into the SAME ChatStore state the direct
        // gateway event router feeds, so the relay path surfaces the identical
        // `ApprovalCard` / `ClarifyBanner` in the identical dock. `turn.completed`
        // settles the turn → expire any pending gate (parity with the direct
        // path's message.complete expiry — a gate answered elsewhere or abandoned
        // must not linger inviting a reply against a dead runtime).
        switch frame.kind {
        case .approvalRequest: chatStore.applyRelayApprovalRequest(frame)
        case .clarifyRequest:  chatStore.applyRelayClarifyRequest(frame)
        case .turnStarted:
            // QA-2 R12/R13: a new turn is the authoritative "clear the dock for
            // a fresh seed" edge — the relay item store accumulates the prior
            // turn's `taskList` item (stable `<sid>:tasks` id, replaced in
            // place only when THIS turn emits its own), so without this clear
            // the next `applyRelayItems` would re-mirror the previous turn's
            // list and the pill would briefly show stale data when the new
            // turn starts streaming.
            chatStore.handleRelayTurnStarted()
        case .turnCompleted:
            chatStore.expireRelayPendingGates()
            // R16 (Live Activity lifecycle): the relay wire's EXPLICIT turn
            // boundary. The direct path ends the lock-screen Live Activity
            // from `handleMessageComplete`; the relay path never flows
            // through it, so without this firing the activity's `startedAt`
            // drove the elapsed timer ENDLESSLY (owner's "timer runs forever
            // on the lock screen" complaint). Idempotent: routes to
            // `LiveActivityManager.end()` (no-op when nothing is live) + the
            // queue-drain pipeline (no-op when no turn was live).
            chatStore.notifyRelayTurnCompleted()
            // QA-2 R12: clear a terminal (all-done/cancelled) task list's
            // ownership so the dock pill dismisses at turn end even though the
            // `taskList` item itself persists in the relay item store.
            chatStore.handleRelayTurnCompleted()
        default: break
        }
        // R16: a failed `.error` item is a turn TERMINAL on the relay wire
        // (parity with the direct path's `error` event → `handleGatewayError`).
        // Fire the DISCARD seam — not a completion, so the queue does NOT
        // auto-drain into a session that just errored. Only item-bearing
        // frames carry a `ChatItem`; delta/approval/etc. frames have `nil`.
        if let item = frame.item, item.type == .error, item.status == .failed {
            chatStore.notifyRelayTurnDiscarded()
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
    private func frameBelongsToCurrentTurn(_ frame: RelayFrame) -> Bool {
        switch frame.kind {
        case .turnStarted, .turnCompleted, .snapshot,
             .approvalRequest, .clarifyRequest, .status, .title:
            return true
        case .itemStarted, .itemDelta, .itemCompleted:
            guard let item = frame.item else { return true }
            let items = store.items
            guard let lastUserIdx = items.lastIndex(where: { $0.type == .userMessage }),
                  let itemIdx = items.lastIndex(where: { $0.itemID == item.itemID })
            else { return true }   // no known turn boundary — treat as current
            return itemIdx >= lastUserIdx
        case .unknown:
            return false
        }
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
        store.settleInProgressLocally()
        chatStore.applyRelayItems(store.items, turnSettled: true)
    }

    private func applyState(_ state: RelayConnectionState) {
        let wasOpen = (phase == .open)
        switch state {
        case .idle:          phase = .idle
        case .connecting:    phase = .connecting
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
            if let sid = activeStoredSessionID ?? activeSessionID, let client {
                Task {
                    await client.setForeground(sid)
                    _ = try? await client.open(sid)
                }
            }
        }
    }

    // MARK: Upstream session ops (§5)

    private func requireClient() throws -> RelayClient {
        guard let client, phase == .open else { throw RelayError.notConnected }
        return client
    }

    /// Start a new turn (or send into `activeSessionID`) and, on success, adopt
    /// the returned session id so subsequent ops target it. `clientMessageID`
    /// carries the durable outbox row's stable id so the relay SUBMIT handler can
    /// dedupe a retry that follows a socket-flap-ambiguous submit (the RPC result
    /// was lost after the relay already ran `prompt_submit`) instead of running a
    /// second turn.
    @discardableResult
    func submit(
        prompt: String,
        sessionID: String? = nil,
        clientMessageID: String? = nil
    ) async throws -> JSONValue {
        let target = sessionID ?? activeSessionID
        let result = try await requireClient().submit(
            sessionID: target, prompt: prompt, clientMessageID: clientMessageID
        )
        if let sid = result["session_id"]?.stringValue {
            activeSessionID = sid
            // A submit with NO target creates the session at the relay (QA-1
            // B13): the returned id is BOTH the stored and the live id, so adopt
            // it as the stored identity too — otherwise `outboxRuntimeID(forStored:)`
            // never maps the new session and a queued prompt for it would hold
            // forever instead of draining over the relay. Guarded so a submit
            // into an open session (stored id bound by start/open/resume) never
            // clobbers its stable identity with a possibly-distinct live id.
            if target == nil, activeStoredSessionID == nil { activeStoredSessionID = sid }
        } else if activeSessionID == nil, let target {
            activeSessionID = target
        }
        return result
    }

    /// The relay runtime id a durable-outbox row destined for `storedID` must
    /// drain to, or `nil` to HOLD the row for a later wake. The relay keys its
    /// runtime on the stored session id, so the runtime id is the destination id
    /// itself — but only when that destination IS the session the relay is
    /// currently driving. Returning a runtime for any other destination would
    /// mis-route the prompt into the active session (drain-into-wrong-session);
    /// holding instead defers the drain until that session is on the relay,
    /// mirroring the gateway path's "no runtime mapped ⇒ hold".
    func outboxRuntimeID(forStored storedID: String) -> String? {
        activeStoredSessionID == storedID ? storedID : nil
    }

    /// Resume + own an idle/terminal session, then adopt it as active.
    @discardableResult
    func resume(_ sessionID: String) async throws -> JSONValue {
        let client = try requireClient()
        resetItemStoreForSessionSwitch(to: sessionID)
        let result = try await client.resumeSession(sessionID)
        activeSessionID = sessionID
        activeStoredSessionID = sessionID
        return result
    }

    /// Open/read a session; its `snapshot` streams into the transcript.
    @discardableResult
    func open(_ sessionID: String) async throws -> JSONValue {
        let client = try requireClient()
        resetItemStoreForSessionSwitch(to: sessionID)
        let result = try await client.open(sessionID)
        activeSessionID = sessionID
        activeStoredSessionID = sessionID
        return result
    }

    /// Clear the render-lane item store when the projected session is about to
    /// CHANGE, so the incoming session's `snapshot` reconciles onto a clean
    /// baseline instead of folding on top of the previous session's items.
    ///
    /// `RelayItemStore.reconcile(snapshot:)` is deliberately additive — items
    /// absent from a snapshot are RETAINED (the snapshot is a resumed baseline,
    /// not a delete list). That is correct for a `resync` of the SAME session,
    /// but on a session SWITCH it would leak session A's items under session
    /// B's snapshot, so the projection would render both. Resetting the STORE
    /// here makes the switch clean and is a no-op re-open/re-resume of the
    /// already-active session, whose live items must survive a `resync`. Called
    /// BEFORE the open/resume RPC awaits so any snapshot frames the pump
    /// delivers during the await land on the fresh store.
    ///
    /// QA-1 (B4/B7/B15): deliberately NO `chatStore.applyRelayItems([])` here.
    /// The projection MERGES (tagged relay rows + untagged history), so the
    /// incoming session's cache paint (untagged rows) must SURVIVE the switch
    /// until its own relay content lands — wiping `chatStore.messages` to `[]`
    /// mid-open was the fully-blank transcript (B4). The previous session's
    /// TAGGED projection rows are dropped by the incoming session's first
    /// projection (it retains only untagged history) and by the open path's
    /// `chat.reset()`; the store reset alone keeps session A's items out of
    /// session B's projection, so nothing leaks either way. (Defense in depth:
    /// `ChatStore.applyRelayItems` ALSO treats an empty projection as a no-op
    /// fallback on `messages`, so a blank screen is impossible even if a future
    /// caller re-projects an emptied store.)
    private func resetItemStoreForSessionSwitch(to sessionID: String) {
        guard sessionID != activeSessionID else { return }
        store = RelayItemStore()
        // N4/A5: clear the previous session's task-list mirror so the new
        // session's dock starts clean (empty store ⇒ mirror cleared, `messages`
        // untouched — never blanks the transcript, QA-1 B4).
        chatStore.syncRelayTaskList(from: store)
        // QA-1 B10: a pending gate belongs to its session's turn — switching
        // the projected session clears the previous session's card (parity with
        // the direct path's `reset()` on open; answering session A's card while
        // viewing B would mis-route the answer).
        chatStore.expireRelayPendingGates()
        // R16: a relay turn mirrored for the outgoing session's Live Activity
        // must end when the user switches away — otherwise the lock-screen
        // timer keeps counting a turn the user is no longer viewing (and may
        // never see complete on this surface). No-op when no turn was live.
        chatStore.endRelayTurnForSessionSwitch()
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
        let result = try await requireClient().attach(
            sessionID: target, kind: kind, name: name, dataURL: dataURL
        )
        if let sid = result["session_id"]?.stringValue { activeSessionID = sid }
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
