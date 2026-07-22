import SwiftUI
import OSLog
import Network  // NWPathMonitor — S3 self-reconnect when the network returns
#if canImport(UIKit)
import UIKit  // UIDevice.current.name — the auto-upgrade device-name hint (W3A-A)
#endif
#if DEBUG
#endif

/// A model pick made on a DRAFT chat (no gateway session yet) — pends until
/// the draft materializes, then applies session-scoped (ABH-84 follow-up).
/// `reasoningEffort`/`fast` are nil when untouched (the session then keeps
/// the global defaults).
struct DraftModelSelection: Codable, Equatable, Sendable {
    var model: String
    var provider: String
    var reasoningEffort: String?
    var fast: Bool?
}

/// Observable owner of the gateway connection lifecycle.
///
/// Drives configuration/persistence, fans gateway events out to `SessionStore`
/// and `ChatStore`, mirrors the transport's connection state into a UI-facing
/// `Phase`, and runs the reconnect loop (exponential backoff with jitter). One
/// instance lives for the lifetime of the app; it holds the single
/// `HermesGatewayClient` whose long-lived streams it consumes.
@MainActor
@Observable
final class ConnectionStore {
    private static let log = Logger(subsystem: "HermesMobile", category: "ConnectionStore")

    /// Operational WebSocket capability for the current transport generation.
    ///
    /// This is intentionally separate from ``Phase``. In particular, `.connected`
    /// is retained during the silent reconnect grace window as presentation policy,
    /// while this value becomes `.unavailable` immediately when its socket drops.
    enum TransportReadiness: Equatable {
        case unconfigured
        case connecting(epoch: UInt64)
        case ready(epoch: UInt64)
        case unavailable(epoch: UInt64)
        case reauthRequired
    }

    #if DEBUG
    /// Test seam for privacy-sensitive Spotlight purges. `nil` in app runs so the
    /// production path calls ``SpotlightIndexer.clearAll`` directly.
    static var spotlightClearAllForTesting: (() -> Void)?
    #endif
    private var phoneForegroundUpdateTask: Task<Void, Never>?

    /// UI-facing connection lifecycle.
    enum Phase: Equatable {
        case needsSetup
        case connecting
        /// A verified connection whose gateway state (session list + running
        /// model) is still being hydrated. Drives the branded loading screen
        /// (ABH-82) so the user sees a brand moment rather than a flash of an
        /// empty shell. ALWAYS transient: a hard `hydrationTimeout` fallback
        /// flips it to `.connected` even if the post-connect probes are slow, so
        /// the loading screen can never strand.
        case hydrating
        case connected
        case reconnecting(attempt: Int)
        case offline(String?)
    }

    /// Current high-level connection phase.
    var phase: Phase = .connecting {
        didSet {
            notifyReadinessWaiters()
            // N3/A1 fast-path trace: the composer is interactive exactly when
            // `phase == .connected` (ChatView.isConnected gates on it). The first
            // such crossing defines the composer_interactive milestone
            // (ConnectTrace.mark is first-occurrence, so reconnects don't overwrite).
            if case .connected = phase {
                ConnectTrace.shared.mark(.composerInteractive)
            }
            switch phase {
            case .needsSetup, .offline:
                resolveAllTransportReadinessWaiters(with: false)
            case .connecting, .hydrating, .connected, .reconnecting:
                break
            }
        }
    }
    #if DEBUG
    /// JSON-safe mirror of ``phase`` for the gstack debug bridge snapshot
    /// (task UI-G). `phase` is a Swift enum and not JSON-serializable, so the
    /// generated StateServer accessor reads this stable String label instead.
    /// Wrapped in `#if DEBUG` so it does not exist in Release.
    var phaseLabel: String {
        switch phase {
        case .needsSetup: return "needsSetup"
        case .connecting: return "connecting"
        case .hydrating: return "hydrating"
        // STR-973A: a `.connected` phase during the silent-grace window still
        // reads as "connected" to every other consumer (RootView, the status
        // banner, ChatView.isConnected) by design — only this stable label
        // distinguishes it, so StateServer/gstack tooling can assert grace is
        // active without a new `Phase` case (which would break the exhaustive
        // `switch connection.phase` sites outside this file's scope).
        case .connected: return isInGrace ? "connected(grace)" : "connected"
        case .reconnecting(let attempt): return "reconnecting(\(attempt))"
        case .offline(let reason): return "offline(\(reason ?? ""))"
        }
    }
    #endif
    /// The server base URL string (persisted in UserDefaults).
    #if DEBUG
    #endif
    var serverURLString: String = ""

    /// The active connection mode (persisted in UserDefaults alongside
    /// ``serverURLString``). Defaults to `.remoteURL` for existing installs
    /// (no-migration).
    ///
    /// **Inc 2 — observed stored property:** promoted from a computed
    /// UserDefaults pass-through to a `@Observable`-tracked stored property
    /// so that views bind to it live and `configure`/reconnect always reads the
    /// current mode at call-time (the old computed getter was not observed by
    /// `@Observable`, causing a stale-mode connect when the transport now
    /// branches on it). The stored value is mirrored to UserDefaults on every
    /// write (same key, same raw-value encoding as before).
    var connectionMode: ConnectionMode = DefaultsKeys.connectionModeValue() {
        didSet {
            UserDefaults.standard.set(
                connectionMode.rawValue,
                forKey: DefaultsKeys.connectionMode
            )
        }
    }

    /// Set when a *configured* connection is rejected for authentication
    /// (HTTP 401/403 on the REST probe, or the WS handshake is rejected for auth
    /// repeatedly). The shell reads this alongside `.needsSetup` to route to
    /// ``WelcomeView`` with a "your pairing was revoked — scan a new code" banner
    /// instead of spinning in an endless reconnect. Cleared on a successful
    /// `configure` and on `disconnect`. (D3 RE-PAIR FLOW.)
    var reauthRequired = false

    /// `true` when the app is in the re-pair/repair posture because the current
    /// device's pairing died — set by `requireRepairAfterCurrentDeviceRevoked()`
    /// (self-revoke via Settings → Devices) and by the auth-rejection loops, all
    /// of which flip `phase` to `.needsSetup` AND arm `reauthRequired` together.
    ///
    /// Distinct from a fresh unconfigured app. Auth rejection can still leave a
    /// stale configured REST surface, while self-revoke now completes Forget and
    /// erases it; in either posture a pair link is recovery, not a destructive
    /// switch, so the router skips its disconnect-confirmation gate. (STR-903.)
    var isAwaitingRePair: Bool {
        if case .needsSetup = phase, reauthRequired { return true }
        return false
    }

    /// Non-blocking advisory for a device-token auto-upgrade that hit the server's
    /// device registry cap. Unlike `.offline`, this DOES NOT describe transport
    /// health and must never gate the composer: the shared token remains live, so
    /// the chat stays usable while the user revokes an unused device and retries.
    #if DEBUG
    #endif
    var deviceLimitAdvisory: String?

    func dismissDeviceLimitAdvisory() {
        deviceLimitAdvisory = nil
    }

    func retryDeviceUpgrade(serverURL: String) async {
        deviceIssueLimitReachedServers.remove(serverURL)

        await autoUpgradeToDeviceTokenIfNeeded(serverURL: serverURL)

        if DefaultsKeys.deviceId(server: serverURL) != nil {
            deviceLimitAdvisory = nil
        }
    }

    /// Short display name of the gateway's currently-configured main model
    /// (F0 / Amendment B). Sourced from `GET /api/model/info` on connect and
    /// re-fetched after a model switch. `nil` until the first successful probe
    /// (or when the server reports no model) — the header/composer model chip
    /// renders only when this is non-nil. Provider prefixes and trailing date
    /// stamps are stripped (see ``shortModelName(provider:model:)``) so the chip
    /// shows e.g. "claude-opus-4" rather than "anthropic/claude-opus-4-20250514".
    var activeModelName: String?

    // MARK: - Active session hot-swap state (ABH-84)
    //
    // These track the LIVE session's model/reasoning/fast as reported by the
    // gateway's `session.info` events (emitted after a `config.set` hot-swap).
    // They are nil when no session is active or no info has arrived yet.
    // The session popup reads these to show current state; the global defaults
    // are separate (Settings → ModelPickerView → POST /api/model/set).

    /// The live session's model id as reported by the last `session.info`.
    /// Distinct from `activeModelName`: this is the per-session override after a
    /// hot-swap; `activeModelName` remains the GLOBAL default (new-session model).
    var sessionModel: String?

    /// The live session's RAW model id (un-shortened) from `session.info`.
    /// The picker needs the raw id for exact row matching; `sessionModel`
    /// stays shortened for the composer chip display.
    var sessionModelRaw: String?

    /// The live session's provider slug from `session.info` (gateways that
    /// predate the field never set it; the picker then falls back to the
    /// session-scoped `model.options` current). Selection identity is
    /// (provider, model) — the model name alone is ambiguous when two
    /// providers offer the same model (ABH-84 QA).
    var sessionProvider: String?

    /// The live session's reasoning effort level
    /// ("minimal"/"low"/"medium"/"high"/"xhigh"/"none"/"") from `session.info`.
    var sessionReasoningEffort: String?

    /// True when the live session is in fast mode (service_tier == "priority").
    var sessionFast: Bool?

    /// Effective approval-bypass (YOLO / flow-state) state for the live session.
    /// Sourced from `session.info["yolo"]`, which already folds together the
    /// session flag and the global `approvals.mode=off` bypass.
    var sessionYolo = false

    // MARK: Draft-mode model pick (ABH-84 follow-up)

    /// The model pick is allowed at ANY point — including a DRAFT chat that has
    /// no gateway session yet. The pick pends here and is applied to the session
    /// the moment the draft materializes (`SessionStore.createDraftSession`),
    /// BEFORE the first prompt is submitted — `config.set key=model` builds the
    /// session agent, so even the FIRST turn runs on the chosen model.
    var draftSelection: DraftModelSelection?

    /// Shortened display name of the pended draft pick (composer chip).
    var draftModelShortName: String? {
        guard let d = draftSelection, !d.model.isEmpty else { return nil }
        return Self.shortModelName(provider: d.provider, model: d.model)
    }

    /// Forget a pended draft pick (fresh draft, opening an existing chat).
    func clearDraftSelection() {
        draftSelection = nil
    }

    /// Apply a pended draft pick to the just-created session. Best-effort BY
    /// DESIGN: a failure must not block (or lose) the user's first message —
    /// the session then simply runs on the global default and the pill follows
    /// the server truth from `session.info`.
    func applyDraftSelection(sessionId: String) async {
        guard let d = draftSelection else { return }
        draftSelection = nil
        if !d.model.isEmpty {
            let value = d.provider.isEmpty ? d.model : "\(d.model) --provider \(d.provider)"
            try? await sessionSetModel(value, sessionId: sessionId)
        }
        if let effort = d.reasoningEffort {
            try? await sessionSetReasoning(effort.isEmpty ? "none" : effort, sessionId: sessionId)
        }
        if let fast = d.fast {
            try? await sessionSetFast(fast, sessionId: sessionId)
        }
    }

    /// Apply the typed `info` echoed by `session.create`/`session.resume` to
    /// the live session state. THIS is what keeps the composer pill session-
    /// true on every switch: the gateway sends the session's actual
    /// model/provider/reasoning/fast/yolo on resume, but the app previously used
    /// it only for profile confirmation — so the pill kept showing the LAST
    /// session's hot-swap (or the global default) until the picker was opened
    /// (build-27 QA).
    func applyRuntimeInfo(_ info: SessionRuntimeInfo) {
        if let model = info.model, !model.isEmpty {
            sessionModel = Self.shortModelName(provider: nil, model: model)
            sessionModelRaw = model
        }
        if let provider = info.provider, !provider.isEmpty {
            sessionProvider = provider
        }
        if let effort = info.reasoningEffort {
            sessionReasoningEffort = effort
        }
        if let fast = info.fast {
            sessionFast = fast
        }
        if let yolo = info.yolo {
            sessionYolo = yolo
        }
    }

    /// Apply a `session.info` payload from the gateway to the live session state
    /// properties. Called from the event router on `.sessionInfo` events.
    func applySessionInfo(_ payload: JSONValue) {
        // Only update when the event belongs to the active runtime session.
        // The payload is the `_session_info()` dict from server.py.
        if let model = payload["model"]?.stringValue, !model.isEmpty {
            sessionModel = Self.shortModelName(provider: nil, model: model)
            sessionModelRaw = model
        }
        if let provider = payload["provider"]?.stringValue, !provider.isEmpty {
            sessionProvider = provider
        }
        if let effort = payload["reasoning_effort"]?.stringValue {
            sessionReasoningEffort = effort
        }
        if let fast = payload["fast"]?.boolValue {
            sessionFast = fast
        }
        if let yolo = payload["yolo"]?.boolValue {
            sessionYolo = yolo
        }
    }

    /// Reset active session hot-swap state when a session is torn down or
    /// the connection drops so a fresh session starts clean.
    func clearSessionState() {
        sessionModel = nil
        sessionModelRaw = nil
        sessionProvider = nil
        sessionReasoningEffort = nil
        sessionFast = nil
        sessionYolo = false
        draftSelection = nil
    }

    // MARK: - WS config.set helpers (ABH-84 session hot-swap)

    /// Session-scoped `model.options`: the gateway layers the LIVE session
    /// agent's provider/model on top of disk config, so `currentModel` /
    /// `currentProvider` reflect this session's hot-swap state — not the
    /// global default the REST endpoint reports. Mirrors the desktop, which
    /// calls WS `model.options` with `session_id` for its session dropdown.
    func sessionModelOptions(sessionId: String) async throws -> ModelOptions {
        let result = try await client.requestRaw(
            "model.options",
            params: .object(["session_id": .string(sessionId)]),
            timeout: .seconds(30)
        )
        return ModelOptions(json: result)
    }

    /// Send `config.set` with `key="model"` and the active `session_id` so the
    /// model switch is scoped to the live session only (not global).
    func sessionSetModel(_ model: String, sessionId: String) async throws {
        _ = try await client.requestRaw(
            "config.set",
            params: .object([
                "key": .string("model"),
                "value": .string(model),
                "session_id": .string(sessionId),
            ]),
            timeout: .seconds(30)
        )
    }

    /// Send `config.set` with `key="reasoning"` scoped to the live session.
    /// Pass an effort string from `VALID_REASONING_EFFORTS` ("none" to disable).
    func sessionSetReasoning(_ effort: String, sessionId: String) async throws {
        _ = try await client.requestRaw(
            "config.set",
            params: .object([
                "key": .string("reasoning"),
                "value": .string(effort),
                "session_id": .string(sessionId),
            ]),
            timeout: .seconds(30)
        )
    }

    /// Send `config.set` with `key="fast"` scoped to the live session.
    func sessionSetFast(_ enabled: Bool, sessionId: String) async throws {
        _ = try await client.requestRaw(
            "config.set",
            params: .object([
                "key": .string("fast"),
                "value": .string(enabled ? "fast" : "normal"),
                "session_id": .string(sessionId),
            ]),
            timeout: .seconds(30)
        )
    }

    /// Send `config.set` with `key="yolo"` scoped to the live session.
    /// This mirrors the desktop zap / TUI Shift+Tab: session-only approval
    /// bypass, never a persistent global config write.
    @discardableResult
    func sessionSetYolo(_ enabled: Bool, sessionId: String) async throws -> Bool {
        let result = try await client.requestRaw(
            "config.set",
            params: .object([
                "key": .string("yolo"),
                "value": .string(enabled ? "1" : "0"),
                "session_id": .string(sessionId),
            ]),
            timeout: .seconds(30)
        )
        let active = result["value"]?.stringValue == "1"
        sessionYolo = active
        return active
    }

    /// Send `config.set` for the GLOBAL default reasoning effort (no session_id).
    func globalSetReasoning(_ effort: String) async throws {
        _ = try await client.requestRaw(
            "config.set",
            params: .object([
                "key": .string("reasoning"),
                "value": .string(effort),
            ]),
            timeout: .seconds(30)
        )
    }

    /// Send `config.set` for the GLOBAL default fast mode (no session_id).
    func globalSetFast(_ enabled: Bool) async throws {
        _ = try await client.requestRaw(
            "config.set",
            params: .object([
                "key": .string("fast"),
                "value": .string(enabled ? "fast" : "normal"),
            ]),
            timeout: .seconds(30)
        )
    }

    /// Send `config.set` with `key="yolo"` and `scope="global"`.
    /// This intentionally flips the persistent approval-bypass mode for every
    /// session, matching the desktop zap's escalation gesture.
    @discardableResult
    func globalSetYolo(_ enabled: Bool) async throws -> Bool {
        let result = try await client.requestRaw(
            "config.set",
            params: .object([
                "key": .string("yolo"),
                "scope": .string("global"),
                "value": .string(enabled ? "1" : "0"),
            ]),
            timeout: .seconds(30)
        )
        let active = result["value"]?.stringValue == "1"
        sessionYolo = active
        return active
    }

    /// Number of consecutive auth-rejection probes seen by the reconnect loop.
    /// Used so a single transient 401 (e.g. a token-rotation race on the host)
    /// doesn't immediately bounce a live session to re-pair; we only flip after
    /// the failure is confirmed on the dedicated re-probe.
    private var consecutiveReconnectFailures = 0
    /// After this many consecutive WS reconnect failures, the loop re-probes REST
    /// to distinguish an auth revocation (→ re-pair) from plain unreachability
    /// (→ keep retrying).
    private static let authReprobeThreshold = 3

    /// Hard ceiling on the branded `.hydrating` loading screen (ABH-82). The
    /// post-connect hydration (session-list refresh + running-model probe) races
    /// against this timeout; whichever finishes first flips the phase to
    /// `.connected`, so a slow or hung probe can NEVER strand the user on the
    /// loading screen. Kept as a named constant so the test can pin it.
    static let hydrationTimeout: Duration = .seconds(8)

    /// Silent-reconnect grace window for a transport drop DURING an active
    /// session (`.closed`/`.failed` after `hasConnected`) — STR-973A. The
    /// reconnect loop runs immediately and silently against this window; only
    /// if every attempt still fails once it elapses do we surface the drop
    /// (transcript warning + a visible `.reconnecting` phase). Named so the
    /// test can pin it. See `handle(state:)` / `startGraceWindow`.
    static let transientGraceWindow: Duration = .seconds(10)

    /// Silent-reconnect grace window for a dead socket found on a cold app
    /// open / foreground (as opposed to a drop witnessed live) — STR-973A.
    /// Shorter than `transientGraceWindow`: a cold-open dead socket is far
    /// more often a stale-suspend reconnect than a real outage. Used by the
    /// foreground/cold-open detection path in `handleScenePhase`. Named so the
    /// test can pin it.
    static let coldOpenGraceWindow: Duration = .seconds(5)

    /// Hard ceiling for a cold push tap that arrives before bootstrap/configure
    /// has made REST/WS usable. The tap path must wait long enough for normal
    /// cold launch bootstrap, but unconfigured/offline installs cannot hang.
    static let pushTapReadinessTimeout: Duration = .seconds(10)

    /// The single, long-lived gateway client.
    let client = HermesGatewayClient()

    /// Wave-2 relay transport bridge (docs/RELAY-PHONE-PROTOCOL.md). Owns the
    /// live `RelayClient` and projects its item stream into the transcript. Only
    /// created when ``transportPath`` resolves to `.relay` (default OFF = the
    /// gateway `client` above is used instead), so the gateway-direct path never
    /// allocates it. Read via ``ensureRelayCoordinator()``.
    private(set) var relayCoordinator: RelaySessionCoordinator?

