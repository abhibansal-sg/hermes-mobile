import XCTest
import UIKit
@testable import HermesMobile

@MainActor
final class AppDelegateBackgroundTransferTests: XCTestCase {
    func testUnknownSessionCompletesImmediately() {
        let delegate = AppDelegate()
        var calls = 0
        delegate.application(UIApplication.shared,
                             handleEventsForBackgroundURLSession: "not-hermes") { calls += 1 }
        XCTAssertEqual(calls, 1)
    }

    func testKnownSessionCompletionIsConsumedOnce() async {
        let delegate = AppDelegate()
        var calls = 0
        delegate.application(
            UIApplication.shared,
            handleEventsForBackgroundURLSession: TransferManager.backgroundSessionIdentifier
        ) { calls += 1 }
        TransferManager.shared.urlSessionDidFinishEvents(forBackgroundURLSession: TransferManager.shared.session)
        try? await Task.sleep(for: .milliseconds(100))
        TransferManager.shared.urlSessionDidFinishEvents(forBackgroundURLSession: TransferManager.shared.session)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(calls, 1)
    }
}
