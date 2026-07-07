import XCTest

/// STR-1012: compact drawer row taps must always dismiss the drawer promptly,
/// including repeated taps on the already-active session and delayed first-paint
/// opens. The `drawerstorm` DEBUG seed keeps the gateway out of the test while
/// driving the real DrawerView -> SessionStore.open path.
@MainActor
final class DrawerSessionTapStormUITests: XCTestCase {
    private let closeDeadline: TimeInterval = 0.5

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testRapidSessionRowTapStormClosesDrawerAfterEveryTap() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_UITEST_SEED"] = "drawerstorm"
        app.launchEnvironment["HERMES_UITEST_SIZE_CLASS"] = "compact"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let drawerToggle = app.buttons["drawerToggle"]
        XCTAssertTrue(drawerToggle.waitForExistence(timeout: 45), "Compact shell did not render")

        let tapPlan = [
            "Storm 1", "Storm 2", "Storm 2", "Storm 3", "Storm 4",
            "Storm 4", "Storm 5", "Storm 6", "Storm 6", "Storm 1",
            "Storm 1", "Storm 3", "Storm 3", "Storm 2", "Storm 5",
            "Storm 5", "Storm 4", "Storm 6", "Storm 2", "Storm 2",
        ]
        XCTAssertEqual(tapPlan.count, 20)

        for (index, title) in tapPlan.enumerated() {
            openDrawer(app, toggle: drawerToggle, iteration: index)
            let row = sessionRow(app, title: title)
            XCTAssertTrue(row.waitForExistence(timeout: 2), "Missing drawer row \(title) at tap \(index + 1)")
            row.tap()
            assertDrawerClosed(app, afterTapping: title, iteration: index)
            waitForCloseAnimationToSettle()
        }
    }

    private func openDrawer(_ app: XCUIApplication, toggle: XCUIElement, iteration: Int) {
        toggle.tap()
        let avatar = app.buttons["settingsAvatar"]
        XCTAssertTrue(
            waitUntil(timeout: 2) { avatar.exists && avatar.isHittable },
            "Drawer did not open before tap \(iteration + 1)"
        )
    }

    private func sessionRow(_ app: XCUIApplication, title: String) -> XCUIElement {
        app.buttons.containing(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }

    private func assertDrawerClosed(_ app: XCUIApplication, afterTapping title: String, iteration: Int) {
        let avatar = app.buttons["settingsAvatar"]
        XCTAssertTrue(
            waitUntil(timeout: closeDeadline) { !avatar.isHittable },
            "Drawer stayed open more than 500ms after tap \(iteration + 1) on \(title)"
        )
    }

    private func waitForCloseAnimationToSettle() {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.4))
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        return condition()
    }
}
