import Foundation
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif
import UserNotifications

/// Coordinates APNs registration and ships the device token to the gateway.
///
/// Remote push is user-controllable behind `UserDefaults` key
/// `hermes.pushEnabled`. A fresh install has no explicit value; successful
/// pairing defaults that unset state to enabled so direct APNs can work, while an
/// explicit Settings opt-out (`false`) is preserved. When enabled,
/// ``enableIfAllowed()`` asks for notification authorization (reusing the local
/// notification grant) and calls
/// `UIApplication.registerForRemoteNotifications()`. iOS then calls the app
/// delegate's
/// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`, which
/// forwards the raw token bytes to ``didRegister(deviceToken:)``. We hex-encode
/// the token and `POST {base}/api/push/register {token, platform:"ios"}`.
///
/// The server endpoint may not exist yet (it ships with X4); a `404` is treated
/// as a **soft failure** — registration is remembered locally and retried on the
/// next launch/enable, but nothing is surfaced to the user. The base URL + token
/// are resolved the same way the rest of the app does: the `HERMES_URL`/
/// `HERMES_TOKEN` dev override first, then the saved server URL + Keychain token.
///
/// All public entry points are `@MainActor` (they touch `UIApplication` and read
/// the connection store); the network POST runs on a `Sendable` helper.
@MainActor
@Observable
final class PushRegistrar {

    /// Shared instance the AppDelegate adaptor + UI toggle call into.
    static let shared = PushRegistrar()

    @ObservationIgnored
    private weak var connection: ConnectionStore?

    /// Test seams for the OS/APNs boundaries. Production uses
    /// ``NotificationService`` + ``UIApplication`` + ``PushTokenPoster``; tests
    /// replace only these edges so the registrar's idempotency logic is exercised
    /// without a real device token, permission dialog, or gateway.
    @ObservationIgnored
    var authorizationRequester: (@MainActor (Bool) async -> UNAuthorizationStatus)?
    @ObservationIgnored
    var remoteNotificationsRegistrar: (@MainActor () -> Void)?
    @ObservationIgnored
    var tokenRegisterOverride: (@MainActor @Sendable (String, [String]?) async -> PushTokenPoster.Outcome)?
    @ObservationIgnored
    private var registrationInFlight = false
    @ObservationIgnored
    private var pendingRegistrationRequest: RegistrationRequest?

