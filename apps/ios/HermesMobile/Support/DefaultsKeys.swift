import Foundation

/// Centralized `UserDefaults` key constants, so a key's spelling can never drift
/// between writer and reader and so every standard-`UserDefaults` key the app uses
/// has one canonical home.
///
/// Every app-level `UserDefaults` key lives here — including keys read/written by a
/// single type (their owning type documents intent next to the constant). The only
/// keys that stay elsewhere are the **app-group** keys in ``SharedStore`` (a
/// different suite, shared with the widget/share extensions), notification category
/// identifiers, and view-local scroll-anchor ids — none of which are
/// `UserDefaults(standard)` preference keys.
enum DefaultsKeys {

    // MARK: Connection

    /// `String` — the saved gateway base URL. Owned by ``ConnectionStore``.
    static let serverURL = "hermes.serverURL"

    /// `Bool` — an explicit, durable user choice to suppress bootstrap and
    /// reconnect work while preserving the pairing and every local cache.
    static let connectionOffline = "hermes.connectionOffline"

    /// `String` — optional address of the transparent gateway proxy. Empty or
    /// absent uses the paired gateway address directly.
    static let relayURLOverride = "hermes.relayURLOverride"

    static func relayURLOverrideValue(_ defaults: UserDefaults = .standard) -> String? {
        let raw = defaults.string(forKey: relayURLOverride)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    /// `Data` — protected, non-content cleanup retry metadata. This contains
    /// only the gateway URL and device id; never a credential or user content.
    static let gatewayCleanupTombstone = "hermes.gatewayCleanupTombstone"

    // MARK: Appearance

    /// `String` (raw value) — the selected theme preset. Owned by ``ThemeStore``.
    static let theme = "hermes.theme"

    // MARK: Session list (persisted UI state)

    /// `[String]` — pinned `stored_session_id`s. Owned by ``SessionStore``.
    static let pinnedSessions = "hermes.pinnedSessions"

    /// `Bool` — whether cron-sourced sessions are hidden from the list. Owned by
    /// ``SessionStore``.
    static let hideCron = "hermes.hideCron"

    /// `Bool` — whether the drawer's Recents list is grouped by workspace
    /// (`cwd`). **Default false** (flat list). Owned by ``SessionStore`` (UI
    /// Batch H2); `UserDefaults.bool(forKey:)` already reads the absent key as
    /// `false`.
    static let groupByWorkspace = "hermes.groupByWorkspace"

    /// `[String]` — workspace keys (`cwd` paths, trimmed) whose groups are
    /// currently collapsed in the grouped Recents list. A key's presence in this
    /// set means collapsed; absence means expanded. Default empty (all groups
    /// expanded). Owned by ``SessionStore``; persisted so collapse state survives
    /// app restarts.
    static let collapsedWorkspaces = "hermes.collapsedWorkspaces"

    /// `[String]` — workspace keys that have been pinned to the top of the
    /// grouped Recents list. Pinned groups appear before recency-ordered groups;
    /// within the pinned tier, recency order is preserved. Default empty.
    /// Owned by ``SessionStore``.
    static let pinnedWorkspaces = "hermes.pinnedWorkspaces"

    /// `[String]` — profile names whose All Profiles drawer group the user has
    /// EXPLICITLY collapsed, overriding the collapsed-by-default rule (STR-1022).
    /// Pairs with ``expandedProfiles``: the effective state is derived from these
    /// two sets plus the default rule (collapse every group except the default
    /// profile), so no one-shot seeding is needed and newly-discovered profiles
    /// auto-collapse without erasing prior choices. Default empty.
    static let collapsedProfiles = "hermes.collapsedProfiles"

    /// `[String]` — profile names the user has EXPLICITLY expanded beyond the
    /// collapsed-by-default rule (STR-1022), so a non-default group they opened
    /// stays open across restarts. Default empty.
    static let expandedProfiles = "hermes.expandedProfiles"

    /// `String` — the active multi-profile SCOPE for the session rail (F4b). The
    /// sentinel ``allProfilesScope`` (`"all"`) or an empty/absent value = the
    /// aggregate "All profiles" view; any other value = that profile's name. Owned
    /// by ``SessionStore``; drives the rail fetch (aggregate vs the existing
    /// `GET /api/sessions`) and the `visibleSessions` filter. Inert unless the
    /// `profiles` capability is `.available` AND the switcher is shown, so the
    /// dormant single-profile path is unaffected by any stale value.
    static let activeProfile = "hermes.activeProfile"

    /// Encoded session-list delta cursors, partitioned by their full fetch scope.
    /// Owned and restored by ``SessionStore``.
    static let sessionListDeltaCursors = "hermes.sessionListDeltaCursors"

    /// Sentinel value of ``activeProfile`` meaning the cross-profile aggregate
    /// view (matches the server's `profile="all"` wire value).
    static let allProfilesScope = "all"

    // MARK: Prompt queue / pending intent

    /// `String` (JSON) — the persistent prompt outbox/queue. Owned by ``QueueStore``.
    static let queue = "hermes.queue"

    /// `String` — a prompt captured by an App Intent while disconnected, replayed
    /// on next launch. Owned by ``PendingIntent``.
    static let pendingIntentPrompt = "hermes.pendingIntentPrompt"

    // MARK: App lock

    /// `Bool` — whether Face ID/passcode app lock is enabled. Owned by ``AppLock``.
    static let appLockEnabled = "hermes.appLockEnabled"

    // MARK: Push / notifications

    /// `Bool` — whether the user opted into push notifications. Owned by
    /// ``PushRegistrar``.
    static let pushEnabled = "hermes.pushEnabled"

    /// `String` — the last APNs device token registered with the gateway, so a
    /// no-op re-register can be skipped. Owned by ``PushRegistrar``.
    static let pushLastDeviceToken = "hermes.push.lastDeviceToken"

    /// `[String]` — the per-event subset last successfully registered with the
    /// gateway, so a prefs change (A4) can force a re-POST even when the device
    /// token is unchanged. Owned by ``PushRegistrar``.
    static let pushLastEvents = "hermes.push.lastEvents"

    /// `String` — the APNs environment (`"sandbox"` / `"production"`) under which
    /// the last successful registration was issued. Added to the dedupe key so that
    /// a sandbox→production transition (Xcode → TestFlight on the same token) forces
    /// a re-POST and the gateway routes the token to the correct APNs host. Owned by
    /// ``PushRegistrar``.
    static let pushLastEnv = "hermes.push.lastEnv"

    /// `String` — non-secret hash of gateway URL + credential/device identity
    /// used for the last successful alert-token registration. Prevents a token
    /// registered against one pairing from becoming APNs authority after a
    /// gateway switch or re-pair. Owned by ``PushRegistrar``.
    static let pushLastRegistrationScope = "hermes.push.lastRegistrationScope"

    /// `Bool` — whether the most recent APNs/gateway registration attempt is
    /// known healthy. Missing is deliberately false (local fallback) until a
    /// successful registration proves remote delivery is authoritative.
    static let pushRegistrationHealthy = "hermes.push.registrationHealthy"

    /// `Bool` — whether notification authorization has already been requested once,
    /// so the prompt isn't re-shown. Owned by ``NotificationService``.
    static let notificationsDidRequestAuthorization =
        "hermes.notifications.didRequestAuthorization"

    // MARK: Per-event push preferences (F2-A / A4)
    //
    // Five independent toggles for which push event kinds the gateway should
    // deliver. Each maps to one wire `events` token: `"approval"`, `"clarify"`,
    // `"turn_complete"`, `"turn_error"`, or `"background_done"`.
    // ALL DEFAULT ON — the keys read as `false` when absent,
    // so the accessors below invert through `object(forKey:) == nil ? true : …`
    // to make "unset" mean "on" (legacy installs / first launch get everything).
    // Owned by ``SettingsView`` (writer) + ``PushRegistrar`` (reads the list to
    // re-register).

    /// `Bool` — deliver approval-request pushes. Default ON.
    static let pushEventApproval = "hermes.push.event.approval"
    /// `Bool` — deliver clarification (question) pushes. Default ON.
    static let pushEventClarify = "hermes.push.event.clarify"
    /// `Bool` — deliver long-turn-complete pushes. Default ON.
    static let pushEventTurnComplete = "hermes.push.event.turnComplete"
    /// `Bool` — deliver errored-turn pushes. Default ON.
    static let pushEventTurnError = "hermes.push.event.turnError"
    /// `Bool` — deliver background-job-complete pushes. Default ON.
    static let pushEventBackgroundDone = "hermes.push.event.backgroundDone"

    /// Read a default-ON push-event toggle: a *missing* key reads as `true`
    /// (everything on by default); a present key is honored verbatim.
    static func pushEventEnabled(_ key: String, _ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }

    /// The wire `events` list for `/api/push/register`, built from the five
    /// toggles. Order is stable (`approval`, `clarify`, `turn_complete`,
    /// `turn_error`, `background_done`) so the body is deterministic for tests
    /// and access-log assertions.
    static func pushEventList(_ defaults: UserDefaults = .standard) -> [String] {
        var events: [String] = []
        if pushEventEnabled(pushEventApproval, defaults) { events.append("approval") }
        if pushEventEnabled(pushEventClarify, defaults) { events.append("clarify") }
        if pushEventEnabled(pushEventTurnComplete, defaults) { events.append("turn_complete") }
        if pushEventEnabled(pushEventTurnError, defaults) { events.append("turn_error") }
        if pushEventEnabled(pushEventBackgroundDone, defaults) { events.append("background_done") }
        return events
    }

    // MARK: Server capabilities (E1)

    /// `String` (JSON) — cache of the last probed ``ServerCapabilities`` snapshot,
    /// scoped to the server URL + app version it was probed against. Lets a
    /// reconnect to the same server reuse the prior probe result instead of
    /// re-probing. Owned by ``ServerCapabilities``; written/read only there.
    static let serverCapabilities = "hermes.serverCapabilities"

    // MARK: Per-device token identity (W3A-A)
    //
    // The NON-SECRET, stable `device_id` the server minted for THIS device,
    // scoped per server URL (mirroring the one-token-per-gateway Keychain model).
    // The device TOKEN itself lives ONLY in the Keychain (the existing
    // `KeychainService`, keyed by server URL) — never here, never in any
    // `@Snapshotable` accessor, never in the DEBUG ring buffer (secrets hygiene,
    // binding). `device_id` is safe to persist: it is not secret and the panel
    // reads it to mark "This device". Owned by ``ConnectionStore`` (the
    // auto-upgrade / QR-v2 paths write it; the Devices panel reads it).

    /// The `UserDefaults` dictionary mapping a server URL → its recorded
    /// `device_id`. A dictionary (not one flat key) so multiple paired gateways
    /// each keep their own id, matching the per-server Keychain token model.
    static let deviceIdsByServer = "hermes.deviceIdsByServer"

    /// The recorded (non-secret) `device_id` for `server`, or `nil` if this
    /// device has not yet auto-upgraded / been issued a device token for it.
    /// Its presence is the signal the auto-upgrade path uses to decide it has
    /// already swapped to a device token (so it does NOT re-issue on every
    /// connect).
    static func deviceId(server: String, _ defaults: UserDefaults = .standard) -> String? {
        let map = defaults.dictionary(forKey: deviceIdsByServer) as? [String: String]
        let value = map?[server]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// Record (or clear, with `nil`) the `device_id` for `server`. Writing a new
    /// id is the second half of the auto-upgrade / QR-v2 swap (the token went to
    /// the Keychain; the id goes here). Clearing is used when a device is revoked
    /// from THIS device so the next connect re-issues a fresh device token.
    static func setDeviceId(_ deviceId: String?, server: String, _ defaults: UserDefaults = .standard) {
        var map = (defaults.dictionary(forKey: deviceIdsByServer) as? [String: String]) ?? [:]
        if let deviceId, !deviceId.isEmpty {
            map[server] = deviceId
        } else {
            map.removeValue(forKey: server)
        }
        if map.isEmpty {
            defaults.removeObject(forKey: deviceIdsByServer)
        } else {
            defaults.set(map, forKey: deviceIdsByServer)
        }
    }

    // MARK: - Push registration device id fallback (QA-3 S13)
    //
    // The relay push registry dedups by `device_id` (one row per device). Build
    // 116's relay registration plumbed `device_id` only when a v2 pairing had
    // issued one (`DefaultsKeys.deviceId(server:)`) — but a relay-only phone on
    // a pre-v2 shared-token pairing never completes the auto-upgrade, so the
    // field was `nil`, the registry row carried no id, and QA-2's device-keyed
    // eviction could never converge (fan-out kept hitting stale null-id rows
    // Apple 200s into the void). The per-install fallback below mints ONE
    // stable id per install the FIRST time a registration needs it, so every
    // registration from day one is keyed. The v2 issued id still wins when it
    // exists (it is the server's authoritative per-device identity).

    /// The single per-install push device id (a minted UUID, persisted the first
    /// time a registration needs a device id and no v2 id is on record). NOT
    /// secret — it identifies the install for dedup, nothing more. Stable across
    /// launches; rotates on app delete+reinstall (acceptable: APNs rotates the
    /// token on reinstall too, and the registry's device-keyed replace handles
    /// that rotation in place).
    static let pushDeviceInstallId = "hermes.pushDeviceInstallId"

    /// Read (or lazily mint) the per-install fallback device id. Idempotent:
    /// the minted id is persisted on first read so every subsequent call
    /// returns the same value.
    static func pushDeviceInstallIdValue(_ defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: pushDeviceInstallId)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !existing.isEmpty {
            return existing
        }
        let minted = UUID().uuidString
        defaults.set(minted, forKey: pushDeviceInstallId)
        return minted
    }

    /// The `device_id` to stamp on a push registration for `server`: the v2
    /// issued id when one exists, else the per-install fallback (always
    /// non-empty). Callers MUST use this — not the bare `deviceId(server:)` —
    /// so the relay registry converges to one row per device.
    static func pushRegistrationDeviceId(server: String, _ defaults: UserDefaults = .standard) -> String {
        if let v2 = deviceId(server: server, defaults) {
            return v2
        }
        return pushDeviceInstallIdValue(defaults)
    }

    // MARK: File browser / @-mentions (F4A-A1)
    //
    // A1's disjoint DefaultsKeys block (A2 adds its detail-toggle /
    // requiresBiometric keys separately — no shared lines). Both gate on the
    // `fs` capability at the call site; these prefs only tune the affordance when
    // the server supports it.

    /// `Bool` — whether typing `@` in the composer opens the file-mention picker
    /// (backed by `complete.path`). **Default ON**: a *missing* key reads as
    /// `true` (the `mentionAutocompleteEnabledValue` accessor inverts through
    /// `object(forKey:) == nil`), so existing installs get the affordance and a
    /// user who dislikes it can turn it off from a future Settings toggle. Read by
    /// ``ComposerView`` to gate the `@`-trigger; still hard-gated on
    /// `capabilities.fs != .unavailable` regardless of this pref.
    static let mentionAutocompleteEnabled = "hermes.mentionAutocompleteEnabled"

    /// Whether the composer's `@`-mention picker is enabled. A *missing* key
    /// reads as `true` (on by default); a present key is honored verbatim.
    static func mentionAutocompleteEnabledValue(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: mentionAutocompleteEnabled) == nil
            ? true
            : defaults.bool(forKey: mentionAutocompleteEnabled)
    }