    /// Test seam: inject a coordinator wired to a mock relay before `configure`.
    #if DEBUG
    var relayCoordinatorFactory: (() -> RelaySessionCoordinator)?
    #endif

    /// Lazily build (once) and return the relay bridge for the active chat store.
    @discardableResult
    func ensureRelayCoordinator() -> RelaySessionCoordinator {
        if let relayCoordinator { return relayCoordinator }
        #if DEBUG
        let created = relayCoordinatorFactory?() ?? RelaySessionCoordinator(chatStore: chatStore)
        #else
        let created = RelaySessionCoordinator(chatStore: chatStore)
        #endif
        // When the relay socket comes up (initial connect OR a reconnect after a
        // drop/flap), drain the durable outbox over the relay — the relay
        // analogue of `setTransportReadiness(.ready)`'s wake on the gateway path.
        // Without this, a prompt the user queued while the relay was mid-connect
        // stays pending until some unrelated wake source fires.
        //
        // QA-2 R1: ALSO re-trigger APNs registration. The launch-time register
        // attempt can race the socket (coordinator not yet up → `.hardFail` →
        // nothing retried until the next launch/foreground); the relay-ready
        // edge is the deterministic re-wake. `enableIfAllowed()` is idempotent:
        // the registrar's dedupe skips the POST when the relay register already
        // succeeded, and the transport-scoped registration identity forces a
        // re-POST when the previous success was on the direct path.
        created.onReady = { [weak self] in
            self?.queueStore?.wake()
            Task { @MainActor in
                PushRegistrar.shared.enableIfAllowed()
            }
        }
        // Bridge relay socket state → the app's `phase` so the banner + composer
        // reflect the REAL connection, not a stale startup stamp. Without this the
        // UI is frozen at `.connected` even when the relay drops and recovers.
        created.onPhaseChange = { [weak self] relayPhase in
            guard let self else { return }
            switch relayPhase {
            case .idle, .connecting:
                self.phase = .connecting
            case .open:
                self.phase = .connected
            case .closed(let reason):
                // Intentional teardown (reason == nil) → about to reconnect via
                // start(); unexpected close → offline with the reason.
                self.phase = reason == nil ? .connecting : .offline(reason)
            case .failed:
                // The coordinator's auto-reconnect driver is armed; surface as
                // reconnecting so the banner shows "reconnecting" not "offline".
                self.phase = .reconnecting(attempt: 0)
            }
        }
        relayCoordinator = created
        return created
    }

    /// The composer "+" visibility gate (B9 / A5). On the relay transport the
    /// attach flows ride the relay WS `attach` RPC (relay → gateway
    /// `file.attach` / `image.attach_bytes`, bytes inlined — see
    /// ``AttachmentStore``), so the gateway-REST upload probe NEVER gets to
    /// hide the menu: a probe against an unreachable — or stock — gateway REST
    /// 404s the upload route and would pin "+" hidden for the whole build
    /// (exactly the B9 regression on the owner's relay-mode phone). The relay
    /// is the source of truth for what the relay transport can do. Direct mode
    /// keeps the E1 probe gate BYTE-FOR-BYTE: `.unavailable` hides (stock
    /// gateway), `.unknown`/`.available` show (optimistic).
    var attachMenuAvailable: Bool {
        transportPath == .relay || capabilities.upload != .unavailable
    }

    /// The selected transport (Wave-2 convergence). Default `.gatewayDirect`
    /// (OFF) — byte-identical to every existing install. In DEBUG a launch env
    /// override (`HERMES_TRANSPORT=relay`, or the presence of `HERMES_RELAY_URL`)
    /// forces `.relay` for the simulator E2E WITHOUT a Settings round-trip; the
    /// override is DEBUG-only so a release build can never be flipped by env.
    var transportPath: TransportPath {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let requested = env["HERMES_TRANSPORT"]?.lowercased() {
            if requested == "relay" { return .relay }
            if requested == "gatewaydirect" || requested == "direct" { return .gatewayDirect }
        }
        if env["HERMES_RELAY_URL"] != nil {
            return .relay
        }
        #endif
        return DefaultsKeys.transportPathValue()
    }

    /// Base address for the transparent stock-protocol lane. The existing relay
    /// override selects the proxy host; without one, direct gateway behavior is
    /// preserved during the Phase 2 rollout.
    func stockProxyURL(forGateway gatewayURL: URL) -> URL {
        let rawOverride: String?
        #if DEBUG
        rawOverride = ProcessInfo.processInfo.environment["HERMES_RELAY_URL"]
            ?? DefaultsKeys.relayURLOverrideValue()
        #else
        rawOverride = DefaultsKeys.relayURLOverrideValue()
        #endif
        guard let rawOverride,
              let override = URL(string: rawOverride),
              var components = URLComponents(url: override, resolvingAgainstBaseURL: false)
        else { return gatewayURL }
        components.scheme = override.scheme == "wss" ? "https" : "http"
        components.path = ""
        components.queryItems = nil
        return components.url ?? gatewayURL
    }

    /// The relay WS URL to dial when ``transportPath`` is `.relay`. Precedence:
    /// (1) in DEBUG the `HERMES_RELAY_URL` env var wins (the simulator E2E points
    /// the app at the isolated relay without a Settings round-trip); (2) an
    /// explicit relay URL the user typed in Settings (`DefaultsKeys.relayURLOverride`)
    /// — the on-device equivalent of the env var, so the phone can dial a relay
    /// that is not co-located with the gateway (e.g. a Mac on the tailnet); (3)
    /// otherwise derive from the gateway base URL (http→ws, https→wss) with the
    /// ratified `/relay` path (§1).
    func relayURL(forGateway gatewayURL: URL) -> URL? {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["HERMES_RELAY_URL"],
           let override = URL(string: raw) {
            return override
        }
        #endif
        if let raw = DefaultsKeys.relayURLOverrideValue(),
           let override = URL(string: raw) {
            return override
        }
        var components = URLComponents(url: gatewayURL, resolvingAgainstBaseURL: false)
        components?.scheme = gatewayURL.scheme == "https" ? "wss" : "ws"
        components?.path = "/relay"
        components?.queryItems = nil
        return components?.url
    }

    /// HTTP sibling of the relay WebSocket, used only for relay-owned truth.
    func relayControlURL(forGateway gatewayURL: URL) -> URL? {
        guard transportPath == .relay,
              let relayURL = relayURL(forGateway: gatewayURL),
              var components = URLComponents(url: relayURL, resolvingAgainstBaseURL: false)
        else { return nil }
        components.scheme = relayURL.scheme == "wss" ? "https" : "http"
        components.path = ""
        components.queryItems = nil
        return components.url
    }

    /// Test seam mirroring ``connectRPC``: when set, the relay-transport branch of
    /// `configure` calls this instead of `relayCoordinator.start` so a test can
    /// assert the relay path was selected without a live socket. `nil` in
    /// production.
    #if DEBUG
    var relayConnectHook: ((_ relayURL: URL, _ token: String) async throws -> Void)?
    #endif

    /// The accepted transport generation. Runtime bindings use this value to
    /// reject work produced by a prior socket after reconnect.
    private(set) var transportEpoch: UInt64 = 0

    /// The authoritative operational state for WebSocket RPC admission.
    private(set) var transportReadiness: TransportReadiness = .unconfigured

    /// `true` only after the current socket has completed `gateway.ready` and
    /// while no presentation-grace window is masking a dropped transport.
    var isTransportReady: Bool {
        guard !isInGrace else { return false }
        // Wave-2 relay transport: the durable outbox drains OVER THE RELAY on this
        // path (the gateway `client` is idle), so admission must track the RELAY
        // socket, not the one-shot `transportReadiness` the initial configure
        // stamped. `relayCoordinator.isOpen` closes the drain gate the instant the
        // relay drops (a flap) and reopens it on reconnect — so a send during the
        // flap enqueues quietly and drains once the relay is live again, rather
        // than churning failed submits against a dead socket. Gated on the
        // coordinator existing first: the gateway-direct default NEVER allocates
        // it, so that path does not even read the flag and stays byte-identical.
        if relayCoordinator != nil, transportPath == .relay {
            return relayCoordinator?.isOpen ?? false
        }
        if case .ready = transportReadiness { return true }
        return false
    }

    /// Which branch-only server features the connected gateway supports (E1).
    /// Probed after a successful configure/connect; views gate on it so one
    /// binary degrades gracefully against a stock hermes-agent. Owned here so the
    /// app has a single instance to read and (via the router) feed passive
    /// signals into.
    let capabilities = ServerCapabilities()

    /// A REST client built from the saved URL + token, or `nil` if unconfigured.
    /// Speaks the path family the capability probe resolved (ABH-88) — `.legacy`
    /// until/unless the plugin-mount probe concludes `.available`.
    var rest: RestClient? {
        #if DEBUG
        // Test-only: a seeded override short-circuits the URL+token build so a
        // stub `URLSession` can observe/no-op the calls made through `rest`
        // (e.g. reconnect probes and the device auto-upgrade round-trip). See
        // `_restOverrideForTesting`.
        if let _restOverrideForTesting { return _restOverrideForTesting }
        #endif
        guard let url = URL(string: serverURLString), let token = currentToken else { return nil }
        let baseURL = transportPath == .gatewayDirect ? stockProxyURL(forGateway: url) : url
        return RestClient(
            baseURL: baseURL, token: token, pathStyle: capabilities.resolvedPathStyle,
            relayControlBaseURL: relayControlURL(forGateway: url)
        )
    }