    private struct RegistrationRequest {
        let token: String
        let events: [String]
        let env: String
        let registerToken: @MainActor @Sendable (String, [String]?) async -> PushTokenPoster.Outcome
    }

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: DefaultsKeys.pushEnabled)
    }

    /// Wire the connection store so the registrar can resolve the base URL +
    /// token when a device token arrives. Called once by the parent (alongside
    /// the other `attach`-style hooks).
    func attach(connection: ConnectionStore) {
        self.connection = connection
    }

    /// Whether the user has opted into push. A TRACKED stored property (R1
    /// #67): it used to read UserDefaults directly, so flipping the master
    /// toggle never invalidated SwiftUI bodies and the per-event rows only
    /// appeared after the Settings sheet was reopened. UserDefaults remains
    /// the persisted source of truth (seeded in `init`, written in
    /// `setEnabled`).
    private(set) var isEnabled: Bool

    /// True only when this exact gateway/credential scope has a persisted,
    /// successful push registration and the server capability remains healthy.
    /// This is the ownership rule consumed by live-event notification fallback.
    var isAlertAuthorityRegistered: Bool {
        guard isEnabled,
              connection?.capabilities.pushRegistry == .available,
              UserDefaults.standard.bool(forKey: DefaultsKeys.pushRegistrationHealthy),
              let token = UserDefaults.standard.string(
                  forKey: DefaultsKeys.pushLastDeviceToken
              ), !token.isEmpty,
              let scope = currentRegistrationScope,
              scope == UserDefaults.standard.string(
                  forKey: DefaultsKeys.pushLastRegistrationScope
              ) else { return false }
        return true
    }

    /// Stable, non-secret namespace for the current gateway + device pairing.
    /// Credential hashing makes a same-URL re-pair a fresh dedupe scope.
    var notificationScope: String? { currentRegistrationScope }

    private var currentRegistrationScope: String? {
        guard let endpoint = resolveEndpoint(), let connection else { return nil }
        let deviceId = DefaultsKeys.deviceId(server: connection.serverURLString) ?? "shared"
        let raw = "\(endpoint.url.absoluteString)|\(deviceId)|\(endpoint.token)"
        let digest = SHA256.hash(data: Data(raw.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        return "device_" + digest.prefix(24)
    }

    /// Flip the opt-in flag and (un)register accordingly. Disabling unregisters
    /// the remembered token server-side, then clears it locally so a later
    /// re-enable forces a fresh server register.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: DefaultsKeys.pushEnabled)
        if enabled {
            // Explicit user toggle-ON — force the auth prompt so a user who
            // declined the first time gets it again (the once-per-install latch
            // only applies to the silent launch path).
            enableIfAllowed(forcePrompt: true)
        } else {
            let lastDeviceToken = UserDefaults.standard.string(
                forKey: DefaultsKeys.pushLastDeviceToken
            )
            if let lastDeviceToken, !lastDeviceToken.isEmpty {
                if let poster = makePoster() {
                    Task { @MainActor in
                        let outcome = await poster.unregister(token: lastDeviceToken)
                        switch outcome {
                        case .success, .softFail, .validationRejected:
                            connection?.capabilities.notePushRegistry(
                                available: outcome.provesEndpointPresent
                            )
                        case .hardFail:
                            // Best-effort network cleanup: keep the Settings toggle
                            // responsive and still clear local opt-out state.
                            break
                        }
                    }
                }
            }
            UserDefaults.standard.removeObject(forKey: DefaultsKeys.pushLastDeviceToken)
            UserDefaults.standard.removeObject(forKey: DefaultsKeys.pushLastEvents)
            UserDefaults.standard.removeObject(forKey: DefaultsKeys.pushLastEnv)
            UserDefaults.standard.removeObject(forKey: DefaultsKeys.pushLastRegistrationScope)
            UserDefaults.standard.set(false, forKey: DefaultsKeys.pushRegistrationHealthy)
            #if canImport(UIKit)
            UIApplication.shared.unregisterForRemoteNotifications()
            #endif
        }
    }

    /// Pair/foreground reconciliation for direct-APNs gateways. A fresh install
    /// has no explicit push preference yet; when the phone successfully pairs,
    /// default that unset state to enabled so the system permission prompt + APNs
    /// token request actually happen. If the user later turns Notifications off,
    /// the key is explicitly `false` and this will not silently re-enable it.
    func ensureRegisteredForPairedGateway() {
        if UserDefaults.standard.object(forKey: DefaultsKeys.pushEnabled) == nil {
            isEnabled = true
            UserDefaults.standard.set(true, forKey: DefaultsKeys.pushEnabled)
        }
        enableIfAllowed()
    }

    /// If push is enabled, request authorization and kick off APNs registration.
    /// Safe to call every launch/foreground — APNs registration is cheap and
    /// idempotent, and the system re-delivers the current token to the delegate
    /// each time. Denied notification access is an honest terminal state: do not
    /// ask APNs for a token the UI would then present as healthy.
    func enableIfAllowed(forcePrompt: Bool = false) {
        guard isEnabled else { return }
        #if canImport(UIKit)
        Task { @MainActor in
            let status: UNAuthorizationStatus
            if let authorizationRequester {
                status = await authorizationRequester(forcePrompt)
            } else {
                status = await NotificationService.requestAuthorizationStatusIfNeeded(force: forcePrompt)
            }
            guard Self.authorizationAllowsRemoteRegistration(status) else {
                UserDefaults.standard.set(
                    false, forKey: DefaultsKeys.pushRegistrationHealthy
                )
                return
            }
            if let remoteNotificationsRegistrar {
                remoteNotificationsRegistrar()
            } else {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
        #endif
    }

    static func authorizationAllowsRemoteRegistration(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - APNs delegate callbacks

    /// Forward the APNs device token to the gateway. Called from the app
    /// delegate's `didRegisterForRemoteNotificationsWithDeviceToken`.
    func didRegister(deviceToken: Data) {
        guard isEnabled else { return }
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        guard !hex.isEmpty else { return }
        let events = DefaultsKeys.pushEventList()
        let env = PushTokenPoster.apnsEnvironment
        // Skip a redundant POST only when the token, event prefs, AND APNs
        // environment are all unchanged from the last successful register. An env
        // flip (e.g. Xcode sandbox → TestFlight production on the same token)
        // must force a re-POST so the gateway re-routes the token to the correct
        // APNs host. A prefs change (A4) must re-POST even when token+env match.
        if UserDefaults.standard.string(forKey: DefaultsKeys.pushLastDeviceToken) == hex,
           lastRegisteredEvents == events,
           lastRegisteredEnv == env,
           currentRegistrationScope == UserDefaults.standard.string(
               forKey: DefaultsKeys.pushLastRegistrationScope
           ),
           UserDefaults.standard.bool(forKey: DefaultsKeys.pushRegistrationHealthy) {
            return
        }

        let registerToken: @MainActor @Sendable (String, [String]?) async -> PushTokenPoster.Outcome
        if let tokenRegisterOverride {
            registerToken = tokenRegisterOverride
        } else {
            guard let poster = makePoster() else { return }  // not configured yet
            registerToken = { token, events in
                await poster.register(token: token, events: events)
            }
        }
        enqueueRegistration(
            RegistrationRequest(token: hex, events: events, env: env, registerToken: registerToken)
        )
    }

    /// Serialize all alert-token registration POSTs through one main-actor drain.
    /// If a newer intent arrives while an older request is in flight, keep only
    /// that newest pending intent. This preserves launch/foreground registration
    /// while ensuring a Settings toggle cannot be clobbered by an older network
    /// completion: server writes happen in intent order and the final successful
    /// local state mirrors the final successful server write.
    private func enqueueRegistration(_ request: RegistrationRequest) {
        pendingRegistrationRequest = request
        guard !registrationInFlight else { return }
        registrationInFlight = true

        Task { @MainActor in
            while let next = pendingRegistrationRequest {
                pendingRegistrationRequest = nil
                let outcome = await next.registerToken(next.token, next.events)
                handleRegisterOutcome(outcome, token: next.token, events: next.events, env: next.env)
            }
            registrationInFlight = false
        }
    }

    private func handleRegisterOutcome(
        _ outcome: PushTokenPoster.Outcome,
        token hex: String,
        events: [String],
        env: String
    ) {
        switch outcome {
        case .success, .softFail, .validationRejected:
            // Feed the push-registry capability gate (E1): a 404 soft-fail
            // proves the endpoint is missing (stock gateway); a 2xx success
            // or a 4xx validation rejection proves it exists.
            connection?.capabilities.notePushRegistry(available: outcome.provesEndpointPresent)
            // Remember the token + the events it was registered with only on a
            // real success; soft-fail (404) and a validation rejection both
            // persisted nothing, so we retry next launch.
            if case .success = outcome {
                UserDefaults.standard.set(hex, forKey: DefaultsKeys.pushLastDeviceToken)
                lastRegisteredEvents = events
                lastRegisteredEnv = env
                UserDefaults.standard.set(
                    currentRegistrationScope,
                    forKey: DefaultsKeys.pushLastRegistrationScope
                )
                UserDefaults.standard.set(true, forKey: DefaultsKeys.pushRegistrationHealthy)
            } else {
                UserDefaults.standard.set(false, forKey: DefaultsKeys.pushRegistrationHealthy)
            }
        case .hardFail:
            // Transport error: inconclusive for the capability gate, nothing
            // remembered. The next enableIfAllowed() retries.
            UserDefaults.standard.set(false, forKey: DefaultsKeys.pushRegistrationHealthy)
        }
    }

    /// Re-POST `/api/push/register` with the current per-event prefs (A4). Called
    /// from Settings whenever a notification toggle changes. No-op unless push is
    /// enabled, a token is already known, and the app is configured. Re-issues a
    /// fresh APNs registration if no token is cached yet so the events still land.
    func reRegisterEvents() {
        guard isEnabled else { return }
        let events = DefaultsKeys.pushEventList()
        guard let hex = UserDefaults.standard.string(forKey: DefaultsKeys.pushLastDeviceToken),
              !hex.isEmpty else {
            // No token cached yet — kick a fresh registration; `didRegister` will
            // carry the current events when the token arrives.
            enableIfAllowed()
            return
        }
        let registerToken: @MainActor @Sendable (String, [String]?) async -> PushTokenPoster.Outcome
        if let tokenRegisterOverride {
            registerToken = tokenRegisterOverride
        } else {
            guard let poster = makePoster() else { return }
            registerToken = { token, events in
                await poster.register(token: token, events: events)
            }
        }
        enqueueRegistration(
            RegistrationRequest(
                token: hex,
                events: events,
                env: PushTokenPoster.apnsEnvironment,
                registerToken: registerToken
            )
        )
    }

    /// The event subset last successfully registered, persisted so a prefs change
    /// can be detected against it (and so it survives relaunch). `nil` when never
    /// registered.
    private var lastRegisteredEvents: [String]? {
        get { UserDefaults.standard.stringArray(forKey: DefaultsKeys.pushLastEvents) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: DefaultsKeys.pushLastEvents)
            } else {
                UserDefaults.standard.removeObject(forKey: DefaultsKeys.pushLastEvents)
            }
        }
    }

    /// The APNs environment string last successfully registered. `nil` for legacy
    /// installs that pre-date this key (treated as a dedupe miss so the next
    /// `didRegister` re-POSTs once to stamp the env). Persisted so it survives
    /// relaunch.
    private var lastRegisteredEnv: String? {
        get { UserDefaults.standard.string(forKey: DefaultsKeys.pushLastEnv) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: DefaultsKeys.pushLastEnv)
            } else {
                UserDefaults.standard.removeObject(forKey: DefaultsKeys.pushLastEnv)
            }
        }
    }

    /// Record that APNs registration failed (no token this launch). Logged only;
    /// the next `enableIfAllowed()` retries. Called from the app delegate's
    /// `didFailToRegisterForRemoteNotificationsWithError`.
    func didFailToRegister(error: Error) {
        UserDefaults.standard.set(false, forKey: DefaultsKeys.pushRegistrationHealthy)
    }

    // MARK: - Configuration resolution

    /// Build a poster from the current base URL + token, or `nil` when the app
    /// isn't configured yet. Mirrors `SessionStore`'s token resolution: dev env
    /// override first, then the saved URL + Keychain.
    private func makePoster() -> PushTokenPoster? {
        guard let endpoint = resolveEndpoint(), let connection else { return nil }
        return PushTokenPoster(
            baseURL: endpoint.url,
            token: endpoint.token,
            pathStyle: endpoint.pathStyle,
            // QA-3 S13: always send a device id so the relay registry's
            // device-keyed dedup converges. The v2 issued id wins when present;
            // otherwise the per-install fallback (identifierForVendor-stable)
            // keys the registration from day one instead of writing a null-id
            // row that QA-2's eviction can never reach.
            deviceID: DefaultsKeys.pushRegistrationDeviceId(server: connection.serverURLString)
        )
    }

    /// The current gateway base URL + session token + REST path family, or
    /// `nil` when unconfigured. Reused by the notification-action backend
    /// (which needs the same loopback URL + Keychain token to respond to
    /// approvals and register Live-Activity tokens) so there's a single
    /// resolution path. Dev `HERMES_URL`/`HERMES_TOKEN` override first, then
    /// the saved URL + Keychain.
    ///
    /// The path family (ABH-88) prefers the LIVE capability snapshot when the
    /// connection is around; the persisted snapshot covers background launches
    /// where the probe hasn't run this process. Either way a stale answer
    /// self-heals via the callers' alternate-family 404 retry.
    func resolveEndpoint() -> (url: URL, token: String, pathStyle: APIPathStyle)? {
        guard let connection else { return nil }
        let urlString = connection.serverURLString
        guard !urlString.isEmpty, let url = URL(string: urlString) else { return nil }

        let env = ProcessInfo.processInfo.environment
        let token: String?
        if let envURL = env["HERMES_URL"], envURL == urlString,
           let envToken = env["HERMES_TOKEN"], !envToken.isEmpty {
            token = envToken
        } else {
            token = KeychainService.loadToken(server: urlString)
        }
        guard let token, !token.isEmpty else { return nil }
        let pathStyle: APIPathStyle =
            connection.capabilities.pluginMount == .available
            ? .plugin
            : ServerCapabilities.cachedPathStyle(serverURL: urlString)
        return (url, token, pathStyle)
    }

    /// The APNs environment string this build registers under (`"sandbox"` /
    /// `"production"`). Exposed for the Live-Activity token registration, which
    /// must route to the same APNs host as the alert registry.
    static var apnsEnvironment: String { PushTokenPoster.apnsEnvironment }
}

