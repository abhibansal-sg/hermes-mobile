import XCTest

/// Verifies the Increment 1 connection-mode picker (CONTRACT-CONNECTION-MODES.md §Inc1).
///
/// Reads the isolated test gateway credentials from the test-runner environment:
///   TEST_RUNNER_HERMES_URL  → HERMES_URL in the runner env
///   TEST_RUNNER_HERMES_TOKEN → HERMES_TOKEN in the runner env
/// Skips when credentials are absent (keeps CI green offline).
final class ConnectionModePickerUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Test 1: Fresh launch shows 3 mode buttons

    func testFreshLaunchShowsThreeModes() throws {
        // Launch WITHOUT credentials so the app lands on WelcomeView.
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // Clear saved config so this is a fresh first-run launch.
        app.launchArguments += ["-hermes.serverURL", ""]
        app.launchArguments += ["-hermes.connectionMode", ""]
        app.launch()

        // WelcomeView renders the mode picker — assert all three mode buttons exist.
        let localBtn  = app.buttons["connectionModeButton_localDesktop"]
        let remoteBtn = app.buttons["connectionModeButton_remoteURL"]
        let sharedBtn = app.buttons["connectionModeButton_sharedDashboard"]

        XCTAssertTrue(localBtn.waitForExistence(timeout: 10),
                      "Local desktop mode button not found")
        XCTAssertTrue(remoteBtn.waitForExistence(timeout: 5),
                      "Remote URL mode button not found")
        XCTAssertTrue(sharedBtn.waitForExistence(timeout: 5),
                      "Shared dashboard mode button not found")
    }

    // MARK: - Test 2: Select Remote URL → enter :9123 URL+token → connected + session row

    func testRemoteURLModeConnectsAndShowsSession() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_URL/HERMES_TOKEN not provided; skipping live test")
        }

        // Launch WITHOUT pre-seeded credentials (fresh launch → WelcomeView).
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += ["-hermes.serverURL", ""]
        app.launchArguments += ["-hermes.connectionMode", ""]
        app.launch()

        // Tap "Remote URL" mode button.
        let remoteBtn = app.buttons["connectionModeButton_remoteURL"]
        XCTAssertTrue(remoteBtn.waitForExistence(timeout: 10), "Remote URL button not found")
        remoteBtn.tap()

        // Tap the Enter URL button (primary CTA for remoteURL mode).
        let enterURLBtn = app.buttons["enterURLButton"]
        XCTAssertTrue(enterURLBtn.waitForExistence(timeout: 5), "Enter URL button not found")
        enterURLBtn.tap()

        // The ConnectionSetupView sheet appears. Fill URL + token.
        let urlField = app.textFields.firstMatch
        XCTAssertTrue(urlField.waitForExistence(timeout: 10), "URL field not found")
        urlField.tap()
        urlField.typeText(url)

        // Move to token field.
        app.keyboards.buttons["Return"].tapIfExists()
        let tokenField = app.secureTextFields.firstMatch
        XCTAssertTrue(tokenField.waitForExistence(timeout: 5), "Token field not found")
        tokenField.tap()
        tokenField.typeText(token)

        // Dismiss keyboard then tap Connect.
        app.keyboards.buttons["Return"].tapIfExists()
        let connectBtn = app.buttons["Connect"]
        XCTAssertTrue(connectBtn.waitForExistence(timeout: 5), "Connect button not found")
        connectBtn.tap()

        // After a successful connect the app transitions to the connected chat shell
        // (drawerToggle appears — the shell header's hamburger).
        let drawerToggle = app.buttons["drawerToggle"]
        XCTAssertTrue(
            drawerToggle.waitForExistence(timeout: 30),
            "Connected chat shell (drawerToggle) did not appear — connect may have failed"
        )

        // Open the drawer and assert at least one session row is present.
        drawerToggle.tap()
        let sessionRow = app.descendants(matching: .any)
            .matching(identifier: "sessionRow").firstMatch
        XCTAssertTrue(
            sessionRow.waitForExistence(timeout: 20),
            "No session row in drawer — gateway may not have a session yet"
        )
    }

    // MARK: - Test 3: Mode persists across relaunch

    func testModePersistsAcrossRelaunch() throws {
        // Launch WITHOUT credentials so the app lands on WelcomeView.
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += ["-hermes.serverURL", ""]
        app.launchArguments += ["-hermes.connectionMode", ""]
        app.launch()

        // Tap "Local desktop" to select it.
        let localBtn = app.buttons["connectionModeButton_localDesktop"]
        XCTAssertTrue(localBtn.waitForExistence(timeout: 10), "Local desktop button not found")
        localBtn.tap()

        // Small pause to let the UserDefaults write settle.
        Thread.sleep(forTimeInterval: 0.5)

        // Relaunch the app WITHOUT clearing the mode key — we want to read the persisted value.
        app.terminate()
        let app2 = XCUIApplication()
        app2.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app2.launchArguments += ["-hermes.serverURL", ""]
        app2.launch()

        // The Local desktop button should be selected (has .isSelected trait).
        let localBtn2 = app2.buttons["connectionModeButton_localDesktop"]
        XCTAssertTrue(localBtn2.waitForExistence(timeout: 10),
                      "Local desktop button not found after relaunch")
        XCTAssertTrue(
            localBtn2.isSelected,
            "Local desktop mode was not persisted across relaunch"
        )
    }
}

// MARK: - XCUIElement helper

private extension XCUIElement {
    /// Tap only when the element exists (avoids a test failure for optional chrome).
    func tapIfExists() {
        if exists { tap() }
    }
}
