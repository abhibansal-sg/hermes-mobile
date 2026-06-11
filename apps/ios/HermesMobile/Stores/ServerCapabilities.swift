import Foundation

/// Observable record of which branch-only server features the connected gateway
/// supports, so one binary degrades gracefully against a STOCK hermes-agent.
///
/// The user's patched gateway adds: `POST /api/upload`, `POST/DELETE
/// /api/push/register`, and `stored_session_id` enrichment on broadcast event
/// frames. A stock gateway has none of these. Rather than feature-flag at build
/// time, the app **probes** at connect and gates UI on the result (E1).
///
/// Each feature is one of three states:
///   - ``State/unknown`` — not yet probed (the safe default; UI shows the
///     feature optimistically until a probe proves it unavailable, except where
///     the contract says otherwise).
///   - ``State/available`` — the probe (or a passive signal) confirmed support.
///   - ``State/unavailable`` — the probe proved the endpoint is missing.
///
/// Probing strategy (cheap, cached per server URL + app version in
/// `UserDefaults` so reconnects don't re-probe; a `configure()` to a NEW URL or
/// an app-version change re-probes):
///   - **upload**: eager single probe — `POST /api/upload` with an EMPTY body.
///     `400` ("multipart field 'file' required") ⇒ available; `404`/`405` ⇒
///     unavailable. Zero side effects either way (no file is created).
///   - **pushRegistry**: wired off ``PushRegistrar``'s existing 404 soft-fail —
///     a soft-fail ⇒ unavailable, a `2xx`/`4xx` validation response ⇒ available.
///   - **broadcast**: passive — marked available when the connection router sees
///     the first event carrying `stored_session_id`; otherwise stays unknown
///     (it is never provably unavailable, which is acceptable).
///
/// `@MainActor`-isolated; stores and views read it on the main actor. The actual
/// HTTP probe runs on a `Sendable` helper so it stays off the main actor.
@MainActor
@Observable
final class ServerCapabilities {

    /// Tri-state support for one feature.
    enum State: String, Sendable, Codable {
        case unknown
        case available
        case unavailable
    }

    /// The ABH-88 plugin mount (`/api/plugins/hermes-mobile/…`). Probed
    /// EAGERLY at connect, BEFORE every other eager probe, because its result
    /// selects the path family (``APIPathStyle``) those probes — and every
    /// mobile REST call — use. Probe: `GET /api/plugins/hermes-mobile/devices`
    /// (absolute path): `200` with a `{"devices":[…]}` body ⇒ available
    /// (de-patched gateway), `404`/`405` ⇒ unavailable (legacy gateway),
    /// anything else ⇒ unknown (and the path family stays `.legacy`, which is
    /// what today's live server speaks).
    private(set) var pluginMount: State = .unknown
    /// `POST <prefix>/upload` — image attachments. Probed eagerly at connect.
    private(set) var upload: State = .unknown
    /// `POST/DELETE /api/push/register` — remote push. Set from PushRegistrar.
    private(set) var pushRegistry: State = .unknown
    /// `stored_session_id` enrichment on broadcast frames. Set passively.
    private(set) var broadcast: State = .unknown
    /// `GET /api/fs/list` + `/api/fs/read` — the F4A file-browser / @-file
    /// endpoints. Probed EAGERLY at connect (like `upload`): a `400`
    /// ("session_id required") ⇒ available, a `404`/`405` ⇒ unavailable. Every
    /// file-browser / working-dir / @-file affordance gates on `fs !=
    /// .unavailable` so a stock gateway shows none of them and never errors.
    private(set) var fs: State = .unknown
    /// `subagent.*` event emission (F4A-A2). PASSIVE — it can't be eagerly probed
    /// (it only fires when the agent delegates). Set via ``noteSubagentObserved()``
    /// the first time the connection router sees a `subagent.*` frame; stays
    /// `.unknown` until then (never provably unavailable, which is acceptable —
    /// the subagent-tree surface simply has no data on a stock server). Single
    /// writer of this file is F4A-A1; A2 only calls the passive setter.
    private(set) var subagentEvents: State = .unknown
    /// The F4b multi-profile switcher capability. Probed EAGERLY at connect (like
    /// `fs`/`upload`) by hitting `GET /api/profiles/sessions` — the cross-profile
    /// AGGREGATE rail, which is the route genuinely NEW at the upstream rebase: a
    /// `200` with a well-formed `{"sessions":[…]}` body ⇒ available, a `404`/`405`
    /// ⇒ unavailable.
    ///
    /// NOTE the probe deliberately does NOT hit `GET /api/profiles` — that route
    /// already exists on today's server (the desktop profiles page) and would
    /// classify our live 9119 as available, breaking dormancy. EVERY profile
    /// affordance (the drawer switcher, the aggregate rail, per-session profile
    /// threading) gates on `profiles == .available`, so a stock / pre-multi-profile
    /// gateway (today's live 9119) shows none of the switcher chrome and never
    /// errors — the F4b dormancy guarantee.
    private(set) var profiles: State = .unknown
    /// The W3a per-device-token capability. Probed EAGERLY at connect (like
    /// `fs`/`upload`/`profiles`) by hitting `GET /api/devices` — the device-token
    /// list, the route genuinely NEW in W3a: a `200` with a well-formed
    /// `{"devices":[…]}` body ⇒ available (even an EMPTY registry is a 200, so the
    /// panel renders with zero rows), a `404`/`405` ⇒ unavailable.
    ///
    /// EVERY Devices-section affordance (the Settings section, the revoke button,
    /// the audit view, AND the auto-upgrade issue call) gates on
    /// `devices == .available`, so a stock hermes-agent (no device routes) hides
    /// the Devices section entirely, never errors, and never issues a device
    /// token — the W3a stock-degradation guarantee (the legacy shared token keeps
    /// working untouched). Single writer of this field is the W3A-A app module.
    private(set) var devices: State = .unknown

