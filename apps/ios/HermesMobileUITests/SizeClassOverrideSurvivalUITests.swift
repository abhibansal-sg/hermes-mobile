import XCTest

/// STR-722 / STR-713 iPad evidence for the DEBUG size-class override seam.
///
/// What this UITest proves (deterministically, on an iPad simulator):
///   - The `HERMES_UITEST_SIZE_CLASS` launch env forces `RootView.mainUI`'s
///     branch: `compact` -> CompactLayout (`drawerToggle`), `regular` ->
///     SplitLayout (the "Show inbox" inspector toggle). Two independent launches
///     prove the seam — not the OS size class — is choosing the branch.
///
/// What is NOT provable from inside an XCUITest (first-hand, this run) and is
/// therefore covered by the host-driven harness instead:
///   1. The `hermesapp://debug/size-class/<compact|regular|auto>` deep link
///      flipping the branch IN-PROCESS. `XCUIApplication.open(_:)` RELAUNCHES
///      the app under test on the iOS 26.5 simulator (verified in the PR review
///      log at the `Open ai.hermes.app with URL` -> `Launch ai.hermes.app`
///      sequence), so it resets in-memory `@State` and cannot demonstrate a
///      same-process flip. `Process`/`NSTask` is unavailable on the iOS-Simulator
///      SDK, so the test cannot shell out to `xcrun simctl openurl` (the
///      host-side delivery that DOES fire `.onOpenURL` in-process without a
///      relaunch). The host harness `scripts/ios-sizeclass-evidence.sh` drives
///      that in-process flip with `simctl openurl` and captures the screenshots.
///   2. Same-process STR-691 hoist survival (an unsaved Settings provider key
///      surviving an in-process compact<->regular flip). The required hoist is
///      present in RootView; see `testSameProcessSurvivalNotAutomatableHere`
///      for the remaining XCUITest constraint and host-capture requirement.
///
/// Run on an iPad simulator:
///   scripts/ios-build.sh test -scheme HermesMobile \
///     -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=26.5' \
///     -only-testing:HermesMobileUITests/SizeClassOverrideSurvivalUITests
///
/// `HERMES_UITEST_SEED=demo` forces `.connected` (chat shell renders, no
/// gateway). SplitLayout is detected via its inspector toggle ("Show inbox"),
/// which exists only in the regular-width layout; CompactLayout exposes the
/// `drawerToggle` instead.
final class SizeClassOverrideSurvivalUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launch-env seam: `HERMES_UITEST_SIZE_CLASS` deterministically picks the
    /// iPad's layout. Two INDEPENDENT launches of the same app on the same iPad
    /// sim, one per value, prove the seam — not the OS — is choosing the branch.
    /// Each launch uses a fresh launch environment so no cross-launch state can
    /// mask the result.
    @MainActor
    func testLaunchEnvSeamForcesBothLayoutsOnPad() throws {
        // compact -> CompactLayout (drawerToggle present, no SplitLayout inspector).
        let compactApp = launch(sizeClass: "compact")
        XCTAssertTrue(
            compactApp.buttons["drawerToggle"].waitForExistence(timeout: 45),
            "Compact shell did not render under HERMES_UITEST_SIZE_CLASS=compact"
        )
        XCTAssertFalse(
            compactApp.buttons["Show inbox"].exists,
            "Compact override leaked SplitLayout's inspector toggle"
        )
        attach(compactApp, named: "launch-env-compact")

        // regular -> SplitLayout (inspector toggle present). Relaunching through
        // XCUITest applies a fresh launch environment; avoiding an explicit
        // terminate keeps the simulator test runner from treating the expected
        // app stop as a crash on iOS 26.5.
        let regularApp = launch(sizeClass: "regular")
        XCTAssertTrue(
            regularApp.buttons["Show inbox"].waitForExistence(timeout: 45),
            "Split shell did not render under HERMES_UITEST_SIZE_CLASS=regular (inspector toggle absent)"
        )
        XCTAssertFalse(
            regularApp.buttons["drawerToggle"].exists,
            "Regular override leaked CompactLayout's drawer toggle"
        )
        attach(regularApp, named: "launch-env-regular")
    }

    // MARK: - Helpers

    @MainActor
    private func launch(sizeClass: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_UITEST_SEED"] = "demo"
        app.launchEnvironment["HERMES_UITEST_SIZE_CLASS"] = sizeClass
        app.launch()
        return app
    }

    @MainActor
    private func attach(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
