import XCTest

/// Verifies the mechanical accessibility fixes introduced by the a11y sweep PR:
///
///   1. ConnectionSetupView — `gatewayURLField` + `sessionTokenField`
///      accessibility identifiers resolve and their labels are correct.
///   2. ToolActivityRow — `toolDetailDisclosure` button exists with
///      `accessibilityValue` "collapsed" initially, flips to "expanded" on tap.
///
/// These tests exercise the STATIC identifier wiring only — no live gateway
/// required. They skip when HERMES_URL/HERMES_TOKEN are missing (consistent
/// with the rest of the UITest suite) so they remain green on CI offline.
final class A11yMechanicalUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - 1. ConnectionSetupView field identifiers + labels

    /// Navigating to ConnectionSetupView (via "Remote URL" → "Enter URL") must
    /// surface `gatewayURLField` and `sessionTokenField` with the expected labels.
    func testConnectionSetupViewFieldsHaveExplicitLabels() throws {
        let app = XCUIApplication()
        // Clear saved config so the app lands on WelcomeView.
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += ["-hermes.serverURL", ""]
        app.launchArguments += ["-hermes.connectionMode", ""]
        app.launch()

        // Navigate: WelcomeView → Remote URL mode → Enter URL → ConnectionSetupView sheet.
        let remoteBtn = app.buttons["connectionModeButton_remoteURL"]
        XCTAssertTrue(remoteBtn.waitForExistence(timeout: 10), "Remote URL button not found")
        remoteBtn.tap()

        let enterURLBtn = app.buttons["enterURLButton"]
        XCTAssertTrue(enterURLBtn.waitForExistence(timeout: 5), "Enter URL button not found")
        enterURLBtn.tap()

        // 1a. URL field — must resolve by accessibilityIdentifier.
        let urlField = app.textFields["gatewayURLField"]
        XCTAssertTrue(urlField.waitForExistence(timeout: 10),
                      "gatewayURLField identifier not found on ConnectionSetupView")
        // Label (read by VoiceOver) must be exactly "Gateway URL".
        XCTAssertEqual(urlField.label, "Gateway URL",
                       "Gateway URL field has wrong VoiceOver label")

        // 1b. Token field — must resolve by accessibilityIdentifier.
        let tokenField = app.secureTextFields["sessionTokenField"]
        XCTAssertTrue(tokenField.waitForExistence(timeout: 5),
                      "sessionTokenField identifier not found on ConnectionSetupView")
        // SecureField placeholder alone is insufficient when filled; label must be explicit.
        XCTAssertEqual(tokenField.label, "Session token",
                       "Session token field has wrong VoiceOver label")
    }

    // MARK: - 2. ToolActivityRow disclosure button identifier + value flip

    /// When a tool-activity turn is present, the `toolDetailDisclosure` button
    /// must start with `accessibilityValue == "collapsed"` and flip to "expanded"
    /// after one tap.
    ///
    /// Requires a live gateway to actually render a tool turn; skips offline.
    func testToolDetailDisclosureValueFlipsOnTap() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_URL/HERMES_TOKEN not provided; skipping live test")
        }

        let app = XCUIApplication()
        app.launchEnvironment["HERMES_URL"] = url
        app.launchEnvironment["HERMES_TOKEN"] = token
        app.launch()

        // Wait for the connected chat shell.
        let drawerToggle = app.buttons["drawerToggle"]
        XCTAssertTrue(drawerToggle.waitForExistence(timeout: 30), "Connected shell did not appear")

        // Send a prompt that reliably triggers a tool call.
        let composerPlaceholder = "Message Hermes…"
        let composerField = app.textFields[composerPlaceholder]
        let composerTextView = app.textViews[composerPlaceholder]
        XCTAssertTrue(
            composerField.waitForExistence(timeout: 20) || composerTextView.waitForExistence(timeout: 5),
            "Composer not found"
        )
        let composer = composerField.exists ? composerField : composerTextView
        composer.tap()
        composer.typeText("Run the shell command `echo A11Y_PROBE` and report its output verbatim.")
        app.buttons["Send"].tap()

        // Wait for the tool-detail disclosure button (appears once the tool.start frame lands).
        let disclosure = app.buttons["toolDetailDisclosure"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 120),
                      "toolDetailDisclosure button did not appear after tool turn")

        // Initial value must be "collapsed".
        XCTAssertEqual(disclosure.value as? String, "collapsed",
                       "toolDetailDisclosure should start collapsed")

        // Tap → value flips to "expanded".
        disclosure.tap()
        // Allow SwiftUI animation to settle.
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(disclosure.value as? String, "expanded",
                       "toolDetailDisclosure should be expanded after tap")

        // Tap again → back to "collapsed".
        disclosure.tap()
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(disclosure.value as? String, "collapsed",
                       "toolDetailDisclosure should collapse on second tap")
    }
}
