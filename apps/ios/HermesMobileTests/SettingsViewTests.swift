import XCTest
@testable import HermesMobile

@MainActor
final class SettingsViewTests: XCTestCase {
    func testMissingPasscodeGuidanceIsActionableAndNeverClaimsActive() async {
        let defaults = UserDefaults(suiteName: "SettingsViewTests")!
        defaults.removePersistentDomain(forName: "SettingsViewTests")
        let lock = AppLock(
            authenticator: SettingsPasscodeMissingAuthenticator(),
            defaults: defaults
        )

        let enabled = await lock.setEnabled(true)
        XCTAssertFalse(enabled)
        XCTAssertFalse(lock.isEnabled)
        XCTAssertTrue(lock.lastError?.contains("iOS Settings") == true)
        XCTAssertTrue(lock.lastError?.contains("device passcode") == true)
    }
}

private struct SettingsPasscodeMissingAuthenticator: BiometricAuthenticating {
    func capability() async -> DeviceOwnerAuthenticationCapability { .passcodeNotSet }
    func evaluate(reason: String) async -> BiometricResult { .passcodeNotSet }
}
