import Foundation
import XCTest
@testable import HermesMobile

@MainActor
final class LiveActivityManagerTests: XCTestCase {

    func testContentRefreshesReuseStartDateWhileElapsedFallbackAdvances() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000.25)
        let first = LiveActivityManager.makeContentState(
            phase: "Thinking",
            toolName: nil,
            needsApproval: false,
            startedAt: startedAt,
            now: startedAt.addingTimeInterval(4)
        )
        let later = LiveActivityManager.makeContentState(
            phase: "Running terminal",
            toolName: "terminal",
            needsApproval: false,
            startedAt: startedAt,
            now: startedAt.addingTimeInterval(19)
        )

        XCTAssertEqual(first.startedAt, startedAt)
        XCTAssertEqual(later.startedAt, startedAt)
        XCTAssertEqual(first.elapsedSeconds, 4)
        XCTAssertEqual(later.elapsedSeconds, 19)
    }

    func testLiveActivityStaleBudgetRemainsLongerThanRoutinePushFloor() {
        XCTAssertEqual(LiveActivityManager.staleAfter, 5 * 60)
        XCTAssertGreaterThan(LiveActivityManager.staleAfter, 3)
    }
}
