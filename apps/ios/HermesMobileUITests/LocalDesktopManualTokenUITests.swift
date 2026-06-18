import XCTest

/// Inc-3b XCUITest: verifies the Local-desktop manual-token flow.
///
/// CONTRACT (CONTRACT-CONNECTION-MODES.md §Inc3b):
/// When a `hermesapp://pair?url=…&manual_token=true` link arrives, the app
/// must NOT fail silently or attempt to configure with an empty token. Instead
/// it must present `ManualTokenPromptView` — a token-entry sheet with the
/// URL pre-filled — so the user can paste the token from their Desktop app.
///
/// Three tests:
///   1. **No-gateway (pure UI):** Inject the deep link via `HERMES_UITEST_DEEPLINK`
///      launch environment variable (a DEBUG-only seam added in Inc-3b). Assert
///      that `ManualTokenPromptView` appears (accessibilityId "manualTokenField").
///      No gateway required — this is a pure routing test.
///
///   2. **Gateway-dependent (skipped offline):** Enter the token in the prompt
///      and assert the app reaches `.connected` (drawerToggle visible). Requires
///      `HERMES_URL` + `HERMES_TOKEN` in the test environment (the isolated
///      :9123 gateway from `scripts/ios-build.sh test`).
///
///   3. **Cancel:** Dismiss the prompt and assert the app stays on WelcomeView.
///      Pure UI, no gateway required.
///
/// Gateway-dependent sub-tests are skip-guarded (like the other live UITests)
/// so they self-skip in CI when credentials are absent.
///
/// Deep-link injection uses the `HERMES_UITEST_DEEPLINK` DEBUG env var rather
/// than `xcrun simctl openurl` (which is a macOS host-side call; the UITest
/// runner compiles for iOS and `Process` is unavailable). The seam fires the
/// URL through `HermesURLRouter.route` after bootstrap, identical to `onOpenURL`.
final class LocalDesktopManualTokenUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    /// URL-encode a string for use as a query-param value.
    private func queryEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }

    /// Build a `hermesapp://pair` URL with `manual_token=true` and no token,
    /// pointing at the provided gateway URL.
    private func manualTokenDeepLink(gatewayURL: String) -> String {
        "hermesapp://pair?url=\(queryEncode(gatewayURL))&manual_token=true"
    }

    /// Launch a fresh unconfigured app with a `HERMES_UITEST_DEEPLINK` that
    /// fires a manual_token pair payload after bootstrap.  The app lands on
    /// WelcomeView first (no saved config), then the debug seam fires the URL.
    private func launchWithManualTokenDeepLink(
        gatewayURL: String,
        extraEnv: [String: String] = [:]
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // Clear any saved config so the app lands on WelcomeView (needsSetup).
        app.launchArguments += ["-hermes.serverURL", ""]
        app.launchArguments += ["-hermes.connectionMode", ""]
        // The HERMES_UITEST_DEEPLINK env var is the DEBUG seam that fires the
        // URL through HermesURLRouter.route after bootstrap, identical to onOpenURL.
        app.launchEnvironment["HERMES_UITEST_DEEPLINK"] = manualTokenDeepLink(gatewayURL: gatewayURL)
        for (k, v) in extraEnv { app.launchEnvironment[k] = v }
        app.launch()
        return app
    }

    // MARK: - Test 1: Deep link with manual_token=true shows the token-entry prompt

    /// Purely a routing test — no live gateway required.
    ///
    /// Injects `hermesapp://pair?url=http://127.0.0.1:9123&manual_token=true`
    /// via the HERMES_UITEST_DEEPLINK seam. Asserts that ManualTokenPromptView
    /// appears (the token field with accessibilityIdentifier "manualTokenField").
    func testManualTokenDeepLinkShowsPrompt() throws {
        let app = launchWithManualTokenDeepLink(gatewayURL: "http://127.0.0.1:9123")

        // ManualTokenPromptView should appear with the token SecureField.
        let tokenField = app.secureTextFields["manualTokenField"]
        XCTAssertTrue(
            tokenField.waitForExistence(timeout: 15),
            "ManualTokenPromptView (manualTokenField) did not appear after manual_token deep link. "
            + "The router may not be calling requestManualTokenPair, or the sheet is not being presented."
        )

        // The discovered URL should be visible in the prompt.
        let urlLabel = app.staticTexts["manualTokenDiscoveredURL"]
        XCTAssertTrue(
            urlLabel.waitForExistence(timeout: 5),
            "Discovered URL label (manualTokenDiscoveredURL) not visible in the manual-token prompt"
        )
    }

    // MARK: - Test 2: Entering token connects to the gateway (gateway-dependent)

    /// Requires a live :9123 gateway with credentials in the test environment.
    /// Self-skips when credentials are absent (CI-safe).
    ///
    /// The HERMES_UITEST_DEEPLINK fires a manual_token=true payload using the
    /// real gateway URL. The user enters the real token → configure() succeeds
    /// → drawerToggle appears (connected state proof).
    func testManualTokenPromptConnectsWithValidToken() throws {
        let env = ProcessInfo.processInfo.environment
        guard let gatewayURL = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              !gatewayURL.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_URL/HERMES_TOKEN not provided; skipping live gateway test")
        }

        let app = launchWithManualTokenDeepLink(gatewayURL: gatewayURL)

        // Assert the token-entry prompt appears.
        let tokenField = app.secureTextFields["manualTokenField"]
        XCTAssertTrue(
            tokenField.waitForExistence(timeout: 15),
            "ManualTokenPromptView did not appear"
        )

        // Enter the token.
        tokenField.tap()
        tokenField.typeText(token)

        // Tap Connect.
        let connectBtn = app.buttons["manualTokenConnectButton"]
        XCTAssertTrue(connectBtn.waitForExistence(timeout: 5), "Connect button not found")
        connectBtn.tap()

        // Successful connect: the manual-token sheet dismisses and the chat shell appears.
        // The drawerToggle in the nav bar is the canonical connected-state proof.
        let drawerToggle = app.buttons["drawerToggle"]
        XCTAssertTrue(
            drawerToggle.waitForExistence(timeout: 30),
            "Connected chat shell (drawerToggle) did not appear after manual-token connect. "
            + "configure() may have failed or the phase did not transition to .connected."
        )
    }

    // MARK: - Test 3: Cancel dismisses the prompt without connecting

    /// Pure UI test — no gateway required.
    ///
    /// After the manual-token prompt appears, tapping Cancel should dismiss it
    /// and leave the app on WelcomeView with no phase change.
    func testManualTokenPromptCancelStaysOnWelcome() throws {
        let app = launchWithManualTokenDeepLink(gatewayURL: "http://127.0.0.1:9123")

        // Assert the prompt appears.
        let tokenField = app.secureTextFields["manualTokenField"]
        XCTAssertTrue(
            tokenField.waitForExistence(timeout: 15),
            "ManualTokenPromptView did not appear"
        )

        // Tap Cancel.
        let cancelBtn = app.buttons["manualTokenCancelButton"]
        XCTAssertTrue(cancelBtn.waitForExistence(timeout: 5), "Cancel button not found")
        cancelBtn.tap()

        // The sheet must actually dismiss. Wait for the token field to
        // disappear rather than asserting `.exists` synchronously: with a
        // `.medium` detent the WelcomeView sits *behind* the sheet, so its
        // button is already in the AX tree and a bare `.exists` check races
        // the dismiss animation (passes locally, flakes on slower cloud VMs).
        XCTAssertTrue(
            tokenField.waitForNonExistence(timeout: 10),
            "ManualTokenPromptView is still visible after Cancel — the sheet did not dismiss"
        )

        // WelcomeView should be visible again (the Local desktop mode button).
        let localBtn = app.buttons["connectionModeButton_localDesktop"]
        XCTAssertTrue(
            localBtn.waitForExistence(timeout: 5),
            "WelcomeView did not reappear after cancelling manual-token prompt"
        )
    }
}
