import UIKit
import UserNotifications

/// Process-lifetime owner for notification registration and response delivery.
/// UIKit creates this through `AppDelegate`, before any SwiftUI view task runs.
@MainActor
final class NotificationLaunchCoordinator: NSObject, UNUserNotificationCenterDelegate {
    struct CompletionBox: @unchecked Sendable {
        let handler: () -> Void
    }

    enum Event: Sendable {
        case tap(NotificationService.Tap)
        case approval(Bool, NotificationService.ApprovalActionPayload?, CompletionBox)
        case reply(String, NotificationService.ClarifyReplyActionPayload?, CompletionBox)
    }

    private var pending: [Event] = []
    private var tapHandler: ((NotificationService.Tap) -> Void)?
    private var endpointProvider: (() -> NotificationService.ActionEndpoint?)?

    func install(center: UNUserNotificationCenter = .current()) {
        center.delegate = self
        NotificationService.registerCategories()
    }

    func attachTapHandler(_ handler: @escaping (NotificationService.Tap) -> Void) {
        tapHandler = handler
        NotificationService.setTapHandler(handler)
        drainIfReady()
    }

    func attachActionEndpointProvider(
        _ provider: @escaping () -> NotificationService.ActionEndpoint?
    ) {
        endpointProvider = provider
        NotificationService.setActionEndpointProvider(provider)
        drainIfReady()
    }

    func receive(_ event: Event) {
        guard dependenciesAttached else {
            pending.append(event)
            return
        }
        route(event)
    }

    private var dependenciesAttached: Bool {
        tapHandler != nil && endpointProvider != nil
    }

    private func drainIfReady() {
        guard dependenciesAttached, !pending.isEmpty else { return }
        let events = pending
        pending.removeAll()
        events.forEach(route)
    }

    private func route(_ event: Event) {
        switch event {
        case .tap(let tap):
            tapHandler?(tap)
        case .approval(let approve, let action, let completion):
            Task { @MainActor in
                if let action {
                    await NotificationService.handleApprovalAction(approve: approve, action: action)
                } else {
                    NotificationService.postFeedbackNotification(
                        title: "Couldn't respond", body: "Open Hermes to respond to this request."
                    )
                }
                completion.handler()
            }
        case .reply(let text, let action, let completion):
            Task { @MainActor in
                if let action {
                    await NotificationService.handleClarifyReplyAction(text: text, action: action)
                } else {
                    NotificationService.postFeedbackNotification(
                        title: "Couldn't reply", body: "Open Hermes to answer this question."
                    )
                }
                completion.handler()
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
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
