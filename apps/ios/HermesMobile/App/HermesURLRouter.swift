import Foundation
import Observation

/// Carries a deferred `hermesapp://pair` payload from the URL-open seam
/// (`HermesMobileApp.onOpenURL`) up to the confirmation UI in `RootView`.
///
/// Re-pairing while a connection already exists is destructive — it disconnects
/// the live session and re-points the gateway — so the router does NOT apply it
/// directly. Instead it stashes the parsed payload here and `RootView` presents a
/// "this will disconnect your current session" confirmation; on approve, the
/// view calls ``HermesURLRouter/applyPair(_:connection:)``. A `nil` `pending`
/// means no confirmation is in flight. Owned at the app root and injected into
/// `RootView` via the environment (it is not part of `AppEnvironment`, since the
/// confirmation is a pure view-layer concern).
///
/// Also carries the Inc-3b Local-desktop manual-token pairing state: when a
/// `hermesapp://pair?manual_token=true` arrives, the URL is pre-discovered but
/// the token must be entered by the user. `pendingManualTokenPair` holds that
/// state until `ManualTokenPromptView` resolves or dismisses it.
@MainActor
@Observable
final class DeepLinkCoordinator {
    /// The pairing payload awaiting user confirmation, or `nil` when none.
    var pendingPair: HermesURLRouter.PairPayload?

    /// A Local-desktop pairing payload that requires the user to enter the token
    /// manually (the plugin-side discovery found the URL but not the token).
    /// Non-nil causes `RootView`/`WelcomeView` to present `ManualTokenPromptView`.
    /// Cleared on completion (connect success or dismiss).
    var pendingManualTokenPair: HermesURLRouter.PairPayload?

    init() {}

    /// Stash a payload for confirmation. Last-write-wins: a second pair link
    /// arriving before the user answers replaces the first (they re-tapped).
    func requestPairConfirmation(_ payload: HermesURLRouter.PairPayload) {
        pendingPair = payload
    }

    /// Stash a manual-token Local-desktop payload. The user will be shown
    /// `ManualTokenPromptView` to enter the token before pairing proceeds.
    /// Last-write-wins (same as `requestPairConfirmation`).
    func requestManualTokenPair(_ payload: HermesURLRouter.PairPayload) {
        pendingManualTokenPair = payload
    }

    /// Drop any pending confirmation or manual-token prompt.
    func clear() {
        pendingPair = nil
        pendingManualTokenPair = nil
    }

    /// Drop only the manual-token prompt (used when the user dismisses without
    /// entering a token, leaving any unrelated `pendingPair` untouched).
    func clearManualTokenPair() {
        pendingManualTokenPair = nil
    }
}

/// Routes incoming `hermesapp://` deep links (emitted by the widgets and the
/// Live Activity — see X1's `HermesWidgetLink`) into the live store graph.
///
/// The widgets/activity only *produce* these URLs; acting on them is owned here.
/// The link contract (from `CONTRACT-WAVE1C.md` + `HermesWidgetLink`):
///
/// - `hermesapp://new-session`        → create + activate a fresh session.
/// - `hermesapp://session/<storedId>` → resume that stored session. When the id
///   cannot be resolved (deleted / archived / belongs to another server) the
///   route does NOT silently dead-end: it surfaces the inbox (the one approval-
///   reachable surface on both width classes), mirroring the push `attention`
///   fallback, so the tap always lands somewhere usable.
/// - `hermesapp://review`              → surface the pending-approval inbox.
/// - `hermesapp://` (bare root)       → start a usable draft surface.
/// - `hermesapp://pair?url=<u>&token=<t>` → configure the connection from a
///   pairing deep link (the `hermes mobile-pair` QR / link, owned by B4). The
///   same params the in-app QR scanner produces, so a tapped link and a scan
///   share one code path. Both query values are percent-decoded. When the app is
///   ALREADY configured (`ConnectionStore.rest != nil` — a live or saved
///   connection), re-pairing is destructive: it tears down the current session
///   and re-points the gateway. So a configured app does NOT reconfigure
///   silently — it raises a confirmation through `requestPairConfirmation` and
///   the user must approve the swap. An UNconfigured app (first run / pre-
///   bootstrap repair) pairs immediately, since there is nothing to lose. A
///   successful `configure` flips `ConnectionStore.phase` to `.connected` and
///   `RootView` re-renders out of the Welcome/setup surface automatically.
///
/// The `hermesapp://capture` route was REMOVED with Quick Capture; capture URLs
/// are no longer produced or honored.
///
/// All work is `@MainActor`: it drives the same `@Observable` stores the UI binds
/// to, so navigation/transcript changes are observed immediately.
@MainActor
enum HermesURLRouter {

