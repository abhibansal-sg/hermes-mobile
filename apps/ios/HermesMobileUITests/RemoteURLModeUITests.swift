import XCTest

/// Inc 2 XCUITest: connect the sim in Remote-URL mode to an isolated :9123
/// gateway bound to `0.0.0.0` and assert `.connected`.
///
/// Reads credentials from the test-runner environment (set by the
/// `scripts/ios-build.sh test` invocation via TEST_RUNNER_HERMES_URL /
/// TEST_RUNNER_HERMES_TOKEN, which xcodebuild surfaces as HERMES_URL /
/// HERMES_TOKEN inside the app process). Skips gracefully when absent.
///
/// Gateway rig (set up by the caller before running this suite):
///   - HERMES_GATEWAY_BROADCAST=1, own token, port :9123, bound to 0.0.0.0
///   - /health returns 200 before tests run
///   - One seeded session row in the DB so the drawer is non-empty
///   - NEVER the live :9119 dashboard
///
/// Tests use the app's dev-env override path (HERMES_URL/HERMES_TOKEN in the
/// launch environment) to bypass the welcome screen and land directly on the
/// connected chat shell, exactly like Inc 1's ChatFlowUITests.
final class RemoteURLModeUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Test 1: Remote-URL mode reaches .connected via real host

    /// Connects directly via the dev-env path (HERMES_URL/HERMES_TOKEN),
    /// which exercises the full `configure → WSURLBuilder.wsRequest(mode:) →
    /// client.connect` chain with the mode derived from the persisted value.
    /// The pre-launch argument seeds `.remoteURL` so the transport omits the
    /// loopback Host override — the gateway's `0.0.0.0` bind accepts the real
    /// host from URLSession.
    func testRemoteURLModeConnects() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_URL/HERMES_TOKEN not provided; skipping live gateway test")
        }

        let app = XCUIApplication()
        // Seed credentials via the DEBUG env-override path (bootstrap reads them).
        app.launchEnvironment["HERMES_URL"] = url
        app.launchEnvironment["HERMES_TOKEN"] = token
        // Seed the connection mode as remoteURL so the transport path is explicit.
        app.launchArguments += ["-hermes.connectionMode", "remoteURL"]
        app.launch()

        // A successful connect lands on the chat shell — the drawerToggle in the
        // nav bar is the canonical connected-state proof (same as ChatFlowUITests).
        let drawerToggle = app.buttons["drawerToggle"]
        XCTAssertTrue(
            drawerToggle.waitForExistence(timeout: 30),
            "Connected chat shell (drawerToggle) did not appear — remote-URL connect failed. "
            + "This proves WSURLBuilder is sending the correct Host for a 0.0.0.0-bound gateway."
        )
    }

    // MARK: - Test 2: Session row visible in drawer after Remote-URL connect

    func testRemoteURLModeShowsSessionRow() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_URL/HERMES_TOKEN not provided; skipping live gateway test")
        }

        let app = XCUIApplication()
        app.launchEnvironment["HERMES_URL"] = url
        app.launchEnvironment["HERMES_TOKEN"] = token
        app.launchArguments += ["-hermes.connectionMode", "remoteURL"]
        app.launch()

        let drawerToggle = app.buttons["drawerToggle"]
        XCTAssertTrue(drawerToggle.waitForExistence(timeout: 30),
                      "Chat shell did not appear — connect failed")
        drawerToggle.tap()

        // At least one session row proves the gateway's session DB is reachable
        // and the REST client built from the remoteURL is talking to the right host.
        let sessionRow = app.descendants(matching: .any)
            .matching(identifier: "sessionRow").firstMatch
        XCTAssertTrue(
            sessionRow.waitForExistence(timeout: 20),
            "No session row in drawer — REST hydration may have failed due to a Host mismatch"
        )
    }
}
