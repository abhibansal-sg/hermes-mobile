import XCTest

/// End-to-end smoke test against a LIVE hermes gateway.
///
/// Requires the shared dashboard to be running and reachable, with
/// credentials provided via the test runner environment:
///   TEST_RUNNER_HERMES_URL / TEST_RUNNER_HERMES_TOKEN on the xcodebuild
///   invocation (surfaced here as HERMES_URL / HERMES_TOKEN).
/// Skips (rather than fails) when credentials are absent so the suite
/// stays green in CI without a backend.
final class ChatFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testNewSessionStreamingTurn() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_URL/HERMES_TOKEN not provided; skipping live test")
        }

        let app = XCUIApplication()
        app.launchEnvironment["HERMES_URL"] = url
        app.launchEnvironment["HERMES_TOKEN"] = token
        app.launch()

        // 1. Chat is home (Batch B drawer navigation): on a successful connect the
        //    app lands directly on a fresh draft chat — no "New session" list step.
        //    The drawer toggle in the chat nav bar proves the connected chat shell
        //    rendered; the composer is then immediately available.
        let drawerToggle = app.buttons["drawerToggle"]
        XCTAssertTrue(
            drawerToggle.waitForExistence(timeout: 30),
            "Connected chat shell (draft home) did not appear"
        )

        // 2. The draft chat's composer is present from launch. Target it by its
        //    placeholder ("Message Hermes…") rather than `firstMatch`: with the
        //    F1 push-card drawer the drawer's "Search" TextField also lives in the
        //    tree (beneath the chat card), and a bare `firstMatch` would type into
        //    it instead of the composer. A vertical-axis SwiftUI TextField is
        //    exposed as either a textField or a textView, so we accept both.
        let composerPlaceholder = "Message Hermes…"
        let composerField = app.textFields[composerPlaceholder]
        let composerTextView = app.textViews[composerPlaceholder]
        XCTAssertTrue(
            composerField.waitForExistence(timeout: 20)
                || composerTextView.waitForExistence(timeout: 5),
            "Composer did not appear on the draft chat"
        )
        let composer = composerField.exists ? composerField : composerTextView
        composer.tap()
        // The expected answer must NOT appear in the prompt text, otherwise
        // the assertion below could match the user's own bubble.
        composer.typeText("What is the capital of France? Reply with just the city name.")

        // 3. Send.
        let send = app.buttons["Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 10), "Send button missing")
        send.tap()

        // 4. The streamed assistant reply lands in the transcript.
        let reply = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Paris")
        ).firstMatch
        XCTAssertTrue(
            reply.waitForExistence(timeout: 150),
            "Streamed assistant reply did not appear"
        )

        // 5. Streaming finished: the composer returns to its idle state. With the
        //    UI-C mic-in-field morph, an empty field after send shows the mic
        //    ("Dictate message"), not "Send". Wait for the idle mic to come back
        //    as the completion signal.
        let idleMic = app.buttons["Dictate message"]
        XCTAssertTrue(
            idleMic.waitForExistence(timeout: 60),
            "Composer did not return to idle state after the turn"
        )
        // The stop affordance is gone once the turn completes. After H4 the
        // single stop affordance is the composer's morph button ("Interrupt"),
        // which only exists while streaming; the turn activity bar no longer
        // carries its own "Stop turn" button at all (single-stop-affordance
        // principle). Neither label should be present at idle.
        XCTAssertFalse(
            app.buttons["Interrupt"].exists,
            "Composer interrupt affordance still present after the turn completed"
        )
        XCTAssertFalse(
            app.buttons["Stop turn"].exists,
            "The removed turn-activity-bar Stop button reappeared"
        )

        // 6. Composer model chip (F3 / Amendment E): once connected to a live
        //    gateway the running model resolves (ConnectionStore.refreshActiveModel),
        //    so the relocated chip renders in the composer's Row 2 with its
        //    `composerModelChip` id. The chip is gated on a non-nil model — its
        //    presence here is the non-nil-model assertion the contract requires.
        let modelChip = app.buttons["composerModelChip"]
        XCTAssertTrue(
            modelChip.waitForExistence(timeout: 30),
            "Composer model chip did not render against a live gateway with a resolved model"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "chat-after-turn"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Settings reachability (F1+F2 / Amendment C+E): the footer gear is gone;
    /// Settings is reached only via the drawer header avatar (`settingsAvatar`).
    /// Open the drawer, tap the avatar, and confirm the Settings sheet appears
    /// (its X-close pill carries `settingsClose`) — proving Settings is never
    /// unreachable after the gear removal.
    func testSettingsReachableViaDrawerAvatar() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_URL/HERMES_TOKEN not provided; skipping live test")
        }

        let app = XCUIApplication()
        app.launchEnvironment["HERMES_URL"] = url
        app.launchEnvironment["HERMES_TOKEN"] = token
        app.launch()

        let drawerToggle = app.buttons["drawerToggle"]
        XCTAssertTrue(
            drawerToggle.waitForExistence(timeout: 30),
            "Connected chat shell (draft home) did not appear"
        )
        drawerToggle.tap()

        // The avatar lives in the DrawerView, which (push-card model, F1) sits
        // BENEATH the chat card and is in the a11y tree even before the open
        // spring settles. Wait for it to become hittable — not merely exist — so
        // the tap lands on the avatar and not the still-displaced chat card's
        // tap-to-close overlay. Retry the tap once if the first attempt didn't
        // present the sheet (a tap during the open animation can be swallowed).
        let avatar = app.buttons["settingsAvatar"]
        XCTAssertTrue(
            avatar.waitForExistence(timeout: 15),
            "Drawer header avatar (Settings entry) missing"
        )
        let close = app.buttons["settingsClose"]
        for _ in 0..<3 where !close.exists {
            let settled = expectation(description: "avatar hittable")
            let probe = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { timer in
                if avatar.isHittable { timer.invalidate(); settled.fulfill() }
            }
            _ = XCTWaiter().wait(for: [settled], timeout: 6)
            probe.invalidate()
            if avatar.isHittable {
                avatar.tap()
            } else if drawerToggle.isHittable {
                // Drawer slipped closed; re-open before retrying.
                drawerToggle.tap()
            }
            _ = close.waitForExistence(timeout: 4)
        }
        XCTAssertTrue(
            close.waitForExistence(timeout: 10),
            "Settings sheet did not present from the drawer avatar"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "settings-via-avatar"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// BUG 1 (hotfix): the Settings Appearance row is a real full-width tap
    /// target. Open Settings via the avatar, tap the Appearance row
    /// (`settingsAppearanceRow`), and confirm the theme picker pushed in (its
    /// dark-only footer is a stable, unique marker that only the picker shows).
    func testSettingsAppearanceRowOpensThemePicker() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_URL/HERMES_TOKEN not provided; skipping live test")
        }

        let app = XCUIApplication()
        app.launchEnvironment["HERMES_URL"] = url
        app.launchEnvironment["HERMES_TOKEN"] = token
        app.launch()

        let drawerToggle = app.buttons["drawerToggle"]
        XCTAssertTrue(
            drawerToggle.waitForExistence(timeout: 30),
            "Connected chat shell (draft home) did not appear"
        )
        drawerToggle.tap()

        // Open Settings from the drawer avatar (same robust path as the
        // reachability test: wait for hittable, retry across the open spring).
        let avatar = app.buttons["settingsAvatar"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 15), "Drawer avatar missing")
        let close = app.buttons["settingsClose"]
        for _ in 0..<3 where !close.exists {
            let settled = expectation(description: "avatar hittable")
            let probe = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { timer in
                if avatar.isHittable { timer.invalidate(); settled.fulfill() }
            }
            _ = XCTWaiter().wait(for: [settled], timeout: 6)
            probe.invalidate()
            if avatar.isHittable {
                avatar.tap()
            } else if drawerToggle.isHittable {
                drawerToggle.tap()
            }
            _ = close.waitForExistence(timeout: 4)
        }
        XCTAssertTrue(
            close.waitForExistence(timeout: 10),
            "Settings sheet did not present from the drawer avatar"
        )

        // Tap the Appearance row — the regression target. It must be hittable
        // (full-width Button, ≥44pt) and actually push the picker.
        let appearanceRow = app.buttons["settingsAppearanceRow"]
        XCTAssertTrue(
            appearanceRow.waitForExistence(timeout: 10),
            "Appearance row (settingsAppearanceRow) missing"
        )
        XCTAssertTrue(appearanceRow.isHittable, "Appearance row is not hittable")
        appearanceRow.tap()

        // The theme picker is identified by its dark-only footer, which appears
        // ONLY on the Appearance picker (not on the settings list it pushed from).
        let pickerFooter = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "dark-only")
        ).firstMatch
        XCTAssertTrue(
            pickerFooter.waitForExistence(timeout: 10),
            "Theme picker did not appear after tapping the Appearance row"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "appearance-picker"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// BUG 2 (hotfix): the open-drawer swipe works from mid-screen with
    /// horizontal-dominance activation (the open-start zone now spans the leading
    /// 50% of the width). Drive a horizontal XCUICoordinate drag starting at
    /// mid-screen-left and assert the drawer reveals (its header avatar becomes
    /// hittable). Proves the widened zone + dominance gating opens the drawer
    /// without relying on the hamburger button.
    func testDrawerOpensViaMidScreenSwipe() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_URL/HERMES_TOKEN not provided; skipping live test")
        }

        let app = XCUIApplication()
        app.launchEnvironment["HERMES_URL"] = url
        app.launchEnvironment["HERMES_TOKEN"] = token
        app.launch()

        let drawerToggle = app.buttons["drawerToggle"]
        XCTAssertTrue(
            drawerToggle.waitForExistence(timeout: 30),
            "Connected chat shell (draft home) did not appear"
        )

        let avatar = app.buttons["settingsAvatar"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 15), "Drawer avatar missing")
        // Closed state: the drawer is behind the full-width chat card, so its
        // avatar should not be hittable yet.
        XCTAssertFalse(avatar.isHittable, "Drawer avatar should be covered while closed")

        // A predominantly-horizontal drag from ~15% width at vertical mid-height,
        // rightward across the screen — well inside the new leading-50% open zone
        // and clearly horizontal so dominance latches.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        // A couple of attempts: a single press-drag-hold-release with a brief
        // hold lets the interactive spring settle open before release commits.
        var opened = false
        for _ in 0..<3 {
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0.1)
            if avatar.waitForExistence(timeout: 2), avatar.isHittable { opened = true; break }
        }
        XCTAssertTrue(
            opened,
            "Drawer did not open via a mid-screen horizontal swipe"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "drawer-swipe-open"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// BUG 3 + BUG 4 (hotfix): the drawer's "New chat" capsule hugs the bottom
    /// safe area (low), and a bottom fade scrim sits between the scrolled recents
    /// and the capsule so rows dissolve beneath it. Open the drawer, scroll the
    /// recents up so rows pass under the low capsule, then capture proof. The
    /// capsule (`drawerNewChat`) must exist and sit in the lower region of the
    /// drawer (BUG 3); the screenshot proves the fade-under (BUG 4).
    func testDrawerCapsuleLowWithBottomFade() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_URL/HERMES_TOKEN not provided; skipping live test")
        }

        let app = XCUIApplication()
        app.launchEnvironment["HERMES_URL"] = url
        app.launchEnvironment["HERMES_TOKEN"] = token
        app.launch()

        let drawerToggle = app.buttons["drawerToggle"]
        XCTAssertTrue(
            drawerToggle.waitForExistence(timeout: 30),
            "Connected chat shell (draft home) did not appear"
        )
        drawerToggle.tap()

        // The floating New-chat capsule must be present.
        let capsule = app.buttons["drawerNewChat"]
        XCTAssertTrue(
            capsule.waitForExistence(timeout: 15),
            "Drawer New-chat capsule (drawerNewChat) missing"
        )
        // BUG 3: it hugs the bottom — its frame should sit well below the vertical
        // midpoint of the window.
        let window = app.windows.firstMatch
        XCTAssertTrue(
            capsule.frame.midY > window.frame.height * 0.7,
            "New-chat capsule should hug the bottom (low), not float high"
        )

        // Scroll the recents up so rows pass UNDER the low capsule (BUG 4 fade).
        // Drag within the drawer band (leading ~40% of the width) upward.
        let dragStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.7))
        let dragEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.35))
        for _ in 0..<2 {
            dragStart.press(forDuration: 0.05, thenDragTo: dragEnd)
        }

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "drawer-fade"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