    /// `Bool` — whether the file browser shows dotfiles (hidden entries the
    /// `/api/fs/list` response always includes — the client decides display).
    /// **Default false** (hidden): `UserDefaults.bool(forKey:)` already reads the
    /// absent key as `false`. Owned by ``FileBrowserView`` (toggle in its toolbar)
    /// — persisted so the choice survives a relaunch.
    static let fileBrowserShowHidden = "hermes.fileBrowserShowHidden"

    /// Whether the file browser shows hidden (dot-prefixed) entries. `false`
    /// unless the user turned it on.
    static func fileBrowserShowHiddenValue(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: fileBrowserShowHidden)
    }

    // MARK: Chat surface — tool detail + secure-prompt biometric (F4A-A2)
    //
    // A2's disjoint DefaultsKeys block (A1 adds its file-browser / @-mention keys
    // separately above — no shared lines).

    /// `Bool` — whether expanded tool rows show raw arguments/results instead of
    /// the product summary. Default false; owned by ``ToolActivityRow``'s visible
    /// Product/Technical toggle (STR-464).
    static let toolTechnicalDetail = "hermes.toolTechnicalDetail"

    /// Whether tool rows are in the technical (verbose) detail mode.
    static func toolTechnicalDetailValue(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: toolTechnicalDetail)
    }

    // MARK: Ambient voice auto-speak (STR-344 / STR-533)

    /// `Bool` — whether a completed assistant reply is read aloud via TTS when
    /// hands-free conversation mode (``VoiceConversationController``) is NOT
    /// active. **Default false**: `UserDefaults.bool` reads the absent key as
    /// `false`, so existing installs stay silent until the user opts in. Owned
    /// by ``SettingsView`` (toggle) + the ambient auto-speak coordinator in
    /// ``AppEnvironment`` (reader).
    static let voiceAutoTTS = "hermes.voice.autoTTS"

    /// Whether completed assistant replies should be read aloud outside
    /// conversation mode. `false` unless the user turned it on.
    static func voiceAutoTTSValue(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: voiceAutoTTS)
    }

    /// `Bool` — whether a Face ID / passcode check is required before a
    /// `sudo.request` / `secret.request` value can be entered AND before the
    /// `*.respond` reply is sent. **Default ON**: a *missing* key reads as `true`
    /// (the `requiresBiometricForSecretsValue` accessor inverts through
    /// `object(forKey:) == nil`), so a secure prompt is biometric-gated out of the
    /// box. Owned by ``SettingsView`` (writer) + ``SecurePromptView`` (reader).
    static let requiresBiometricForSecrets = "hermes.requiresBiometricForSecrets"

    /// Whether secure prompts (sudo/secret) require a biometric gate. A *missing*
    /// key reads as `true` (on by default); a present key is honored verbatim.
    static func requiresBiometricForSecretsValue(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: requiresBiometricForSecrets) == nil
            ? true
            : defaults.bool(forKey: requiresBiometricForSecrets)
    }

    // MARK: Identity (F2 / Amendment E)

    /// `String` — the user's first name, used as the greeting source on the draft
    /// chat ("Evening, Sam"). Edited in the Settings sheet's account card
    /// (``SettingsView``) and read by the chat draft greeting (F3 / ChatView).
    /// **Default empty**: when unset/blank the greeting falls back to the
    /// time-of-day phrase alone, with a trailing period ("Evening.").
    static let displayName = "hermes.displayName"

    // MARK: Convenience accessors

    /// The trimmed display name, or `nil` when unset/blank. Callers use `nil` to
    /// decide whether to append a name to the greeting; a present value is the
    /// user's verbatim entry (trimmed of surrounding whitespace only).
    static func displayNameValue(_ defaults: UserDefaults = .standard) -> String? {
        let raw = defaults.string(forKey: displayName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    // MARK: Connection mode (Increment 1 — Topology B)

    /// `String` (raw value of `ConnectionMode`) — the chosen connection mode.
    /// Absent/unrecognised values fall back to `.remoteURL` (the legacy default:
    /// the URL+token form the app already uses for all pairing). Owned by
    /// ``ConnectionStore``.
    static let connectionMode = "hermes.connectionMode"

    /// Read + decode the persisted ``ConnectionMode``. Returns `.remoteURL` when
    /// unset (existing installs keep the existing behaviour unchanged).
    static func connectionModeValue(_ defaults: UserDefaults = .standard) -> ConnectionMode {
        let raw = defaults.string(forKey: connectionMode) ?? ""
        return ConnectionMode(rawValue: raw) ?? .remoteURL
    }

}
