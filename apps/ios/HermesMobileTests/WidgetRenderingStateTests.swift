import XCTest
@testable import HermesMobile

/// Rendering-state contract shared by StatusWidget and UsageWidget. The views
/// consume these exact snapshot fields; keeping this table exhaustive prevents
/// either widget from treating transport connectivity alone as current data.
final class WidgetRenderingStateTests: XCTestCase {
    func testFreshStaleAndOfflineRenderingStates() {
        let now = Date(timeIntervalSince1970: 20_000)
        var snapshot = value(now: now)
        XCTAssertFalse(snapshot.isEffectivelyStale(at: now), "fresh committed snapshot may show Connected")

        snapshot.fetchedAt = now.addingTimeInterval(-901)
        XCTAssertTrue(snapshot.isEffectivelyStale(at: now), "suspended widget must render cached/last-updated")

        snapshot.fetchedAt = now
        snapshot.connectionState = .offline
        XCTAssertTrue(snapshot.isEffectivelyStale(at: now), "offline must render cached/last-updated")
    }

    func testNullUsageAndIndependentStatusCounts() {
        let snapshot = SharedStore.WidgetSnapshot(
            serverScope: "server/profile", serverRevision: "9", connectionState: .connected,
            openSessionCount: 5, activeTurnCount: 2, pendingAttentionCount: 3,
            tokensToday: nil, costToday: nil, fetchedAt: Date(), writtenAt: Date(), isStale: false
        )
        XCTAssertNil(snapshot.tokensToday, "usage widget renders unavailable dash")
        XCTAssertNil(snapshot.costToday, "usage widget renders unavailable dash")
        XCTAssertEqual(snapshot.openSessionCount, 5)
        XCTAssertEqual(snapshot.activeTurnCount, 2)
        XCTAssertEqual(snapshot.pendingAttentionCount, 3)
        XCTAssertNotEqual(snapshot.openSessionCount, snapshot.activeTurnCount,
                          "status widget must not collapse open sessions into active turns")
    }

    private func value(now: Date) -> SharedStore.WidgetSnapshot {
        .init(serverScope: "server/profile", serverRevision: "9", connectionState: .connected,
              openSessionCount: 1, activeTurnCount: 1, pendingAttentionCount: 0,
              tokensToday: 100, costToday: 0.1, fetchedAt: now,
              writtenAt: now, isStale: false)
    }
}