    /// The server URL the current snapshot was probed against. A `configure()` to
    /// a different URL invalidates the snapshot and forces a re-probe.
    private var probedServerURL: String?
    /// The app version the current snapshot was probed against. A version change
    /// (the branch-only feature set may shift between builds) forces a re-probe.
    private var probedAppVersion: String?

    /// The path family mobile REST calls should use against the probed server.
    /// `.plugin` only when the mount probe CONCLUDED available; `.unknown` and
    /// `.unavailable` both resolve `.legacy` (safe against today's live server;
    /// the background flows carry a one-shot alternate-family retry for the
    /// stale-cache case).
    var resolvedPathStyle: APIPathStyle {
        pluginMount == .available ? .plugin : .legacy
    }

    init() {}

    // MARK: - Probe entry point

    /// Probe (or reuse a cached probe of) the gateway at `serverURL`.
    ///
    /// Called by ``ConnectionStore`` after a successful `configure`/connect. If a
    /// cached snapshot exists for this exact `serverURL` + current app version,
    /// it is restored and no network call is made. Otherwise the eager probes
    /// run and the result is cached.
    ///
    /// `pushRegistry` is deliberately NOT probed here — it has no zero-side-effect
    /// probe of its own and is instead learned from ``PushRegistrar``'s real
    /// register call (``notePushRegistry(available:)``). `broadcast` likewise
    /// stays passive (``noteBroadcastObserved()``). Both are preserved across a
    /// cache restore so a known value survives a reconnect.
    func probe(serverURL: String, rest: RestClient, force: Bool = false) async {
        let version = Self.currentAppVersion

        // Reuse a cached snapshot for the same server + app version: a reconnect
        // to a server we already probed must not re-probe (contract E1).
        //
        // `force` bypasses BOTH the in-memory short-circuit and the disk-cache
        // restore (R1 #57): after the socket actually DROPPED, the same URL may
        // now serve a different gateway (a restart swapping stock↔patched on
        // the same port), and the cached snapshot would pin features hidden —
        // or shown against 404ing routes — for the rest of the app version.
        // The reconnect path passes `force: true`; the initial connect keeps
        // the cheap cached path.
        if !force {
            if probedServerURL == serverURL,
               probedAppVersion == version,
               upload != .unknown {
                return
            }
            if let cached = Self.loadCache(),
               cached.serverURL == serverURL,
               cached.appVersion == version {
                applyCache(cached)
                return
            }
        }

        // Fresh server (or new app version): reset passive/derived state so a
        // stale prior-server value can't leak through, then probe.
        pluginMount = .unknown
        upload = .unknown
        pushRegistry = .unknown
        broadcast = .unknown
        fs = .unknown
        subagentEvents = .unknown
        profiles = .unknown
        devices = .unknown
        probedServerURL = serverURL
        probedAppVersion = version

        // Stage 1 (ABH-88): resolve the plugin mount FIRST — its result selects
        // the path family every other eager probe (and every mobile REST call)
        // targets. One extra round-trip, paid once per server + app version.
        let mountState = await Self.probePluginMount(rest: rest)
        guard probedServerURL == serverURL else { return }
        pluginMount = mountState
        let styledRest = rest.withPathStyle(resolvedPathStyle)

        // Stage 2: the remaining eager probes are side-effect-free and
        // independent; run them concurrently against the resolved family so a
        // fresh connect pays two round-trips total, not five.
        async let uploadProbe = Self.probeUpload(rest: styledRest)
        async let fsProbe = Self.probeFs(rest: styledRest)
        async let profilesProbe = Self.probeProfiles(rest: styledRest)
        async let devicesProbe = Self.probeDevices(rest: styledRest)
        let (uploadState, fsState, profilesState, devicesState) =
            await (uploadProbe, fsProbe, profilesProbe, devicesProbe)
        // The connection (and thus serverURL) may have changed while we awaited;
        // only apply if we're still probing the same server.
        guard probedServerURL == serverURL else { return }
        upload = uploadState
        fs = fsState
        profiles = profilesState
        devices = devicesState
        persist()
    }

