import Foundation
import UserNotifications

/// Offline-only HRP/2 preview decryptor. It never opens a socket, reads a Hub
/// grant, or obtains chat identity keys. Failure always delivers a generic alert.
final class NotificationService: UNNotificationServiceExtension {
    private let processor = RelayV2NotificationServiceProcessor()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var fallbackContent: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        let fallback = RelayV2NotificationServiceProcessor.genericFallback(
            from: request.content
        )
        self.fallbackContent = fallback
        contentHandler(processor.render(request.content))
        self.contentHandler = nil
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let fallbackContent {
            contentHandler(fallbackContent)
            self.contentHandler = nil
        }
    }

}
