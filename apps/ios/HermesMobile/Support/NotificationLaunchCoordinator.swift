import UIKit
import UserNotifications

/// Resolves the notification-action REST endpoint without constructing or
/// waiting for a ``ConnectionStore``. The URL and path family come from their
/// established UserDefaults owners; the credential is read exclusively through
/// ``KeychainService``.
struct PersistedNotificationEndpointResolver {
    var loadURLString: () -> String? = {
        UserDefaults.standard.string(forKey: DefaultsKeys.serverURL)
    }
    var loadToken: (String) -> String? = { KeychainService.loadToken(server: $0) }
    var loadPathStyle: (String) -> APIPathStyle = {
        ServerCapabilities.cachedPathStyle(serverURL: $0)
    }

    func resolve() -> NotificationService.ActionEndpoint? {
        guard let rawURL = loadURLString()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty,
              let url = URL(string: rawURL),
              url.scheme != nil,
              url.host != nil,
              let token = loadToken(rawURL),
              !token.isEmpty else { return nil }
        return NotificationService.ActionEndpoint(
            baseURL: url, token: token, pathStyle: loadPathStyle(rawURL)
        )
    }
}

/// Process-lifetime owner for notification registration and response delivery.
/// UIKit creates this through `AppDelegate`, before any SwiftUI view task runs.
@MainActor
final class NotificationLaunchCoordinator: NSObject, UNUserNotificationCenterDelegate {
    struct CompletionBox: @unchecked Sendable {
        let handler: () -> Void
    }

    private struct PresentationBox: @unchecked Sendable {
        let userInfo: [AnyHashable: Any]
        let completion: (UNNotificationPresentationOptions) -> Void
    }

    enum Event: Sendable {
        case tap(NotificationService.Tap)
        case approval(Bool, NotificationService.ApprovalActionPayload?, CompletionBox)
        case reply(String, NotificationService.ClarifyReplyActionPayload?, CompletionBox)
    }

    private var pending: [Event] = []
    private var didInstall = false
    private var tapHandler: (@MainActor @Sendable (NotificationService.Tap) -> Void)?
    private var endpointProvider:
        (@MainActor @Sendable () -> NotificationService.ActionEndpoint?)?
    private var actionCompletionHandler: (@MainActor @Sendable () -> Void)?
    private var owesActionReconciliation = false
    private var actionRequestIDsInFlight: Set<String> = []
    private var completedActionRequestIDs: Set<String> = []

    func install(center: UNUserNotificationCenter = .current()) {
        guard !didInstall else { return }
        didInstall = true
        center.delegate = self
        NotificationService.registerCategories(center: center)
    }

    func attachTapHandler(
        _ handler: @escaping @MainActor @Sendable (NotificationService.Tap) -> Void
    ) {
        tapHandler = handler
        NotificationService.setTapHandler(handler)
        drainIfReady()
    }

    func attachActionEndpointProvider(
        _ provider: @escaping @MainActor @Sendable () -> NotificationService.ActionEndpoint?
    ) {
        endpointProvider = provider
        NotificationService.setActionEndpointProvider(provider)
        drainIfReady()
    }

    func attachActionCompletionHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {
        actionCompletionHandler = handler
        if owesActionReconciliation {
            owesActionReconciliation = false
            handler()
        }
    }

    func receive(_ event: Event) {
        guard isReady(for: event) else {
            pending.append(event)
            return
        }
        route(event)
    }

    private func isReady(for event: Event) -> Bool {
        switch event {
        case .tap: return tapHandler != nil
        case .approval, .reply: return endpointProvider != nil
        }
    }

    private func drainIfReady() {
        guard !pending.isEmpty else { return }
        var blocked: [Event] = []
        for event in pending {
            isReady(for: event) ? route(event) : blocked.append(event)
        }
        pending = blocked
    }

    private func route(_ event: Event) {
        switch event {
        case .tap(let tap):
            tapHandler?(tap)
        case .approval(let approve, let action, let completion):
            guard beginAction(requestID: action?.requestId) else {
                completion.handler()
                return
            }
            Task { @MainActor in
                if let action {
                    await NotificationService.handleApprovalAction(approve: approve, action: action)
                } else {
                    NotificationService.postFeedbackNotification(
                        title: "Couldn't respond", body: "Open Hermes to respond to this request."
                    )
                }
                self.finishAction(requestID: action?.requestId)
                self.notifyActionCompletion()
                completion.handler()
            }
        case .reply(let text, let action, let completion):
            guard beginAction(requestID: action?.approvalId) else {
                completion.handler()
                return
            }
            Task { @MainActor in
                if let action {
                    await NotificationService.handleClarifyReplyAction(text: text, action: action)
                } else {
                    NotificationService.postFeedbackNotification(
                        title: "Couldn't reply", body: "Open Hermes to answer this question."
                    )
                }
                self.finishAction(requestID: action?.approvalId)
                self.notifyActionCompletion()
                completion.handler()
            }
        }
    }

    private func beginAction(requestID: String?) -> Bool {
        guard let requestID, !requestID.isEmpty else { return true }
        guard !actionRequestIDsInFlight.contains(requestID),
              !completedActionRequestIDs.contains(requestID) else { return false }
        actionRequestIDsInFlight.insert(requestID)
        return true
    }

    private func finishAction(requestID: String?) {
        guard let requestID, !requestID.isEmpty else { return }
        actionRequestIDsInFlight.remove(requestID)
        completedActionRequestIDs.insert(requestID)
    }

    private func notifyActionCompletion() {
        if let actionCompletionHandler {
            actionCompletionHandler()
        } else {
            owesActionReconciliation = true
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let box = PresentationBox(
            userInfo: notification.request.content.userInfo,
            completion: completionHandler
        )
        Task { @MainActor in
            box.completion(
                NotificationService.foregroundPresentationOptions(userInfo: box.userInfo)
            )
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let actionId = response.actionIdentifier
        let event: Event?
        let completion = CompletionBox(handler: completionHandler)
        if let approve = NotificationService.approveChoice(for: actionId) {
            event = .approval(
                approve, NotificationService.decodeApprovalAction(from: userInfo), completion
            )
        } else if actionId == NotificationService.replyActionIdentifier {
            let text = (response as? UNTextInputNotificationResponse)?.userText ?? ""
            event = .reply(
                text, NotificationService.decodeClarifyReplyAction(from: userInfo), completion
            )
        } else if actionId == UNNotificationDefaultActionIdentifier,
                  let tap = NotificationService.decodeTap(from: userInfo) {
            event = .tap(tap)
        } else {
            event = nil
        }
        guard let event else {
            completionHandler()
            return
        }
        if case .tap = event { completionHandler() }
        Task { @MainActor in self.receive(event) }
    }
}