    /// Clear all capability state (used on an explicit disconnect). The cached
    /// snapshot is intentionally retained so a reconnect to the same server can
    /// reuse it; only the live in-memory state resets to `.unknown`.
    func reset() {
        pluginMount = .unknown
        upload = .unknown
        pushRegistry = .unknown
        broadcast = .unknown
        fs = .unknown
        subagentEvents = .unknown
        profiles = .unknown
        devices = .unknown
        probedServerURL = nil
        probedAppVersion = nil
    }

    // MARK: - Passive / derived signals

    /// Record the outcome of a real push-register call (from ``PushRegistrar``).
    /// `false` (the 404 soft-fail) ⇒ unavailable; `true` (a 2xx or a 4xx
    /// validation response) ⇒ available. Persists so the gate is stable across a
    /// reconnect within the same server + app version.
    func notePushRegistry(available: Bool) {
        let newState: State = available ? .available : .unavailable
        guard pushRegistry != newState else { return }
        pushRegistry = newState
        persist()
    }

    /// Mark broadcast enrichment available — called by the connection router the
    /// first time an event carries `stored_session_id`. Idempotent; only the
    /// first transition persists.
    func noteBroadcastObserved() {
        guard broadcast != .available else { return }
        broadcast = .available
        persist()
    }

    /// Mark `subagent.*` emission available — called by the connection router the
    /// first time a `subagent.*` frame routes (F4A-A2). Idempotent; only the
    /// first transition persists. Passive (never proves unavailable), mirroring
    /// ``noteBroadcastObserved()``.
    func noteSubagentObserved() {
        guard subagentEvents != .available else { return }
        subagentEvents = .available
        persist()
    }

    // MARK: - Plugin-mount probe (ABH-88)

    /// `GET /api/plugins/hermes-mobile/devices` (absolute path — style-free).
    /// See ``RestClient/probePluginMountEndpoint()`` for the classification.
    private nonisolated static func probePluginMount(rest: RestClient) async -> State {
        switch await rest.probePluginMountEndpoint() {
        case .available: return .available
        case .unavailable: return .unavailable
        case .inconclusive: return .unknown
        }
    }

    // MARK: - Upload probe

