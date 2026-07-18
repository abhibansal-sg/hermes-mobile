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

    // GitHub #207: `.inactive` (partial home swipe, Control Center, notification
    // shade) keeps the live app visible and must NOT raise the opaque shield. The
    // shield is an app-switcher snapshot boundary and belongs to `.background` only.
    // This test previously asserted the buggy contract (`.inactive` raises the
    // shield); it now asserts the corrected split.
    func testInactiveDoesNotRaiseShieldButBackgroundDoesWhenAppLockDisabled() {
        UserDefaults.standard.set(false, forKey: defaultsKey)
        let lock = AppLock()

        lock.handleScenePhase(.inactive)
        XCTAssertFalse(lock.isPrivacyShieldVisible)
        XCTAssertFalse(lock.isLocked)

        lock.handleScenePhase(.background)
        XCTAssertTrue(lock.isPrivacyShieldVisible)
        XCTAssertFalse(lock.isLocked)
    }

    // The snapshot shield must be raised before iOS captures the app-switcher
    // image, i.e. synchronously on the `.background` transition.
    func testBackgroundRaisesShieldBeforeSnapshot() {
        let lock = AppLock()

        lock.handleScenePhase(.background)
        XCTAssertTrue(lock.isPrivacyShieldVisible)
    }

    // `.inactive` never touches the visible surface; only `.background` raises the
    // shield, and `.active` clears it.
    func testInactiveNeverRaisesShieldAndActiveClearsIt() {
        let lock = AppLock()

        lock.handleScenePhase(.inactive)
        XCTAssertFalse(lock.isPrivacyShieldVisible)

        lock.handleScenePhase(.background)
        XCTAssertTrue(lock.isPrivacyShieldVisible)

        lock.handleScenePhase(.inactive)
        // Coming back through `.inactive` on the way to active must not itself
        // clear the shield, but it must never re-raise once already down.
        lock.handleScenePhase(.active)
        XCTAssertFalse(lock.isPrivacyShieldVisible)
    }
}
