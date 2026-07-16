import Foundation
import CryptoKit
import LocalAuthentication
import UIKit
import UserNotifications

/// Persisted, bounded dedupe ledger for system-alert delivery. Keys already
/// contain gateway + device namespaces, so switching or re-pairing cannot make
/// one installation suppress another. Main-actor isolation serializes APNs and
/// live-event arrival races.
@MainActor
final class NotificationDeliveryLedger {
    static let defaultTTL: TimeInterval = 24 * 60 * 60
    static let defaultMaximumEntries = 256

    private let defaults: UserDefaults
    private let storageKey: String
    private let ttl: TimeInterval
    private let maximumEntries: Int

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "hermes.notifications.deliveryLedger.v1",
        ttl: TimeInterval = defaultTTL,
        maximumEntries: Int = defaultMaximumEntries
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.ttl = ttl
        self.maximumEntries = max(1, maximumEntries)
    }

    /// Atomically reserve one alert. Returns false when the same logical event
    /// was already reserved/delivered inside the TTL window.
    func claim(namespace: String, eventId: String, now: Date = Date()) -> Bool {
        guard !namespace.isEmpty, !eventId.isEmpty else { return false }
        let timestamp = now.timeIntervalSince1970
        let cutoff = timestamp - ttl
        var entries = load().filter { $0.value > cutoff }
        let key = Self.digest("\(namespace)|\(eventId)")
        if entries[key] != nil {
            persist(entries)
            return false
        }
        entries[key] = timestamp
        if entries.count > maximumEntries {
            let newest = entries.sorted { $0.value > $1.value }.prefix(maximumEntries)
            entries = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        persist(entries)
        return true
    }

    var entryCount: Int { load().count }

    private func load() -> [String: TimeInterval] {
        (defaults.dictionary(forKey: storageKey) as? [String: TimeInterval]) ?? [:]
    }

    private func persist(_ entries: [String: TimeInterval]) {
        if entries.isEmpty {
            defaults.removeObject(forKey: storageKey)
        } else {
            defaults.set(entries, forKey: storageKey)
        }
    }

    nonisolated static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// APNs-authority policy, correlated local fallback, tap handling, and haptics.
///
/// All entry points are `@MainActor`. Authorization is requested *lazily* — the
/// first time an approval/clarify actually arrives — so the user is never
/// ambushed with a permission dialog at first launch; the "asked once" flag is
/// persisted in `UserDefaults`.
///
/// A live event only schedules a local request when the persisted registration
/// state says APNs is unavailable/unhealthy. Healthy registrations leave system
/// alert ownership to APNs.
@MainActor
enum NotificationService {
    enum AlertKind: String, Sendable, Equatable {
        case approval
        case clarify
        case turnComplete = "turn_complete"
    }

    struct PresentationContext {
        let deviceScope: String
        let activeRuntimeId: String?
        let activeStoredId: String?
        let pushIsAuthoritative: Bool
    }

    struct CorrelatedAlert: Sendable, Equatable {
        let kind: AlertKind
        let eventId: String
        let gatewayScope: String
        let sessionId: String
        let storedSessionId: String?

        var namespaceComponent: String { gatewayScope }
    }

    nonisolated(unsafe) static var presentationContextProvider:
        (@MainActor () -> PresentationContext?)?
    nonisolated(unsafe) static var localRequestSink:
        (@MainActor (UNNotificationRequest) -> Void)?
    nonisolated(unsafe) static var hapticSink: (@MainActor (AlertKind) -> Void)?
    private static var deliveryLedger = NotificationDeliveryLedger()

    static func setPresentationContextProvider(
        _ provider: @escaping @MainActor () -> PresentationContext?
    ) {
        presentationContextProvider = provider
    }

    static func setDeliveryLedgerForTesting(_ ledger: NotificationDeliveryLedger) {
        deliveryLedger = ledger
    }

    /// Apply APNs-authority policy to a live event. Missing server identity is
    /// never replaced with a client UUID: UI state still updates, but no system
    /// alert can be safely deduplicated.
    static func handleLiveAlert(
        _ alert: CorrelatedAlert?,
        title: String,
        body: String,
        deviceScope: String,
        pushIsAuthoritative: Bool,
        isActiveSession: Bool
    ) {
        guard let alert else { return }
        let namespace = "\(alert.gatewayScope)|\(deviceScope)"

        if isActiveSession {
            // The visible session never needs a system banner. Whichever path
            // arrives first reserves the event and owns the one in-app haptic.
            if deliveryLedger.claim(namespace: namespace, eventId: alert.eventId) {
                emitHaptic(alert.kind)
            }
            return
        }
        guard !pushIsAuthoritative else { return }
        guard deliveryLedger.claim(namespace: namespace, eventId: alert.eventId) else { return }
        postCorrelated(
            alert,
            title: title,
            body: body,
            namespace: namespace
        )
    }

    /// Foreground APNs policy: first arrival may alert for a non-active session;
    /// duplicates and the active session are silent. The ledger claim happens
    /// before the active-session check so a later WebSocket fallback cannot race.
    static func foregroundPresentationOptions(
        userInfo: [AnyHashable: Any]
    ) -> UNNotificationPresentationOptions {
        guard let alert = decodeCorrelatedAlert(from: userInfo),
              let context = presentationContextProvider?() else {
            return [.banner, .sound]
        }
        let namespace = "\(alert.gatewayScope)|\(context.deviceScope)"
        guard deliveryLedger.claim(namespace: namespace, eventId: alert.eventId) else {
            return []
        }
        let active = alert.sessionId == context.activeRuntimeId
            || (alert.storedSessionId != nil && alert.storedSessionId == context.activeStoredId)
        if active {
            emitHaptic(alert.kind)
            return []
        }
        return [.banner, .sound]
    }

    nonisolated static func decodeCorrelatedAlert(
        from userInfo: [AnyHashable: Any]
    ) -> CorrelatedAlert? {
        let custom = (userInfo["hermes"] as? [AnyHashable: Any]) ?? userInfo
        guard let rawKind = custom["event_type"] as? String,
              let kind = AlertKind(rawValue: rawKind),
              let eventId = nonEmpty(custom["event_id"] as? String),
              let gatewayScope = nonEmpty(custom["gateway_scope"] as? String),
              let sessionId = nonEmpty(custom["session_id"] as? String) else { return nil }
        return CorrelatedAlert(
            kind: kind,
            eventId: eventId,
            gatewayScope: gatewayScope,
            sessionId: sessionId,
            storedSessionId: nonEmpty(custom["stored_session_id"] as? String)
        )
    }

    private nonisolated static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
    // Notification category identifiers — these are `UNNotificationCategory`
    // identifiers, NOT `UserDefaults` keys, so they stay local to this type.
    //
    // The `hermes.*` ids are the LOCAL-notification categories (B-wave, fired
    // in-process). The `HERMES_*` ids are the REMOTE APNs categories the gateway
    // stamps into `aps.category` (F2-S), which carry the actionable buttons. The
    // two namespaces coexist: a local approval notification has no action buttons
    // (it routes a tap to the inbox), while a remote `HERMES_APPROVAL` push
    // renders Approve / Deny inline (A1).
    private static let approvalCategory = "hermes.approval"
    private static let clarifyCategory = "hermes.clarify"

    // MARK: - Actionable push categories + actions (A1)
    //
    // BINDING (contract A1): registered exactly as
    //   HERMES_APPROVAL → APPROVE [.authenticationRequired],
    //                     DENY    [.destructive, .authenticationRequired]
    //   HERMES_CLARIFY  → REPLY   [text input]
    //   HERMES_TURN     → no actions (open-app only).
    //
    // `.authenticationRequired` is the OS-level half of the BINDING "no approval
    // action may fire from a locked, unauthenticated device": iOS will not even
    // deliver an `.authenticationRequired` action to the app until the device is
    // unlocked, so a locked-screen Approve/Deny tap first forces a device unlock.
    // (Verified against the SDK: `UNNotificationActionOptionAuthenticationRequired`
    // in UNNotificationAction.h.) The app-level half — an explicit `LAContext`
    // re-check for destructive approvals — is layered on top in `didReceive`.

    // `nonisolated` so the nonisolated decoders (`decodeTap`) and the unit tests
    // can read them without hopping to the main actor; they're immutable string
    // constants, so this is sound.

    /// Remote APNs category id for an approval request (carries action buttons).
    nonisolated static let remoteApprovalCategory = "HERMES_APPROVAL"
    /// Remote APNs category id for a clarification (open-app only).
    nonisolated static let remoteClarifyCategory = "HERMES_CLARIFY"
    /// Remote APNs category id for a long-turn completion (open-app only).
    nonisolated static let remoteTurnCategory = "HERMES_TURN"

    /// Action id for the inline "Approve" button on a `HERMES_APPROVAL` push.
    nonisolated static let approveActionIdentifier = "APPROVE"
    /// Action id for the inline "Deny" button on a `HERMES_APPROVAL` push.
    nonisolated static let denyActionIdentifier = "DENY"
    /// Action id for the inline text reply on a `HERMES_CLARIFY` push.
    nonisolated static let replyActionIdentifier = "REPLY"

    // MARK: - Tap routing (B5)

    /// What a tapped notification asks the app to do, decoded from the push
    /// payload's `event_type` + `session_id`. Both the local notifications fired
    /// here and the remote APNs alerts the gateway sends (see `push_notify.py` /
    /// `tui_gateway/server.py` `_push_hook`) share this contract: the custom keys
    /// live under the `hermes` block of the APNs payload, namespaced as
    /// `{"hermes": {"event_type": "approval"|"clarify"|"turn_complete",
    /// "session_id": <runtime sid>}}`. Local notifications post the same keys flat
    /// in `userInfo` (no `aps` envelope), so the decoder looks in both places.
    enum Tap: Sendable, Equatable {
        /// An approval / clarification needs the user — open its session (and
        /// surface the inbox if the session can't be located).
        case attention(sessionId: String)
        /// A long turn finished — open its session.
        case turnComplete(sessionId: String)
    }

    /// The app-supplied sink that routes a decoded tap into the live store graph.
    /// Wired once at launch by `HermesMobileApp` (it forwards to
    /// `HermesURLRouter.routePushTap`). Set on the main actor; read on the main
    /// actor from the delegate callback after a hop.
    nonisolated(unsafe) static var tapHandler: (@MainActor @Sendable (Tap) -> Void)?

    /// Install the app's tap router. Idempotent; safe to call at launch.
    static func setTapHandler(_ handler: @escaping @MainActor @Sendable (Tap) -> Void) {
        tapHandler = handler
    }

    // MARK: - Action backend resolution (A2)

    /// Resolved gateway endpoint for the approval-action REST call: the base URL
    /// and the session token, packaged so the (possibly background-launched)
    /// notification-action delegate can build a ``RestClient`` without reaching
    /// into the `@MainActor` store graph.
    struct ActionEndpoint: Sendable {
        let baseURL: URL
        let token: String
        /// REST path family for the mobile endpoints (ABH-88). Resolved from
        /// the live/cached capability snapshot; a stale value self-heals via
        /// ``RestClient/respondToApproval``'s alternate-family 404 retry.
        var pathStyle: APIPathStyle = .legacy
    }

    /// App-supplied resolver for the current gateway endpoint. Wired once at
    /// launch by `HermesMobileApp` off the live `ConnectionStore` (mirrors how
    /// `PushRegistrar.makePoster()` resolves URL + token). Read on the main actor
    /// from the action callback. `nil` when the app isn't configured yet, in
    /// which case the action falls back to a feedback notification.
    nonisolated(unsafe) static var endpointProvider:
        (@MainActor @Sendable () -> ActionEndpoint?)?

    /// Seam over `LAContext` so the destructive-approval gate is unit-testable
    /// (XCTest can't satisfy a real biometric prompt). Defaults to the live
    /// `LAContext`-backed implementation reused from ``AppLock``.
    nonisolated(unsafe) static var biometricAuthenticator: BiometricAuthenticating
        = LAContextAuthenticator()

    #if DEBUG
    /// Injectable approval sender for killed-launch action tests.
    nonisolated(unsafe) static var approvalActionSender:
        ((ActionEndpoint, ApprovalActionPayload, Bool) async -> RestClient.ApprovalRespondOutcome)?
    #endif

    /// Install the action backend resolver (endpoint + categories). Idempotent.
    static func setActionEndpointProvider(
        _ provider: @escaping @MainActor @Sendable () -> ActionEndpoint?
    ) {
        endpointProvider = provider
    }

    // MARK: - Approval action handling (A2)

    /// Whether a given action identifier maps to approve vs deny. `nil` for any
    /// other action (e.g. the default open-app tap, dismiss).
    ///
    /// Pure mapping, exposed for the unit tests (A5: action→request mapping).
    nonisolated static func approveChoice(for actionIdentifier: String) -> Bool? {
        switch actionIdentifier {
        case approveActionIdentifier: return true
        case denyActionIdentifier: return false
        default: return nil
        }
    }

    /// Handle an `APPROVE` / `DENY` notification action.
    ///
    /// Flow (contract A2):
    ///  1. Decode the `hermes` block → runtime session id + `destructive`.
    ///  2. If `destructive == true`, gate behind an explicit `LAContext`
    ///     biometric re-check (the `.authenticationRequired` action option
    ///     already forced a device unlock to even reach here; this is the
    ///     app-level Wave-2.2 amendment for dangerous actions). A failed/cancelled
    ///     gate aborts the send and posts feedback — the inbox stays authoritative.
    ///  3. `POST /api/approvals/respond` with the Keychain token + loopback Host
    ///     override (via ``RestClient``, which runs fine from this possibly
    ///     background-launched callback).
    ///  4. `resolved:false` / 404 → "Already handled elsewhere" feedback.
    ///     Transport / 401 failure → feedback + the inbox remains the source of
    ///     truth (nothing is silently dropped).
    ///
    /// Returns when the work is done so the delegate can call its completion
    /// handler — the system keeps the app alive for the action only until then.
    @MainActor
    static func handleApprovalAction(
        approve: Bool,
        action: ApprovalActionPayload
    ) async {
        // Destructive approvals (and the BINDING for dangerous actions) require an
        // explicit biometric re-check before the response is sent. Deny is also
        // gated when destructive: confirming a dangerous decision either way
        // should prove device ownership.
        if action.destructive {
            let result = await biometricAuthenticator.evaluate(
                reason: approve ? "Approve a destructive action"
                                : "Respond to a destructive action"
            )
            if case .failure = result {
                // Authentication failed/cancelled: do not send. Keep the prompt
                // actionable in-app and tell the user why nothing happened.
                postFeedbackNotification(
                    title: "Not confirmed",
                    body: "Face ID was needed to \(approve ? "approve" : "deny") this. Open Hermes to respond."
                )
                return
            }
        }

        guard let endpoint = endpointProvider?() else {
            // Not configured (no server/token yet): can't reach the gateway.
            postFeedbackNotification(
                title: "Couldn't respond",
                body: "Open Hermes to respond to this request."
            )
            return
        }

        let outcome: RestClient.ApprovalRespondOutcome
        #if DEBUG
        if let sender = approvalActionSender {
            outcome = await sender(endpoint, action, approve)
        } else {
            outcome = await sendApproval(endpoint: endpoint, action: action, approve: approve)
        }
        #else
        outcome = await sendApproval(endpoint: endpoint, action: action, approve: approve)
        #endif

        switch outcome {
        case .resolved:
            // Mirror the in-flight Live Activity: the turn resumes.
            LiveActivityManager.shared.clearNeedsApproval()
        case .alreadyHandled:
            postFeedbackNotification(
                title: "Already handled elsewhere",
                body: feedbackBody(for: action)
            )
        case .failed:
            postFeedbackNotification(
                title: "Couldn't respond",
                body: "The request didn't go through. Open Hermes to respond."
            )
        }
    }

    private static func sendApproval(
        endpoint: ActionEndpoint, action: ApprovalActionPayload, approve: Bool
    ) async -> RestClient.ApprovalRespondOutcome {
        let rest = RestClient(
            baseURL: endpoint.baseURL, token: endpoint.token, pathStyle: endpoint.pathStyle
        )
        return await rest.respondToApproval(
            sessionId: action.sessionId, approve: approve, all: false
        )
    }

    // MARK: - Clarify text reply handling (ABH-296)

    /// The fields a `REPLY` text action needs from a `HERMES_CLARIFY` push.
    struct ClarifyReplyActionPayload: Sendable, Equatable {
        /// Runtime session id — used for session ownership/auth checks server-side.
        let sessionId: String
        /// `_block(...)` request id (`approval_id` in the mobile push payload).
        let approvalId: String
    }

    #if DEBUG
    /// Injectable sender for notification-reply unit tests. `nil` in production.
    nonisolated(unsafe) static var clarifyReplySender:
        ((ActionEndpoint, ClarifyReplyActionPayload, String) async -> RestClient.ApprovalRespondOutcome)?
    #endif

    /// Decode the clarify-reply payload from a notification's `userInfo`.
    nonisolated static func decodeClarifyReplyAction(
        from userInfo: [AnyHashable: Any]
    ) -> ClarifyReplyActionPayload? {
        guard let block = userInfo["hermes"] as? [AnyHashable: Any] else { return nil }
        guard
            let sessionId = (block["session_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !sessionId.isEmpty
        else { return nil }
        let rawApprovalId = (block["approval_id"] as? String)
            ?? (block["request_id"] as? String)
        guard
            let approvalId = rawApprovalId?.trimmingCharacters(in: .whitespacesAndNewlines),
            !approvalId.isEmpty
        else { return nil }
        let responseAction = (block["response_action"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard responseAction == nil || responseAction == "reply" else { return nil }
        return ClarifyReplyActionPayload(sessionId: sessionId, approvalId: approvalId)
    }

    /// Handle a `REPLY` text action on a `HERMES_CLARIFY` notification.
    @MainActor
    static func handleClarifyReplyAction(
        text: String,
        action: ClarifyReplyActionPayload
    ) async {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else {
            postFeedbackNotification(
                title: "Couldn't reply",
                body: "Type a reply, or open Hermes to answer this question."
            )
            return
        }
        guard let endpoint = endpointProvider?() else {
            postFeedbackNotification(
                title: "Couldn't reply",
                body: "Open Hermes to answer this question."
            )
            return
        }

        let outcome: RestClient.ApprovalRespondOutcome
        #if DEBUG
        if let sender = clarifyReplySender {
            outcome = await sender(endpoint, action, answer)
        } else {
            outcome = await sendClarifyReply(endpoint: endpoint, action: action, answer: answer)
        }
        #else
        outcome = await sendClarifyReply(endpoint: endpoint, action: action, answer: answer)
        #endif

        switch outcome {
        case .resolved:
            LiveActivityManager.shared.clearNeedsApproval()
        case .alreadyHandled:
            postFeedbackNotification(
                title: "Already handled elsewhere",
                body: "This question was already answered."
            )
        case .failed:
            postFeedbackNotification(
                title: "Couldn't reply",
                body: "The reply didn't go through. Open Hermes to answer."
            )
        }
    }

    private enum ClarifyReplyAttempt {
        case outcome(RestClient.ApprovalRespondOutcome)
        case routeMiss

        var outcome: RestClient.ApprovalRespondOutcome {
            switch self {
            case .outcome(let value): return value
            case .routeMiss: return .alreadyHandled
            }
        }
    }

    private static func sendClarifyReply(
        endpoint: ActionEndpoint,
        action: ClarifyReplyActionPayload,
        answer: String
    ) async -> RestClient.ApprovalRespondOutcome {
        let first = await sendClarifyReplyAttempt(
            endpoint: endpoint, style: endpoint.pathStyle, action: action, answer: answer
        )
        guard case .routeMiss = first else { return first.outcome }
        let second = await sendClarifyReplyAttempt(
            endpoint: endpoint, style: endpoint.pathStyle.alternate, action: action, answer: answer
        )
        return second.outcome
    }

    private static func sendClarifyReplyAttempt(
        endpoint: ActionEndpoint,
        style: APIPathStyle,
        action: ClarifyReplyActionPayload,
        answer: String
    ) async -> ClarifyReplyAttempt {
        let rest = RestClient(
            baseURL: endpoint.baseURL,
            token: endpoint.token,
            pathStyle: style
        )
        var request = rest.makeRequest(path: "\(style.mobileAPIPrefix)/approvals/reply", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: JSONValue = .object([
            "session_id": .string(action.sessionId),
            "approval_id": .string(action.approvalId),
            "answer": .string(answer),
        ])
        guard let payload = try? rest.encodeBody(body, context: "approvals/reply") else {
            return .outcome(.failed)
        }
        request.httpBody = payload

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await rest.session.data(for: request)
        } catch {
            return .outcome(.failed)
        }
        guard let http = response as? HTTPURLResponse else { return .outcome(.failed) }
        switch http.statusCode {
        case 200, 201:
            let root = try? rest.decodeJSONValue(from: data, context: "approvals/reply")
            let resolved = root?["resolved"]?.boolValue ?? false
            return .outcome(resolved ? .resolved : .alreadyHandled)
        case 404:
            return .routeMiss
        default:
            return .outcome(.failed)
        }
    }

    /// Body line for the "already handled" feedback, naming the target when known.
    private static func feedbackBody(for action: ApprovalActionPayload) -> String {
        if let title = action.approvalTitle, !title.isEmpty {
            return "\(title) was already resolved."
        }
        return "This request was already resolved."
    }

    /// Fire a local feedback notification for an action that couldn't land
    /// authoritatively (already handled, failed, not confirmed). No category /
    /// userInfo so a tap just opens the app.
    static func postFeedbackNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// Decode a tap from a notification's `userInfo`. Tolerant of both shapes:
    /// the gateway's APNs payload (`userInfo["hermes"]`) and a local
    /// notification's flat keys. Returns `nil` for payloads we don't route.
    nonisolated static func decodeTap(from userInfo: [AnyHashable: Any]) -> Tap? {
        // Prefer the namespaced `hermes` block (remote APNs), fall back to flat.
        let custom: [AnyHashable: Any]
        if let block = userInfo["hermes"] as? [AnyHashable: Any] {
            custom = block
        } else {
            custom = userInfo
        }
        guard
            let sessionId = (custom["session_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !sessionId.isEmpty
        else { return nil }

        let eventType = (custom["event_type"] as? String)?.lowercased() ?? ""
        switch eventType {
        case "approval", "clarify":
            return .attention(sessionId: sessionId)
        case "turn_complete":
            return .turnComplete(sessionId: sessionId)
        default:
            // No `event_type` (the F2-S remote payload routes by `aps.category`
            // instead of a flat event_type). Fall back to the APNs category so a
            // tapped HERMES_APPROVAL / HERMES_CLARIFY still surfaces its session
            // as "attention", and HERMES_TURN as "open the session".
            switch apsCategory(in: userInfo) {
            case remoteApprovalCategory, remoteClarifyCategory:
                return .attention(sessionId: sessionId)
            case remoteTurnCategory:
                return .turnComplete(sessionId: sessionId)
            default:
                // A session id is present but no event_type / category — treat as
                // plain "open the session" (older / local notifications).
                return .turnComplete(sessionId: sessionId)
            }
        }
    }

    /// The `aps.category` value from a notification's `userInfo`, if present.
    /// On a delivered remote notification the category also rides on
    /// `UNNotificationContent.categoryIdentifier`; this reads it straight from
    /// the raw payload so the decoder is exercisable in unit tests.
    nonisolated static func apsCategory(in userInfo: [AnyHashable: Any]) -> String? {
        (userInfo["aps"] as? [AnyHashable: Any])?["category"] as? String
    }

    // MARK: - Approval action payload (A2)

    /// The fields an `APPROVE` / `DENY` action needs, decoded from a
    /// `HERMES_APPROVAL` push's `hermes` block. Per the pinned interface the
    /// block carries `session_id` (runtime sid), `stored_session_id` (when
    /// resolvable), `destructive` (bool, default false), and `approval_title`.
    struct ApprovalActionPayload: Sendable, Equatable {
        /// Runtime session id — the target of `POST /api/approvals/respond`.
        let sessionId: String
        /// Stable gateway request id used to suppress duplicate APNs delivery.
        let requestId: String?
        /// Persistent stored session id, when the push carried it.
        let storedSessionId: String?
        /// `true` when the approval marks a destructive/dangerous action: gates
        /// the action behind an explicit `LAContext` biometric re-check.
        let destructive: Bool
        /// Short target string, surfaced in the "Already handled" feedback.
        let approvalTitle: String?
    }

    /// Decode the approval-action payload from a notification's `userInfo`.
    /// Returns `nil` when there is no usable runtime `session_id`.
    nonisolated static func decodeApprovalAction(
        from userInfo: [AnyHashable: Any]
    ) -> ApprovalActionPayload? {
        guard let block = userInfo["hermes"] as? [AnyHashable: Any] else { return nil }
        guard
            let sessionId = (block["session_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !sessionId.isEmpty
        else { return nil }

        let stored = (block["stored_session_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (block["approval_title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requestId = ((block["approval_id"] as? String) ?? (block["request_id"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ApprovalActionPayload(
            sessionId: sessionId,
            requestId: (requestId?.isEmpty == false) ? requestId : nil,
            storedSessionId: (stored?.isEmpty == false) ? stored : nil,
            // Tolerate both a real JSON bool and a "true"/"1" string, since some
            // APNs JSON paths stringify booleans.
            destructive: boolValue(block["destructive"]),
            approvalTitle: (title?.isEmpty == false) ? title : nil
        )
    }

    /// Coerce a JSON value (Bool, NSNumber, or "true"/"1" string) to a Bool.
    private nonisolated static func boolValue(_ any: Any?) -> Bool {
        if let bool = any as? Bool { return bool }
        if let number = any as? NSNumber { return number.boolValue }
        if let string = (any as? String)?.lowercased() {
            return string == "true" || string == "1" || string == "yes"
        }
        return false
    }

    /// Ask for notification authorization. Also installs the foreground-
    /// presentation delegate so notifications fired while the app is active still
    /// show a banner + play a sound.
    ///
    /// `force` distinguishes the once-per-install LAUNCH path (`false` — suppress
    /// the prompt after the first ask so we never nag on every cold start) from an
    /// EXPLICIT user action (`true` — toggling notifications ON in Settings).
    /// `requestAuthorization` only presents the system dialog when status is
    /// `.notDetermined`, so re-calling with `force` is safe: it lets a user who
    /// dismissed the first prompt ("Don't Allow"/"Ask Next Time") get it again by
    /// toggling ON (the latch previously swallowed that forever). When already
    /// `.denied`, the OS returns the denial without a prompt and Settings surfaces
    /// its "Open Settings" path.
    static func requestAuthorizationIfNeeded(force: Bool = false) {
        Task { @MainActor in
            _ = await requestAuthorizationStatusIfNeeded(force: force)
        }
    }

    /// Async variant for remote-push registration: returns the settled system
    /// authorization state so callers can avoid asking APNs for a token when iOS
    /// has already denied alert delivery (the Settings UI must then show a real
    /// "not authorized" state, not a fake OK).
    static func requestAuthorizationStatusIfNeeded(force: Bool = false) async -> UNAuthorizationStatus {
        registerCategories()
        let defaults = UserDefaults.standard
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .notDetermined else {
            return settings.authorizationStatus
        }
        if !force {
            guard !defaults.bool(forKey: DefaultsKeys.notificationsDidRequestAuthorization) else {
                return settings.authorizationStatus
            }
        }

        return await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge]
            ) { _, _ in
                // Latch "asked once" only AFTER the dialog resolves (release
                // audit): setting it before meant an app kill mid-dialog consumed
                // the one-shot without an answer — the prompt never re-showed.
                defaults.set(true, forKey: DefaultsKeys.notificationsDidRequestAuthorization)
                UNUserNotificationCenter.current().getNotificationSettings { updated in
                    continuation.resume(returning: updated.authorizationStatus)
                }
            }
        }
    }

    // MARK: - Category registration (A1)

    /// Register the actionable-push categories with the notification center.
    ///
    /// Idempotent and cheap; called from `requestAuthorizationIfNeeded()` (so the
    /// categories exist before any push lands) and again at launch via
    /// ``setActionHandler(_:)``. `setNotificationCategories` REPLACES the whole
    /// set, so we register all categories in one call.
    static func registerCategories(center: UNUserNotificationCenter = .current()) {
        center.setNotificationCategories(
            remoteNotificationCategoriesForTesting()
        )
    }

    /// Build the remote APNs categories. Exposed internally for host tests;
    /// `registerCategories()` is still the only production registration path.
    nonisolated static func remoteNotificationCategoriesForTesting() -> Set<UNNotificationCategory> {
        let approve = UNNotificationAction(
            identifier: approveActionIdentifier,
            title: "Approve",
            options: [.authenticationRequired]
        )
        let deny = UNNotificationAction(
            identifier: denyActionIdentifier,
            title: "Deny",
            // `.destructive` renders the button red; `.authenticationRequired`
            // forces a device unlock before the action reaches the app.
            options: [.destructive, .authenticationRequired]
        )
        let reply = UNTextInputNotificationAction(
            identifier: replyActionIdentifier,
            title: "Reply",
            options: [.authenticationRequired],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Reply to Hermes"
        )
        let approvalCat = UNNotificationCategory(
            identifier: remoteApprovalCategory,
            actions: [approve, deny],
            intentIdentifiers: [],
            options: []
        )
        let clarifyCat = UNNotificationCategory(
            identifier: remoteClarifyCategory,
            actions: [reply],
            intentIdentifiers: [],
            options: []
        )
        let turnCat = UNNotificationCategory(
            identifier: remoteTurnCategory,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        return [approvalCat, clarifyCat, turnCat]
    }

    private static func postCorrelated(
        _ alert: CorrelatedAlert,
        title: String,
        body: String,
        namespace: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        switch alert.kind {
        case .approval: content.categoryIdentifier = approvalCategory
        case .clarify: content.categoryIdentifier = clarifyCategory
        case .turnComplete: content.categoryIdentifier = remoteTurnCategory
        }
        var info: [AnyHashable: Any] = [
            "event_type": alert.kind.rawValue,
            "event_id": alert.eventId,
            "gateway_scope": alert.gatewayScope,
            "session_id": alert.sessionId,
        ]
        if let storedSessionId = alert.storedSessionId {
            info["stored_session_id"] = storedSessionId
        }
        content.userInfo = info
        let identifier = "hermes." + NotificationDeliveryLedger.digest(
            "\(namespace)|\(alert.eventId)"
        ).prefix(40)
        let request = UNNotificationRequest(
            identifier: String(identifier), content: content, trigger: nil
        )
        if let localRequestSink {
            localRequestSink(request)
        } else {
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }
    }

    private static func emitHaptic(_ kind: AlertKind) {
        if let hapticSink {
            hapticSink(kind)
            return
        }
        switch kind {
        case .approval, .clarify: approvalHaptic()
        case .turnComplete: turnCompleteHaptic()
        }
    }

    // MARK: - Haptics

    /// Warning haptic — used when an approval/clarification needs attention.
    static func approvalHaptic() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.warning)
    }

    /// Success haptic — used when a (long-running) turn completes.
    static func turnCompleteHaptic() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }

}
