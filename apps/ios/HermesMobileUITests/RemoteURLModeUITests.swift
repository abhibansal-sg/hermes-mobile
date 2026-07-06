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

    // MARK: - Test 3: HERMES_UITEST_PANEL=gateway cold-launches into Gateway Status

    /// STR-459/STR-462/STR-485: proves the DEBUG-only navigation seed lands a
    /// cold launch directly on the Settings sheet's Gateway Status panel — no
    /// drawer tap, no Settings tap, no row tap — via
    /// `HERMES_UITEST_PANEL=gateway`. Uses the same live remote-URL gateway
    /// rig as the tests above.
    ///
    /// Asserts TWO independent proofs the real `GatewayStatusView` rendered
    /// (not the `SettingsView.panelView` "Not connected" placeholder a
    /// premature seed would land on — see `RootView.seedGatewayPanelIfReady()`):
    /// the panel's own navigation title, AND its "Restart Gateway"
    /// gateway-recovery button (`GatewayStatusView.actionButtons`,
    /// `GatewayRecoveryAction.restartGateway.buttonTitle`) — the placeholder
    /// has neither.
    ///
    /// DRAIN/CANCEL CONTROLS: per the STR-459 retry requirement, this test
    /// must assert PR #26's drain/cancel recovery controls if this branch/base
    /// contains them, or block with exact evidence if it doesn't rather than
    /// weaken the test. Evidence they are absent here: `GatewayRecoveryAction`
    /// (`GatewayStatusView.swift:332-334`) declares exactly two cases —
    /// `.restartGateway` and `.updateHermes` — with no drain/cancel case, and
    /// `actionButtons` (`GatewayStatusView.swift:140-152`) renders unconditionally
    /// from `GatewayRecoveryAction.allCases`, so there is no drain/cancel
    /// affordance anywhere in this view to assert without an out-of-scope edit
    /// to `GatewayStatusView.swift` (outside this issue's scope fence). This is
    /// reported as a blocked sub-scope in the STR-485 hand-back rather than
    /// synthesized here.
    func testUITestPanelGatewaySeedLandsOnGatewayStatus() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_URL/HERMES_TOKEN not provided; skipping live gateway test")
        }

        let app = XCUIApplication()
        app.launchEnvironment["HERMES_URL"] = url
        app.launchEnvironment["HERMES_TOKEN"] = token
        app.launchEnvironment["HERMES_UITEST_PANEL"] = "gateway"
        app.launchArguments += ["-hermes.connectionMode", "remoteURL"]
        app.launch()

        // The seed pushes Settings' sheet open, then appends the Gateway
        // Status panel onto its NavigationPath — both before any user
        // interaction. `GatewayStatusView.navigationTitle("Gateway")` is the
        // canonical proof the push landed (the Settings row itself is
        // titled "Gateway Status"; the pushed destination's own title is
        // "Gateway" — assert either so this doesn't overfit one label).
        let gatewayTitle = app.navigationBars.matching(
            NSPredicate(format: "identifier == %@ OR identifier == %@", "Gateway", "Gateway Status")
        ).firstMatch
        XCTAssertTrue(
            gatewayTitle.waitForExistence(timeout: 30),
            "HERMES_UITEST_PANEL=gateway did not cold-launch into the Gateway Status panel"
        )

        // Second, independent proof: the real panel's recovery controls are
        // present — the "Not connected" placeholder SettingsView falls back to
        // when `connectionStore.control` isn't ready has no such button, so
        // this cannot pass on a race that lands on the placeholder.
        XCTAssertTrue(
            app.buttons["Restart Gateway"].waitForExistence(timeout: 15),
            "Gateway Status panel's Restart Gateway recovery control did not appear — "
            + "the seed may have landed on the \"Not connected\" placeholder "
            + "instead of the real GatewayStatusView"
        )
    }
}
