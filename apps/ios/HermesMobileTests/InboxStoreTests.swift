import XCTest
@testable import HermesMobile

@MainActor
final class InboxStoreTests: XCTestCase {
    private func event(_ type: String, session: String, id: String = "approval-1") -> GatewayEvent {
        GatewayEvent(params: .object([
            "type": .string(type), "session_id": .string(session),
            "payload": .object(["id": .string(id), "title": .string("Approve")]),
        ]))!
    }

    func testMessageCompletionExpiresVisibleFailedOrPendingRows() {
        let inbox = InboxStore()
        inbox.handle(event: event("approval.request", session: "runtime"))
        XCTAssertEqual(inbox.pendingCount, 1)
        inbox.handle(event: event("message.complete", session: "runtime"))
        XCTAssertEqual(inbox.pendingCount, 0)
        XCTAssertEqual(inbox.items.first?.state, .expired)
    }

    func testExplicitDismissRemainsAnIntentionalLocalAction() {
        let inbox = InboxStore()
        inbox.handle(event: event("approval.request", session: "runtime"))
        inbox.dismiss(inbox.items[0])
        XCTAssertTrue(inbox.items.isEmpty)
    }
}
