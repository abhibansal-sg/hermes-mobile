import XCTest

/// Live gateway proof for the composer YOLO / flow-state bolt.
///
/// Requires TEST_RUNNER_HERMES_URL / TEST_RUNNER_HERMES_TOKEN on the wrapper
/// invocation, surfaced to the test runner as HERMES_URL / HERMES_TOKEN.
/// Skips cleanly without credentials so offline CI remains green.
final class ComposerYoloGatewayUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testComposerYoloToggleReflectsGatewaySessionInfo() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_URL/HERMES_TOKEN not provided; skipping live gateway test")
        }

        let app = XCUIApplication()
        app.launchEnvironment["HERMES_URL"] = url
        app.launchEnvironment["HERMES_TOKEN"] = token
        app.launchEnvironment["HERMES_UITEST_YOLO_GATEWAY_PROBE"] = "1"
        app.launch()

        let drawerToggle = app.buttons["drawerToggle"]
        XCTAssertTrue(
            drawerToggle.waitForExistence(timeout: 30),
            "Connected chat shell (draft home) did not appear"
        )

        let yolo = app.buttons["composerYoloToggle"]
        XCTAssertTrue(yolo.waitForExistence(timeout: 10), "Composer YOLO toggle missing")
        XCTAssertEqual(yolo.value as? String, "Off", "Draft composer should start with YOLO off")

        yolo.tap()
        let unavailableNote = app.staticTexts["steerNote"]
        XCTAssertTrue(
            unavailableNote.waitForExistence(timeout: 3),
            "Tapping YOLO before a live runtime session should show feedback"
        )
        XCTAssertEqual(
            unavailableNote.label,
            "Start a live session to toggle flow-state",
            "No-live-session feedback should explain why the bolt cannot toggle"
        )
        XCTAssertEqual(yolo.value as? String, "Off", "Unavailable tap must not flip local YOLO state")

        materializeSession(in: app)

        let gatewayState = app.staticTexts["composerYoloGatewayState"]
        XCTAssertTrue(
            gatewayState.waitForExistence(timeout: 10),
            "DEBUG gateway YOLO read-back marker missing"
        )
        XCTAssertTrue(
            waitForElement(gatewayState, value: "Off", timeout: 30),
            "Gateway session.info did not report initial YOLO Off"
        )
        print("STR-1006 gateway session.info yolo=Off")

        yolo.tap()
        XCTAssertTrue(waitForElement(yolo, value: "On", timeout: 10), "YOLO button did not flip On")
        XCTAssertTrue(
            waitForElement(gatewayState, value: "On", timeout: 30),
            "Gateway session.info did not confirm YOLO On after config.set"
        )
        print("STR-1006 config.set yolo=1 confirmed by session.info yolo=On")

        yolo.tap()
        XCTAssertTrue(waitForElement(yolo, value: "Off", timeout: 10), "YOLO button did not flip Off")
        XCTAssertTrue(
            waitForElement(gatewayState, value: "Off", timeout: 30),
            "Gateway session.info did not confirm YOLO Off after config.set"
        )
        print("STR-1006 config.set yolo=0 confirmed by session.info yolo=Off")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "composer-yolo-gateway-off-on-off"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func materializeSession(in app: XCUIApplication) {
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
        composer.typeText("Reply with exactly: ok")

        let send = app.buttons["Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 10), "Send button missing")
        send.tap()

        let idleMic = app.buttons["Dictate message"]
        XCTAssertTrue(
            idleMic.waitForExistence(timeout: 150),
            "Composer did not return to idle state after materializing the session"
        )
    }

    private func waitForElement(_ element: XCUIElement, value: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
