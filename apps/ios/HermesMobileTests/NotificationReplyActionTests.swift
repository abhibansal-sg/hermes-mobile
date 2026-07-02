import UserNotifications
import XCTest
@testable import HermesMobile

/// ABH-296: lock-screen Reply(text) for clarification prompts only.
final class NotificationReplyActionTests: XCTestCase {

    func testClarifyRemoteCategoryHasReplyTextActionOnly() throws {
        let categories = NotificationService.remoteNotificationCategoriesForTesting()
        let clarify = try XCTUnwrap(
            categories.first { $0.identifier == NotificationService.remoteClarifyCategory }
        )
        let approval = try XCTUnwrap(
            categories.first { $0.identifier == NotificationService.remoteApprovalCategory }
        )

        let reply = try XCTUnwrap(
            clarify.actions.first { $0.identifier == NotificationService.replyActionIdentifier }
        )
        XCTAssertTrue(reply is UNTextInputNotificationAction)
        XCTAssertEqual(reply.title, "Reply")
        XCTAssertFalse(
            approval.actions.contains { $0.identifier == NotificationService.replyActionIdentifier },
            "approval pushes stay Approve/Deny only; Reply is clarify-only"
        )
    }

    func testDecodeClarifyReplyActionRequiresSessionAndApprovalId() throws {
        let payload = try XCTUnwrap(NotificationService.decodeClarifyReplyAction(from: [
            "hermes": [
                "session_id": " runtime-sid ",
                "approval_id": " rid-123 ",
                "response_action": "reply",
            ],
        ]))

        XCTAssertEqual(payload.sessionId, "runtime-sid")
        XCTAssertEqual(payload.approvalId, "rid-123")
        XCTAssertNil(NotificationService.decodeClarifyReplyAction(from: [
            "hermes": ["session_id": "runtime-sid"],
        ]))
        XCTAssertNil(NotificationService.decodeClarifyReplyAction(from: [
            "hermes": ["approval_id": "rid-123"],
        ]))
    }

    @MainActor
    func testHandleClarifyReplyActionRoutesTypedTextToReplyEndpoint() async throws {
        #if DEBUG
        let payload = NotificationService.ClarifyReplyActionPayload(
            sessionId: "runtime-sid",
            approvalId: "rid-123"
        )
        var captured: (endpoint: NotificationService.ActionEndpoint,
                       payload: NotificationService.ClarifyReplyActionPayload,
                       answer: String)?
        NotificationService.setActionEndpointProvider {
            NotificationService.ActionEndpoint(
                baseURL: URL(string: "http://127.0.0.1:8080")!,
                token: "token",
                pathStyle: .plugin
            )
        }
        NotificationService.clarifyReplySender = { endpoint, payload, answer in
            captured = (endpoint, payload, answer)
            return .resolved
        }
        defer {
            NotificationService.clarifyReplySender = nil
            NotificationService.endpointProvider = nil
        }

        await NotificationService.handleClarifyReplyAction(
            text: "  use api.py  ",
            action: payload
        )

        let sent = try XCTUnwrap(captured)
        XCTAssertEqual(sent.endpoint.baseURL.absoluteString, "http://127.0.0.1:8080")
        XCTAssertEqual(sent.endpoint.pathStyle, .plugin)
        XCTAssertEqual(sent.payload.sessionId, "runtime-sid")
        XCTAssertEqual(sent.payload.approvalId, "rid-123")
        XCTAssertEqual(sent.answer, "use api.py")
        #else
        throw XCTSkip("clarifyReplySender seam is DEBUG-only")
        #endif
    }
}