/// Self-contained `Sendable` HTTP poster for the push-register endpoint.
///
/// Kept separate from ``RestClient`` because it runs off the main actor (the
/// APNs callback path) and owns a register/unregister-specific outcome model
/// (404 soft-fail vs. validation rejection drives the E1 capability gate). It
/// reproduces the mandatory loopback `Host` override and the
/// `X-Hermes-Session-Token` auth header. The single endpoint is
/// `POST /api/push/register` with body `{token, platform:"ios", env}` where `env`
/// is the APNs environment (``apnsEnvironment``); `DELETE` is symmetric and
/// provided for an unregister path.
struct PushTokenPoster: Sendable {

    /// Result of a register/unregister call.
    enum Outcome: Sendable {
        case success
        /// The endpoint returned 404 — server-side push isn't deployed yet.
        case softFail
        /// A non-404 4xx — the endpoint EXISTS but rejected this request (e.g.
        /// validation). Proves push-registry support even though this call
        /// didn't persist a token (E1: a "4xx validation response = available").
        case validationRejected
        /// A transport error or 5xx bad status.
        case hardFail

        /// Whether this outcome proves the `/api/push/register` endpoint exists
        /// on the gateway. A 404 (softFail) is the only "not deployed" signal;
        /// every other non-transport outcome means the route is present.
        var provesEndpointPresent: Bool {
            switch self {
            case .success, .validationRejected: return true
            case .softFail, .hardFail: return false
            }
        }
    }

