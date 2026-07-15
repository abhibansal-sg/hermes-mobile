import XCTest
import UIKit
@testable import HermesMobile

final class SilentSyncPushTests: XCTestCase {
    func testDecodesFrozenEnvelope() {
        let decoded = SilentSyncInvalidation.decode([
            "aps": ["content-available": 1],
            "sync": ["scope": "profile:work", "revision": 42, "reason": "attention"],
        ])
        XCTAssertEqual(decoded, .init(scope: "profile:work", revision: 42, reason: .attention))
    }

    func testRejectsMalformedAndNonSyncNotifications() {
        XCTAssertNil(SilentSyncInvalidation.decode(["aps": ["content-available": 1]]))
        XCTAssertNil(SilentSyncInvalidation.decode([
            "aps": ["content-available": 1, "alert": "no"],
            "sync": ["scope": "all", "revision": 1, "reason": "sessions"],
        ]))
        XCTAssertNil(SilentSyncInvalidation.decode([
            "aps": ["content-available": 1],
            "sync": ["scope": "all", "revision": 1, "reason": "unknown"],
        ]))
    }

    func testDuplicateAndOlderRevisionDoNotPublish() async {
        let calls = CallCounter()
        let coordinator = ManifestInvalidationCoordinator { _ in
            await calls.increment()
            return true
        }
        let newest = SilentSyncInvalidation(scope: "all", revision: 9, reason: .sessions)
        let first = await coordinator.synchronize(for: newest)
        let duplicate = await coordinator.synchronize(for: newest)
        let older = await coordinator.synchronize(for: .init(scope: "all", revision: 8, reason: .widget))
        let count = await calls.value
        XCTAssertEqual(first, .newData)
        XCTAssertEqual(duplicate, .noData)
        XCTAssertEqual(older, .noData)
        XCTAssertEqual(count, 1)
    }

    func testColdLaunchWaitsForAttachment() async {
        let bridge = SilentSyncBridge()
        let invalidation = SilentSyncInvalidation(scope: "all", revision: 2, reason: .coalesced)
        let delivery = Task { await bridge.handle(invalidation) }
        await Task.yield()
        let coordinator = ManifestInvalidationCoordinator { _ in true }
        await bridge.attach(coordinator)
        let result = await delivery.value
        XCTAssertEqual(result, .newData)
    }

    func testCancellationAndFailureReturnFailed() async {
        let failing = ManifestInvalidationCoordinator { _ in throw TestError.expected }
        let failure = await failing.synchronize(for: .init(scope: "all", revision: 1, reason: .sessions))
        XCTAssertEqual(failure, .failed)

        let cancelled = ManifestInvalidationCoordinator { _ in try Task.checkCancellation(); return true }
        let task = Task { await cancelled.synchronize(for: .init(scope: "all", revision: 1, reason: .sessions)) }
        task.cancel()
        let cancellation = await task.value
        XCTAssertEqual(cancellation, .failed)
    }

    func testWidgetProjectionOperationFinishesBeforeSuccess() async {
        let ordering = OrderingRecorder()
        let coordinator = ManifestInvalidationCoordinator { _ in
            await ordering.record("commit")
            await ordering.record("widget")
            return true
        }
        let result = await coordinator.synchronize(for: .init(scope: "all", revision: 3, reason: .widget))
        await ordering.record("completion")
        XCTAssertEqual(result, .newData)
        let events = await ordering.events
        XCTAssertEqual(events, ["commit", "widget", "completion"])
    }

    func testBackgroundCompletionCallsUIKitExactlyOnce() {
        var results: [UIBackgroundFetchResult] = []
        let completion = BackgroundFetchCompletion { results.append($0) }
        completion.call(.newData)
        completion.call(.failed)
        XCTAssertEqual(results, [.newData])
    }
}

private actor CallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor OrderingRecorder {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

private enum TestError: Error { case expected }
