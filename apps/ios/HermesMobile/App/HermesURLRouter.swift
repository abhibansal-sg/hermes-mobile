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
@MainActor
@Observable
final class DeepLinkCoordinator {
    /// The pairing payload awaiting user confirmation, or `nil` when none.
    var pendingPair: HermesURLRouter.PairPayload?

    init() {}

    /// Stash a payload for confirmation. Last-write-wins: a second pair link
    /// arriving before the user answers replaces the first (they re-tapped).
    func requestPairConfirmation(_ payload: HermesURLRouter.PairPayload) {
        pendingPair = payload
    }

    /// Drop any pending confirmation (the user dismissed / declined).
    func clear() {
        pendingPair = nil
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
/// - `hermesapp://` (bare root)       → no navigation; the app opens to the
///   session list, which already surfaces pending approvals (the activity's
///   "Review approval" link lands here).
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
    struct PairPayload: Equatable, Sendable {
        let url: String
        let token: String
        /// `true` iff the payload explicitly carried `kind=device` AND a non-empty
        /// `device_id`. When true, `token` IS already a device token and
        /// `deviceId` is its server-minted id — record it; do NOT auto-upgrade.
        /// When false, this is a v1 (shared) pairing — auto-upgrade handles it.
        let isDeviceToken: Bool
        /// The server-minted `device_id`, present iff `isDeviceToken`.
        let deviceId: String?
    }

    /// Parse a `hermesapp://pair?url=…&token=…[&kind=device&device_id=…]` payload
    /// into a ``PairPayload``. Returns `nil` for any non-pair URL or one missing
    /// either required value (`url`/`token`). The optional `kind`/`device_id` keys
    /// are read additively — a v1 payload (no `kind`) yields `isDeviceToken ==
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

        let urlValue = value("url") ?? ""
        let tokenValue = value("token") ?? ""
        guard !urlValue.isEmpty, !tokenValue.isEmpty else { return nil }

        // v2 additive keys (a v1 payload simply has neither).
        let kind = value("kind")?.lowercased()
        let deviceId = value("device_id")
        let isDevice = (kind == "device") && (deviceId?.isEmpty == false)

        return PairPayload(
            url: urlValue,
            token: tokenValue,
            isDeviceToken: isDevice,
            deviceId: isDevice ? deviceId : nil
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
    static func route(
        _ url: URL,
        connection: ConnectionStore,
        sessions: SessionStore,
        chat: ChatStore,
        inbox: InboxStore,
        requestPairConfirmation: ((PairPayload) -> Void)? = nil
    ) {
        guard url.scheme?.lowercased() == scheme else { return }

        // `URL.host` is the first authority component: "new-session", "session",
        // or empty for a bare `hermesapp://`.
        let host = url.host(percentEncoded: false) ?? ""

        switch host {
        case "new-session":
            PendingIntentRouter.apply(
                .newSession, connection: connection, sessions: sessions, chat: chat
            )

        case "session":
            // `hermesapp://session/<storedId>` — the stored id is the first path
            // component after the host.
            let storedId = url.pathComponents
                .first { $0 != "/" }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !storedId.isEmpty else { return }
            openSession(storedId: storedId, sessions: sessions, inbox: inbox)

        case "pair":
            // `?url=` + `?token=` carry the pairing payload (v1); a v2 payload
            // additionally carries `kind=device` + `device_id`. Empty/absent
            // required values are ignored (no destructive reconfigure on a
            // malformed link). The shared parser reads the optional v2 keys so a
            // tapped link records the device identity exactly like a scan.
            guard let payload = parsePairPayload(url.absoluteString) else { return }
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
    /// pairing deep link. Shared by the direct (unconfigured) path and the
    /// confirmed (was-connected) path so both run byte-identical `configure`s.
    static func applyPair(_ payload: PairPayload, connection: ConnectionStore) {
        // A `kind=device` QR payload comes from `hermes mobile-pair` (shared
        // dashboard flow) — mark the mode so the picker reflects what the user
        // actually did. A v1 (no kind) payload keeps whatever mode was selected.
        if payload.isDeviceToken {
            connection.connectionMode = .sharedDashboard
        }
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
