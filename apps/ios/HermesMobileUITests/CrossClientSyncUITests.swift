import XCTest

/// Gateway-backed cross-client acceptance: disk repaint, pagination, and push
/// routing. Stock does not fan another client's live frames into this socket.
final class CrossClientSyncUITests: XCTestCase {

    @MainActor
    func testExternallyDrivenSessionRepaintsAfterForceClose() throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              let marker = env["HERMES_LIVE_FOLLOW_MARKER"],
              !base.isEmpty, !token.isEmpty, !marker.isEmpty else {
            throw XCTSkip("live gateway credentials/marker not provided; skipping live test")
        }

        let app = XCUIApplication()
        app.launchEnvironment["HERMES_URL"] = base
        app.launchEnvironment["HERMES_TOKEN"] = token
        if let relayURL = env["HERMES_RELAY_URL"], !relayURL.isEmpty {
            app.launchEnvironment["HERMES_RELAY_URL"] = relayURL
        }
        app.launchArguments += ["-hermes.connectionOffline", "false"]
        app.launchArguments += ["-hermes.connectionMode", "remoteURL"]
        app.launchArguments += ["--uitest-mute-audio"]

        func openSeededSession() {
            app.launch()
            let drawerToggle = app.buttons["drawerToggle"]
            XCTAssertTrue(drawerToggle.waitForExistence(timeout: 30))
            dismissDeviceConnectionBannerIfPresent()
            drawerToggle.tap()
            let ownedSession = app.buttons.matching(identifier: "sessionRow")
                .matching(NSPredicate(format: "label BEGINSWITH %@", marker)).firstMatch
            XCTAssertTrue(ownedSession.waitForExistence(timeout: 20))
            ownedSession.tap()
        }

        let secondMarker = app.textViews.matching(
            NSPredicate(format: "label CONTAINS %@", marker + "-SECOND")
        ).firstMatch
        openSeededSession()
        XCTAssertTrue(secondMarker.waitForExistence(timeout: 30))

        app.terminate()
        openSeededSession()
        XCTAssertTrue(
            secondMarker.waitForExistence(timeout: 10),
            "Force-close/reopen did not repaint the stored transcript"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "stored-transcript-force-close-repaint"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testStockLoadEarlierPreservesActiveTurn() throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              let title = env["HERMES_PAGINATION_TITLE"],
              !base.isEmpty, !token.isEmpty, !title.isEmpty else {
            throw XCTSkip("live gateway credentials/pagination fixture not provided")
        }

        let app = XCUIApplication()
        app.launchEnvironment["HERMES_URL"] = base
        app.launchEnvironment["HERMES_TOKEN"] = token
        if let relayURL = env["HERMES_RELAY_URL"], !relayURL.isEmpty {
            app.launchEnvironment["HERMES_RELAY_URL"] = relayURL
        }
        app.launchEnvironment["HERMES_TRANSPORT"] = "gatewayDirect"
        app.launchArguments += ["-hermes.transportPath", "gatewayDirect"]
        app.launchArguments += ["-hermes.connectionMode", "remoteURL"]
        app.launchArguments += ["-hermes.connectionOffline", "false"]
        app.launchArguments += ["--uitest-mute-audio"]
        app.launch()

        let drawerToggle = app.buttons["drawerToggle"]
        XCTAssertTrue(drawerToggle.waitForExistence(timeout: 30))
        dismissDeviceConnectionBannerIfPresent()
        drawerToggle.tap()
        let row = app.buttons.matching(identifier: "sessionRow")
            .matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "seeded stock session missing")
        row.tap()

        XCTAssertTrue(app.textFields["Message Hermes…"].waitForExistence(timeout: 30)
            || app.textViews["Message Hermes…"].waitForExistence(timeout: 3))

        let field = app.textFields["Message Hermes…"]
        let textView = app.textViews["Message Hermes…"]
        let composer = field.exists ? field : textView
        composer.tap()
        composer.typeText(
            "Use the terminal to run sleep 120. Then reply with the uppercase form "
                + "of the words 'pagination survived' and nothing else."
        )
        app.buttons["Send"].tap()
        XCTAssertTrue(app.buttons["Interrupt"].waitForExistence(timeout: 30))