    /// `POST /api/upload` with an empty body. The patched gateway rejects the
    /// missing multipart field with `400`; a stock gateway has no such route and
    /// returns `404`/`405`. No file is ever created, so this is side-effect-free.
    private nonisolated static func probeUpload(rest: RestClient) async -> State {
        switch await rest.probeUploadEndpoint() {
        case .available: return .available
        case .unavailable: return .unavailable
        case .inconclusive: return .unknown
        }
    }

    // MARK: - FS probe

    /// `GET /api/fs/list` with NO `session_id`. The patched gateway rejects the
    /// missing required param with `400`; a stock gateway has no such route and
    /// returns `404`/`405`. No file is read, so this is side-effect-free.
    private nonisolated static func probeFs(rest: RestClient) async -> State {
        switch await rest.probeFsEndpoint() {
        case .available: return .available
        case .unavailable: return .unavailable
        case .inconclusive: return .unknown
        }
    }

    // MARK: - Profiles probe (F4b)

    /// `GET /api/profiles/sessions` (the aggregate rail, NEW at the rebase — NOT
    /// `GET /api/profiles`, which already exists on today's server). A multi-profile
    /// gateway returns `200` with a well-formed `{"sessions":[…]}` body (route
    /// exists ⇒ available); a pre-multi-profile gateway has no such route and
    /// returns `404`/`405` (unavailable). The probe is a read (side-effect-free).
    /// Mirrors ``probeFs``;
    /// the tri-state mapping (available→available, unavailable→unavailable,
    /// inconclusive→unknown) is identical, so a flaky probe leaves `profiles` at
    /// `.unknown` and the switcher stays hidden (the visibility gate requires
    /// `.available`).
    private nonisolated static func probeProfiles(rest: RestClient) async -> State {
        switch await rest.probeProfilesEndpoint() {
        case .available: return .available
        case .unavailable: return .unavailable
        case .inconclusive: return .unknown
        }
    }

    // MARK: - Devices probe (W3a)

    /// `GET /api/devices` (the device-token list, NEW in W3a). A W3a server
    /// returns `200` with a well-formed `{"devices":[…]}` body (route exists ⇒
    /// available — even an EMPTY registry is a 200, so the panel renders with
    /// zero rows); a stock gateway has no such route and returns `404`/`405`
    /// (unavailable). The probe is a READ (side-effect-free). Mirrors
    /// ``probeProfiles``/``probeFs``; the tri-state mapping is identical, so a
    /// flaky probe leaves `devices` at `.unknown` and the Devices section stays
    /// hidden (the visibility gate requires `.available`) AND no auto-upgrade
    /// issue call fires (it too gates on `.available`).
    private nonisolated static func probeDevices(rest: RestClient) async -> State {
        switch await rest.probeDevicesEndpoint() {
        case .available: return .available
        case .unavailable: return .unavailable
        case .inconclusive: return .unknown
        }
    }

    // MARK: - Persistence

    /// The serializable snapshot cached in `UserDefaults`. `fs`,
    /// `subagentEvents`, and `profiles` are `decodeIfPresent`-tolerant so a cache
    /// written by a pre-F4A / pre-F4b build (no such keys) restores cleanly as
    /// `.unknown` rather than failing the whole decode (which would force a
    /// needless re-probe).
    private struct Cache: Codable {
        var serverURL: String
        var appVersion: String
        var pluginMount: State
        var upload: State
        var pushRegistry: State
        var broadcast: State
        var fs: State
        var subagentEvents: State
        var profiles: State
        var devices: State

        enum CodingKeys: String, CodingKey {
            case serverURL, appVersion, pluginMount, upload, pushRegistry, broadcast, fs, subagentEvents, profiles, devices
        }

