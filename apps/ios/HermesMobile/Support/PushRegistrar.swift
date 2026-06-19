import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Coordinates APNs registration and ships the device token to the gateway.
///
/// Remote push is opt-in behind `UserDefaults` key `hermes.pushEnabled` (default
/// off). When enabled, ``enableIfAllowed()`` asks for notification authorization
/// (reusing the local-notification grant) and calls
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

    /// Flip the opt-in flag and (un)register accordingly. Disabling clears the
    /// remembered token so a later re-enable forces a fresh server register.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: DefaultsKeys.pushEnabled)
        if enabled {
            // Explicit user toggle-ON — force the auth prompt so a user who
            // declined the first time gets it again (the once-per-install latch
            // only applies to the silent launch path).
            enableIfAllowed(forcePrompt: true)
        } else {
            UserDefaults.standard.removeObject(forKey: DefaultsKeys.pushLastDeviceToken)
            UserDefaults.standard.removeObject(forKey: DefaultsKeys.pushLastEvents)
            UserDefaults.standard.removeObject(forKey: DefaultsKeys.pushLastEnv)
            #if canImport(UIKit)
            UIApplication.shared.unregisterForRemoteNotifications()
            #endif
        }
    }

    /// If push is enabled, request authorization and kick off APNs registration.
    /// Safe to call every launch — APNs registration is cheap and idempotent, and
    /// the system re-delivers the current token to the delegate each time.
    func enableIfAllowed(forcePrompt: Bool = false) {
        guard isEnabled else { return }
        #if canImport(UIKit)
        NotificationService.requestAuthorizationIfNeeded(force: forcePrompt)
        UIApplication.shared.registerForRemoteNotifications()
        #endif
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
           lastRegisteredEnv == env {
            return
        }

        guard let poster = makePoster() else { return }  // not configured yet
        Task { @MainActor in
            let outcome = await poster.register(token: hex, events: events)
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
                }
            case .hardFail:
                // Transport error: inconclusive for the capability gate, nothing
                // remembered. The next enableIfAllowed() retries.
                break
            }
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
        guard let poster = makePoster() else { return }
        Task { @MainActor in
            let outcome = await poster.register(token: hex, events: events)
            if case .success = outcome {
                lastRegisteredEvents = events
            }
        }
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
        // Best-effort: nothing to surface to the user. Kept as a seam so the
        // AppDelegate adaptor has a symmetric place to forward the failure.
    }

    // MARK: - Configuration resolution

    /// Build a poster from the current base URL + token, or `nil` when the app
    /// isn't configured yet. Mirrors `SessionStore`'s token resolution: dev env
    /// override first, then the saved URL + Keychain.
    private func makePoster() -> PushTokenPoster? {
        guard let endpoint = resolveEndpoint() else { return nil }
        return PushTokenPoster(
            baseURL: endpoint.url,
            token: endpoint.token,
            pathStyle: endpoint.pathStyle
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
    private let session: URLSession

    init(baseURL: URL, token: String, pathStyle: APIPathStyle = .legacy) {
        self.baseURL = baseURL
        self.token = token
        self.pathStyle = pathStyle
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.timeout
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    private static let timeout: TimeInterval = 15

    /// The APNs environment this build registers under: `"sandbox"` for dev-signed
    /// Xcode builds (and the simulator), `"production"` for TestFlight/App Store.
    ///
    /// Mere PRESENCE of `embedded.mobileprovision` is not a reliable signal:
    /// TestFlight builds also carry one (with `aps-environment = production`).
    /// So when a profile exists, read its actual `aps-environment` value —
    /// the profile is a CMS envelope around a plist, and a plain byte scan
    /// for the key/value pair is the established lightweight technique. No
    /// profile at all → App Store → production. Simulator → always sandbox.
    /// The server registry routes the device token per this value.
    static let apnsEnvironment: String = {
        #if targetEnvironment(simulator)
        return "sandbox"
        #else
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .ascii) else {
            return "production"  // no profile = App Store signed
        }
        // Look for <key>aps-environment</key><string>development|production</string>
        guard let keyRange = text.range(of: "<key>aps-environment</key>") else {
            return "production"  // distribution profile without the dev entitlement
        }
        let tail = text[keyRange.upperBound...].prefix(120)
        return tail.contains("<string>development</string>") ? "sandbox" : "production"
        #endif
    }()

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
