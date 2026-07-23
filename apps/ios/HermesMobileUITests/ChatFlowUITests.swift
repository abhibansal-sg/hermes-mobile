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
        if let relayURL = env["HERMES_RELAY_URL"], !relayURL.isEmpty {
            app.launchEnvironment["HERMES_RELAY_URL"] = relayURL
        }
        app.launchArguments += ["--uitest-mute-audio"]
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

        // 2. A physical device preserves per-session drafts between launches,
        //    so the placeholder is not a stable query. Use the field's identity.
        let composerField = app.textFields["composerInput"]
        let composerTextView = app.textViews["composerInput"]
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
        let reply = app.textViews.matching(
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
        app.launchArguments += ["--uitest-mute-audio"]
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

    /// ABH-519 / I12 physical regression: a stock clarify request belongs to
    /// its STORED session across a cache/reset navigation, while its runtime id
    /// remains the response target. This is deliberately one narrow workflow,
    /// matching the device failure instead of replaying the full UI suite.
    func testClarificationStaysWithOwningSessionAcrossSwitch() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_URL/HERMES_TOKEN not provided; skipping live test")
        }

        let app = XCUIApplication()
        app.launchEnvironment["HERMES_URL"] = url
        app.launchEnvironment["HERMES_TOKEN"] = token
        if let relayURL = env["HERMES_RELAY_URL"], !relayURL.isEmpty {
            app.launchEnvironment["HERMES_RELAY_URL"] = relayURL
        }
        app.launchArguments += ["--uitest-mute-audio"]
        app.launch()

        let drawerToggle = app.buttons["drawerToggle"]
        XCTAssertTrue(drawerToggle.waitForExistence(timeout: 30))
        drawerToggle.tap()
        let initialNewChat = app.buttons["drawerNewChat"]
        XCTAssertTrue(initialNewChat.waitForExistence(timeout: 15))
        initialNewChat.tap()
        let field = app.textFields["composerInput"]
        let textView = app.textViews["composerInput"]
        XCTAssertTrue(field.waitForExistence(timeout: 20) || textView.waitForExistence(timeout: 5))
        let composer = field.exists ? field : textView
        composer.tap()
        composer.typeText(
            "ABH519 physical owner check. Use the clarify tool now to ask exactly "
                + "'ABH519 owner check?' with choices Left and Right. After I answer, reply "
                + "with exactly 'ABH519 owner answered'."
        )
        app.buttons["Send"].tap()

        let clarifyCard = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Clarification request")
        ).firstMatch
        XCTAssertTrue(
            clarifyCard.waitForExistence(timeout: 180),
            "The owning session never rendered its clarification card"
        )

        drawerToggle.tap()
        let newChat = app.buttons["drawerNewChat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 15))
        newChat.tap()
        XCTAssertFalse(
            clarifyCard.waitForExistence(timeout: 3),
            "Session A's clarification rendered inline on the draft/B surface"
        )

        drawerToggle.tap()
        let newestSession = app.buttons["sessionRow"].firstMatch
        XCTAssertTrue(newestSession.waitForExistence(timeout: 20))
        newestSession.tap()
        XCTAssertTrue(
            clarifyCard.waitForExistence(timeout: 20),
            "The clarification did not return when its owning session reopened"
        )

        let answer = app.buttons["Left"]
        XCTAssertTrue(answer.waitForExistence(timeout: 10))
        answer.tap()
        XCTAssertFalse(
            clarifyCard.waitForExistence(timeout: 20),
            "The answered clarification card did not clear"
        )
        XCTAssertTrue(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@", "ABH519 owner answered")
            ).firstMatch.waitForExistence(timeout: 180),
            "The clarification answer did not resume and complete the owning turn"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "abh519-clarification-owner-restored"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testApprovalPushOpensOwningGateAndResumesTurn() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_URL/HERMES_TOKEN not provided; skipping live test")
        }

        let app = XCUIApplication()
        app.launchEnvironment["HERMES_URL"] = url
        app.launchEnvironment["HERMES_TOKEN"] = token
        app.launchEnvironment["HERMES_TRANSPORT"] = "gatewayDirect"
        app.launchArguments += ["-hermes.transportPath", "gatewayDirect"]
        app.launchArguments += ["-hermes.connectionMode", "remoteURL"]
        app.launchArguments += ["--uitest-mute-audio"]
        app.launch()

        let drawerToggle = app.buttons["drawerToggle"]
        XCTAssertTrue(drawerToggle.waitForExistence(timeout: 30))
        drawerToggle.tap()
        let newChat = app.buttons["drawerNewChat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 15))
        newChat.tap()

        let field = app.textFields["composerInput"]
        let textView = app.textViews["composerInput"]
        XCTAssertTrue(field.waitForExistence(timeout: 20) || textView.waitForExistence(timeout: 5))
        let composer = field.exists ? field : textView
        composer.tap()
        composer.typeText(
            "Use the terminal exactly once to run: rm -f /private/tmp/abh519-approval-gate-physical. "
                + "After it succeeds, reply with the uppercase form of 'abh519 approval resumed' "
                + "and nothing else."
        )
        app.buttons["Send"].tap()
        XCTAssertTrue(app.buttons["Interrupt"].waitForExistence(timeout: 30))

        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let notification = springboard.buttons.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "approval")
        ).firstMatch
        if !notification.waitForExistence(timeout: 15) {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
                .press(
                    forDuration: 0.1,
                    thenDragTo: springboard.coordinate(
                        withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)
                    )
                )
            let focusGroup = springboard.buttons.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "While in Do Not Disturb, Hermes Agent")
            ).firstMatch
            if focusGroup.waitForExistence(timeout: 5) {
                focusGroup.tap()
            }
        }
        XCTAssertTrue(notification.waitForExistence(timeout: 20), "stock approval hook sent no push")
        notification.tap()
        app.activate()

        let approvalCard = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Tool approval request:")
        ).firstMatch
        XCTAssertTrue(approvalCard.waitForExistence(timeout: 30), "approval push opened no gate")
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", "abh519-approval-gate-physical")
            ).firstMatch.waitForExistence(timeout: 10),
            "approval push opened a foreign gate"
        )
        app.buttons["Approve"].tap()
        XCTAssertTrue(approvalCard.waitForNonExistence(timeout: 30), "approved gate did not clear")
        XCTAssertTrue(
            app.textViews.containing(
                NSPredicate(format: "label CONTAINS %@", "ABH519 APPROVAL RESUMED")
            ).firstMatch.waitForExistence(timeout: 180),
            "approval response did not resume the blocked turn"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "stock-approval-push-opened-owning-gate"
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
        app.launchArguments += ["--uitest-mute-audio"]
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

    func testProjectsTabLoadsAndNewProjectSheetOpens() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_URL/HERMES_TOKEN not provided; skipping live test")
        }

        let app = XCUIApplication()
        app.launchEnvironment["HERMES_URL"] = url
        app.launchEnvironment["HERMES_TOKEN"] = token
        if let relayURL = env["HERMES_RELAY_URL"], !relayURL.isEmpty {
            app.launchEnvironment["HERMES_RELAY_URL"] = relayURL
        }
        app.launchArguments += ["--uitest-mute-audio"]
        app.launch()

        let drawerToggle = app.buttons["drawerToggle"]
        XCTAssertTrue(drawerToggle.waitForExistence(timeout: 30))
        drawerToggle.tap()

        let tabs = app.segmentedControls["drawerTabToggle"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 15), "Drawer section control missing")
        tabs.buttons["Projects"].tap()

        let projectRow = app.buttons["projectRow"].firstMatch
        let emptyState = app.staticTexts["No projects found"]
        XCTAssertTrue(
            projectRow.waitForExistence(timeout: 15) || emptyState.waitForExistence(timeout: 5),
            "Projects route produced neither content nor its honest empty state"
        )
        XCTAssertFalse(app.staticTexts["Couldn't load projects"].exists)

        let newProject = app.buttons["drawerNewProject"]
        XCTAssertTrue(newProject.waitForExistence(timeout: 10))
        newProject.tap()
        XCTAssertTrue(app.textFields["newProjectName"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["newProjectRoot"].exists)
        app.buttons["newProjectCancel"].tap()
    }

    func testWorkingDirectoryAndFileBrowserRoundTrip() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_URL/HERMES_TOKEN not provided; skipping live test")
        }

        let app = XCUIApplication()
        app.launchEnvironment["HERMES_URL"] = url
        app.launchEnvironment["HERMES_TOKEN"] = token
        if let relayURL = env["HERMES_RELAY_URL"], !relayURL.isEmpty {
            app.launchEnvironment["HERMES_RELAY_URL"] = relayURL
        }
        app.launchArguments += ["--uitest-mute-audio"]
        app.launch()

        let drawerToggle = app.buttons["drawerToggle"]
        XCTAssertTrue(drawerToggle.waitForExistence(timeout: 30))
        drawerToggle.tap()
        let session = app.buttons["sessionRow"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 20))
        session.tap()

        let overflow = app.buttons["chatOverflowMenu"]
        XCTAssertTrue(overflow.waitForExistence(timeout: 20))
        overflow.tap()
        let workingDirectory = app.buttons["workingDirMenuItem"]
        XCTAssertTrue(workingDirectory.waitForExistence(timeout: 15))
        workingDirectory.tap()

        let useRoot = app.buttons["fileBrowserUseFolder"]
        XCTAssertTrue(useRoot.waitForExistence(timeout: 20))
        useRoot.tap()
        let cwdConfirmation = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Working directory set to")
        ).firstMatch
        XCTAssertTrue(cwdConfirmation.waitForExistence(timeout: 20))

        let attach = app.buttons["composerAttachButton"]
        XCTAssertTrue(attach.waitForExistence(timeout: 10))
        attach.tap()
        let browse = app.buttons["composerBrowseFiles"]
        XCTAssertTrue(browse.waitForExistence(timeout: 10))
        browse.tap()
        XCTAssertTrue(app.navigationBars["Files"].waitForExistence(timeout: 20))
        app.navigationBars["Files"].buttons["Done"].firstMatch.tap()
        XCTAssertTrue(
            app.textFields["composerInput"].waitForExistence(timeout: 10)
                || app.textViews["composerInput"].waitForExistence(timeout: 3)
        )
    }

    func testSessionModelPickerAndYoloToggleRoundTrip() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_URL/HERMES_TOKEN not provided; skipping live test")
        }

        let app = XCUIApplication()
        app.launchEnvironment["HERMES_URL"] = url
        app.launchEnvironment["HERMES_TOKEN"] = token
        if let relayURL = env["HERMES_RELAY_URL"], !relayURL.isEmpty {
            app.launchEnvironment["HERMES_RELAY_URL"] = relayURL
        }
        app.launchArguments += ["--uitest-mute-audio"]
        app.launch()

        let drawerToggle = app.buttons["drawerToggle"]
        XCTAssertTrue(drawerToggle.waitForExistence(timeout: 30))
        drawerToggle.tap()
        let session = app.buttons["sessionRow"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 20))
        session.tap()

        let yolo = app.buttons["composerYoloToggle"]
        XCTAssertTrue(yolo.waitForExistence(timeout: 10))
        XCTAssertTrue(yolo.isHittable)
        let initial = yolo.value as? String
        XCTAssertTrue(initial == "On" || initial == "Off")
        yolo.tap()
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@ AND value != %@", initial ?? "", "Updating"),
            object: yolo
        )
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 15), .completed)
        yolo.tap()
        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", initial ?? ""),
            object: yolo
        )
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 15), .completed)

        let model = app.buttons["composerModelChip"]
        XCTAssertTrue(model.waitForExistence(timeout: 20))
        model.tap()
        let modelSheet = app.navigationBars["This Chat"]
        XCTAssertTrue(modelSheet.waitForExistence(timeout: 15))
        XCTAssertTrue(app.searchFields["Filter models"].waitForExistence(timeout: 20))
        modelSheet.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(modelSheet.waitForNonExistence(timeout: 10))
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
        app.launchArguments += ["--uitest-mute-audio"]
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
        app.launchArguments += ["--uitest-mute-audio"]
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