        init(
            serverURL: String,
            appVersion: String,
            pluginMount: State,
            upload: State,
            pushRegistry: State,
            broadcast: State,
            fs: State,
            subagentEvents: State,
            profiles: State,
            devices: State
        ) {
            self.serverURL = serverURL
            self.appVersion = appVersion
            self.pluginMount = pluginMount
            self.upload = upload
            self.pushRegistry = pushRegistry
            self.broadcast = broadcast
            self.fs = fs
            self.subagentEvents = subagentEvents
            self.profiles = profiles
            self.devices = devices
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            serverURL = try c.decode(String.self, forKey: .serverURL)
            appVersion = try c.decode(String.self, forKey: .appVersion)
            // Tolerant so a cache written by a pre-ABH-88 build (no
            // `pluginMount` key) restores cleanly as `.unknown` (→ legacy
            // path family) rather than failing the whole decode.
            pluginMount = try c.decodeIfPresent(State.self, forKey: .pluginMount) ?? .unknown
            upload = try c.decode(State.self, forKey: .upload)
            pushRegistry = try c.decode(State.self, forKey: .pushRegistry)
            broadcast = try c.decode(State.self, forKey: .broadcast)
            fs = try c.decodeIfPresent(State.self, forKey: .fs) ?? .unknown
            subagentEvents = try c.decodeIfPresent(State.self, forKey: .subagentEvents) ?? .unknown
            // `decodeIfPresent`-tolerant so a cache written by a pre-F4b build
            // (no `profiles` key) restores cleanly as `.unknown` rather than
            // failing the whole decode (which would force a needless re-probe).
            profiles = try c.decodeIfPresent(State.self, forKey: .profiles) ?? .unknown
            // Likewise tolerant so a cache written by a pre-W3a build (no
            // `devices` key) restores cleanly as `.unknown` rather than failing
            // the whole decode (which would force a needless re-probe).
            devices = try c.decodeIfPresent(State.self, forKey: .devices) ?? .unknown
        }
    }

    private func applyCache(_ cache: Cache) {
        probedServerURL = cache.serverURL
        probedAppVersion = cache.appVersion
        pluginMount = cache.pluginMount
        upload = cache.upload
        pushRegistry = cache.pushRegistry
        broadcast = cache.broadcast
        fs = cache.fs
        subagentEvents = cache.subagentEvents
        profiles = cache.profiles
        devices = cache.devices
    }

    private func persist() {
        guard let serverURL = probedServerURL, let appVersion = probedAppVersion else { return }
        // An entirely-inconclusive probe (every eager field still .unknown —
        // e.g. a forced reconnect re-probe against a server whose REST was
        // momentarily unreachable) is NOT knowledge: persisting it would
        // overwrite a good snapshot with unknowns that the next UNFORCED
        // probe restores verbatim, hiding pessimistic-gated features across
        // launches until the URL or app version changes (ABH-52 judge round).
        // Keep the prior snapshot; the in-memory unknowns last only until a
        // probe actually concludes.
        guard pluginMount != .unknown || upload != .unknown || fs != .unknown
            || profiles != .unknown || devices != .unknown else { return }
        let cache = Cache(
            serverURL: serverURL,
            appVersion: appVersion,
            pluginMount: pluginMount,
            upload: upload,
            pushRegistry: pushRegistry,
            broadcast: broadcast,
            fs: fs,
            subagentEvents: subagentEvents,
            profiles: profiles,
            devices: devices
        )
        guard let data = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.standard.set(data, forKey: DefaultsKeys.serverCapabilities)
    }

    private nonisolated static func loadCache() -> Cache? {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKeys.serverCapabilities) else {
            return nil
        }
        return try? JSONDecoder().decode(Cache.self, from: data)
    }

    /// The cached path family for `serverURL`, readable WITHOUT an instance —
    /// for background flows (notification-action respond, push registration)
    /// that run before any live connection exists. Matches on `serverURL` only
    /// (NOT app version): the server doesn't change because the app updated,
    /// and a wrong guess self-heals via the callers' alternate-family 404
    /// retry. Missing/foreign cache → `.legacy` (today's live server).
    nonisolated static func cachedPathStyle(serverURL: String) -> APIPathStyle {
        guard let cache = loadCache(), cache.serverURL == serverURL else {
            return .legacy
        }
        return cache.pluginMount == .available ? .plugin : .legacy
    }

    /// `"<short> (<build>)"` — matches the version string SettingsView renders, so
    /// the cache invalidates on any build bump.
    static var currentAppVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