    /// The custom URL scheme (mirrors `HermesWidgetLink.scheme`).
    static let scheme = "hermesapp"

    // MARK: - QR pairing payload (v1 + v2)

    /// A parsed `hermesapp://pair?…` payload. v1 carries only `url`+`token` (a
    /// SHARED token); v2 (W3a) additionally carries `kind=device` + `device_id`
    /// so the app records the device identity it was handed instead of
    /// auto-upgrading from a shared token.
    ///
    /// BACKWARD COMPAT (binding): `token` remains the credential key in BOTH
    /// versions, so an old parser never breaks. A v2 payload missing/absent
    /// `kind` (or `kind` != `"device"`) is treated as a SHARED pairing exactly
    /// as v1 — the app pairs with `token` and then (on a W3a server) auto-upgrades
    /// to a device token. `kind`/`device_id` are purely additive.
    struct RelayPairPayload: Equatable, Sendable {
        let relayURL: String
        let agentID: String
        let pairingSecret: String
    }

    struct PairPayload: Equatable, Identifiable, Sendable {
        /// Stable identity for `Identifiable` conformance (needed by `.sheet(item:)`
        /// in `RootView`). Keyed on the URL so re-tapping the same link produces
        /// the same identity; a different URL correctly replaces the sheet.
        var id: String { url }
        let url: String
        let token: String
        /// `true` iff the payload explicitly carried `kind=device` AND a non-empty
        /// `device_id`. When true, `token` IS already a device token and
        /// `deviceId` is its server-minted id — record it; do NOT auto-upgrade.
        /// When false, this is a v1 (shared) pairing — auto-upgrade handles it.
        let isDeviceToken: Bool
        /// The server-minted `device_id`, present iff `isDeviceToken`.
        let deviceId: String?
        /// `true` when the pairing payload arrives from the plugin-side Local-
        /// desktop discovery (`mobile_pair.py` Inc-3a) and the token CANNOT be
        /// recovered from disk — either the stock local gateway uses an ephemeral
        /// memory-only token, or the Desktop's connection.json uses Electron
        /// safeStorage encryption that is inaccessible outside the Electron context.
        ///
        /// When `true`, `token` is empty. The iOS app must ask the user to paste
        /// the token from the Desktop app's Settings UI (or run
        /// `hermes token` on the Mac).  The URL is pre-filled; only the token is
        /// required from the user.  The happy path (token present) is unchanged.
        ///
        /// (Inc-3b: wires the plugin's `manual_token=True` signal into the iOS UX.)
        let manualToken: Bool
        /// Relay pairing payload (`kind=relay`) minted by the configured relay.
        /// Kept separate from the dashboard-token path so callers do not confuse
        /// a relay pairing secret for a dashboard session token.
        let relayPair: RelayPairPayload?

        var isRelayPairing: Bool { relayPair != nil }

        init(
            url: String,
            token: String,
            isDeviceToken: Bool,
            deviceId: String?,
            manualToken: Bool,
            relayPair: RelayPairPayload? = nil
        ) {
            self.url = url
            self.token = token
            self.isDeviceToken = isDeviceToken
            self.deviceId = deviceId
            self.manualToken = manualToken
            self.relayPair = relayPair
        }
    }

