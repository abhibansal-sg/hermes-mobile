import SwiftUI
import XCTest
@testable import HermesMobile

@MainActor
final class PrivacyShieldTests: XCTestCase {
    private let defaultsKey = DefaultsKeys.appLockEnabled

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        super.tearDown()
    }

    func testInactiveAndBackgroundImmediatelyRaiseShieldWhenAppLockDisabled() {
        UserDefaults.standard.set(false, forKey: defaultsKey)
        let lock = AppLock()

        lock.handleScenePhase(.inactive)
        XCTAssertTrue(lock.isPrivacyShieldVisible)
        XCTAssertFalse(lock.isLocked)

        lock.handleScenePhase(.background)
        XCTAssertTrue(lock.isPrivacyShieldVisible)
        XCTAssertFalse(lock.isLocked)
    }

    func testRapidLifecycleTransitionsNeverClearShieldUntilActive() {
        let lock = AppLock()

        for phase in [ScenePhase.inactive, .background, .inactive, .background] {
            lock.handleScenePhase(phase)
            XCTAssertTrue(lock.isPrivacyShieldVisible)
        }

        lock.handleScenePhase(.active)
        XCTAssertFalse(lock.isPrivacyShieldVisible)
    }
}