    private let baseURL: URL
    private let token: String
    private let pathStyle: APIPathStyle
    /// Stable per-install device identity (QA-2 R1c) sent as `device_id` so
    /// the gateway registry can keep ONE token per device. `nil` for legacy
    /// scopes without a device id (token-string-only dedup).
    private let deviceID: String?
    private let session: URLSession

    init(
        baseURL: URL, token: String, pathStyle: APIPathStyle = .legacy,
        deviceID: String? = nil
    ) {
        self.baseURL = baseURL
        self.token = token
        self.pathStyle = pathStyle
        self.deviceID = deviceID
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.timeout
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    private static let timeout: TimeInterval = 15

    /// The APNs environment this build registers under: `"sandbox"` for dev-signed
    /// Xcode builds (and the simulator), `"production"` for TestFlight/App Store.
    ///
    /// QA-2 R1a (the killer break): the previous implementation decoded
    /// `embedded.mobileprovision` with `String(data:encoding:.ascii)` — Swift's
    /// `.ascii` is STRICT (any byte ≥ 0x80 → `nil`) and every SIGNED profile
    /// carries a binary CMS/PKCS#7 envelope, so the decode ALWAYS returned nil
    /// and the fallback stamped `"production"` on every dev-signed build.
    /// Sandbox tokens then routed to `api.push.apple.com` → 400 BadDeviceToken
    /// on every notify — the phone received NOTHING. The simulator never caught
    /// it: its `#if` returns "sandbox" before the profile is ever read, so every
    /// sim/E2E/conformance run saw the correct env. The profile is now parsed
    /// for real (binary-safe plist extraction — `parseAPNsEnvironment`).
    ///
    /// Order: build-flag override (scripts/ios-build.sh stamps release archives
    /// `HERMES_APS_ENV_PRODUCTION`; an explicit `HERMES_APS_ENVIRONMENT` env at
    /// build time wins for either action) → real profile entitlement → fail-safe
    /// sandbox. No profile at all → App Store → production. Simulator → sandbox.
    /// The server registry routes the device token per this value.
    static let apnsEnvironment: String = {
        #if targetEnvironment(simulator)
        return "sandbox"
        #else
        #if HERMES_APS_ENV_SANDBOX
        return "sandbox"
        #elseif HERMES_APS_ENV_PRODUCTION
        return "production"
        #endif
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let data = FileManager.default.contents(atPath: path) else {
            return "production"  // no profile = App Store signed
        }
        if let parsed = parseAPNsEnvironment(profileData: data) {
            return parsed
        }
        // A profile EXISTS but is unreadable. Fail safe to SANDBOX: with the
        // QA-2 R1b eviction a wrong-host sandbox stamp fails LOUD (400
        // BadDeviceToken → evicted → re-registered next launch), whereas
        // mis-stamping production on a dev build was the unrecoverable
        // silent-deaf case this fix replaces.
        return "sandbox"
        #endif
    }()

    /// Parse `Entitlements.aps-environment` out of an `embedded.mobileprovision`
    /// blob: `"sandbox"` for `development`, `"production"` for `production`,
    /// `nil` when the profile carries no readable plist/entitlement.
    ///
    /// The profile is a CMS/PKCS#7 envelope (binary DER bytes) AROUND a plain
    /// XML plist. Locating the `<?xml … </plist>` span is a BINARY search —
    /// never a whole-blob string decode, because the DER signature bytes make
    /// any strict charset decode fail (the exact QA-2 R1a break). Pure and
    /// `Sendable` so unit tests can feed synthetic signed-profile bytes.
    static func parseAPNsEnvironment(profileData data: Data) -> String? {
        let xmlStart = Data("<?xml".utf8)
        let plistEnd = Data("</plist>".utf8)
        guard let startRange = data.range(of: xmlStart),
              let endRange = data.range(of: plistEnd, in: startRange.upperBound..<data.endIndex)
        else { return nil }
        let plistData = data.subdata(in: startRange.lowerBound..<endRange.upperBound)
        guard let root = (try? PropertyListSerialization.propertyList(
            from: plistData, options: [], format: nil
        )) as? [String: Any],
              let entitlements = root["Entitlements"] as? [String: Any],
              let aps = entitlements["aps-environment"] as? String
        else { return nil }
        switch aps {
        case "development": return "sandbox"
        case "production": return "production"
        default: return nil
        }
    }

    /// `POST /api/push/register {token, platform:"ios", env, events?}`.
    ///
    /// - Parameter events: the per-event subset (``DefaultsKeys/pushEventList``)
    ///   the gateway should deliver. `nil` registers with no `events` key
    ///   (legacy "everything" semantics). An empty list means "deliver nothing".
    func register(token deviceToken: String, events: [String]? = nil) async -> Outcome {
        await send(method: "POST", deviceToken: deviceToken, events: events)
    }

    /// `DELETE /api/push/register {token, platform:"ios"}` — symmetric unregister.
    func unregister(token deviceToken: String) async -> Outcome {
        await send(method: "DELETE", deviceToken: deviceToken, events: nil)
    }

    /// Self-healing path-family retry (ABH-88): APNs registration callbacks are
    /// OS-timed and can race the connect-time capability probe, so a `404`
    /// (`.softFail`) on the resolved family retries once on the alternate. A
    /// 404 on BOTH families is the genuine "push registry not deployed" →
    /// `.softFail`, exactly the old E1 signal.
    private func send(method: String, deviceToken: String, events: [String]?) async -> Outcome {
        let first = await sendAttempt(
            style: pathStyle, method: method, deviceToken: deviceToken, events: events
        )
        guard case .softFail = first else { return first }
        return await sendAttempt(
            style: pathStyle.alternate, method: method,
            deviceToken: deviceToken, events: events
        )
    }

    private func sendAttempt(
        style: APIPathStyle,
        method: String,
        deviceToken: String,
        events: [String]?
    ) async -> Outcome {
        // Drop the prefix's leading "/" — appendingPathComponent supplies one.
        let url = baseURL.appendingPathComponent(
            "\(style.mobileAPIPrefix.dropFirst())/push/register"
        )
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: Self.timeout
        )
        request.httpMethod = method
        // Loopback Host override — the gateway validates Host against its bind.
        request.setValue("127.0.0.1", forHTTPHeaderField: "Host")
        request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var body: [String: Any] = [
            "token": deviceToken,
            "platform": "ios",
            // APNs environment so the server registry routes the token to the
            // right APNs host (sandbox vs production). Detection lives in
            // ``apnsEnvironment`` below.
            "env": Self.apnsEnvironment,
        ]
        // QA-2 R1c: stable device identity for one-token-per-device dedup.
        if let deviceID, !deviceID.isEmpty {
            body["device_id"] = deviceID
        }
        // Per-event prefs (F2-A): only POST carries `events`; a DELETE drops the
        // token wholesale. `nil` omits the key (legacy "all events") so a stock
        // registry entry keeps working.
        if method == "POST", let events {
            body["events"] = events
        }
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return .hardFail
        }
        request.httpBody = payload

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .hardFail }
            if (200..<300).contains(http.statusCode) { return .success }
            if http.statusCode == 404 { return .softFail }
            // A non-404 4xx means the route exists but rejected this request —
            // enough to prove push-registry support (E1).
            if (400..<500).contains(http.statusCode) { return .validationRejected }
            return .hardFail
        } catch {
            return .hardFail
        }
    }
}