    /// Parse a `hermesapp://pair?url=…&token=…[&kind=device&device_id=…]` payload
    /// into a ``PairPayload``. Returns `nil` for any non-pair URL or one missing
    /// the required `url` value.
    ///
    /// **Inc-3b additive:** when `manual_token=true` is present the `token` query
    /// param may be absent (the plugin-side discovery cannot recover it). In that
    /// case `token` is empty and `manualToken` is `true`; the caller must ask the
    /// user to supply the token. For all other payloads `token` is required as
    /// before (returns `nil` when absent/empty). The optional `kind`/`device_id`
    /// keys are read additively — a v1 payload (no `kind`) yields `isDeviceToken ==
    /// false`; a v2 `kind=device` payload WITH a non-empty `device_id` yields
    /// `isDeviceToken == true`. Any other `kind` value, or a `kind=device` missing
    /// `device_id`, falls back to a shared pairing (defensive). Single parser
    /// shared by the in-app QR scanner and the deep-link route so a scan and a
    /// tapped link behave identically.
    static func parsePairPayload(_ payload: String) -> PairPayload? {
        guard
            let url = URL(string: payload),
            url.scheme?.lowercased() == scheme,
            (url.host(percentEncoded: false) ?? "") == "pair",
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        func value(_ name: String) -> String? {
            components.queryItems?
                .first(where: { $0.name == name })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let kind = value("kind")?.lowercased()

        if kind == "relay" {
            let relayURL = value("relay") ?? ""
            let agentID = value("agent") ?? ""
            let pairingSecret = value("pairing") ?? ""
            guard !relayURL.isEmpty, !agentID.isEmpty, !pairingSecret.isEmpty else { return nil }
            return PairPayload(
                url: relayURL,
                token: pairingSecret,
                isDeviceToken: false,
                deviceId: nil,
                manualToken: false,
                relayPair: RelayPairPayload(
                    relayURL: relayURL,
                    agentID: agentID,
                    pairingSecret: pairingSecret
                )
            )
        }

        let urlValue = value("url") ?? ""
        guard !urlValue.isEmpty else { return nil }

        // Inc-3b: `manual_token=true` signals that the plugin-side discovery
        // couldn't recover the token (ephemeral/encrypted). Allow a missing or
        // empty `token` param when this flag is present; set manualToken = true.
        let manualTokenFlag = value("manual_token")?.lowercased() == "true"
        let tokenValue = value("token") ?? ""

        // For standard payloads (no manual_token flag), token is still required.
        if !manualTokenFlag && tokenValue.isEmpty { return nil }

        // v2 additive keys (a v1 payload simply has neither).
        let deviceId = value("device_id")
        let isDevice = (kind == "device") && (deviceId?.isEmpty == false)

        return PairPayload(
            url: urlValue,
            token: manualTokenFlag ? "" : tokenValue,
            isDeviceToken: isDevice,
            deviceId: isDevice ? deviceId : nil,
            manualToken: manualTokenFlag
        )
    }

    /// Parse + apply a deep link. Unknown schemes/hosts are ignored.
    ///
    /// - Parameter inbox: surfaced when a `session/<id>` deep link cannot be
    ///   resolved, so the tap never dead-ends silently (mirrors the push path).
    /// - Parameter requestPairConfirmation: invoked (instead of reconfiguring)
    ///   when a `pair` link arrives while the app is ALREADY configured, so the
    ///   user can confirm the destructive disconnect-and-repair. `nil` is treated
    ///   as "no confirmation available" → a configured app then ignores the link
    ///   rather than silently nuking the live session.
    /// - Parameter requestManualTokenPair: invoked when a `pair` link arrives
    ///   with `manual_token=true` — the plugin-side Local-desktop discovery found
    ///   the gateway URL but could not recover the token (ephemeral/encrypted).
    ///   The payload carries the pre-discovered URL; the user must paste their
    ///   Desktop token.  `nil` treated as "no prompt available" → the payload is
    ///   dropped rather than silently failing (same defensive posture as the
    ///   confirmation seam).  (Inc-3b)
    static func route(
        _ url: URL,
        connection: ConnectionStore,
        sessions: SessionStore,
        chat: ChatStore,
        inbox: InboxStore,
        requestPairConfirmation: ((PairPayload) -> Void)? = nil,
        requestManualTokenPair: ((PairPayload) -> Void)? = nil
    ) {
        guard url.scheme?.lowercased() == scheme else { return }

        // `URL.host` is the first authority component: "new-session", "session",
        // or empty for a bare `hermesapp://`.
        let host = url.host(percentEncoded: false) ?? ""

        switch host {
        case "new-session":
            if routeToRunningTurnIfNeeded(url, sessions: sessions, chat: chat, inbox: inbox) {
                return
            }
            PendingIntentRouter.apply(
                .newSession, connection: connection, sessions: sessions, chat: chat
            )

        case "session":
            // `hermesapp://session/<storedId>` — the stored id is the first path
            // component after the host. ABH-192: an optional `?message=<n>` query
            // carries a wire message_id to scroll the opened transcript to
            // (jump-to-exact-message); when present it is stashed on
            // `SessionStore.pendingMessageJump` before the open so ChatView's
            // transcript-generation observer resolves it once the rows load.
            let storedId = url.pathComponents
                .first { $0 != "/" }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !storedId.isEmpty else { return }
            if let messageParam = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "message" })?.value,
               let messageId = Int(messageParam),
               messageId > 0 {  // N2: wire message_id is a positive ordinal;
                                // reject 0/negatives/NaN. Graceful — invalid
                                // just means no jump (native bottom anchor).
                sessions.pendingMessageJump = messageId
            }
            openSession(storedId: storedId, sessions: sessions, inbox: inbox)

        case "review":
            // Explicit widget / Live Activity approval affordance. Keep this
            // separate from the bare root route, whose contract is to start a
            // usable draft, so "Review approval" taps surface the pending prompt.
            inbox.requestPresentation()

        case "pair":
            // `?url=` + `?token=` carry the pairing payload (v1); a v2 payload
            // additionally carries `kind=device` + `device_id`. Empty/absent
            // required values are ignored (no destructive reconfigure on a
            // malformed link). The shared parser reads the optional v2 keys so a
            // tapped link records the device identity exactly like a scan.
            //
            // Inc-3b: `?manual_token=true` signals a Local-desktop payload where
            // the token cannot be auto-recovered; token is empty, URL is present.
            guard let payload = parsePairPayload(url.absoluteString) else { return }

            // Inc-3b: manual-token Local-desktop pairing — the URL is pre-filled
            // but the user must supply the token. Route to the token-entry prompt
            // rather than straight to configure(), regardless of whether a
            // connection already exists (the prompt carries all the context needed
            // for the user to decide). The requestManualTokenPair seam is invoked
            // to stash the payload; if no seam is wired, drop the link (same
            // defensive posture as the pair-confirmation path).
            if payload.manualToken {
                requestManualTokenPair?(payload)
                return
            }

            // Re-pairing WHILE CONNECTED is destructive (it disconnects the
            // current session and re-points the gateway). If a configuration
            // already exists, defer to a user confirmation instead of swapping
            // silently. An unconfigured app (first run / pre-bootstrap repair)
            // pairs immediately — nothing to lose. `rest != nil` iff a server
            // URL + token are already in place (a live or restored connection).
            if connection.rest != nil {
                if let requestPairConfirmation {
                    requestPairConfirmation(payload)
                }
                // No confirmation seam wired → do NOT silently reconfigure over a
                // live session; drop the link.
                return
            }
            applyPair(payload, connection: connection)

        case "":
            if routeToRunningTurnIfNeeded(url, sessions: sessions, chat: chat, inbox: inbox) {
                return
            }
            // Bare root (Live Activity / widget link): land on a USABLE
            // surface. `closeActive()` left compact width on a permanent
            // "Loading conversation…" spinner with a dead composer (R1 #96 —
            // the same dead state as the delete path, reached via deep link).
            // A fresh draft gives the greeting + a live composer on both
            // widths, and the drawer/inbox still surface pending approvals.
            sessions.startDraft()

        default:
            // Unknown host — ignore rather than guess.
            break
        }
    }

    /// Preserve the running turn when a widget / Live Activity tap foregrounds
    /// the app through a generic open/new-session route.
    ///
    /// The root and status-widget routes still create a draft when idle. But while
    /// the app is already rendering a turn, treating that tap as "new session"
    /// calls `SessionStore.startDraft()`, which resets `ChatStore`, cancels the
    /// stream, and fires `onTurnDiscarded` (ending the activity the user tapped).
    /// A tap on a live surface is navigation-to-self, not discard.
    @discardableResult
    private static func routeToRunningTurnIfNeeded(
        _ url: URL,
        sessions: SessionStore,
        chat: ChatStore,
        inbox: InboxStore
    ) -> Bool {
        guard chat.isStreaming else { return false }

        let targetRuntimeId = liveActivitySessionId(from: url)
            ?? LiveActivityManager.shared.currentSessionIdForRouting
            ?? sessions.activeRuntimeId

        guard let targetRuntimeId, !targetRuntimeId.isEmpty else {
            // We know a turn is live, but not enough to translate it. The honest
            // action is to leave the current transcript intact rather than wipe it.
            return true
        }
        resumeRunningTurn(runtimeSessionId: targetRuntimeId, sessions: sessions, inbox: inbox)
        return true
    }

    /// Parse an optional runtime id carried by a future/ActivityKit-specific URL.
    /// Existing `hermesapp://` and `hermesapp://new-session` links omit it, so this
    /// is strictly additive and falls back to the app-side LiveActivityManager id.
    private static func liveActivitySessionId(from url: URL) -> String? {
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "session_id" || $0.name == "sessionId" }?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    /// Route to the stored session for a live runtime id without resetting the
    /// already-open live transcript when the target is the current session.
    private static func resumeRunningTurn(
        runtimeSessionId: String,
        sessions: SessionStore,
        inbox: InboxStore
    ) {
        let storedId = inbox.storedSessionId(forRuntime: runtimeSessionId)
            ?? (sessions.activeRuntimeId == runtimeSessionId ? sessions.activeStoredId : nil)
            ?? (sessions.sessions.contains { $0.id == runtimeSessionId } ? runtimeSessionId : nil)

        guard let storedId, !storedId.isEmpty else { return }
        guard sessions.activeStoredId != storedId else { return }
        if let summary = sessions.sessions.first(where: { $0.id == storedId }) {
            sessions.open(summary)
            return
        }
        Task {
            await sessions.refresh()
            if let summary = sessions.sessions.first(where: { $0.id == storedId }) {
                sessions.open(summary)
            } else {
                inbox.requestPresentation()
            }
        }
    }

    // MARK: - Push notification taps (B5)

    /// Route a tapped push notification into the store graph.
    ///
    /// Reuses the same activation plumbing as the deep-link `session` route. Push
    /// payloads carry the **runtime** `session_id` (see `tui_gateway/server.py`
    /// `_push_hook` → `push_notify.notify(..., {"session_id": sid})`), while
    /// `SessionStore.open(_:)` is keyed by the **stored** id. So we translate
    /// runtime → stored first via the inbox (which holds both, broadcast for every
    /// prompt), then fall back to treating the id as a stored id directly (REST
    /// rows and the RPC list both key on the stored id, and the two coincide for
    /// fresh sessions that were never compressed).
    ///
    /// - `attention` (approval / clarify): open the session; if it can't be
    ///   located even after a refresh, surface the inbox so the pending prompt is
    ///   still reachable.
    /// - `turnComplete`: open the session (no inbox fallback — nothing to action).
    static func routePushTap(
        _ tap: NotificationService.Tap,
        sessions: SessionStore,
        inbox: InboxStore
    ) {
        switch tap {
        case .attention(let sessionId):
            openForPush(runtimeSessionId: sessionId, sessions: sessions, inbox: inbox, surfaceInboxIfMissing: true)
        case .turnComplete(let sessionId):
            openForPush(runtimeSessionId: sessionId, sessions: sessions, inbox: inbox, surfaceInboxIfMissing: false)
        }
    }

    // MARK: - Spotlight / Handoff continuation (L11)

    /// Route a restored `NSUserActivity` — either a Handoff of the open-session
    /// activity (`SpotlightIndexer.openSessionActivityType`) or a Spotlight result
    /// tap (`CSSearchableItemActionType`) — into the store graph.
    ///
    /// Both carry a `stored_session_id`; `SpotlightIndexer.sessionId(fromActivity:)`
    /// decodes whichever form arrived. We then reuse the SAME stored-id resolution
    /// (+ inbox fallback) as the `session/<id>` deep link, so a Spotlight tap on a
    /// session that has since been deleted/archived surfaces the inbox instead of
    /// dead-ending. Unrecognized activities are ignored.
    ///
    /// Cold-launch vs warm: on a cold launch iOS replays the activity right after
    /// the scene connects; `openSession` refreshes the (possibly empty) list before
    /// resolving, so a tap that beat the first `SessionStore.refresh` still lands.
    /// - Returns: `true` if the activity was a recognized Hermes session
    ///   continuation (so the caller can mark it handled), `false` otherwise.
    @discardableResult
    static func routeContinuedActivity(
        _ activity: NSUserActivity,
        sessions: SessionStore,
        inbox: InboxStore
    ) -> Bool {
        guard let storedId = SpotlightIndexer.sessionId(fromActivity: activity),
              !storedId.isEmpty else {
            return false
        }
        openSession(storedId: storedId, sessions: sessions, inbox: inbox)
        return true
    }

    /// Resolve a runtime session id to a stored session and open it. When the
    /// session can't be found and `surfaceInboxIfMissing` is set, request the
    /// inbox instead so the user can still reach the prompt.
    private static func openForPush(
        runtimeSessionId: String,
        sessions: SessionStore,
        inbox: InboxStore,
        surfaceInboxIfMissing: Bool
    ) {
        // Prefer the inbox's runtime→stored mapping; fall back to the raw id.
        let storedId = inbox.storedSessionId(forRuntime: runtimeSessionId) ?? runtimeSessionId

        if let summary = sessions.sessions.first(where: { $0.id == storedId }) {
            sessions.open(summary)
            return
        }
        Task {
            await sessions.refresh()
            if let summary = sessions.sessions.first(where: { $0.id == storedId }) {
                sessions.open(summary)
            } else if surfaceInboxIfMissing {
                // Couldn't locate the session — make sure the pending prompt is
                // still reachable by surfacing the inbox.
                inbox.requestPresentation()
            }
        }
    }

    /// Apply a parsed pairing payload: (re)configure the connection from a
    /// pairing deep link or in-app QR scan. Shared by the direct (unconfigured)
    /// path, the confirmed (was-connected) path, and the in-app QR scanner so
    /// all three run byte-identical `configure`s with the correct mode tag.
    ///
    /// **Inc 2 (Follow-up A):** all pair payloads — v1 (shared token) AND v2
    /// (device token) — set `.sharedDashboard` so the mode picker reflects the
    /// scan, and the transport uses loopback Host for the Tailscale-Serve path.
    /// Previously only v2 payloads tagged the mode, leaving v1 scans on whatever
    /// mode the picker last persisted (a stale `.remoteURL` would then emit the
    /// wrong Host header once Inc 2 transport-branches on the mode).
    static func applyPair(_ payload: PairPayload, connection: ConnectionStore) {
        guard !payload.isRelayPairing else { return }
        // All QR / deep-link pair payloads come from the shared-dashboard flow —
        // tag the mode so the picker reflects the action AND so the transport
        // derives the correct loopback Host header (Tailscale Serve path).
        connection.connectionMode = .sharedDashboard
        Task {
            _ = await connection.configure(
                urlString: payload.url,
                token: payload.token,
                issuedDeviceId: payload.deviceId
            )
        }
    }

    /// Resume a stored session by id. If it's already in the loaded list, open it
    /// directly; otherwise refresh the list first, then open if it appears. If it
    /// STILL can't be found after the refresh (deleted / archived / belongs to a
    /// different server), the inbox is surfaced rather than letting the tap
    /// dead-end silently — mirroring the push `attention` fallback so a deep link
    /// to a vanished session always lands on a usable, approval-reachable surface.
    private static func openSession(
        storedId: String,
        sessions: SessionStore,
        inbox: InboxStore
    ) {
        if let summary = sessions.sessions.first(where: { $0.id == storedId }) {
            sessions.open(summary)
            return
        }
        Task {
            await sessions.refresh()
            if let summary = sessions.sessions.first(where: { $0.id == storedId }) {
                sessions.open(summary)
            } else {
                // Unresolvable id — surface the inbox so the tap is never a
                // silent no-op (R1 dead-end fix).
                inbox.requestPresentation()
            }
        }
    }
}