    /// Declare which stored session this phone is visibly watching. The plugin
    /// keeps this ephemeral and clears it when the authenticated socket drops.
    func updatePhoneForeground(_ storedSessionId: String?) {
        guard transportPath == .gatewayDirect, let rest else { return }
        let previous = phoneForegroundUpdateTask
        phoneForegroundUpdateTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            try? await rest.setDeviceForeground(storedSessionId: storedSessionId)
        }
    }

    /// Wait until session-list refresh has a usable transport, or until the
    /// connection has reached a terminal not-ready state / timeout.
    ///
    /// This is deliberately narrower than full hydration: push-tap resolution only
    /// needs REST (preferred by `SessionStore.refresh`) or an open WS client to
    /// fetch `session.list`. A verified `configure()` stamps `serverURLString` and
    /// `currentToken` before `.hydrating`, so `rest != nil` is enough to let the
    /// miss path refresh without waiting for the branded loading screen to finish.
    func waitUntilSessionRefreshReady(
        timeout: Duration = ConnectionStore.pushTapReadinessTimeout
    ) async -> Bool {
        #if DEBUG
        if let sessionRefreshReadinessOverride {
            return await sessionRefreshReadinessOverride()
        }
        #endif
        if await isSessionRefreshReady() { return true }
        if isTerminallyNotReadyForSessionRefresh { return false }

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            if Task.isCancelled { return }
            await self?.notifyReadinessWaiters()
        }
        await waitForReadinessChange()
        timeoutTask.cancel()

        return await isSessionRefreshReady()
    }

    private func isSessionRefreshReady() async -> Bool {
        if rest != nil { return true }
        return await client.state == .open
    }

    private var isTerminallyNotReadyForSessionRefresh: Bool {
        switch phase {
        case .needsSetup, .offline:
            return true
        case .connecting, .hydrating, .connected, .reconnecting:
            return false
        }
    }

    private func waitForReadinessChange() async {
        await withCheckedContinuation { continuation in
            readinessWaiters.append(continuation)
        }
    }

    private func notifyReadinessWaiters() {
        guard !readinessWaiters.isEmpty else { return }
        let waiters = readinessWaiters
        readinessWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// A ``RestClient`` for the control-surface panels (model / personality /
    /// usage / cron / skills — now ``RestClient`` extension members), built from
    /// the same saved URL + token as `rest`, or `nil` if unconfigured.
    var control: RestClient? {
        #if DEBUG
        // Test-only: same seam as `rest` (see `_restOverrideForTesting`) so the
        // control-surface client is equally stubbable in unit tests.
        if let _restOverrideForTesting { return _restOverrideForTesting }
        #endif
        guard let url = URL(string: serverURLString), let token = currentToken else { return nil }
        let baseURL = transportPath == .gatewayDirect ? stockProxyURL(forGateway: url) : url
        return RestClient(
            baseURL: baseURL, token: token, pathStyle: capabilities.resolvedPathStyle
        )
    }

    #if DEBUG
    /// Test-only override: when set, `rest`/`control` return this client instead
    /// of building one from the saved URL + token, so a stub `URLSession`
    /// (`URLProtocol`-injected) can observe/no-op the requests they issue —
    /// in particular the reconnect-path probes inside `recoverActiveSession()`
    /// (`capabilities.probe`, `autoUpgradeToDeviceTokenIfNeeded`) and the
    /// auto-upgrade `issueDevice` round-trip, which are
    /// otherwise routed through an internal `.ephemeral` session that no
    /// `URLProtocol` can intercept, and which leak real network calls to a
    /// dead loopback gateway on a CI runner with no server (STR-1481). Mirrors
    /// the existing `_seed…ForTesting` conventions; compiled out of Release,
    /// so there is no production surface and no secret exposure (the stub
    /// client's session and token are entirely test-injected).
    var _restOverrideForTesting: RestClient?
    #endif

    /// The persistent prompt outbox/queue. Drained here after reconnect backfill.
    /// Wired by `AppEnvironment` (ChatStore holds no reference to it).
    weak var queueStore: QueueStore?

    /// The global approval/clarification inbox. The event router fans the
    /// broadcast prompt events to it (in addition to `ChatStore`) so pending
    /// requests from every session collect in one place. Wired by
    /// `AppEnvironment`; `ChatStore` holds no reference to it.
    weak var inboxStore: InboxStore?

    /// The one offline cache instance, wired by AppEnvironment for scoped forget.
    weak var cacheStore: CacheStore?

    private let sessionStore: SessionStore
    private let chatStore: ChatStore

    /// The token for the active connection (kept in memory; also in Keychain).
    private var currentToken: String?
    /// Monotonic ownership token for every connection lifecycle. Any task that
    /// crosses an await captures this value and must revalidate it before it can
    /// publish connection state or schedule more work. Configure and every
    /// terminal transition advance it, permanently fencing continuations that
    /// belonged to the prior gateway.
    private var connectionGeneration: UInt64 = 0
    private var readinessWaiters: [CheckedContinuation<Void, Never>] = []
    private var transportReadinessWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var transportReadinessTimeouts: [UUID: Task<Void, Never>] = [:]

    @discardableResult
    private func advanceConnectionGeneration() -> UInt64 {
        connectionGeneration &+= 1
        setTransportReadiness(.unconfigured, resolveWaiters: true)
        sessionStore.transportDidBecomeUnavailable()
        sessionStore.invalidateConnectionWork()
        // WS-RECONNECT-SOFTEN (a): a genuinely new connection lifecycle (fresh
        // bootstrap/configure, explicit reconnect-to-new-server) deserves an
        // unthrottled first forced capability re-probe; only repeated attempts
        // WITHIN the same lifecycle's reconnect loop should be throttled.
        lastForcedCapabilitiesProbeAt = nil
        return connectionGeneration
    }

    /// Wait for an operationally-ready WebSocket. A visible `.connected` phase
    /// during silent grace intentionally does not satisfy this contract.
    ///
    /// Waiters survive transient `.unavailable → .connecting` retries. They end
    /// only on readiness, a terminal setup/auth state, cancellation, timeout, or
    /// replacement of the owning connection generation.
    func waitForTransportReady(timeout: Duration) async -> Bool {
        if isTransportReady { return true }
        if isTransportTerminal { return false }

        let id = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                guard !self.isTransportReady, !self.isTransportTerminal else {
                    continuation.resume(returning: self.isTransportReady)
                    return
                }

                self.transportReadinessWaiters[id] = continuation
                self.transportReadinessTimeouts[id] = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    self?.resolveTransportReadinessWaiter(id: id, with: false)
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.resolveTransportReadinessWaiter(id: id, with: false)
            }
        })
    }

    private var isTransportTerminal: Bool {
        if reauthRequired { return true }
        switch phase {
        case .needsSetup, .offline:
            return true
        case .connecting, .hydrating, .connected, .reconnecting:
            return false
        }
    }

    /// `true` while the reconnect loop's `client.connect(...)` handshake for
    /// the CURRENT attempt is actively in flight — i.e. `beginTransportAttempt()`
    /// has reserved an epoch but it has not yet been accepted or failed.
    ///
    /// WS-RECONNECT-SOFTEN (b) — single-flight reconnect across triggers: a
    /// foreground wake, a network-path-satisfied event, and the loop's own
    /// backoff timer can all want to "kick" a fresh attempt. Cancelling and
    /// restarting the loop while a handshake is genuinely mid-flight aborts
    /// that handshake and restarts from attempt 0 — if two triggers fire in
    /// close succession (e.g. a flapping path during a foreground app-switch)
    /// this can repeatedly abort an attempt just before it would have
    /// succeeded, livelocking reconnection during exactly the flappy window
    /// these triggers exist to help. Callers that want to reset a PARKED loop
    /// (idling in backoff) still may; only an in-flight handshake is protected.
    private var isReconnectHandshakeInFlight: Bool {
        if case .connecting = transportReadiness { return true }
        return false
    }

    private func beginTransportAttempt() {
        // Reserve the next epoch for this handshake, but do not publish it as
        // accepted until `gateway.ready` has completed. Failed retries therefore
        // never create a runtime epoch that callers could bind to.
        let candidateEpoch = transportEpoch &+ 1
        ReliabilityDiagnostics.shared.websocketConnect(epoch: candidateEpoch)
        setTransportReadiness(.connecting(epoch: candidateEpoch))
    }

    private func acceptCurrentTransport() {
        guard case .connecting(let epoch) = transportReadiness,
              epoch == transportEpoch &+ 1 else { return }
        transportEpoch = epoch
        ReliabilityDiagnostics.shared.websocketReady(epoch: epoch)
        setTransportReadiness(.ready(epoch: epoch), resolveWaiters: true)
    }

    private func markTransportUnavailable() {
        switch transportReadiness {
        case .ready(let epoch), .connecting(let epoch), .unavailable(let epoch):
            ReliabilityDiagnostics.shared.websocketClose(epoch: epoch)
            setTransportReadiness(.unavailable(epoch: epoch))
            // The stored selection survives grace/reconnect, but its runtime id
            // was minted by the dropped socket and is no longer admissible.
            sessionStore.transportDidBecomeUnavailable()
        case .unconfigured, .reauthRequired:
            break
        }
    }

    private func requireTransportReauthentication() {
        setTransportReadiness(.reauthRequired, resolveWaiters: true)
    }

    private func setTransportReadiness(
        _ readiness: TransportReadiness,
        resolveWaiters: Bool = false
    ) {
        transportReadiness = readiness
        if resolveWaiters {
            let result: Bool
            if case .ready = readiness {
                result = true
            } else {
                result = false
            }
            resolveAllTransportReadinessWaiters(with: result)
        }
        if case .ready = readiness {
            // A fresh transport permit must kick the durable outbox immediately.
            // The drain gate is edge-triggered, not polled — without this wake a
            // queued prompt would idle until the next unrelated wake source fired.
            queueStore?.wake()
        }
    }

    private func resolveTransportReadinessWaiter(id: UUID, with result: Bool) {
        transportReadinessTimeouts.removeValue(forKey: id)?.cancel()
        transportReadinessWaiters.removeValue(forKey: id)?.resume(returning: result)
    }

    private func resolveAllTransportReadinessWaiters(with result: Bool) {
        let waiters = transportReadinessWaiters
        transportReadinessWaiters.removeAll()
        let timeouts = transportReadinessTimeouts
        transportReadinessTimeouts.removeAll()
        timeouts.values.forEach { $0.cancel() }
        waiters.values.forEach { $0.resume(returning: result) }
    }

    private func isCurrentGeneration(_ generation: UInt64) -> Bool {
        generation == connectionGeneration
    }

    private func isActiveGeneration(_ generation: UInt64) -> Bool {
        guard isCurrentGeneration(generation), hasConnected, !reauthRequired else { return false }
        switch phase {
        case .needsSetup, .offline: return false
        case .connecting, .hydrating, .connected, .reconnecting: return true
        }
    }

    /// Servers where `POST /devices/issue` hit the device registry cap during
    /// this app run. A 409 is permanent until a device is revoked, so automatic
    /// reconnect/recover probes should not hammer it repeatedly in silence. The
    /// existing banner retry path calls `configure()` again, which clears the
    /// marker for an explicit user re-attempt after cleanup.
    private var deviceIssueLimitReachedServers = Set<String>()

    /// Per-server single-flight guard for silent shared-token → device-token
    /// upgrades (STR-546/STR-512). Multiple reconnect/configure paths can
    /// overlap for the same active server; only one `/devices/issue` request
    /// may be in flight for a server at a time, and joiners await that same
    /// operation instead of minting a second device token. Cleared on every
    /// exit path (success, typed 409, generic failure, Keychain-write
    /// failure) so a later legitimate retry is never permanently suppressed.
    private var autoUpgradeIssueTasks: [String: Task<IssuedDevice, Error>] = [:]

    /// WS-RECONNECT-SOFTEN (a) — delay before `recoverActiveSession`'s
    /// background capability/profile/auto-upgrade burst fires after a
    /// (re)connect, so it lands slightly AFTER the user-visible hydration
    /// calls (model refresh, session resume, transcript backfill, session-list
    /// refresh) rather than in the exact same instant. Nothing on the
    /// user-visible path awaits this task, so the delay is invisible to the
    /// user; it only spreads out the REST load a just-recovered gateway sees.
    private static let backgroundCapabilityBurstStagger: Duration = .milliseconds(300)

    /// WS-RECONNECT-SOFTEN (a) — minimum spacing between FORCED capability
    /// re-probes across reconnects. A forced re-probe fires 5 concurrent REST
    /// calls (`pluginMount`, then `upload`/`fs`/`profiles`/`devices`) — needed
    /// once per genuine drop (the gateway may have restarted on a different
    /// build), but firing it on EVERY attempt of a rapid reconnect crash-loop
    /// piles five requests onto a server that is already struggling to come
    /// up. See the throttle at the `recoverActiveSession` call site.
    private static let capabilitiesReprobeMinInterval: Duration = .seconds(20)

    /// The `ContinuousClock` instant of the last FORCED capabilities re-probe
    /// this connection generation issued, or `nil` before the first one.
    /// Reset alongside every other per-connection generation state.
    private var lastForcedCapabilitiesProbeAt: ContinuousClock.Instant?

    /// Injectable connect implementation (tests). When non-nil the reconnect
    /// loop calls this closure instead of `client.connect(...)` — the same
    /// pattern as `SessionStore.resumeRPC`. Defaults to `nil`; the live path
    /// is taken in production (the nil-check is free). Set by unit tests to
    /// make the loop deterministic without a live socket.
    var connectRPC: ((_ url: URL, _ token: String, _ mode: ConnectionMode) async throws -> Void)?

    #if DEBUG
    /// DEBUG-only test seam for deterministic single-flight auto-upgrade tests
    /// (STR-546): when non-nil, replaces the live `rest.issueDevice(name:)`
    /// call so a test can delay/observe the issue round-trip without a live
    /// server (e.g. suspend it to prove two overlapping callers share one
    /// invocation). `nil` in production (the nil-check is free).
    var issueDeviceRPC: (@Sendable (_ rest: RestClient, _ name: String) async throws -> IssuedDevice)?
    #endif

    #if DEBUG
    /// Injectable configure status probe (tests). When non-nil, replaces the live
    /// `RestClient.status()` call so unit tests can exercise verified configure
    /// persistence without a gateway.
    var statusRPC: ((_ url: URL, _ token: String) async throws -> Void)?

    /// Injectable push-tap readiness result (tests). When non-nil, replaces the
    /// live phase/transport wait so notification routing tests can deterministically
    /// model cold-ready and cold-offline launches without sleeping for the timeout.
    var sessionRefreshReadinessOverride: (() async -> Bool)?

    /// Injectable auth-revoke probe (tests). When non-nil, replaces the live
    /// `probeIsAuthRevoked` REST call with this closure's return value so unit
    /// tests can drive the threshold → `reauthRequired` flip without a server.
    /// `nil` in production (the nil-check is free). Pattern mirrors `connectRPC`.
    var probeIsAuthRevokedRPC: (() async -> Bool)?

    /// Injectable backoff override (tests). When non-nil, `backoffDelay(attempt:)`
    /// returns this value instead of the exponential schedule, so tests that
    /// must drive multiple consecutive failures (threshold ≥ 3) do not stall
    /// for seconds of wall-clock time. `nil` = normal exponential schedule.
    var reconnectBackoffOverride: Double?

    /// Injectable grace-window override (tests). When non-nil, `startGraceWindow`
    /// uses this value instead of `transientGraceWindow`/`coldOpenGraceWindow` so
    /// expiry tests don't burn real wall-clock time. `nil` = the named windows.
    /// Pattern mirrors `reconnectBackoffOverride`.
    var graceWindowOverride: Duration?

    /// Injectable stagger override (tests, WS-RECONNECT-SOFTEN a). When non-nil,
    /// `recoverActiveSession`'s background capability-probe burst sleeps this long
    /// instead of `backgroundCapabilityBurstStagger` before firing, so a test can
    /// drive it to `.zero` (fire immediately, deterministic ordering) or an
    /// unreachably long value (prove it never fires within the test's window).
    /// `nil` = the real 300ms stagger.
    var backgroundCapabilityBurstStaggerOverride: Duration?

    /// Injectable throttle override (tests, WS-RECONNECT-SOFTEN a). When non-nil,
    /// replaces `capabilitiesReprobeMinInterval` — the minimum spacing between
    /// FORCED capability re-probes across reconnects — so a test can prove
    /// suppression (a large value) or the always-force baseline (`.zero`)
    /// without waiting out the real 20s window. `nil` = the real interval.
    var capabilitiesReprobeMinIntervalOverride: Duration?

    /// Injectable liveness probe (tests). When non-nil, replaces the live
    /// `client.probeLiveness()` call in `handleScenePhase` with this closure's
    /// return value so unit tests can drive the dead-socket routing path without
    /// needing to inject a full mock transport into the store's own client (which
    /// is `let`/init-time). A `false` result exercises the full detection →
    /// reconcile → reconnect routing. Pattern mirrors `connectRPC`/`steerRPC`.
    var probeLivenessRPC: ((_ timeout: Duration) async -> Bool)?

    /// Injectable socket-state override for `handleScenePhase` (tests). When
    /// non-nil, `handleScenePhase` uses this value instead of reading
    /// `client.state` — which is not injectable because `client` is a `let`
    /// property created at init time. Allows the `dead` branch (socket
    /// `.closed`/`.failed`) to be exercised without a real transport. Pattern
    /// mirrors `probeLivenessRPC`.
    var clientStateOverrideForScenePhase: GatewayConnectionState?

    /// Retains the most recent reconnect `Task` even after completion, so tests
    /// can `await waitForReconnectForTesting()` to deterministically block until
    /// the loop exits rather than racing a fixed `Task.sleep`. Unlike
    /// `reconnectTask` (niled on completion inside the task), this is only
    /// written — never cleared — so `await value` resolves once and only once.
    var lastReconnectTask: Task<Void, Never>?
    func waitForReconnectForTesting() async { await lastReconnectTask?.value }

    /// Injectable path monitor (tests). When non-nil, `startPathMonitor()` wires
    /// this fake instead of building a live `NWPathMonitor` adapter, so path
    /// transitions can be emitted deterministically without real hardware.
    /// Pattern mirrors `connectRPC`/`probeLivenessRPC`. `nil` in production.
    var _pathMonitorForTesting: NetworkPathMonitoring?

    /// Injectable network-reconnect debounce (tests). When non-nil, the
    /// path-satisfied trigger uses this instead of `networkReconnectDebounce` so
    /// flapping/single-attempt tests don't wait a real second.
    var networkReconnectDebounceOverride: Duration?

    /// Test seam: wire + start the path monitor without going through a full
    /// `configure()` (used by the already-connected no-op test, which seeds the
    /// connected state directly).
    func _startPathMonitorForTesting() { startPathMonitor() }

    /// Test observability: whether a path monitor is currently armed.
    var _pathMonitorIsRunningForTesting: Bool { pathMonitor != nil }
    #endif

    /// Tasks that live as long as the client: the event router and the
    /// state-change observer. Started once on the first successful configure.
    private var eventRouterTask: Task<Void, Never>?
    private var stateObserverTask: Task<Void, Never>?
    /// Pending coalesced session-list refresh (ABH-86 item 1). Cancelled and
    /// replaced whenever a new message.start / message.complete arrives during
    /// the debounce window; only the trailing edge fires the actual `refresh()`.
    /// Both the event-router path (streaming frames) and the foreground path
    /// (`handleScenePhase`) share this single task slot so concurrent triggers
    /// collapse to one fetch rather than piling up.
    private var sessionRefreshDebounceTask: Task<Void, Never>?
    /// Debounce interval for the coalesced session refresh (ABH-86 item 1).
    private static let sessionRefreshDebounceMs: Int = 400
    /// FIX 5 — WS intake yield budget. The event router drains an UNBOUNDED stream
    /// on the main actor; a queued frame burst (a long agentic turn, a reconnect
    /// backfill colliding with a live stream) would otherwise hold the main actor
    /// back-to-back with NO runloop turn between frames, freezing UIKit for the
    /// burst's duration. After each `route()` returns, the loop yields the main actor
    /// once a contiguous wall-clock budget is exceeded OR every `intakeYieldEveryK`
    /// frames — converting one long hold into many short ones BY CONSTRUCTION (a yield
    /// point, not timing luck), giving UIKit a runloop turn mid-burst. The stream stays
    /// UNBOUNDED (lossless — no frame is dropped); only the HOLD is capped.
    private static let intakeYieldBudget: Duration = .milliseconds(8)
    /// Hard frame-count ceiling between yields, as a floor under the wall-clock budget
    /// (so a run of cheap frames still yields periodically even if it never crosses the
    /// time budget). Bursts of expensive frames cross the time budget first.
    private static let intakeYieldEveryK = 32
    /// The in-flight reconnect loop, if any. The setter remains store-owned;
    /// internal read access keeps reconnect-race tests able to assert teardown.
    private(set) var reconnectTask: Task<Void, Never>?
    /// The in-flight silent-grace timer, if any (STR-973A). Races the reconnect
    /// loop's attempts: cancelled the moment an attempt succeeds (or the loop
    /// exits for any other reason — auth revoke, vanished config) so a stale
    /// timer can never fire after the phase has already resolved; left to fire
    /// on its own if every attempt is still failing when it elapses, which
    /// escalates to the visible drop (see `startGraceWindow`/`endGrace`/
    /// `escalateGraceExpiry`).
    /// Read visibility mirrors `reconnectTask`: current reconnect teardown is
    /// complete only when both the retry loop and silent-grace timer are gone.
    private(set) var graceTask: Task<Void, Never>?
    /// True while a drop is being retried silently within the grace window
    /// (STR-973A) — `phase` stays `.connected` and `ChatStore`/`SessionStore`
    /// are NOT told the connection dropped, so an in-flight turn is never
    /// stranded or stomped by a blip that heals inside the window. Flipped
    /// false the moment grace ends, whether by healing or by expiry-escalation.
    /// `private(set)` so `ChatStore.send()` can route a fresh send to the
    /// outbox instead of surfacing a live-socket failure during grace.
    private(set) var isInGrace = false
    /// The reconnect loop's current attempt index, updated every iteration.
    /// `escalateGraceExpiry()` reads this to stamp the visible `.reconnecting`
    /// phase immediately at expiry, rather than waiting for the loop's next
    /// iteration (which could be a full backoff delay away).
    private var currentReconnectAttempt = 0

    // MARK: - Network path monitoring (S3 — self-reconnect)

    /// The single network-path monitor owned by this store (S3). Started in
    /// `configure()` — so even a cold-launch-offline configure whose REST probe
    /// fails (`phase = .offline`, `hasConnected == false`) leaves a live monitor
    /// armed — and torn down in `stopLiveWork()` (disconnect / forget / explicit
    /// offline). When the path transitions to `.satisfied` while we are stalled
    /// (`.offline` or `.reconnecting`), it kicks the EXISTING reconnect entry
    /// point (`startReconnectLoop`, or `bootstrap()` for the cold case) behind a
    /// debounce — it never invents a new connect path.
    private var pathMonitor: NetworkPathMonitoring?
    /// Debounced trailing-edge trigger for a path-satisfied reconnect. Cancelled
    /// and replaced on every fresh `.satisfied`, so a rapidly flapping path
    /// (satisfied/unsatisfied/satisfied…) collapses to a SINGLE reconnect attempt.
    private var networkReconnectDebounceTask: Task<Void, Never>?
    /// Debounce window between a `.satisfied` path event and the reconnect kick.
    /// Short enough to feel instant, long enough to absorb interface flapping
    /// (Wi-Fi↔cellular handoff, VPN re-handshake) into one attempt.
    private static let networkReconnectDebounce: Duration = .seconds(1)

    /// The in-flight post-connect hydration coordinator, if any (ABH-82). Owns
    /// the `.hydrating → .connected` transition and the timeout fallback;
    /// cancelled on disconnect so a teardown mid-hydration can't later flip the
    /// phase back to `.connected`.
    private var hydrationTask: Task<Void, Never>?
    /// Whether the session-list `refresh()` kicked off in ``startHydration`` actually
    /// COMPLETED, vs being cancelled by the hard-`hydrationTimeout` race. For a large
    /// account the list pull (hundreds/thousands of sessions) reliably loses the 8s
    /// race, so the refresh is cancelled and the drawer is left on STALE cache even
    /// though the phase flips to `.connected` (reported: cold-launch sessions stuck at
    /// an old timestamp, new messages not visible). ``finishHydration`` re-fires the
    /// refresh in the background when this is false — the same safety net the running-
    /// model probe already has.
    private var hydrationRefreshCompleted = false
    /// True once a connection has been established at least once, so that a
    /// later `.closed`/`.failed` should trigger reconnection rather than be
    /// treated as a clean initial idle state.
    ///
    /// ALSO the routing discriminator the shell needs (ABH-82 follow-up): a
    /// `.connecting`/`.offline` phase means very different things before vs.
    /// after a verified connection. BEFORE — a manual/QR `configure` that failed
    /// validation (bad URL, unreachable host, transport error). The user must
    /// stay in onboarding with the inline error, NOT be dropped into the chat
    /// shell. AFTER — a live session that dropped → the shell with an offline
    /// banner + reconnect loop. `RootView` reads this so an invalid credential
    /// can never ride a non-`.needsSetup` failure phase into the main UI.
    /// `private(set)` so the view can read it but only the store mutates it.
    private(set) var hasConnected = false

    /// True only while the launch `bootstrap()` is resolving a SAVED config
    /// (UserDefaults URL + Keychain token, or the dev-env override). During this
    /// window `hasConnected` is still `false` (the reconnect hasn't completed)
    /// yet the user is a RETURNING user, not someone in first-run setup — so the
    /// shell should show the launch splash (chat shell + offline/connecting
    /// banner) rather than flashing `WelcomeView`. Set around the saved-config
    /// `configure` call in `bootstrap()` and cleared when it returns. A first-run
    /// launch (no saved config) never sets this, so it falls straight through to
    /// `.needsSetup` → `WelcomeView`. (ABH-82 follow-up.)
    private(set) var isBootstrapping = false

    #if DEBUG
    /// Test-only switch for exercising persisted-config bootstrap while the
    /// build wrapper injects the DEV environment override for live tests.
    var _skipEnvironmentBootstrapForTesting = false
    #endif

    /// True when this install has a SAVED connection configuration — a previously-
    /// paired user. Read by `RootView` so the CACHE-FIRST shell (WhatsApp bar)
    /// renders for a paired user in `.offline`/`.connecting`/`.reconnecting` even
    /// after `isBootstrapping` has cleared (the cold-launch-offline window the old
    /// `hasConnected || isBootstrapping` gate dropped to `WelcomeView`).
    ///
    /// The signal is the persisted server URL: `configure()` writes it to
    /// UserDefaults ONLY after a verified connection, so a genuinely-unconfigured
    /// install (or one whose only `configure` attempt FAILED validation — nothing
    /// persisted) reports `false` and still routes to `WelcomeView`. The in-memory
    /// `serverURLString` is the cache-first early-set fallback (set in
    /// `paintCacheFirst` before any persistence) so the gate holds during the very
    /// first launch frames too. A deliberate `disconnect()` clears the persisted
    /// URL elsewhere? — no: `disconnect()` returns to `.needsSetup`, which routes
    /// to `WelcomeView` directly, so this gate is never consulted there.
    var hasSavedConfiguration: Bool {
        if let saved = UserDefaults.standard.string(forKey: DefaultsKeys.serverURL),
           !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        // Cache-first early-set (pre-persistence) fallback — set by
        // `paintCacheFirst` from the saved/dev-env URL before `configure()`
        // persists. A failed `configure()` never reaches this set with a value
        // that outlives the launch (it returns early before any non-bootstrap
        // path), so a garbage manual entry does not spuriously flip the gate.
        return !serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(sessionStore: SessionStore, chatStore: ChatStore) {
        self.sessionStore = sessionStore
        self.chatStore = chatStore
    }

    private static func clearSpotlightSessionIndexForPrivacy() {
        #if DEBUG
        if let clearAll = spotlightClearAllForTesting {
            clearAll()
            return
        }
        #endif
        SpotlightIndexer.clearAll()
    }

    // MARK: - Bootstrap

    /// Resolve the connection at launch: dev env override → saved config →
    /// `.needsSetup`.
    func bootstrap() async {
        let generation = advanceConnectionGeneration()
        await bootstrap(generation: generation)
    }

    private func bootstrap(generation: UInt64) async {
        // Reconcile any pending gateway-forget tombstone against the CURRENT
        // pairing BEFORE the cache-first paint path runs. A stale tombstone left
        // by a forget whose remote revoke failed must NOT suppress the cache of a
        // server the user has since RE-PAIRED under a new device — cached content
        // for a currently-paired server always paints (LANE A). If this resumes a
        // genuinely-interrupted forget, it returns `true` and bootstrap aborts.
        if await reconcilePendingForgetTombstone() { return }
        if UserDefaults.standard.bool(forKey: DefaultsKeys.connectionOffline) {
            if let savedURL = UserDefaults.standard.string(forKey: DefaultsKeys.serverURL), !savedURL.isEmpty {
                await paintCacheFirst(serverURLString: savedURL)
                guard isCurrentGeneration(generation) else { return }
            }
            phase = .offline(nil)
            return
        }
        #if DEBUG
        // Dev-only override (sim/test runs inject HERMES_URL/HERMES_TOKEN via
        // SIMCTL_CHILD_/TEST_RUNNER_). DEBUG-gated so a production binary can
        // never be silently re-pointed via injected env vars (release audit).
        let env = ProcessInfo.processInfo.environment
        if !_skipEnvironmentBootstrapForTesting,
           let url = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
           !url.isEmpty, !token.isEmpty {
            // A saved/dev-env config: this is a RETURNING user. Flag the launch
            // window so the shell shows the splash rather than `WelcomeView` even
            // while the reconnect is still in flight (ABH-82 follow-up).
            isBootstrapping = true
            // CACHE-FIRST (WhatsApp bar): bind the cache scope to this server and
            // paint the drawer from disk BEFORE the REST probe, so the session
            // list renders instantly regardless of whether the probe succeeds,
            // fails, or hangs. `serverURLString` is what `currentCacheScope`
            // resolves from, so it must be set before the paint — the later
            // `configure()` re-stamps it (trimmed) verbatim on a verified connect.
            await paintCacheFirst(serverURLString: url)
            guard isCurrentGeneration(generation) else { return }
            _ = await configure(
                urlString: url, token: token, issuedDeviceId: nil, generation: generation
            )
            guard isCurrentGeneration(generation) else { return }
            isBootstrapping = false
            enterDraftAfterBootstrapConfigure()
            return
        }
        #endif

        let savedURL = UserDefaults.standard.string(forKey: DefaultsKeys.serverURL)
        if let savedURL, !savedURL.isEmpty {
            isBootstrapping = true
            // CACHE-FIRST (WhatsApp bar): paint the drawer from disk BEFORE the
            // REST probe — this is the fix for the empty-drawer / Welcome-on-
            // offline cold start. The probe's early-return offline path no longer
            // strands an empty drawer because the cache read already ran here.
            await paintCacheFirst(serverURLString: savedURL)
            guard isCurrentGeneration(generation) else { return }

            guard let token = KeychainService.loadToken(server: savedURL) else {
                // A cached URL still identifies a returning user even when the
                // token is unavailable on this install. Keep the cached shell
                // visible; a fresh install has no saved URL and still reaches
                // onboarding, while a failed manual/QR configure persists neither.
                phase = .offline("Saved pairing token unavailable")
                isBootstrapping = false
                return
            }

            _ = await configure(
                urlString: savedURL, token: token, issuedDeviceId: nil, generation: generation
            )
            guard isCurrentGeneration(generation) else { return }
            isBootstrapping = false
            enterDraftAfterBootstrapConfigure()
            return
        }

        phase = .needsSetup
    }

    /// STR-249/STR-248: land a returning user's cold launch on the draft
    /// composer even when `configure()` never reaches `startHydration()` — the
    /// no-gateway-reachable case, where `configure()` returns at the REST probe
    /// with `phase = .offline` and neither `finishHydration()` nor
    /// `startReconnectLoop()` (the two other `enterDraftIfNoActiveSession()`
    /// call sites) ever run, so the shell earned by `hasSavedConfiguration`
    /// (RootView) stranded on the "No conversation" placeholder instead.
    ///
    /// Guarded on `phase != .needsSetup` so a revoked/invalid saved token —
    /// which routes `configure()` to `.needsSetup` + `reauthRequired` for the
    /// re-pair prompt — does NOT get silently swapped for a draft chat instead.
    /// Safe to call unconditionally otherwise: on the connected/hydrating path
    /// this races harmlessly against `finishHydration()`, since
    /// `enterDraftIfNoActiveSession()` itself is idempotent once a draft (or a
    /// real active session) already exists.
    private func enterDraftAfterBootstrapConfigure() {
        guard phase != .needsSetup else { return }
        enterDraftIfNoActiveSession()
    }

    /// Cold-open frame-0 paint (build125 smoothness): resolve the returning
    /// user's saved / dev-env gateway URL and paint the cached drawer + last-opened
    /// transcript from disk IMMEDIATELY at launch, BEFORE the inbox cache hydrate
    /// or any network await. `bootstrap()` re-runs this exact paint, but the
    /// `paintFromCache()` read is latched + idempotent so it collapses onto this
    /// one — hoisting it here only removes the frame-0 dependency on unrelated
    /// launch awaits (the inbox hydrate). A fresh install (no saved URL, no dev
    /// env) is a no-op, byte-identical to today. The resolution below mirrors
    /// `bootstrap(generation:)` exactly so the painted scope matches the scope
    /// bootstrap will connect under.
    func paintDrawerCacheFirst() async {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if !_skipEnvironmentBootstrapForTesting,
           let url = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
           !url.isEmpty, !token.isEmpty {
            await paintCacheFirst(serverURLString: url)
            return
        }
        #endif
        guard let savedURL = UserDefaults.standard.string(forKey: DefaultsKeys.serverURL),
              !savedURL.isEmpty else { return }
        await paintCacheFirst(serverURLString: savedURL)
    }

    /// Bind the session cache scope to `serverURLString` and paint the drawer from
    /// the local cache (WhatsApp bar — cache-first launch).
    ///
    /// `serverURLString` drives `SessionStore.currentCacheScope`; it is set HERE
    /// (trimmed, matching the Keychain/cache identity) so the cold read partitions
    /// correctly before any network call. `configure()` re-stamps the SAME trimmed
    /// value on a verified connection, so this early set is consistent with the
    /// post-connect state and is harmless if the connection later fails (the saved
    /// URL is the one the cache was written under). The paint itself is idempotent
    /// (`didColdReadCache`-latched), so the `refresh()` inside hydration collapses
    /// onto this same read rather than doing a second one.
    private func paintCacheFirst(serverURLString url: String) async {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only the cache-scope identity is set here — NOT the persisted credential
        // (configure() still owns persistence after a verified connect).
        self.serverURLString = trimmed
        await sessionStore.paintFromCache()
        // N3/A1 fast-path trace: the cached drawer/transcript is painted from DISK
        // here — never sequenced behind a network call (paintFromCache is a GRDB
        // read). This is the cache_paint milestone.
        ConnectTrace.shared.mark(.cachePaint)
    }

    // MARK: - Configure

    /// Validate, probe, persist, and connect to a gateway.
    ///
    /// Returns `nil` on success; otherwise a human-readable error string (and
    /// leaves `phase` reflecting the failure). On success the URL/token are
    /// persisted (UserDefaults + Keychain), the socket is connected, and the
    /// event/state tasks are started.
    ///
    /// - Parameter issuedDeviceId: the server-minted `device_id` when this pairing
    ///   came from a W3a v2 QR (`kind=device`) — `token` is then ALREADY a device
    ///   token, so we record the id and SKIP auto-upgrade. `nil` for a v1 (shared)
    ///   pairing, a manual token entry, or a saved-config bootstrap, where the
    ///   post-connect auto-upgrade transparently swaps the shared token for a
    ///   device token if the server advertises the `devices` capability.
    func configure(urlString: String, token: String, issuedDeviceId: String? = nil) async -> String? {
        let generation = advanceConnectionGeneration()
        return await configure(
            urlString: urlString,
            token: token,
            issuedDeviceId: issuedDeviceId,
            generation: generation
        )
    }

    private func configure(
        urlString: String,
        token: String,
        issuedDeviceId: String?,
        generation: UInt64
    ) async -> String? {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousServerURL = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)

        // Scheme is restricted to http/https — `URL(string:)` happily accepts
        // `file:`, `javascript:`, `ftp:` etc., and a malformed QR code or a
        // typo'd manual entry must not reach the REST probe (release audit).
        guard let url = URL(string: trimmedURL),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil else {
            phase = .offline("Invalid server URL")
            return "That doesn't look like a valid server URL."
        }
        guard !trimmedToken.isEmpty else {
            phase = .offline("Missing token")
            return "A session token is required."
        }
        let stockTransportURL = stockProxyURL(forGateway: url)

        // Cancel any reconnect loop tied to a previous configuration.
        reconnectTask?.cancel()
        reconnectTask = nil
        hydrationTask?.cancel()
        hydrationTask = nil
        graceTask?.cancel()
        graceTask = nil
        sessionRefreshDebounceTask?.cancel()
        sessionRefreshDebounceTask = nil
        isInGrace = false
        // Until this generation is verified, queued state from the prior socket
        // must not qualify as active (especially a late `.open`).
        hasConnected = false
        deviceIssueLimitReachedServers.remove(trimmedURL)
        deviceLimitAdvisory = nil

        // Reset the initial-fill guard so the next refresh() after this
        // configure re-runs the fill-to-30 loop for the new server.
        sessionStore.resetInitialFill()

        phase = .connecting

        // S3: arm the network-path monitor BEFORE the REST probe. A cold-launch-
        // offline configure fails at the probe below and returns terminal
        // `.offline` with `hasConnected == false`; arming here (not after a
        // verified connect) is what lets a later path-satisfied event lift that
        // terminal state and reconnect by itself. Idempotent — a single instance
        // survives re-configures.
        startPathMonitor()

        // Probe REST first to fail fast with a clear message before opening WS.
        let previousToken = KeychainService.loadToken(server: trimmedURL)
        let isSavedTokenReuse = issuedDeviceId == nil && previousToken == trimmedToken

        // N3/A1 connect fast-path (relay): relay readiness is the WS socket, not a
        // gateway REST round-trip — the ratified relay contract has NO REST
        // handshake (RelayClient §1). Gating the socket open behind `probe.status()`
        // would put a blocking status round-trip in front of interactivity, so on
        // the relay path we validate auth in the BACKGROUND (still routing a 401/403
        // to the D3 re-pair flow) and let the socket connect proceed immediately.
        // The gateway-direct path keeps the fail-fast probe, byte-unchanged.
        if transportPath == .relay {
            probeRelayAuthInBackground(url: url, token: trimmedToken, generation: generation)
        } else {
            do {
                #if DEBUG
                if let statusRPC {
                    try await statusRPC(stockTransportURL, trimmedToken)
                } else {
                    let probe = RestClient(baseURL: stockTransportURL, token: trimmedToken)
                    _ = try await probe.status()
                }
                #else
                let probe = RestClient(baseURL: stockTransportURL, token: trimmedToken)
                _ = try await probe.status()
                #endif
            } catch {
                guard isCurrentGeneration(generation) else { return nil }
                // An auth rejection on a probe means this token is no longer valid —
                // surface the re-pair affordance rather than a generic offline error
                // (D3 RE-PAIR FLOW). This covers both an explicit re-auth attempt and
                // a bootstrap of a now-revoked saved token.
                if Self.isAuthFailure(error) {
                    reauthRequired = true
                    requireTransportReauthentication()
                    phase = .needsSetup
                    return Self.reauthMessage
                }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                phase = .offline(message)
                return message
            }
        }
        guard isCurrentGeneration(generation) else { return nil }

        do {
            beginTransportAttempt()
            // Wave-2 convergence: when the transport flag is `.relay`, dial the
            // relay WS through the RelayClient bridge INSTEAD of the gateway-direct
            // socket — decoded item frames stream into the transcript via the item
            // layer. The gateway `client` stays idle. `.gatewayDirect` (default,
            // OFF) is the original branch below, byte-unchanged.
            if transportPath == .relay {
                guard let relayURL = relayURL(forGateway: url) else {
                    throw RelayError.transport("Could not derive a relay URL for \(trimmedURL)")
                }
                #if DEBUG
                if let relayConnectHook {
                    try await relayConnectHook(relayURL, trimmedToken)
                } else {
                    try await ensureRelayCoordinator().start(url: relayURL, token: trimmedToken)
                }
                #else
                try await ensureRelayCoordinator().start(url: relayURL, token: trimmedToken)
                #endif
            } else if let connectRPC {
                try await connectRPC(stockTransportURL, trimmedToken, connectionMode)
            } else {
                try await client.connect(
                    baseURL: stockTransportURL,
                    token: trimmedToken,
                    mode: connectionMode
                )
            }
        } catch {
            guard isCurrentGeneration(generation) else { return nil }
            markTransportUnavailable()
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phase = .offline(message)
            return message
        }
        guard isCurrentGeneration(generation) else { return nil }
        // N3/A1 fast-path trace: the transport socket is up. Relay: `start()`
        // returned after the WS resumed (`.open`); gateway-direct: `connect`
        // returned after `gateway.ready`.
        ConnectTrace.shared.mark(.socketOpen)
        // `HermesGatewayClient.connect` returns only after `gateway.ready`, so
        // this is the first point at which operational RPC admission is allowed.
        acceptCurrentTransport()
        // N3/A1 fast-path trace: operational RPC admission is now allowed
        // (transport epoch accepted). On the relay path this coincides with
        // socket_open (the relay has no ready handshake) — the delta honestly
        // reads ~0 there.
        ConnectTrace.shared.mark(.transportReady)

        let switchedServers = !previousServerURL.isEmpty && previousServerURL != trimmedURL
        if switchedServers {
            // ABH-410 follow-up: when a verified re-pair switches servers, purge
            // the previous server's indexed session titles from Spotlight before
            // the new URL becomes the cache/index identity.
            Self.log.notice("Server switch clearing Hermes Spotlight session index")
            Self.clearSpotlightSessionIndexForPrivacy()
            sessionStore.invalidateGatewayScopeWork()
        }

        // Persist only after a verified connection.
        serverURLString = trimmedURL
        currentToken = trimmedToken
        UserDefaults.standard.set(trimmedURL, forKey: DefaultsKeys.serverURL)
        try? KeychainService.saveToken(trimmedToken, server: trimmedURL)

        // W3A-A QR v2: a `kind=device` pairing handed us a device token + its
        // server-minted `device_id`. Record the (non-secret) id so the panel can
        // mark "This device" and the auto-upgrade path sees this device already
        // holds a device token (so it does NOT re-issue). A nil id is ambiguous:
        // saved-token bootstrap/retry paths also call configure without an
        // issued id while reusing the already-stored device-token credential, so
        // preserve only when the presented token matches the stored one.
        // Explicit self-revoke continues to clear via DevicesView, and nil-id
        // manual/shared-token pairing clears any stale id so auto-upgrade can run.
        if let issuedDeviceId, !issuedDeviceId.isEmpty {
            DefaultsKeys.setDeviceId(issuedDeviceId, server: trimmedURL)
        } else if !isSavedTokenReuse {
            DefaultsKeys.setDeviceId(nil, server: trimmedURL)
        }

        // Re-pairing supersedes forget: a verified connection to a server that
        // still carries a stale cleanup tombstone from a PRIOR device's forget
        // must void that tombstone's cache-suppression now, so a later cold-open
        // never paints an empty shell over this server's populated cache. The
        // owed remote revoke of the old device (if any) is preserved. When the
        // tombstone's device equals the just-configured pairing, forget semantics
        // are kept (`.keep`) exactly as the launch reconciler decides.
        if let tombstone = Self.pendingCleanupTombstone(),
           tombstone.server.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedURL {
            let decision = GatewayForgetCoordinator.evaluate(
                tombstone: tombstone,
                currentDeviceId: DefaultsKeys.deviceId(server: trimmedURL),
                hasLivePairing: true
            )
            Self.applyTombstoneDecision(decision, for: tombstone, defaults: .standard)
        }

        // R4/W2a (contract I13): the gateway event-router + state-observer tasks
        // consume `client.events` / `client.stateChanges` — gateway-direct machinery
        // that must stay idle in relay mode (the relay coordinator owns the live
        // transport; the gateway `client` never connects on this path). The whole
        // startLongLivedTasks/startReconnectLoop/probeLiveness family deletes in
        // Wave 4; this gate is the transitional day-1 guard.
        if transportPath != .relay {
            startLongLivedTasks()
        }
        hasConnected = true
        updatePhoneForeground(sessionStore.activeStoredId)
        // A verified connection clears any prior re-pair flag and failure tally.
        reauthRequired = false
        consecutiveReconnectFailures = 0
        // A cold cache restore intentionally selected/painted without issuing
        // RPC. Now that `gateway.ready` accepted this epoch, bind that latest
        // durable selection in the background; its token/epoch guards make a
        // newer drawer tap win while hydration continues independently.
        if !switchedServers, sessionStore.activeStoredId != nil {
            Task { [weak self] in
                await self?.sessionStore.resumeActiveAfterReconnect()
            }
        }
        // ABH-82: enter the branded loading screen rather than flashing the empty
        // shell. The hydration coordinator below flips this to `.connected` once
        // the gateway state has been pulled (or the timeout fires first).
        phase = .hydrating

        // Probe branch-only server capabilities (E1) so the UI can gate on a
        // stock vs. patched gateway. Cheap + cached per server URL + app version,
        // so a reconnect to the same server is a no-op. Fire-and-forget: the UI
        // shows features optimistically until a probe proves one unavailable.
        // NOT part of the hydration gate — it never blocks the loading screen.
        Task { [weak self] in
            guard let self, self.isActiveGeneration(generation),
                  let rest = self.rest else { return }
            await self.capabilities.probe(serverURL: trimmedURL, rest: rest)
            guard self.isActiveGeneration(generation) else { return }
            // F4b: once the `profiles` capability has settled, load the profile
            // list backing the switcher (a no-op clearing the cache on a stock
            // gateway). Gated inside `loadProfiles()` on `profiles == .available`.
            await self.sessionStore.loadProfiles()
            guard self.isActiveGeneration(generation) else { return }
            // W3A-A: once the `devices` capability has settled, transparently
            // auto-upgrade a legacy shared token to a per-device token (a no-op on
            // a stock gateway, where `devices` is `.unavailable`, and on a device
            // that already holds a device token for this server). Runs AFTER the
            // probe so it sees the settled capability.
            await self.autoUpgradeToDeviceTokenIfNeeded(serverURL: trimmedURL)
            guard self.isActiveGeneration(generation) else { return }
        }

        // ABH-82: coordinate the `.hydrating → .connected` transition. The
        // user-visible hydration is the session-list refresh + the running-model
        // probe; both are raced against `hydrationTimeout` so a slow or hung
        // probe can never strand the loading screen. On completion (whichever
        // wins) we land on a fresh new-chat draft and reveal the connected UI.
        //
        // N3/A1 note (relay): on the relay path the `onPhaseChange` bridge already
        // flips `phase` to `.connected` the instant the socket reports `.open`
        // (well before this hydration race resolves), so the REST hydration here
        // does NOT gate composer interactivity — it only back-fills the drawer +
        // model chip in the background. The single blocking status round-trip that
        // DID gate interactivity was the pre-connect `probe.status()`, removed for
        // the relay path above (see `probeRelayAuthInBackground`).
        startHydration(generation: generation)
        return nil
    }

    /// N3/A1 connect fast-path (relay): validate gateway auth WITHOUT gating the
    /// relay socket open on the round-trip. The relay transport's readiness is the
    /// WS socket (no REST handshake), so a blocking `probe.status()` before the
    /// socket would be a gratuitous status round-trip in front of interactivity.
    /// This runs the same REST probe in the background and preserves the D3 re-pair
    /// flow: on a 401/403 the token is dead → `reauthRequired` + `.needsSetup`,
    /// exactly as the blocking probe did. Any OTHER (transient) REST failure is
    /// deliberately ignored — on the relay path the WS socket is the transport
    /// authority, so a gateway REST blip must not knock an interactive relay session
    /// offline. The gateway-direct path never calls this (it keeps the fail-fast
    /// blocking probe in `configure`).
    private func probeRelayAuthInBackground(url: URL, token: String, generation: UInt64) {
        Task { [weak self] in
            guard let self else { return }
            do {
                #if DEBUG
                if let statusRPC {
                    try await statusRPC(url, token)
                } else {
                    let probe = RestClient(baseURL: url, token: token)
                    _ = try await probe.status()
                }
                #else
                let probe = RestClient(baseURL: url, token: token)
                _ = try await probe.status()
                #endif
            } catch {
                guard self.isCurrentGeneration(generation) else { return }
                guard Self.isAuthFailure(error) else { return }
                self.reauthRequired = true
                self.requireTransportReauthentication()
                self.phase = .needsSetup
            }
        }
    }

    // MARK: - Hydration (ABH-82)

    /// Coordinate the post-connect `.hydrating → .connected` transition.
    ///
    /// Races the real gateway-state hydration (session-list refresh + running-
    /// model probe) against a hard `hydrationTimeout`: whichever finishes first
    /// flips the phase to `.connected` and lands on a fresh new-chat draft, so
    /// the branded loading screen NEVER strands even if a probe is slow or hangs.
    /// Idempotent in effect — `finishHydration()` only acts while still
    /// `.hydrating`, so the losing branch of the race is a no-op.
    /// The hydration session-list refresh, wrapped so its COMPLETION (vs being
    /// cancelled by the timeout race) is recorded on the main actor. `refresh()`
    /// returns early on cancellation, so `Task.isCancelled` distinguishes a real
    /// completion from a cancelled one; `finishHydration` re-fires the refresh in
    /// the background when this never set the flag.
    private func runHydrationRefresh(generation: UInt64) async {
        guard isActiveGeneration(generation) else { return }
        await sessionStore.refresh()
        guard !Task.isCancelled, isActiveGeneration(generation) else { return }
        hydrationRefreshCompleted = true
    }

    private func startHydration(generation: UInt64) {
        guard isActiveGeneration(generation) else { return }
        hydrationTask?.cancel()
        hydrationRefreshCompleted = false
        hydrationTask = Task { [weak self] in
            guard let self, self.isActiveGeneration(generation) else { return }
            await withTaskGroup(of: Void.self) { group in
                // Branch 1: the real hydration — pull the session list (so the
                // drawer is populated when the shell reveals) AND resolve the
                // running model (so the composer chip can render immediately).
                // The two run CONCURRENTLY with each other via `async let`, not
                // chained: with hundreds of sessions the list pull can eat the
                // whole hydration budget, and sequencing the probe behind it meant
                // a slow first connect let the timeout branch win and cancel the
                // group before the probe ran — so the composer chip stayed empty
                // until a force-quit warmed the cache. Awaiting both here keeps
                // the outer race intact (this branch finishes only when BOTH are
                // done) while letting the chip resolve in parallel. (ABH-84 QA.)
                group.addTask { [weak self] in
                    guard let self, await self.isActiveGeneration(generation) else { return }
                    async let sessions: Void = self.runHydrationRefresh(generation: generation)
                    async let model: Void = self.refreshActiveModel(generation: generation)
                    _ = await (sessions, model)
                }
                // Branch 2: the hard timeout fallback. Proceeds to `.connected`
                // even if hydration is slow — the loading screen must not strand.
                group.addTask {
                    try? await Task.sleep(for: Self.hydrationTimeout)
                }
                // The first branch to finish wins; cancel the rest so a pending
                // sleep (or a slow refresh after the timeout) does nothing more.
                _ = await group.next()
                group.cancelAll()
            }
            guard !Task.isCancelled, self.isActiveGeneration(generation) else { return }
            self.finishHydration(generation: generation)
        }
    }

    /// Complete hydration: reveal the connected UI on a fresh new-chat draft.
    /// Guarded on the phase so a late timeout branch (or a re-entrant call)
    /// after a disconnect/re-configure is a harmless no-op.
    ///
    /// `internal` (not `private`) so the phase-transition unit tests can drive it
    /// directly without standing up a live gateway — both race branches converge
    /// here, so pinning its guard + side effects is the seam that proves the
    /// timeout fallback lands on `.connected` + a fresh draft (ABH-82).
    func finishHydration() {
        finishHydration(generation: connectionGeneration, requireActive: false)
    }

    private func finishHydration(generation: UInt64, requireActive: Bool = true) {
        guard isCurrentGeneration(generation),
              !reauthRequired,
              (!requireActive || hasConnected) else { return }
        guard phase == .hydrating else { return }
        // Land on a fresh draft chat (chat-as-home), but only when nothing is
        // already active — a manual re-configure while a session is open must not
        // stomp it.
        enterDraftIfNoActiveSession()
        phase = .connected
        // Enforce the invariant `phase == .connected ⟹ hasConnected == true`.
        // The normal path (configure() → client.connect() succeeds) already sets
        // `hasConnected = true` before finishHydration() runs, so this is
        // idempotent there. The direct-call path (unit tests, and any future
        // re-hydration shortcut) was missing this set — the tests in #23 and the
        // RootView gate both rely on the invariant, so we enforce it here rather
        // than relying on the caller to have set it first.
        hasConnected = true
        // Safety net: if the hydration race was won by the hard timeout branch,
        // branch 1's model probe was cancelled mid-flight and the composer chip
        // would render empty. Re-run the probe (best-effort, off the reveal path)
        // whenever the model is still unresolved so the chip fills in shortly
        // after connect instead of staying blank until a force-quit. (ABH-84 QA.)
        if activeModelName == nil {
            Task { [weak self] in
                await self?.refreshActiveModel(generation: generation)
            }
        }
        // STALE-DRAWER FIX: the hydration race cancels the session-list `refresh()`
        // when the 8s timeout branch wins — which it reliably does for a large account
        // (the list pull eats the whole budget). Without recovery the drawer stays on
        // STALE cache while the UI shows "connected" (reported: cold-launch sessions
        // stuck at an old timestamp; new messages not visible until a manual pull).
        // The model probe above already has this exact safety net; give the session
        // list one too — re-run the refresh in the BACKGROUND (off the reveal path,
        // phase is already `.connected`) so the drawer reconciles to the gateway's
        // fresh state shortly after connect. Opening a session then fetches its fresh
        // transcript on its own (the delta route falls back to a full resync).
        if !hydrationRefreshCompleted {
            Task { [weak self] in
                guard let self, self.isActiveGeneration(generation) else { return }
                await self.sessionStore.refresh()
                guard self.isActiveGeneration(generation) else { return }
            }
        }
        // CACHE-FIRST coverage (WhatsApp bar): hydration has settled and the
        // session list is populated — warm the top-N recent transcripts in the
        // background so nearly every subsequent drawer tap is a disk hit. Paced +
        // cancellable; a no-op when offline (no REST client) or on a cold cache.
        sessionStore.prefetchRecentTranscripts()
        // Hygiene (WhatsApp bar): run the daily-throttled eviction sweep so the
        // cache never grows unbounded. Self-throttled to once/24h in CacheStore.
        sessionStore.runEvictionIfNeeded()
    }

    /// Land the app on a fresh draft chat (chat-as-home) unless a real session
    /// is already active or a draft has already been started — a manual
    /// re-configure, a deep-link-opened session, or a session resumed by the
    /// reconnect loop must not be stomped.
    ///
    /// Shared by every route that can land the app on `.connected`/shell
    /// without going through a user-initiated "New Chat" tap: `finishHydration()`
    /// (the initial connect), `startReconnectLoop()`'s success branch (STR-249: a
    /// transport drop that interrupts the initial hydration race sends `phase`
    /// to `.reconnecting` before the race resolves, which makes
    /// `finishHydration()`'s `phase == .hydrating` guard a no-op — without this,
    /// the reconnect-success path never entered draft mode either, so a cold
    /// launch that blips once during connect stranded the user on the "No
    /// conversation" placeholder instead of the composer), and `bootstrap()`
    /// (STR-249: a cold launch with NO gateway reachable never reaches either of
    /// the above — `configure()` returns at the REST probe with `phase = .offline`
    /// BEFORE `startHydration()` ever runs, so `finishHydration()`'s call site
    /// never fires and `hasConnected` stays false so the reconnect loop never
    /// starts either — `hasSavedConfiguration` still earns the main shell, but
    /// with no active session and no draft entered `chatStack` falls through to
    /// the "No conversation" placeholder — CUJ-01/STR-248).
    ///
    /// `!sessionStore.isDraft` (not just `activeStoredId == nil`) makes this
    /// idempotent across call sites that can legitimately race on the same cold
    /// launch (e.g. bootstrap's own call racing finishHydration's later one), so
    /// a second call can't reset an already-started draft and wipe anything
    /// typed in the composer during the hydration window.
    private func enterDraftIfNoActiveSession() {
        guard sessionStore.activeStoredId == nil, !sessionStore.isDraft else { return }
        sessionStore.startDraft()
    }

    // MARK: - Offline / forget

    /// Enter durable offline mode without deleting or resetting user data.
    func goOffline() async {
        UserDefaults.standard.set(true, forKey: DefaultsKeys.connectionOffline)
        await stopLiveWork(returningTo: .offline(nil), clearSpotlight: false)
    }

    /// Leave explicit offline mode and resume the normal saved-pairing bootstrap.
    func reconnect() async {
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.connectionOffline)
        await bootstrap()
    }

    /// Tear down the connection, returning to `.needsSetup`.
    ///
    /// The event-router and state-observer tasks are deliberately NOT cancelled
    /// (R1 #11): `HermesGatewayClient.events`/`.stateChanges` are SINGLE-CONSUMER
    /// AsyncStreams that survive reconnects by design — cancelling their
    /// consumer terminates the stream, so the `for await` a later `configure()`
    /// restarted iterated a dead (or, racing the old task's exit, doubly-claimed)
    /// stream: every event after a disconnect→reconnect cycle was silently
    /// dropped, or the second `next()` trapped. The tasks idle at their
    /// suspension points while disconnected and cost nothing.
    func disconnect() async {
        await stopLiveWork(returningTo: .needsSetup, clearSpotlight: true)
    }

    private func stopLiveWork(
        returningTo finalPhase: Phase?,
        clearSpotlight: Bool,
        generation ownedGeneration: UInt64? = nil
    ) async {
        let generation = ownedGeneration ?? advanceConnectionGeneration()
        // S3: tear down the path monitor on every deliberate stop — disconnect
        // (→ needsSetup, no saved config to retry), forget (unpair), and explicit
        // goOffline (a user-chosen offline must NOT silently self-reconnect). A
        // later `configure()`/`bootstrap()` re-arms it.
        stopPathMonitor()
        reconnectTask?.cancel()
        reconnectTask = nil
        // Cancel any in-flight hydration so a teardown mid-load can't later flip
        // the phase back to `.connected` (ABH-82).
        hydrationTask?.cancel()
        hydrationTask = nil
        sessionRefreshDebounceTask?.cancel()
        sessionRefreshDebounceTask = nil
        // A deliberate disconnect always wins over a silent-reconnect grace
        // window in flight — never leave a stale grace timer able to fire
        // after teardown.
        graceTask?.cancel()
        graceTask = nil
        isInGrace = false
        hasConnected = false
        // A deliberate disconnect is not an auth revocation — clear the re-pair
        // flag so the welcome screen shows its normal first-run copy.
        reauthRequired = false
        consecutiveReconnectFailures = 0
        // Drop live capability state (the cached snapshot is retained so a
        // reconnect to the same server reuses it — see ServerCapabilities).
        capabilities.reset()
        // Forget the resolved model so a fresh connection re-probes it (F0).
        activeModelName = nil
        // Clear the per-session hot-swap state so the next session starts clean.
        clearSessionState()
        // CACHE-FIRST coverage (WhatsApp bar): stop any paced background prefetch
        // so it never outlives the connection it ran under.
        sessionStore.cancelPrefetch()
        // Finalize any in-flight stream explicitly and SYNCHRONOUSLY (R1
        // #9/#42), before the teardown await opens a suspension window. The
        // live state observer will also see the `.closed` transition below and
        // re-run this — harmless, `handleConnectionDrop` is idempotent — and
        // its reconnect guard stays quiet because `hasConnected` was cleared
        // above, BEFORE the close.
        chatStore.handleConnectionDrop()
        // ABH-178: clear any stuck turn flags on explicit disconnect so a later
        // re-pair starts with a clean carry-forward slate.
        sessionStore.clearAllTurnsInProgress()
        // ABH-410: privacy cleanup for unpair/sign-out. Indexed session titles
        // live outside the app sandbox until explicitly removed from Spotlight.
        if clearSpotlight {
            Self.log.notice("Disconnect clearing Hermes Spotlight session index")
            Self.clearSpotlightSessionIndexForPrivacy()
        }
        await client.disconnect()
        // Wave-2: tear down the relay bridge too, but ONLY if it was ever built
        // (the gateway-direct default never allocates it — byte-identical path).
        if let relayCoordinator { await relayCoordinator.stop() }
        guard isCurrentGeneration(generation) else { return }
        if let finalPhase { phase = finalPhase }
    }

    // MARK: - Forget tombstone reconciliation

    /// Read the pending gateway-forget cleanup tombstone, if any.
    static func pendingCleanupTombstone(
        _ defaults: UserDefaults = .standard
    ) -> GatewayCleanupTombstone? {
        defaults.data(forKey: DefaultsKeys.gatewayCleanupTombstone)
            .flatMap { try? JSONDecoder().decode(GatewayCleanupTombstone.self, from: $0) }
    }

    /// Whether a live credential currently exists for `server` — either it is the
    /// persisted/configured server URL, or a Keychain token is present for it.
    static func hasLivePairing(
        for server: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let target = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if let saved = defaults.string(forKey: DefaultsKeys.serverURL),
           saved.trimmingCharacters(in: .whitespacesAndNewlines) == target,
           !target.isEmpty {
            return true
        }
        return KeychainService.loadToken(server: server) != nil
    }

    /// Apply a ``GatewayForgetCoordinator.Decision`` to the persisted tombstone.
    static func applyTombstoneDecision(
        _ decision: GatewayForgetCoordinator.Decision,
        for tombstone: GatewayCleanupTombstone,
        defaults: UserDefaults = .standard
    ) {
        switch decision.rewrite {
        case .keep:
            break
        case .remove:
            defaults.removeObject(forKey: DefaultsKeys.gatewayCleanupTombstone)
        case .supersede:
            // Retry-only form: cache-suppression is void, the remote revoke of the
            // OLD device stays owed (background, best-effort, never gating paint).
            let superseded = GatewayCleanupTombstone(
                server: tombstone.server,
                deviceId: tombstone.deviceId,
                remoteRetryNeeded: tombstone.remoteRetryNeeded,
                supersededByRepair: true
            )
            if let data = try? JSONEncoder().encode(superseded) {
                defaults.set(data, forKey: DefaultsKeys.gatewayCleanupTombstone)
            }
        }
    }

    /// Reconcile a pending forget tombstone at launch against the current pairing.
    ///
    /// Returns `true` when it resumed a genuinely-interrupted local forget (the
    /// caller must abort the rest of bootstrap). Returns `false` — the common
    /// case — when there is no tombstone, or when a re-pair under a new device has
    /// superseded it (the stale cache-suppression is voided, only the owed remote
    /// revoke is preserved, and the normal cache-first launch proceeds so the
    /// re-paired server's cache paints).
    func reconcilePendingForgetTombstone(
        defaults: UserDefaults = .standard
    ) async -> Bool {
        guard let tombstone = Self.pendingCleanupTombstone(defaults) else { return false }
        let decision = GatewayForgetCoordinator.evaluate(
            tombstone: tombstone,
            currentDeviceId: DefaultsKeys.deviceId(server: tombstone.server, defaults),
            hasLivePairing: Self.hasLivePairing(for: tombstone.server, defaults: defaults)
        )
        guard decision.suppressesCache else {
            // Re-pairing supersedes forget. Void the cache-suppression and keep
            // only the owed remote revoke of the old device.
            Self.applyTombstoneDecision(decision, for: tombstone, defaults: defaults)
            // If the interrupted forget cleared the persisted URL but a live token
            // for the re-paired server remains, restore the URL so the cache-first
            // paint below binds the correct scope.
            if defaults.string(forKey: DefaultsKeys.serverURL) == nil,
               KeychainService.loadToken(server: tombstone.server) != nil {
                defaults.set(tombstone.server, forKey: DefaultsKeys.serverURL)
            }
            return false
        }
        // Forget semantics preserved (deviceId == current pairing, or no live
        // pairing). Resume the interrupted LOCAL cleanup only when no live
        // credential URL remains — otherwise there is nothing left to resume and
        // the normal launch path handles the still-configured server.
        if defaults.string(forKey: DefaultsKeys.serverURL) == nil {
            await forgetGateway()
            return true
        }
        return false
    }

    /// Authenticated caller-only privacy transaction. Local erasure always wins;
    /// remote failure records a minimal retry tombstone without retaining token.
    /// `serverOverride` lets a just-revoked device identify the credential even
    /// if persisted URL cleanup raced ahead of its callback.
    func forgetGateway(
        remoteCleanup: (() async throws -> Void)? = nil,
        serverOverride: String? = nil
    ) async {
        let generation = advanceConnectionGeneration()
        // Keep onboarding hidden until every local privacy owner has completed.
        phase = .connecting
        let defaults = UserDefaults.standard
        let pending = defaults.data(forKey: DefaultsKeys.gatewayCleanupTombstone)
            .flatMap { try? JSONDecoder().decode(GatewayCleanupTombstone.self, from: $0) }
        guard let server = serverOverride
                ?? defaults.string(forKey: DefaultsKeys.serverURL)
                ?? pending?.server,
              !server.isEmpty else {
            await stopLiveWork(
                returningTo: nil, clearSpotlight: true, generation: generation
            )
            guard isCurrentGeneration(generation) else { return }
            sessionStore.removeForgottenGatewayState()
            chatStore.reset()
            phase = .needsSetup
            return
        }
        let deviceId = DefaultsKeys.deviceId(server: server) ?? pending?.deviceId
        let tombstone = GatewayCleanupTombstone(
            server: server, deviceId: deviceId, remoteRetryNeeded: pending?.remoteRetryNeeded ?? false
        )
        if let data = try? JSONEncoder().encode(tombstone) {
            // Write-ahead marker: every following step is repeatable, and launch
            // resumes local cleanup when termination occurs between steps.
            defaults.set(data, forKey: DefaultsKeys.gatewayCleanupTombstone)
        }
        var remoteFailed = false
        do { try await remoteCleanup?() } catch { remoteFailed = true }
        guard isCurrentGeneration(generation) else { return }
        await stopLiveWork(returningTo: nil, clearSpotlight: true, generation: generation)
        guard isCurrentGeneration(generation) else { return }
        sessionStore.removeForgottenGatewayState()
        // Forget is a privacy erase: the last-viewed transcript stays resident in
        // ChatStore after stopLiveWork (which only ends the live stream), so clear
        // it too before repairing to `.needsSetup` — otherwise a forgotten
        // gateway's cached messages remain on screen (GatewayForgetCoordinatorTests
        // testForgetClearsPublishedDrawerAndTranscriptBeforeRepairing).
        chatStore.reset()
        try? await cacheStore?.purgeGateway(serverId: server)
        guard isCurrentGeneration(generation) else { return }
        await queueStore?.removeAll()
        inboxStore?.removeAll()
        PendingIntent.clearPending()
        SharedStore.clearInbox()
        SharedStore.clearSnapshot()
        await AttachmentBlobCache.shared.clearAll()
        LiveActivityManager.shared.end()
        defaults.removeObject(forKey: DefaultsKeys.serverURL)
        defaults.removeObject(forKey: DefaultsKeys.connectionOffline)
        defaults.removeObject(forKey: DefaultsKeys.serverCapabilities)
        defaults.removeObject(forKey: DefaultsKeys.pushLastDeviceToken)
        defaults.removeObject(forKey: DefaultsKeys.pushLastEvents)
        defaults.removeObject(forKey: DefaultsKeys.pushLastEnv)
        defaults.removeObject(forKey: DefaultsKeys.pushLastRegistrationScope)
        defaults.removeObject(forKey: DefaultsKeys.pushRegistrationHealthy)
        DefaultsKeys.setDeviceId(nil, server: server)
        KeychainService.deleteToken(server: server)
        serverURLString = ""
        currentToken = nil
        if remoteFailed {
            if let data = try? JSONEncoder().encode(GatewayCleanupTombstone(
                server: server, deviceId: deviceId, remoteRetryNeeded: true
            )) { defaults.set(data, forKey: DefaultsKeys.gatewayCleanupTombstone) }
        } else if pending?.remoteRetryNeeded != true {
            defaults.removeObject(forKey: DefaultsKeys.gatewayCleanupTombstone)
        }
        guard isCurrentGeneration(generation) else { return }
        phase = .needsSetup
    }

    // MARK: - Long-lived tasks

    /// Start the event router and state observer once. Idempotent.
    private func startLongLivedTasks() {
        if eventRouterTask == nil {
            eventRouterTask = Task { [weak self] in
                guard let self else { return }
                // FIX 5 — bound the main-actor HOLD, not the buffer. Track the start
                // of the current contiguous (un-yielded) drain and the frames since
                // the last yield. The `for await` only suspends on its own when the
                // buffer is EMPTY; for a queued burst we add an explicit yield once a
                // wall-clock budget OR a frame count is exceeded, so UIKit gets a
                // runloop turn mid-burst. Yielding ONLY AFTER `route()` returns means
                // no event is ever half-applied — an interleaved session switch is
                // already made safe by the openToken / streamingIsForeign ownership
                // gates. Lossless: every frame is still routed in order.
                var holdStart = ContinuousClock.now
                var sinceYield = 0
                var iterator = self.client.events.makeAsyncIterator()
                while !Task.isCancelled {
                    let generation = self.connectionGeneration
                    guard let event = await iterator.next() else { return }
                    guard self.isActiveGeneration(generation) else { continue }
                    self.route(event: event, generation: generation)
                    sinceYield += 1
                    if sinceYield >= Self.intakeYieldEveryK
                        || ContinuousClock.now - holdStart >= Self.intakeYieldBudget {
                        await Task.yield()
                        holdStart = ContinuousClock.now
                        sinceYield = 0
                    }
                }
            }
        }
        if stateObserverTask == nil {
            stateObserverTask = Task { [weak self] in
                guard let self else { return }
                var iterator = self.client.stateChanges.makeAsyncIterator()
                while !Task.isCancelled {
                    let generation = self.connectionGeneration
                    guard let state = await iterator.next() else { return }
                    guard self.isActiveGeneration(generation) else { continue }
                    self.handle(state: state, generation: generation)
                }
            }
        }
    }

    /// Fan a single gateway event out to the right store.
    private func route(event: GatewayEvent, generation: UInt64) {
        // The router task now outlives disconnects (R1 #11 — cancelling it
        // killed the single-consumer stream), so frames the dead socket
        // buffered into the unbounded stream can drain AFTER a deliberate
        // disconnect. `hasConnected` is cleared first thing in `disconnect()`
        // and only set after a verified `configure()` connect (with no
        // suspension before the flag, so a fresh connection's own frames can
        // never be dropped) — gate on it so a ghost frame from a server the
        // user just left can't re-claim a turn or mutate store state
        // (ABH-52 judge round).
        guard isActiveGeneration(generation) else { return }
        // ABH-46 item 8: a frame carrying `broadcast_gap` means the gateway's
        // bounded per-client broadcast queue dropped frames before this one
        // (F3 overflow policy, ws.py:253). The live stream has a hole, so
        // reconcile: REST-backfill the active transcript (authoritative) and
        // refresh the drawer so list state catches up too. Runs alongside
        // normal routing — the carrying frame itself is still applied below.
        if let gap = event.broadcastGap, gap > 0 {
            Task {
                guard self.isActiveGeneration(generation) else { return }
                await self.chatStore.backfill()
                guard self.isActiveGeneration(generation) else { return }
                await self.sessionStore.refresh()
                guard self.isActiveGeneration(generation) else { return }
            }
        }
        switch event.type {
        case .gatewayReady:
            Task {
                guard self.isActiveGeneration(generation) else { return }
                await self.sessionStore.refresh()
                guard self.isActiveGeneration(generation) else { return }
            }
        case .messageStart, .messageDelta, .messageComplete,
             .thinkingDelta, .reasoningDelta,
             .toolStart, .toolProgress, .toolComplete,
             .approvalRequest, .clarifyRequest,
             // ABH-46 item 1: turn-level gateway failures route to ChatStore so a
             // failed turn clears streaming and surfaces, instead of dropping to
             // `.unknown` and spinning forever.
             .error,
             // F4A-A2: subagent delegation frames were previously dropped to
             // `.unknown` at this whitelist (one of the THREE drop layers). They
             // carry the parent runtime's `session_id` (+ `stored_session_id` on
             // broadcast frames), so they stamp activity and route through the
             // same ownership gate as message/tool frames.
             .subagentStart, .subagentThinking, .subagentTool,
             .subagentProgress, .subagentComplete,
             // F4A-A2: secure prompts. These are session-local (the gateway does
             // not broadcast-mirror them), carry the requesting runtime's
             // `session_id`, and drive ChatStore's transient secure-prompt state.
             .sudoRequest, .secretRequest:
            // The first observed subagent frame proves the patched gateway emits
            // delegation events (E1 passive capability signal — mirror
            // `noteBroadcastObserved`). Done here, at the routing source, before
            // ownership classification, so the inspector affordance can appear.
            switch event.type {
            case .subagentStart, .subagentThinking, .subagentTool,
                 .subagentProgress, .subagentComplete:
                capabilities.noteSubagentObserved()
            default:
                break
            }
            // Stamp the live-activity registry so the drawer can pulse a row
            // whose conversation just moved (this device or a broadcasting
            // client). Prefer the frame's stored id (present on broadcast /
            // mirror frames); otherwise, for our own active runtime turn, use
            // the active stored id. Stamping before `handle` is harmless — it
            // only feeds the drawer's dot and never gates transcript routing.
            stampActivity(for: event)
            // ABH-86 item 1: coalesced session-list refresh on streaming frames.
            // Both message.start (a new turn is beginning — the session's
            // last_active will move) and message.complete (the turn finished —
            // last_active is now authoritative) trigger a trailing debounce so
            // frame bursts collapse to one fetch. Skipped for every other frame
            // type (delta, tool, etc.) to avoid hammering the server during a
            // long streaming response.
            switch event.type {
            case .messageStart, .messageComplete:
                // ABH-86: optimistically re-sort the originating session to the
                // top of the drawer the instant a turn starts/finishes — the
                // server only advances lastActive on completion, so without this
                // the row sits in its old slot until a refresh round-trips. Use
                // the broadcast frame's stored id (foreign turns) or, for our own
                // active turn, the active stored id. Unknown ids no-op here and
                // are picked up by the debounced refresh below (covers a brand-new
                // remote session's first message).
                let activityStoredId = event.storedSessionId
                    ?? (event.sessionId == sessionStore.activeRuntimeId
                        ? sessionStore.activeStoredId : nil)
                sessionStore.noteActivity(storedId: activityStoredId)
                // ABH-178: maintain the explicit turn-in-progress registry so
                // mergeSessionPage's carry-forward gate is gated on a real
                // lifecycle event, not the 10s liveWindow time-proxy.
                if event.type == .messageStart {
                    sessionStore.markTurnStarted(
                        storedId: activityStoredId,
                        runtimeId: event.sessionId
                    )
                } else {
                    // .messageComplete — turn finished; server lastActive is now
                    // authoritative, so the carry-forward can release.
                    sessionStore.markTurnCompleted(
                        storedId: activityStoredId,
                        runtimeId: event.sessionId
                    )
                }
                scheduleSessionRefresh(generation: generation)
            case .error:
                // A gateway error is a turn TERMINAL (ChatStore also handles it).
                // Clear the turn-in-progress flag so the carry-forward releases
                // and the server's lastActive becomes authoritative again.
                let errorStoredId = event.storedSessionId
                    ?? (event.sessionId == sessionStore.activeRuntimeId
                        ? sessionStore.activeStoredId : nil)
                sessionStore.markTurnCompleted(
                    storedId: errorStoredId,
                    runtimeId: event.sessionId
                )
            default:
                break
            }
            chatStore.handle(event: event)
            // The inbox accumulates broadcast approval/clarify prompts across
            // every session and expires them on message.complete. It ignores
            // all other event types, so forwarding here is a no-op for them.
            // Routed AFTER `chatStore.handle` so the active-session chat
            // behavior is unchanged.
            inboxStore?.handle(event: event)
        case .sessionInfo:
            // ABH-84: session hot-swap state update. The gateway emits session.info
            // after a config.set with a session_id (model/reasoning/fast hot-swap).
            // Only apply it when the event belongs to our active runtime session.
            if let sid = event.sessionId,
               !sid.isEmpty,
               sid == sessionStore.activeRuntimeId {
                applySessionInfo(event.payload)
            }
        case .statusUpdate, .unknown:
            break
        }
    }

    /// Schedule a coalesced session-list refresh with a trailing debounce
    /// (ABH-86 item 1). Calling this repeatedly during a streaming burst collapses
    /// all triggers to one `sessionStore.refresh()` that fires 400ms after the
    /// LAST call in each burst. The debounce task slot is shared by the
    /// event-router path (message frames) and the foreground path
    /// (`handleScenePhase`) so both sources collapse together.
    ///
    /// Not called during the connect/hydration phase: `gatewayReady` fires a
    /// direct `sessionStore.refresh()` (not via this debounce) and `recoverActiveSession`
    /// also ends with a direct refresh — the debounce is exclusively for the
    /// per-message streaming triggers.
    private func scheduleSessionRefresh(generation: UInt64) {
        guard isActiveGeneration(generation) else { return }
        sessionRefreshDebounceTask?.cancel()
        sessionRefreshDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.sessionRefreshDebounceMs))
            guard !Task.isCancelled, let self,
                  self.isActiveGeneration(generation) else { return }
            await self.sessionStore.refresh()
            guard self.isActiveGeneration(generation) else { return }
        }
    }

    /// Resolve the *stored* session id a streaming frame belongs to and stamp the
    /// session store's live-activity registry. Broadcast/mirror frames carry
    /// `stored_session_id` directly; for a frame on our own active runtime turn
    /// (no stored id on the wire) we attribute it to the active stored session.
    private func stampActivity(for event: GatewayEvent) {
        if let stored = event.storedSessionId, !stored.isEmpty {
            // A frame carrying stored_session_id proves broadcast enrichment is
            // live on this gateway (E1: the broadcast capability is passive).
            capabilities.noteBroadcastObserved()
            sessionStore.noteActivity(storedSessionId: stored)
        } else if let sid = event.sessionId,
                  sid == sessionStore.activeRuntimeId,
                  let active = sessionStore.activeStoredId {
            sessionStore.noteActivity(storedSessionId: active)
        }
    }

    /// React to a transport state transition: keep `phase` honest and start the
    /// reconnect loop when an established connection drops.
    private func handle(state: GatewayConnectionState, generation: UInt64) {
        guard isActiveGeneration(generation) else { return }
        switch state {
        case .idle, .connecting:
            break
        case .open:
            // Don't override an in-flight hydration (ABH-82): the WS may resolve
            // `.open` right after `configure` sets `.hydrating`; the hydration
            // coordinator owns the `.hydrating → .connected` transition. The
            // reconnect loop sets `.connected` itself on success.
            if reconnectTask == nil, phase != .hydrating,
               isActiveGeneration(generation) { phase = .connected }
        case .closed, .failed:
            // Keep the UI in `.connected` during silent grace, but make the
            // transport unusable immediately. A live task object is not proof
            // that this generation may admit RPC.
            markTransportUnavailable()
            // STR-973A silent reconnect: a drop after we were connected no
            // longer finalizes the stream or shows `.reconnecting` right
            // away. Start the grace window instead — it fires the reconnect
            // loop immediately underneath (so a quick heal is fast) but
            // withholds `chatStore.handleConnectionDrop()` / the visible
            // `.reconnecting` phase until the grace window actually expires.
            // An expected close (disconnect/needsSetup) leaves `hasConnected`
            // false and this is a no-op. Idempotent against the repeated
            // `.failed` transitions the reconnect loop's own attempts emit —
            // `reconnectTask`/`graceTask` are both already non-nil by then.
            guard hasConnected, reconnectTask == nil, graceTask == nil else { return }
            #if DEBUG
            startGraceWindow(
                duration: graceWindowOverride ?? Self.transientGraceWindow,
                generation: generation
            )
            #else
            startGraceWindow(duration: Self.transientGraceWindow, generation: generation)
            #endif
        }
    }

    // MARK: - Silent reconnect grace (STR-973A)

    /// Start the silent-reconnect grace window: the reconnect loop fires
    /// immediately underneath (attempt 0 has no backoff, so a quick heal is
    /// still fast), but `phase` is held at `.connected` (with `isInGrace`
    /// true) and the transcript is left untouched for `duration`. Only if
    /// the window expires with retries still failing does
    /// `escalateGraceExpiry()` finalize the stream and surface
    /// `.reconnecting`.
    private func startGraceWindow(duration: Duration, generation: UInt64) {
        guard isActiveGeneration(generation) else { return }
        isInGrace = true
        ReliabilityDiagnostics.shared.graceStarted(duration: duration)
        startReconnectLoop(generation: generation)
        graceTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard let self, !Task.isCancelled,
                  self.isActiveGeneration(generation) else { return }
            self.escalateGraceExpiry(generation: generation)
        }
    }

    /// Grace expired while the reconnect loop is still failing: only now do
    /// we drop the stranded stream/turn state and make the reconnect visible.
    /// A no-op if grace already ended (the loop healed first, or a teardown
    /// raced this timer) — `escalateGraceExpiry` must never resurrect a
    /// settled phase.
    private func escalateGraceExpiry(generation: UInt64) {
        guard isInGrace, isActiveGeneration(generation) else { return }
        isInGrace = false
        graceTask = nil
        ReliabilityDiagnostics.shared.graceExpired(attempt: currentReconnectAttempt)
        chatStore.handleConnectionDrop()
        sessionStore.clearAllTurnsInProgress()
        phase = .reconnecting(attempt: currentReconnectAttempt)
    }

    /// End the grace window without escalating — used on every reconnect-loop
    /// exit path (success, config vanished, auth revoked) so a stale timer
    /// can never fire after the phase has already moved on.
    private func endGrace() {
        graceTask?.cancel()
        graceTask = nil
        isInGrace = false
    }

    // MARK: - Network path monitoring (S3)

    /// Arm the single network-path monitor. Idempotent: a monitor already
    /// running is left untouched so re-configures don't churn it. In DEBUG a
    /// test can inject a fake via `_pathMonitorForTesting`.
    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor: NetworkPathMonitoring
        #if DEBUG
        if let injected = _pathMonitorForTesting {
            monitor = injected
        } else if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            // Under XCTest with no injected fake, do NOT arm a live NWPathMonitor:
            // the simulator's real `.satisfied` path would fire spurious
            // reconnects into unrelated tests that assert on a stalled `.offline`/
            // `.reconnecting` state. S3 tests inject `_pathMonitorForTesting`.
            return
        } else {
            monitor = NWPathMonitorAdapter()
        }
        #else
        monitor = NWPathMonitorAdapter()
        #endif
        monitor.onPathUpdate = { [weak self] status in
            self?.handleNetworkPath(status)
        }
        pathMonitor = monitor
        monitor.start()
    }

    /// Disarm the monitor and drop any pending debounced kick.
    private func stopPathMonitor() {
        networkReconnectDebounceTask?.cancel()
        networkReconnectDebounceTask = nil
        pathMonitor?.onPathUpdate = nil
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    /// A path update arrived (main actor). Only a `.satisfied` path can heal a
    /// stalled connection, and only while we are actually stalled — `.offline`
    /// (including the terminal cold-launch-offline state) or `.reconnecting`.
    ///
    /// `.requiresConnection`/`.unsatisfied` are treated as "still down" and
    /// ignored; the next `.satisfied` fires the trigger. Constrained paths (Low
    /// Data Mode) still report `.satisfied` — we deliberately do NOT special-case
    /// `path.isConstrained` here, so behavior is unchanged on constrained links
    /// (noted per spec).
    private func handleNetworkPath(_ status: NetworkPathStatus) {
        guard status == .satisfied else { return }
        switch phase {
        case .offline, .reconnecting:
            break
        case .needsSetup, .connecting, .hydrating, .connected:
            // Live, hydrating, or unpaired — nothing to self-heal.
            return
        }
        // A user-chosen offline (goOffline) must never be silently overridden by
        // a returning network. (stopLiveWork also tears the monitor down in that
        // case, so this is belt-and-suspenders against an in-flight event.)
        if UserDefaults.standard.bool(forKey: DefaultsKeys.connectionOffline) { return }
        scheduleNetworkReconnect()
    }

    /// Debounce the reconnect kick on the trailing edge so a flapping path
    /// collapses to a single attempt.
    private func scheduleNetworkReconnect() {
        networkReconnectDebounceTask?.cancel()
        #if DEBUG
        let delay = networkReconnectDebounceOverride ?? Self.networkReconnectDebounce
        #else
        let delay = Self.networkReconnectDebounce
        #endif
        networkReconnectDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.networkReconnectDebounceTask = nil
            self.fireNetworkReconnect()
        }
    }

    /// Trailing-edge of the debounce: re-check state and route into the EXISTING
    /// reconnect seam. Never a new connect path.
    private func fireNetworkReconnect() {
        // R4/W2a (contract I13): NWPathMonitor kicks route into the gateway-direct
        // `startReconnectLoop`. In relay mode the coordinator's auto-driver
        // (RSC §4) is the sole reconnect owner, so this kick is a no-op — the
        // coordinator re-dials the relay on its own socket. Wave 4 deletes this
        // whole kick path; this guard is the transitional day-1 no-op.
        guard transportPath != .relay else { return }
        // Re-check at fire time — the window may have healed us, or the user may
        // have just chosen offline.
        if UserDefaults.standard.bool(forKey: DefaultsKeys.connectionOffline) { return }
        switch phase {
        case .offline:
            if hasConnected {
                // We reached the gateway at least once this launch, so the saved
                // URL + in-memory token are live: the reconnect loop can resume
                // (its own backoff still applies to subsequent failures).
                startReconnectLoop(generation: connectionGeneration)
            } else {
                // Cold-launch-offline: `configure()`'s REST probe never succeeded,
                // so there is no in-memory token to resume. Re-run bootstrap — it
                // re-reads the saved config, reloads the Keychain token, and
                // re-probes REST — which is what lifts the TERMINAL `.offline`
                // state (S3 cold-launch case).
                Task { [weak self] in await self?.bootstrap() }
            }
        case .reconnecting:
            // A reconnect loop is already running but may be parked deep in
            // backoff. Reset it so the next attempt fires immediately now that
            // the path is back — same kick `handleScenePhase` performs on
            // foreground. The loop keeps its backoff schedule on further failures.
            //
            // WS-RECONNECT-SOFTEN (b) single-flight: but NOT while a handshake
            // is already actively in flight — a flapping path can otherwise
            // fire this debounced trigger again just as the in-flight attempt
            // is about to resolve, cancelling and restarting it from attempt 0
            // forever. Let the in-flight attempt run to completion; if it
            // fails, the loop's own retry picks up the (now-healthy) path on
            // its next try.
            guard !isReconnectHandshakeInFlight else { return }
            reconnectTask?.cancel()
            reconnectTask = nil
            startReconnectLoop(generation: connectionGeneration)
        case .needsSetup, .connecting, .hydrating, .connected:
            return
        }
    }

    // MARK: - Reconnect

    /// Exponential-backoff reconnect loop. Attempt 0 fires immediately (no
    /// pre-delay) so a foreground wake or an initial drop reconnects without
    /// any added latency. Subsequent attempts wait
    /// `min(0.5 * 2^attempt, 8)s + jitter(0…0.5s)` before retrying — i.e.
    /// roughly 1s/2s/4s/8s/8s/… (WS-RECONNECT-SOFTEN c: capped low so a
    /// crash-looping gateway isn't hammered by a persistent client, while
    /// still recovering fast for the common transient blip). On success,
    /// re-resumes the active session and backfills the transcript.
    private func startReconnectLoop(generation: UInt64) {
        guard isActiveGeneration(generation), reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            guard let self, self.isActiveGeneration(generation) else { return }
            var attempt = 0
            while !Task.isCancelled {
                guard self.isActiveGeneration(generation) else { return }
                self.currentReconnectAttempt = attempt
                ReliabilityDiagnostics.shared.reconnectAttempt(number: attempt)
                // STR-973A: while grace is holding, keep `phase` at
                // `.connected` — `escalateGraceExpiry()` is the only path
                // allowed to surface `.reconnecting` during grace.
                if !self.isInGrace {
                    self.phase = .reconnecting(attempt: attempt)
                }

                // Attempt 0: connect immediately — no backoff delay.
                // The loop can be (re)started from `handleScenePhase` on
                // foreground, where the user expects an instant reconnect;
                // adding even the base 0.5s delay is perceptible dead air.
                // Subsequent attempts back off normally.
                if attempt > 0 {
                    #if DEBUG
                    let delay = self.reconnectBackoffOverride ?? Self.backoffDelay(attempt: attempt)
                    #else
                    let delay = Self.backoffDelay(attempt: attempt)
                    #endif
                    try? await Task.sleep(for: .seconds(delay))
                }
                guard !Task.isCancelled, self.isActiveGeneration(generation) else { return }

                guard let url = URL(string: self.serverURLString),
                      let token = self.currentToken else {
                    // Config vanished mid-loop (e.g. a disconnect raced the
                    // backoff sleep). Route to setup WITH `hasConnected`
                    // cleared — leaving it true would strand the user on the
                    // chat shell in `.offline` with NO re-pair affordance
                    // (RootView only shows WelcomeView when hasConnected is
                    // false). Release audit P1.
                    self.endGrace()
                    self.hasConnected = false
                    self.phase = .needsSetup
                    self.reconnectTask = nil
                    return
                }
                let stockTransportURL = self.stockProxyURL(forGateway: url)

                do {
                    self.beginTransportAttempt()
                    if let hook = self.connectRPC {
                        try await hook(stockTransportURL, token, self.connectionMode)
                    } else {
                        try await self.client.connect(
                            baseURL: stockTransportURL,
                            token: token,
                            mode: self.connectionMode
                        )
                    }
                    guard !Task.isCancelled,
                          self.isActiveGeneration(generation) else { return }
                    // End grace immediately on the successful connect, BEFORE
                    // the awaited recovery below — `recoverActiveSession()`
                    // has genuine network suspensions, and while this task is
                    // suspended the MainActor is free for the armed
                    // `graceTask` to fire `escalateGraceExpiry()`. That guards
                    // only on `isInGrace`, so leaving grace open here let a
                    // late-firing timer stamp a spurious "Connection lost"
                    // warning on a reconnect that had already succeeded
                    // (STR-1126 regression). `handle(state:)` won't re-arm a
                    // new grace window while `reconnectTask` is still
                    // non-nil, so ending it this early is safe.
                    self.endGrace()
                    // The client only returns after its `gateway.ready`
                    // handshake, so this accepts a fresh transport epoch. Grace
                    // must end first: resolving a waiter while `isInGrace` is
                    // still true would hand callers a false admission signal.
                    self.acceptCurrentTransport()
                    ReliabilityDiagnostics.shared.reconnectHeal(epoch: self.transportEpoch)
                    // A quick heal (attempt-0 success, typically still inside
                    // grace): silently finalize any stream the drop left
                    // stranded — REQUIRED for `backfill()`'s `guard
                    // !isStreaming` to ever pass — but withhold the visible
                    // "Connection lost" warning since the user never saw a
                    // reconnect banner.
                    self.chatStore.handleConnectionDrop(stampWarning: false)
                    self.sessionStore.clearAllTurnsInProgress()
                    let recovered = await self.recoverActiveSession(generation: generation)
                    guard !Task.isCancelled,
                          self.isActiveGeneration(generation) else { return }
                    // A live socket without a resumed runtime is not a recovered
                    // chat. Keep the same reconnect loop alive so a transient
                    // `session.resume` failure retries instead of publishing a
                    // false `.connected` state that only an app restart resets.
                    guard recovered else {
                        throw GatewayError.timeout(method: "session.resume")
                    }
                    self.enterDraftIfNoActiveSession()
                    guard self.isActiveGeneration(generation) else { return }
                    self.phase = .connected
                    self.reconnectTask = nil
                    self.consecutiveReconnectFailures = 0
                    return
                } catch {
                    guard !Task.isCancelled,
                          self.isActiveGeneration(generation) else { return }
                    self.markTransportUnavailable()
                    // The WS handshake error is not typed as auth, so once a
                    // string of reconnects keep failing we re-probe REST to tell
                    // an auth *revocation* (→ re-pair) apart from plain
                    // unreachability (→ keep retrying). (D3 RE-PAIR FLOW: "WS
                    // rejects repeatedly".)
                    self.consecutiveReconnectFailures += 1
                    if self.consecutiveReconnectFailures >= Self.authReprobeThreshold,
                       await self.probeIsAuthRevoked(url: url, token: token) {
                        guard !Task.isCancelled,
                              self.isActiveGeneration(generation) else { return }
                        // A hard auth revocation must never be swallowed by
                        // grace — end it now and escalate straight to re-pair.
                        self.endGrace()
                        self.reauthRequired = true
                        self.requireTransportReauthentication()
                        self.phase = .needsSetup
                        self.reconnectTask = nil
                        return
                    }
                    guard !Task.isCancelled,
                          self.isActiveGeneration(generation) else { return }
                    // Keep trying; bump the attempt for a longer next backoff.
                    attempt += 1
                }
            }
        }
        #if DEBUG
        lastReconnectTask = reconnectTask
        #endif
    }

    /// Re-probe REST to determine whether the saved token has been revoked.
    /// Returns `true` only on a definitive auth rejection (401/403); any other
    /// outcome (success, network error, other status) returns `false` so the
    /// reconnect loop keeps retrying rather than dumping the user to re-pair on a
    /// transient outage.
    private func probeIsAuthRevoked(url: URL, token: String) async -> Bool {
        #if DEBUG
        if let hook = probeIsAuthRevokedRPC { return await hook() }
        #endif
        do {
            _ = try await RestClient(
                baseURL: stockProxyURL(forGateway: url), token: token
            ).status()
            return false
        } catch {
            return Self.isAuthFailure(error)
        }
    }

    /// Backoff in seconds for `attempt` ≥ 1: `min(0.5 * 2^attempt, 8) + jitter`.
    /// Attempt 0 is handled by the caller (immediate, no delay). Produces
    /// ~1s/2s/4s/8s/8s/… (WS-RECONNECT-SOFTEN c) — capped at 8s (not the
    /// previous 30s) so sustained failures against a crash-looping gateway
    /// still retry promptly for the user without ever exceeding a gentle
    /// worst-case request rate.
    static func backoffDelay(attempt: Int) -> Double {
        let base = min(0.5 * pow(2.0, Double(attempt)), 8.0)
        let jitter = Double.random(in: 0...0.5)
        return base + jitter
    }

    // MARK: - Auth-failure detection

    /// `true` when an error is a REST auth rejection (HTTP 401 or 403) — the
    /// signal that the device's pairing/token is no longer valid. (D3 RE-PAIR
    /// FLOW.)
    static func isAuthFailure(_ error: Error) -> Bool {
        if case let RestError.badStatus(code, _) = error {
            return code == 401 || code == 403
        }
        return false
    }

    /// The user-facing message returned to a configure caller when the token is
    /// rejected for auth — friendly, and pointing at the fix (scan a new code).
    static let reauthMessage =
        "This device's pairing was revoked. Scan a new pairing code to reconnect."

    /// Synchronously route a deliberate self-revoke to the re-pair state.
    ///
    /// External revocations still go through the reconnect-loop debounce; this
    /// path is only for the Settings → Devices branch where the UI already knows
    /// from `wasCurrent` that the current install revoked its own token.
    func requireRepairAfterCurrentDeviceRevoked(clearPrivacySurfaces: Bool = true) {
        advanceConnectionGeneration()
        reconnectTask?.cancel()
        reconnectTask = nil
        hydrationTask?.cancel()
        hydrationTask = nil
        sessionRefreshDebounceTask?.cancel()
        sessionRefreshDebounceTask = nil
        graceTask?.cancel()
        graceTask = nil
        isInGrace = false
        chatStore.handleConnectionDrop()
        sessionStore.clearAllTurnsInProgress()
        // ABH-410 follow-up: self-revoke is a stronger privacy action than
        // disconnect, so purge indexed session titles before routing to re-pair.
        if clearPrivacySurfaces {
            Self.log.notice("Self-device revoke clearing Hermes Spotlight session index")
            Self.clearSpotlightSessionIndexForPrivacy()
        }
        reauthRequired = true
        requireTransportReauthentication()
        hasConnected = false
        consecutiveReconnectFailures = 0
        phase = .needsSetup
    }

    /// User-visible, actionable copy for the non-retryable device registry cap.
    /// Shown as a non-blocking advisory because the shared token remains live; the
    /// user can keep chatting while they revoke an unused device and retry.
    static func deviceLimitReachedMessage(maxDevices: Int?) -> String {
        if let maxDevices {
            return "Device limit reached (\(maxDevices) devices). Revoke an unused device in Settings → Devices, then retry."
        }
        return "Device limit reached. Revoke an unused device in Settings → Devices, then retry."
    }

    private func handleDeviceLimitReached(serverURL: String, maxDevices: Int?) {
        deviceIssueLimitReachedServers.insert(serverURL)
        deviceLimitAdvisory = Self.deviceLimitReachedMessage(maxDevices: maxDevices)
    }

    // MARK: - Device-token auto-upgrade (W3A-A — silent rotation)

    /// Transparently swap a legacy SHARED token for a per-device token when the
    /// connected gateway advertises the W3a `devices` capability and this device
    /// does not yet hold a device token for `serverURL`.
    ///
    /// This is the migration bridge: the user's live phone is paired with the
    /// shared token today; after the server gains device routes, the FIRST
    /// connect silently issues a device token, persists it to the Keychain
    /// (overwriting the shared token IN THE KEYCHAIN ITEM for this server) and the
    /// non-secret `device_id` to UserDefaults, and re-points `currentToken`. The
    /// existing reconnect loop then reopens the live socket with that device token
    /// so the gateway can bind foreground/watch state to this phone. No second
    /// connection path or capability reset is introduced.
    ///
    /// Gating (ALL must hold, else this is a no-op):
    ///   - `devices == .available` (stock server / flaky probe ⇒ keep shared token,
    ///     never issue);
    ///   - no `device_id` already recorded for this server (already upgraded, or a
    ///     v2 QR handed us a device token — don't re-issue);
    ///   - we are still configured against `serverURL` with a live token;
    /// Device-token support is established by the capability probe itself. The
    /// stock loopback and gated auth paths now both consult the plugin token-auth
    /// seam, so `auth_required == false` is not a reason to keep the phone on the
    /// anonymous shared credential.
    ///
    /// FAILURE IS SILENT (binding) for transient/status failures: if `issueDevice`
    /// throws (500 persist failure, 401, transport), the app KEEPS the shared
    /// token (no regression) and the next connect retries (this method is
    /// re-invoked from `recoverActiveSession` after a reconnect). A device-limit
    /// 409 is the exception: it is user-visible and suppresses further automatic
    /// re-issues for this server until the user explicitly retries. The shared
    /// token never stops working.
    ///
    /// SECRETS HYGIENE (binding): the issued token goes straight to the Keychain
    /// + `currentToken` (in-memory, non-observable) and is NEVER logged,
    /// telemetered, written to UserDefaults, or held in a `@Snapshotable`
    /// accessor. Only the non-secret `device_id` is persisted to UserDefaults.
    func autoUpgradeToDeviceTokenIfNeeded(serverURL: String) async {
        // The server must advertise the capability — never issue against a stock
        // gateway (it has no route) or on an unsettled/flaky probe.
        guard capabilities.devices == .available else { return }
        // Already holding a device token for this server (prior upgrade or a v2
        // QR) → nothing to do.
        guard DefaultsKeys.deviceId(server: serverURL) == nil else { return }
        // A prior 409 is not transient; retrying it on every reconnect produces
        // the silent-forever loop ABH-254 is fixing. The existing offline banner's
        // Retry action re-enters `configure()`, which clears this suppression so a
        // user can re-attempt after revoking an unused device.
        guard !deviceIssueLimitReachedServers.contains(serverURL) else { return }
        // Must still be the active configuration with a live token + REST client.
        guard serverURLString == serverURL, let rest else { return }

        // STR-546/STR-512: single-flight the actual issue call per server.
        // Overlapping auto-upgrade attempts for the same server (e.g. the
        // initial connect racing a reconnect-loop retry) join the same
        // in-flight `Task` instead of each minting their own device token —
        // an unshared second issue would silently orphan the first and
        // silently consume a second slot against the 64-device cap
        // (STR-512). Cleared via `defer` on every exit from this function so
        // a later legitimate retry (after a failure or a Keychain-write
        // failure clears `device_id`) is never permanently suppressed.
        let issueTask: Task<IssuedDevice, Error>
        if let inFlight = autoUpgradeIssueTasks[serverURL] {
            issueTask = inFlight
        } else {
            #if DEBUG
            let issueDeviceRPC = issueDeviceRPC
            #endif
            issueTask = Task { [rest] in
                #if DEBUG
                if let issueDeviceRPC {
                    return try await issueDeviceRPC(rest, Self.deviceNameHint)
                }
                #endif
                return try await rest.issueDevice(name: Self.deviceNameHint)
            }
            autoUpgradeIssueTasks[serverURL] = issueTask
        }
        defer { autoUpgradeIssueTasks[serverURL] = nil }

        let issued: IssuedDevice
        do {
            issued = try await issueTask.value
        } catch DeviceIssueError.limitReached(let maxDevices) {
            handleDeviceLimitReached(serverURL: serverURL, maxDevices: maxDevices)
            return
        } catch {
            // Keep the shared token silently (no regression). A later connect
            // retries. Never log the error path with a token — `issueDevice`
            // surfaces only a status/transport error, never the token itself.
            return
        }

        // The connection may have changed (disconnect / re-configure to another
        // server) while the issue round-trip was in flight; only swap if we are
        // STILL configured against the same server with the same shared token we
        // started from. (A v2 QR re-pair mid-flight would have recorded a
        // device_id, caught by the guard re-check below.)
        guard serverURLString == serverURL,
              DefaultsKeys.deviceId(server: serverURL) == nil else { return }

        // Persist the device token to the Keychain (overwrites the shared token in
        // the per-server item) and re-point the in-memory token before reconnecting.
        do {
            try KeychainService.saveToken(issued.token, server: serverURL)
        } catch {
            // Keychain write failed — keep the shared token (still valid). Do NOT
            // record the device_id, so a later connect retries cleanly.
            return
        }
        currentToken = issued.token
        DefaultsKeys.setDeviceId(issued.deviceId, server: serverURL)
        // The live socket authenticated with the old shared token. Close it so
        // the existing reconnect loop immediately reopens with the device token;
        // foreground push suppression is intentionally tied to that live socket.
        if transportPath == .gatewayDirect {
            await client.disconnect()
        }
    }

    #if DEBUG
    /// DEBUG-only, NON-SECRET observability for the W3a integration gate: the
    /// recorded `device_id` for the current server (the proof the app
    /// auto-upgraded to a per-device token), or `nil` if it still holds the shared
    /// token. NEVER the token value — `device_id` is the opaque, non-secret handle
    /// (safe to list/log per the contract). Surfaced via the hand-maintained
    /// StateAccessor, mirroring the `fsCapability` pattern. Absent in Release.
    var recordedDeviceIdForCurrentServer: String? {
        DefaultsKeys.deviceId(server: serverURLString)
    }
    /// DEBUG-only observability: whether the Settings Devices section would render
    /// for the current connection (`devices == .available`). The integration
    /// gate's stock-degradation step asserts this is `false` on a stock server.
    var devicesSectionVisible: Bool {
        capabilities.devices == .available
    }

    /// DEBUG-only test seam: seed the in-memory connection state as if a prior
    /// `configure()` succeeded (stable URL + token stored, `hasConnected` true)
    /// then arm and fire the reconnect loop. Exercises the restart-survival path
    /// (4b) without a live socket: pair with `connectRPC` to inject a fake
    /// transport sequence (fail-once-then-succeed, immediate auth-revocation, …).
    ///
    /// Must only be called from unit tests — absent in Release.
    func _seedAndStartReconnect(serverURL: String, token: String) {
        let generation = advanceConnectionGeneration()
        serverURLString = serverURL
        currentToken = token
        hasConnected = true
        reauthRequired = false
        phase = .connected
        beginTransportAttempt()
        acceptCurrentTransport()
        markTransportUnavailable()
        startReconnectLoop(generation: generation)
    }

    /// DEBUG-only test seam: seed the app as already paired and connected without
    /// starting a reconnect loop. Used by ABH-355 regression coverage to exercise
    /// the real state-observer drop path from a connected, mid-stream shell.
    func _seedConnectedForTesting(serverURL: String, token: String) {
        advanceConnectionGeneration()
        serverURLString = serverURL
        currentToken = token
        hasConnected = true
        reauthRequired = false
        phase = .connected
        beginTransportAttempt()
        acceptCurrentTransport()
    }

    /// DEBUG-only test seam for a gateway-client state transition. This keeps the
    /// ABH-355 mid-turn disconnect test on the production handler (`handle(state:)`)
    /// instead of duplicating reconnect/drop logic in the test.
    func _handleGatewayStateForTesting(_ state: GatewayConnectionState) {
        handle(state: state, generation: connectionGeneration)
    }

    var _connectionGenerationForTesting: UInt64 { connectionGeneration }

    func _handleGatewayStateForTesting(
        _ state: GatewayConnectionState,
        generation: UInt64
    ) {
        handle(state: state, generation: generation)
    }

    func _handleDeviceLimitReachedForTesting(serverURL: String, maxDevices: Int?) {
        handleDeviceLimitReached(serverURL: serverURL, maxDevices: maxDevices)
    }

    func _isDeviceIssueLimitReachedSuppressedForTesting(serverURL: String) -> Bool {
        deviceIssueLimitReachedServers.contains(serverURL)
    }

    #endif

    /// The best client-side device-name hint available without a new entitlement.
    /// `UIDevice.current.name` returns a generic model name (e.g. "iPhone") on
    /// iOS 16+ without the user-assigned-device-name entitlement — acceptable per
    /// the contract (the name is a hint; a rename endpoint is a later follow-up).
    /// Falls back to "iPhone" off-UIKit (tests / extensions).
    static var deviceNameHint: String {
        #if canImport(UIKit)
        let name = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "iPhone" : name
        #else
        return "iPhone"
        #endif
    }

    /// After a (re)connect, re-resume the active session so its runtime id is
    /// valid on the new connection, then backfill the transcript over REST.
    @discardableResult
    private func recoverActiveSession(generation: UInt64) async -> Bool {
        guard isActiveGeneration(generation) else { return false }
        updatePhoneForeground(sessionStore.activeStoredId)
        // Re-probe capabilities after a reconnect — FORCED (R1 #57): this path
        // only runs after the socket genuinely dropped, and a restart on the
        // same URL may have swapped a stock↔patched gateway; the same-URL
        // cache short-circuit would pin stale feature gates for the whole app
        // version (features hidden, or shown against 404ing routes, device
        // auto-upgrade never firing).
        //
        // FIRE-AND-FORGET (build-30 freeze fix): spawned, NOT awaited inline.
        // probe() performs ~8 @Observable mutations on `capabilities` through
        // `resolvedPathStyle`, which `rest`/`control` read — so awaiting it
        // here serialized that invalidation thrash onto the reconnect-critical
        // path and saturated the main actor while the always-mounted drawer was
        // interactive (the W3 regression that froze the UI on reconnect →
        // drawer-open, and starved the transcript seed → empty render).
        // Hydration below must NOT wait on it: the session-list + transcript
        // endpoints are absolute and path-style-independent, and the
        // mobile-group affordances are UI-gated on the capability state the
        // probe still settles asynchronously (plus the background flows'
        // alternate-family 404 self-heal). Matches the proven initial-connect
        // contract in configure().
        if let rest {
            Task { [weak self] in
                guard let self, self.isActiveGeneration(generation) else { return }
                // WS-RECONNECT-SOFTEN (a): stagger this burst behind the
                // user-visible hydration below it (model refresh, session
                // resume, transcript backfill, session-list refresh all run
                // un-awaited by this task) — nothing on the happy path waits on
                // it, so the delay is invisible to the user.
                #if DEBUG
                let stagger = self.backgroundCapabilityBurstStaggerOverride ?? Self.backgroundCapabilityBurstStagger
                #else
                let stagger = Self.backgroundCapabilityBurstStagger
                #endif
                if stagger > .zero {
                    try? await Task.sleep(for: stagger)
                }
                guard self.isActiveGeneration(generation) else { return }
                // Throttle repeated FORCED re-probes: a reconnect crash-loop
                // (the gateway flapping every few seconds) would otherwise pile
                // 5 concurrent REST calls onto the server on EVERY attempt.
                // `force: false` still probes once per genuinely new server URL
                // (the in-memory/disk cache short-circuit only applies to a
                // server already probed this app version) — the throttle only
                // suppresses the *forced* re-probe of an already-known URL.
                #if DEBUG
                let minInterval = self.capabilitiesReprobeMinIntervalOverride ?? Self.capabilitiesReprobeMinInterval
                #else
                let minInterval = Self.capabilitiesReprobeMinInterval
                #endif
                let now = ContinuousClock.now
                let shouldForce: Bool
                if let last = self.lastForcedCapabilitiesProbeAt, now - last < minInterval {
                    shouldForce = false
                } else {
                    shouldForce = true
                    self.lastForcedCapabilitiesProbeAt = now
                }
                await self.capabilities.probe(
                    serverURL: self.serverURLString, rest: rest, force: shouldForce
                )
                guard self.isActiveGeneration(generation) else { return }
                // Capability-dependent settles run BEHIND the probe but OFF the
                // reconnect-critical path (same ordering as configure()).
                // W3A-A: retry the device-token auto-upgrade — covers a server
                // that gained device routes while offline, or a prior failed
                // issue. No-op once a device token is held.
                await self.autoUpgradeToDeviceTokenIfNeeded(serverURL: self.serverURLString)
                guard self.isActiveGeneration(generation) else { return }
                // F4b: re-load the switcher profile list now the capability is
                // re-affirmed (clears the cache on a stock gateway).
                await self.sessionStore.loadProfiles()
                guard self.isActiveGeneration(generation) else { return }
            }
        }
        // Re-resolve the running model — it may have changed while we were
        // offline (another client switched it) (F0).
        await refreshActiveModel(generation: generation)
        guard isActiveGeneration(generation) else { return false }
        // A failed resume for the still-selected session means this reconnect
        // did not recover a usable chat and must retry. A nil result after the
        // selection changed is supersession instead: follow the latest intent
        // (coalesced with any readiness-released `open()` task) rather than
        // treating the old A failure as B's failure.
        var selectedIdentity = sessionStore.activeScopedIdentity
        while let expectedIdentity = selectedIdentity {
            let resumedRuntime = await sessionStore.resumeActiveAfterReconnect()
            guard isActiveGeneration(generation) else { return false }
            if resumedRuntime != nil { break }

            let latestIdentity = sessionStore.activeScopedIdentity
            guard latestIdentity != expectedIdentity else { return false }
            selectedIdentity = latestIdentity
        }
        if sessionStore.activeStoredId != nil {
            await chatStore.backfill()
            guard isActiveGeneration(generation) else { return false }
            // Flush the offline outbox now the transcript is current — but only
            // with a live runtime session, or the queue would burn through with
            // a "No active session" error (see QueueStore drain notes).
            if sessionStore.activeRuntimeId != nil {
                // ABH-465: the durable outbox drains itself — wake() schedules the
                // flush without blocking reconnect (drain-in-line was the old queue).
                queueStore?.wake()
            }
        }
        await sessionStore.refresh()
        guard isActiveGeneration(generation) else { return false }
        // CACHE-FIRST coverage (WhatsApp bar): re-warm the recent transcripts now
        // the list is current again — covers sessions that moved while offline.
        sessionStore.prefetchRecentTranscripts()
        return true
    }

    // MARK: - Scene phase

    /// React to app lifecycle changes.
    ///
    /// `.active`: if the socket is dead (iOS killed it in the background) OR a
    /// reconnect loop is mid-backoff, cancel the pending wait and kick an
    /// IMMEDIATE reconnect attempt — the client must not sit in a multi-second
    /// backoff window while the user is staring at the screen. Then always
    /// backfill the transcript over REST to re-sync with other clients.
    /// `.background`/`.inactive`: cancel the paced transcript prefetch (WhatsApp
    /// bar) so it doesn't run against a socket iOS is about to kill; otherwise a
    /// no-op — the socket may be killed and we recover on the next foreground.
    func handleScenePhase(_ scenePhase: ScenePhase) {
        guard scenePhase == .active else {
            // Leaving the foreground: stop any in-flight prefetch sweep.
            sessionStore.cancelPrefetch()
            // §6a foreground hygiene (QA-1 B14): declare we are no longer
            // watching. iOS does not kill the relay WS the instant the app
            // backgrounds, so without this clear a turn completing seconds
            // after backgrounding would be §6-gated (user NOT watching, yet
            // the relay thinks they are) and the banner never fires. The
            // re-assert on return-to-foreground mirrors this clear.
            if transportPath == .relay {
                Task { [weak self] in
                    await self?.relayCoordinator?.clearForeground()
                }
            } else {
                updatePhoneForeground(nil)
            }
            return
        }
        guard hasConnected else { return }
        let generation = connectionGeneration

        Task { [weak self] in
            guard let self, self.isActiveGeneration(generation) else { return }
            let dead: Bool
            // Wave-2 relay transport: the gateway `client` is IDLE (never
            // connected) on this path — its state is always `.closed`, which
            // would make every foreground look like a dead connection and trigger
            // spurious reconnect churn. Check the RELAY socket instead.
            if self.transportPath == .relay {
                dead = !(self.relayCoordinator?.isOpen ?? false)
                if !dead {
                    // §6a: the background clear dropped the relay's foreground
                    // declaration for this socket; re-assert the driven session
                    // so pushes are gated again while the user is watching.
                    await self.relayCoordinator?.reassertForeground()
                }
            } else {
                self.updatePhoneForeground(self.sessionStore.activeStoredId)
                #if DEBUG
                let _liveState = await self.client.state
                let socketState = self.clientStateOverrideForScenePhase ?? _liveState
                #else
                let socketState = await self.client.state
                #endif
                guard self.isActiveGeneration(generation) else { return }
                switch socketState {
                case .closed, .failed: dead = true
                default: dead = false
                }
            }
            guard self.isActiveGeneration(generation) else { return }

            if dead {
                // The presentation phase may still be `.connected`; that is
                // silent-grace policy, not permission to send JSON-RPC.
                self.markTransportUnavailable()
                // iOS killed the socket in the background. If we already have a
                // reconnect loop running (possibly mid-backoff), RESET it so the
                // next attempt fires immediately rather than waiting out whatever
                // backoff interval was in progress. The user just foregrounded —
                // they expect instant reconnection. Cancelling the existing task
                // also cancels any pending `Task.sleep` inside it, so
                // `startReconnectLoop` can begin at attempt 0 with zero delay.
                if self.reconnectTask != nil || self.graceTask != nil {
                    self.reconnectTask?.cancel()
                    self.reconnectTask = nil
                    self.graceTask?.cancel()
                    self.graceTask = nil
                    self.isInGrace = false
                }
                // Do not finalize a turn or stamp a warning here. Cold-open
                // grace has the same presentation contract as a witnessed live
                // drop: `escalateGraceExpiry` performs that work only if the
                // replacement transport still has not healed.
                guard self.isActiveGeneration(generation) else { return }
                // A foreground/cold-open discovery has a shorter grace window
                // than a witnessed live drop. It preserves the existing UI
                // policy while ensuring the readiness contract is already false.
                #if DEBUG
                let grace = self.graceWindowOverride ?? Self.coldOpenGraceWindow
                #else
                let grace = Self.coldOpenGraceWindow
                #endif
                self.startGraceWindow(duration: grace, generation: generation)
            } else if case .connected = self.phase, self.transportPath != .relay {
                // R4/W2a (contract I13): the gateway-direct liveness probe +
                // REST backfill (`probeLiveness` on `client`, then
                // `chatStore.backfill()`) must no-op in relay mode — a healthy
                // relay foreground already re-asserted foreground above; the
                // coordinator owns resync/reconcile. Wave 4 deletes this whole
                // probe branch; this guard is the transitional day-1 no-op.
                // ABH-177: verify the socket is still alive with a read-only ping
                // before attempting the REST backfill. A silent-dead socket that
                // reports `.connected` at the transport level would otherwise pass
                // the `dead` check above, enter the backfill path, and then stall
                // or fail there. `probeLiveness` calls `handleSocketFailure` on a
                // dead ping, flipping transport state to `.failed` so the existing
                // state-observer–driven reconnect loop starts immediately.
                //
                // In DEBUG builds, `probeLivenessRPC` can be injected by tests to
                // exercise the full detection → reconcile → reconnect routing path
                // without needing to drive the real URLSession ping machinery.
                let alive: Bool
                #if DEBUG
                if let hook = self.probeLivenessRPC {
                    alive = await hook(HermesGatewayClient.livenessPingTimeout)
                } else {
                    alive = await self.client.probeLiveness()
                }
                #else
                alive = await self.client.probeLiveness()
                #endif
                guard self.isActiveGeneration(generation) else { return }
                guard alive else {
                    ReliabilityDiagnostics.shared.foregroundLiveness(alive: false)
                    self.markTransportUnavailable()
                    // ABH-177: the real `probeLiveness` path calls `handleSocketFailure`
                    // which sets transport state to `.failed`; the existing state observer
                    // then starts the reconnect loop. In tests the injected hook does NOT
                    // call `handleSocketFailure`, so we start the loop explicitly here to
                    // keep the routing correct in both code paths.
                    LiveActivityManager.shared.reconcile(hasActiveTurn: self.chatStore.isStreaming)
                    // Keep active-turn state intact during cold-open grace. If
                    // recovery does not heal in time, `escalateGraceExpiry`
                    // clears it alongside the visible disconnect treatment.
                    if self.reconnectTask != nil || self.graceTask != nil {
                        self.reconnectTask?.cancel()
                        self.reconnectTask = nil
                        self.graceTask?.cancel()
                        self.graceTask = nil
                        self.isInGrace = false
                    }
                    guard self.isActiveGeneration(generation) else { return }
                    #if DEBUG
                    let grace = self.graceWindowOverride ?? Self.coldOpenGraceWindow
                    #else
                    let grace = Self.coldOpenGraceWindow
                    #endif
                    self.startGraceWindow(duration: grace, generation: generation)
                    return
                }
                ReliabilityDiagnostics.shared.foregroundLiveness(alive: true)
                // ABH-182 Inc-1: on a healthy foreground, reconcile the LA so
                // any orphaned activity (e.g. from a previous backgrounded turn
                // whose message.complete was missed) is dismissed.
                LiveActivityManager.shared.reconcile(hasActiveTurn: self.chatStore.isStreaming)
                await self.chatStore.backfill()
                guard self.isActiveGeneration(generation) else { return }
                // ABH-86 item 5: refresh the session list on foreground so the
                // drawer reflects changes made on other clients while the app
                // was backgrounded. Uses the shared coalesced seam so a
                // simultaneous streaming trigger and a foreground collapse to one
                // fetch. The reconnect path already ends with `recoverActiveSession`
                // → `sessionStore.refresh()`, so this only runs on a live socket.
                self.scheduleSessionRefresh(generation: generation)
            }
        }
    }

    // MARK: - Running model (F0 / Amendment B)

    /// Fetch the gateway's currently-configured main model and publish its short
    /// display name into ``activeModelName``.
    ///
    /// Called on connect, after a reconnect, and after a model switch (the
    /// `ModelPickerView` `onModelChanged` hook → this). No-op when no control
    /// surface is configured. Best-effort: a probe failure leaves the prior
    /// value untouched rather than blanking the chip on a transient error.
    func refreshActiveModel() async {
        await refreshActiveModel(generation: connectionGeneration, requireActive: false)
    }

    private func refreshActiveModel(
        generation: UInt64,
        requireActive: Bool = true
    ) async {
        guard isCurrentGeneration(generation),
              (!requireActive || isActiveGeneration(generation)) else { return }
        guard let control else { return }
        guard let info = try? await control.modelInfo() else { return }
        guard isCurrentGeneration(generation),
              (!requireActive || isActiveGeneration(generation)) else { return }
        activeModelName = Self.shortModelName(provider: info.provider, model: info.model)
    }

    /// Reduce a wire model id to a compact chip label: drop a leading
    /// `provider/` (or `provider:`) prefix and any trailing 6–8 digit date stamp
    /// (e.g. `-20250514`, `-2024-08-06`). Returns `nil` when the model is absent
    /// or empties out — the chip stays hidden rather than showing a stray token.
    ///
    /// Examples:
    /// - `anthropic/claude-opus-4-20250514` → `claude-opus-4`
    /// - `claude-3-5-sonnet-20241022`       → `claude-3-5-sonnet`
    /// - `gpt-4o-2024-08-06`                → `gpt-4o`
    static func shortModelName(provider: String?, model: String?) -> String? {
        guard var name = model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }

        // Strip a leading provider qualifier ("anthropic/…", "openai:…").
        if let slashIdx = name.firstIndex(where: { $0 == "/" || $0 == ":" }) {
            name = String(name[name.index(after: slashIdx)...])
        }

        // Strip a trailing date stamp without eating a version number. Two
        // recognised shapes (and only these), so `claude-opus-4` keeps its `4`
        // while `claude-opus-4-20250514` loses the date:
        //   (a) one trailing segment of ≥ 6 digits — `…-20250514`
        //   (b) a trailing `YYYY-MM-DD` triple — `…-2024-08-06`
        var segments = name.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        func isDigits(_ s: String, _ n: Int) -> Bool { s.count == n && s.allSatisfy(\.isNumber) }
        func isLongDigits(_ s: String) -> Bool { s.count >= 6 && s.allSatisfy(\.isNumber) }

        if segments.count >= 4,
           isDigits(segments[segments.count - 1], 2),
           isDigits(segments[segments.count - 2], 2),
           isDigits(segments[segments.count - 3], 4) {
            // (b) YYYY-MM-DD — drop the trailing three segments.
            segments.removeLast(3)
        } else if segments.count >= 2, let last = segments.last, isLongDigits(last) {
            // (a) single compact date stamp — drop the trailing segment.
            segments.removeLast()
        }
        name = segments.joined(separator: "-")

        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "-").union(.whitespaces))
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Network path monitoring seam (S3)

