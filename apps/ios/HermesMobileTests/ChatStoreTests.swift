import XCTest
import UserNotifications
@testable import HermesMobile

@MainActor
final class ChatStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var requests: [UNNotificationRequest] = []
    private var haptics: [NotificationService.AlertKind] = []

    override func setUp() {
        super.setUp()
        let suite = "ChatStoreNotificationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        NotificationService.setDeliveryLedgerForTesting(
            NotificationDeliveryLedger(defaults: defaults, storageKey: "ledger")
        )
        requests = []
        haptics = []
        NotificationService.localRequestSink = { [weak self] in self?.requests.append($0) }
        NotificationService.hapticSink = { [weak self] in self?.haptics.append($0) }
    }

    override func tearDown() {
        NotificationService.localRequestSink = nil
        NotificationService.hapticSink = nil
        super.tearDown()
    }

    func testUnavailablePushPostsOneDeterministicLocalFallback() throws {
        let chat = ChatStore()
        chat.pushAlertAuthorityOverride = false
        chat.notificationDeviceScopeOverride = "device-a"
        chat.notificationForegroundOverride = false
        let event = try XCTUnwrap(makeEvent(
            type: "approval.request",
            sessionId: "runtime-background",
            payload: [
                "approval_id": "approval-stable",
                "event_id": "evt-stable",
                "gateway_scope": "gateway-a",
                "title": "Approval required",
            ]
        ))

        chat.handle(event: event)
        chat.handle(event: event)

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(
            requests[0].identifier,
            "hermes." + String(NotificationDeliveryLedger.digest(
                "gateway-a|device-a|evt-stable"
            ).prefix(40))
        )
        XCTAssertEqual(requests[0].content.userInfo["session_id"] as? String, "runtime-background")
    }

    func testActiveSessionUpdatesPromptAndHapticWithoutLocalAlert() throws {
        let sessions = SessionStore()
        let chat = ChatStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat, attachments: attachments)
        sessions.activeRuntimeId = "runtime-active"
        sessions.activeStoredId = "stored-active"
        chat.pushAlertAuthorityOverride = false
        chat.notificationDeviceScopeOverride = "device-a"
        chat.notificationForegroundOverride = true
        let event = try XCTUnwrap(makeEvent(
            type: "clarify.request",
            sessionId: "runtime-active",
            payload: [
                "request_id": "clarify-stable",
                "event_id": "evt-clarify",
                "gateway_scope": "gateway-a",
                "question": "Which file?",
            ]
        ))

        chat.handle(event: event)

        XCTAssertEqual(chat.pendingClarification?.request.question, "Which file?")
        XCTAssertEqual(haptics, [.clarify])
        XCTAssertTrue(requests.isEmpty)
    }

    func testSelectedBackgroundSessionStillReceivesFallbackAlert() throws {
        let sessions = SessionStore()
        let chat = ChatStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        chat.attach(connection: connection, sessions: sessions, attachments: AttachmentStore())
        sessions.activeRuntimeId = "runtime-selected"
        chat.pushAlertAuthorityOverride = false
        chat.notificationDeviceScopeOverride = "device-a"
        chat.notificationForegroundOverride = false
        let event = try XCTUnwrap(makeEvent(
            type: "clarify.request",
            sessionId: "runtime-selected",
            payload: [
                "request_id": "clarify-background",
                "event_id": "evt-background",
                "gateway_scope": "gateway-a",
                "question": "Which file?",
            ]
        ))

        chat.handle(event: event)

        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(haptics.isEmpty)
        XCTAssertEqual(
            requests[0].content.userInfo["session_id"] as? String,
            "runtime-selected"
        )
    }

    private func makeEvent(
        type: String,
        sessionId: String,
        payload: [String: JSONValue]
    ) -> GatewayEvent? {
        GatewayEvent(params: .object([
            "type": .string(type),
            "session_id": .string(sessionId),
            "payload": .object(payload),
        ]))
    }
}
