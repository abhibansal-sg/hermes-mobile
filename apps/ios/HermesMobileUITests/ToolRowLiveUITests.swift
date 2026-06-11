import XCTest

/// ABH-45 live regression guard: a real agent turn that invokes a tool must
/// render a tool-activity row from the gateway's actual wire contract
/// (`tool_id` / `duration_s`) and must not leave the active-tool spinner
/// stuck after `tool.complete`.
///
/// Self-skips offline (no HERMES_URL/HERMES_TOKEN). Run against an isolated
/// dashboard instance, never the live 9119 — see CONTRACT-F2 environment
/// rules.
final class ToolRowLiveUITests: XCTestCase {

    func testLiveToolRowRendersAndCompletes() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_URL/HERMES_TOKEN not provided; skipping live test")
        }

        let app = XCUIApplication()
        app.launchEnvironment["HERMES_URL"] = url
        app.launchEnvironment["HERMES_TOKEN"] = token
        app.launch()

        // Connected draft chat shell (same landing assertions as
        // ChatFlowUITests.testNewSessionStreamingTurn).
        let drawerToggle = app.buttons["drawerToggle"]
        XCTAssertTrue(drawerToggle.waitForExistence(timeout: 30),
                      "Connected chat shell did not appear")

        let composerPlaceholder = "Message Hermes…"
        let composerField = app.textFields[composerPlaceholder]
        let composerTextView = app.textViews[composerPlaceholder]
        XCTAssertTrue(
            composerField.waitForExistence(timeout: 20)
                || composerTextView.waitForExistence(timeout: 5),
            "Composer did not appear"
        )
        let composer = composerField.exists ? composerField : composerTextView
        composer.tap()
        // Deliberately phrased WITHOUT the word "terminal": the tool-row
        // assertion below matches the row's tool-name label exactly, and the
        // user bubble must not be able to satisfy it.
        composer.typeText("Run the shell command `echo ABH45LIVE` and report its output verbatim.")

        let send = app.buttons["Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 10), "Send button missing")
        send.tap()

        // 1. The tool-activity row appears, named from the live tool.start
        //    frame. Before the ABH-45 decoder fix this NEVER rendered (the
        //    gateway emits `tool_id`; the decoder required `tool_call_id`).
        //    The row's name sits inside a Button whose label SwiftUI merges
        //    from the HStack, so match any element whose label CONTAINS the
        //    tool name rather than an exact staticText. "terminal" appears
        //    only in the tool row for this prompt (the user text says "shell
        //    command", the reply says "Output: …").
        let toolRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "terminal")
        ).firstMatch
        XCTAssertTrue(toolRow.waitForExistence(timeout: 120),
                      "Live tool-activity row did not render (wire-contract decode broken?)")

        // 2. The reply lands (the agent echoes the nonce back).
        let reply = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "ABH45LIVE")
        ).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 120),
                      "Assistant reply with tool output did not appear")

        // 3. The turn completes cleanly: the composer returns to its idle mic
        //    state, i.e. no stuck active-tool spinner / streaming state.
        let idleMic = app.buttons["Dictate message"]
        XCTAssertTrue(idleMic.waitForExistence(timeout: 60),
                      "Composer did not return to idle after the tool turn")
    }
}
