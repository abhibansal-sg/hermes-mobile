import XCTest

/// STR-136 evidence capture: iPad/iPhone connection-state truthfulness.
///
/// Finding A — a stale error toast must not resurrect on a `ChatView` remount
/// (the trigger the bug reports is an iPad Split View / Stage Manager / Slide
/// Over resize; the seed reproduces the same `onAppear` code path by flipping
/// `activeStoredId` off then back on, which XCUITest can drive deterministically
/// where an OS-level window resize cannot be).
///
/// Finding B — the offline/reconnecting banner must be visible even when no
/// session/draft is selected (the empty-detail placeholder), not just inside
/// the active chat branch.
final class ConnectionTruthfulnessUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testStaleErrorToastDoesNotResurrectOnRemount() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_UITEST_SEED"] = "toast-stale-resurrect"
        app.launchArguments += ["--uitest-mute-audio"]
        app.launch()

        // `newChatButton` renders on BOTH widths unconditionally (ChatView's
        // toolbar comment: "used on BOTH widths"); `drawerToggle` is iPad-split-
        // view-only (hidden when the sidebar supplies its own navigation), so it
        // can't be used as a cross-device "shell appeared" signal.
        let shellReady = app.buttons["newChatButton"]
        XCTAssertTrue(
            shellReady.waitForExistence(timeout: 20),
            "Seeded connected shell did not appear"
        )

        let toast = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Seeded failure for STR-136")
        ).firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 5), "Seeded error toast did not present")

        let seededShot = XCTAttachment(screenshot: app.screenshot())
        seededShot.name = "toast-stale-resurrect-seeded"
        seededShot.lifetime = .keepAlways
        add(seededShot)

        // Auto-dismiss fires at 4s; give it margin, then confirm it's gone.
        let toastGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: toast
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [toastGone], timeout: 6),
            .completed,
            "Toast never auto-dismissed"
        )

        let dismissedShot = XCTAttachment(screenshot: app.screenshot())
        dismissedShot.name = "toast-stale-resurrect-dismissed"
        dismissedShot.lifetime = .keepAlways
        add(dismissedShot)

        // The seed unmounts + remounts ChatView ~0.3-0.8s after the dismiss
        // window closes. Give the remount time to land, then assert the toast
        // stayed gone — pre-fix, `chatStore.lastError` survived the dismiss and
        // the remount's `onAppear` resurrected it here.
        let staysGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: toast
        )
        Thread.sleep(forTimeInterval: 1.5)  // let the seeded remount complete
        XCTAssertEqual(
            XCTWaiter().wait(for: [staysGone], timeout: 3),
            .completed,
            "Stale error toast resurrected after ChatView remount (STR-136 Finding A regression)"
        )

        let afterRemountShot = XCTAttachment(screenshot: app.screenshot())
        afterRemountShot.name = "toast-stale-resurrect-after-remount"
        afterRemountShot.lifetime = .keepAlways
        add(afterRemountShot)
    }

    func testOfflineBannerVisibleWithNoSessionSelected() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_UITEST_SEED"] = "offline-no-session"
        app.launchArguments += ["--uitest-mute-audio"]
        app.launch()

        let placeholder = app.staticTexts["Start a chat"]
        let compactPlaceholder = app.staticTexts["No conversation"]
        XCTAssertTrue(
            placeholder.waitForExistence(timeout: 20) || compactPlaceholder.waitForExistence(timeout: 5),
            "Empty-detail placeholder did not appear"
        )

        let connectedShot = XCTAttachment(screenshot: app.screenshot())
        connectedShot.name = "offline-no-session-before-outage"
        connectedShot.lifetime = .keepAlways
        add(connectedShot)

        let offlineBanner = app.staticTexts["Offline"]
        XCTAssertTrue(
            offlineBanner.waitForExistence(timeout: 5),
            "Offline banner did not appear with no session selected (STR-136 Finding B regression)"
        )

        let offlineShot = XCTAttachment(screenshot: app.screenshot())
        offlineShot.name = "offline-no-session-outage"
        offlineShot.lifetime = .keepAlways
        add(offlineShot)
    }
}