        func swipeTowardEarlier() {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
                .press(
                    forDuration: 0.05,
                    thenDragTo: app.coordinate(
                        withNormalizedOffset: CGVector(dx: 0.5, dy: 0.68)
                    )
                )
        }
        for _ in 0..<12 { swipeTowardEarlier() }
        let loadEarlier = app.buttons["loadEarlierMessages"]
        XCTAssertTrue(loadEarlier.waitForExistence(timeout: 10), "Load Earlier missing")
        // The first tap reveals the remainder of the already-loaded 50-row
        // window; the second must cross the server boundary and fetch page 2.
        loadEarlier.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        for _ in 0..<3 { swipeTowardEarlier() }
        XCTAssertTrue(loadEarlier.waitForExistence(timeout: 5), "server page affordance missing")
        loadEarlier.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        swipeTowardEarlier()
        let olderPageMarker = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "pagination fixture message 070")
        ).firstMatch
        XCTAssertTrue(olderPageMarker.waitForExistence(timeout: 10), "stock page 2 was not applied")
        XCTAssertTrue(app.buttons["Interrupt"].exists, "page load discarded the active turn")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "stock-pagination-during-active-turn"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Interrupt"].tap()
    }

    @MainActor
    func testDesktopCompletionPushOpensOwningSession() throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              let marker = env["HERMES_LIVE_FOLLOW_MARKER"],
              !base.isEmpty, !token.isEmpty, !marker.isEmpty else {
            throw XCTSkip("live gateway credentials/marker not provided; skipping live test")
        }

        let app = XCUIApplication()
        app.launchEnvironment["HERMES_URL"] = base
        app.launchEnvironment["HERMES_TOKEN"] = token
        if let relayURL = env["HERMES_RELAY_URL"], !relayURL.isEmpty {
            app.launchEnvironment["HERMES_RELAY_URL"] = relayURL
        }
        app.launchArguments += ["-hermes.connectionOffline", "false"]
        app.launchArguments += ["-hermes.connectionMode", "remoteURL"]
        app.launchArguments += ["--uitest-mute-audio"]
        app.launch()
        XCTAssertTrue(app.buttons["drawerToggle"].waitForExistence(timeout: 30))
        dismissDeviceConnectionBannerIfPresent()

        XCUIDevice.shared.press(.home)
        print("ABH519_PUSH_READY")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let notification = springboard.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", marker + "-COMPLETE")
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
                NSPredicate(format: "label CONTAINS[c] %@", "While in Do Not Disturb")
            ).firstMatch
            if focusGroup.waitForExistence(timeout: 5) {
                focusGroup.tap()
            }
        }
        guard notification.waitForExistence(timeout: 165) else {
            XCTFail("Desktop completion did not produce a phone notification")
            return
        }
        notification.tap()

        XCTAssertTrue(app.buttons["drawerToggle"].waitForExistence(timeout: 30))
        XCTAssertTrue(
            app.textViews.containing(
                NSPredicate(format: "label CONTAINS %@", marker + "-COMPLETE")
            ).firstMatch.waitForExistence(timeout: 30),
            "Completion notification did not open its owning transcript"
        )
        XCTAssertTrue(
            notification.waitForNonExistence(timeout: 8),
            "Completion produced more than one phone notification"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "desktop-completion-push-opened-session"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testDesktopClarificationPushOpensOwningGate() throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              let marker = env["HERMES_LIVE_FOLLOW_MARKER"],
              !base.isEmpty, !token.isEmpty, !marker.isEmpty else {
            throw XCTSkip("live gateway credentials/marker not provided; skipping live test")
        }

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_URL"] = base
        app.launchEnvironment["HERMES_TOKEN"] = token
        if let relayURL = env["HERMES_RELAY_URL"], !relayURL.isEmpty {
            app.launchEnvironment["HERMES_RELAY_URL"] = relayURL
        }
        app.launchArguments += ["-hermes.connectionOffline", "false"]
        app.launchArguments += ["-hermes.connectionMode", "remoteURL"]
        app.launchArguments += ["--uitest-mute-audio"]
        app.launch()
        XCTAssertTrue(app.buttons["drawerToggle"].waitForExistence(timeout: 30))
        dismissDeviceConnectionBannerIfPresent()

        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        print("ABH519_CLARIFY_PUSH_READY")

        // Notification Summaries may rewrite visible text, but SpringBoard's
        // notification button retains the original body in its accessibility
        // label. Select by the unique marker so an older alert cannot win.
        let notification = springboard.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", marker + "-QUESTION")
        ).firstMatch
        if !notification.waitForExistence(timeout: 15) {
            // A grouped alert can go straight to Notification Center without a
            // persistent banner. Pull down from the top edge and use the stored
            // notification instead of treating presentation timing as delivery.
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
                .press(
                    forDuration: 0.1,
                    thenDragTo: springboard.coordinate(
                        withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)
                    )
                )
            let focusGroup = springboard.buttons.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "While in Do Not Disturb")
            ).firstMatch
            if focusGroup.waitForExistence(timeout: 5) {
                focusGroup.tap()
            }
        }
        guard notification.waitForExistence(timeout: 15) else {
            XCTFail("Desktop clarification did not produce a phone notification")
            return
        }
        notification.tap()

        XCTAssertTrue(app.buttons["drawerToggle"].waitForExistence(timeout: 30))
        let clarificationCard = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Clarification request")
        ).firstMatch
        guard clarificationCard.waitForExistence(timeout: 30) else {
            XCTFail("Clarification notification did not open its owning gate")
            return
        }
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", marker + "-QUESTION")
            ).firstMatch.waitForExistence(timeout: 10),
            "Clarification notification opened a stale or foreign gate"
        )
        let leftChoice = app.buttons["Left"]
        guard leftChoice.waitForExistence(timeout: 10) else {
            XCTFail("Clarification gate did not expose its Left choice")
            return
        }
        leftChoice.tap()
        XCTAssertTrue(
            clarificationCard.waitForNonExistence(timeout: 30),
            "Clarification card did not clear after answering"
        )
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", marker + "-ANSWERED")
            ).firstMatch.waitForExistence(timeout: 180),
            "Clarification answer did not reach the blocked agent and complete the turn"
        )
        XCTAssertTrue(
            notification.waitForNonExistence(timeout: 8),
            "Clarification produced more than one phone notification"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "desktop-clarification-push-opened-owning-gate"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
