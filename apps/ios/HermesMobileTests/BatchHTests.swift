import XCTest
@testable import HermesMobile

/// ABH-53 (R1 Batch H) — the store/helper-level slices of the navigation +
/// affordances batch. Most of Batch H is view wiring (verified by build +
/// manual paths); these pin the newly-wired store affordances and the
/// clock-skew clamp.
///
/// Ledger coverage here: #78 (relative-date clamp), #94 (inbox dismiss /
/// clear-expired, previously dead code now reachable from InboxView).
@MainActor
final class BatchHTests: XCTestCase {

    private func frame(
        type: String,
        runtime: String,
        payload: JSONValue = .null
    ) -> GatewayEvent {
        GatewayEvent(params: .object([
            "type": .string(type),
            "session_id": .string(runtime),
            "payload": payload,
        ]))!
    }

    // MARK: - #78: server-clock skew must never render a future "last seen"

    func testRelativeDateClampsFutureTimestamps() {
        let now = Date().timeIntervalSince1970
        // A server clock 5 minutes ahead must render exactly like "just now"
        // (clamped), not "in 5 min".
        let skewed = DevicesView.relativeDate(now + 300)
        let justNow = DevicesView.relativeDate(now)
        XCTAssertEqual(skewed, justNow,
                       "future timestamps clamp to the same render as now")
        XCTAssertEqual(DevicesView.relativeDate(0), "—")
    }

    // MARK: - #94: dismiss / clearExpired are live store affordances

    func testInboxDismissRemovesStuckPendingItem() {
        let inbox = InboxStore()
        inbox.handle(event: frame(
            type: "approval.request", runtime: "rt-x",
            payload: .object(["id": .string("ap-1"), "title": .string("Run")])
        ))
        XCTAssertEqual(inbox.pendingItems.count, 1)

        inbox.dismiss(inbox.pendingItems[0])

        XCTAssertTrue(inbox.pendingItems.isEmpty)
        XCTAssertTrue(inbox.items.isEmpty, "dismiss drops the row entirely")
    }

    func testInboxClearExpiredDropsOnlyExpiredItems() {
        let inbox = InboxStore()
        // One approval that will expire (its session completes)…
        inbox.handle(event: frame(
            type: "approval.request", runtime: "rt-done",
            payload: .object(["id": .string("ap-old"), "title": .string("Old")])
        ))
        inbox.handle(event: frame(type: "message.complete", runtime: "rt-done"))
        // …and one still genuinely pending on another session.
        inbox.handle(event: frame(
            type: "approval.request", runtime: "rt-live",
            payload: .object(["id": .string("ap-live"), "title": .string("Live")])
        ))
        XCTAssertTrue(inbox.items.contains { $0.state == .expired })

        inbox.clearExpired()

        XCTAssertFalse(inbox.items.contains { $0.state == .expired })
        XCTAssertEqual(inbox.pendingItems.map(\.id), ["ap-live"],
                       "pending items survive the tidy-up")
    }
}