/// The minimal path-reachability signal the S3 self-reconnect trigger consumes.
/// A deliberately reduced projection of `NWPath.Status` so the store's trigger
/// logic (and its tests) never depend on the `Network` framework's concrete
/// types.
enum NetworkPathStatus: Equatable, Sendable {
    /// A usable path exists (the only status that kicks a reconnect).
    case satisfied
    /// No usable path.
    case unsatisfied
    /// A path may become satisfied after a connection step (e.g. captive portal
    /// / VPN handshake). Treated as "still down" until it flips to `.satisfied`.
    case requiresConnection
}

/// Protocol-wrapped `NWPathMonitor` so tests can inject deterministic path
/// transitions without real hardware (the production impl is
/// ``NWPathMonitorAdapter``). Main-actor bound because its single consumer,
/// `ConnectionStore`, is `@MainActor` and mutates connection state on every
/// update.
@MainActor
protocol NetworkPathMonitoring: AnyObject {
    /// Invoked on the main actor for each path update after `start()`.
    var onPathUpdate: ((NetworkPathStatus) -> Void)? { get set }
    /// Begin delivering updates. Idempotent per instance.
    func start()
    /// Stop delivering updates and release the underlying monitor.
    func cancel()
}

/// Production ``NetworkPathMonitoring`` backed by `NWPathMonitor`. `NWPathMonitor`
/// delivers updates on a background dispatch queue, so each update hops to the
/// main actor before touching `onPathUpdate`.
@MainActor
final class NWPathMonitorAdapter: NetworkPathMonitoring {
    var onPathUpdate: ((NetworkPathStatus) -> Void)?
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ai.hermes.app.networkpath")
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let status: NetworkPathStatus
            switch path.status {
            case .satisfied: status = .satisfied
            case .unsatisfied: status = .unsatisfied
            case .requiresConnection: status = .requiresConnection
            @unknown default: status = .unsatisfied
            }
            Task { @MainActor [weak self] in
                self?.onPathUpdate?(status)
            }
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }
}
