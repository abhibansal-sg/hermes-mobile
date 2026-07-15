import LocalAuthentication
import XCTest
@testable import HermesMobile

@MainActor
final class AppLockTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "AppLockTests")!
        defaults.removePersistentDomain(forName: "AppLockTests")
    }

    func testAvailableBiometricsCanEnable() async {
        let lock = AppLock(authenticator: StubAuthenticator(capability: .biometrics, results: [.success]), defaults: defaults)
        let enabled = await lock.setEnabled(true)
        XCTAssertTrue(enabled)
        XCTAssertTrue(lock.isEnabled)
        XCTAssertFalse(lock.isLocked)
    }

    func testPasscodeFallbackWithoutBiometricsCanEnable() async {
        let lock = AppLock(authenticator: StubAuthenticator(capability: .passcodeFallback, results: [.success]), defaults: defaults)
        let enabled = await lock.setEnabled(true)
        XCTAssertTrue(enabled)
        XCTAssertTrue(lock.isEnabled)
    }

    func testPasscodeNotSetRefusesEnableAndStaysFalseAfterRelaunch() async {
        let authenticator = StubAuthenticator(capability: .passcodeNotSet, results: [])
        let lock = AppLock(authenticator: authenticator, defaults: defaults)
        let enabled = await lock.setEnabled(true)
        XCTAssertFalse(enabled)
        XCTAssertFalse(lock.isEnabled)
        XCTAssertEqual(lock.lastError, BiometricResult.passcodeGuidance)

        let relaunched = AppLock(authenticator: authenticator, defaults: defaults)
        XCTAssertFalse(relaunched.isEnabled)
        XCTAssertFalse(relaunched.isLocked)
    }

    func testCapabilityLossAfterEnableKeepsContentCovered() async {
        let authenticator = SequencedAuthenticator(
            capability: .biometrics,
            results: [.success, .passcodeNotSet]
        )
        let lock = AppLock(authenticator: authenticator, defaults: defaults)
        let enabled = await lock.setEnabled(true)
        XCTAssertTrue(enabled)

        lock.authenticateAtLaunch()
        await waitUntilAuthenticationFinishes(lock)

        XCTAssertTrue(lock.isEnabled, "Capability loss must not silently disable protection")
        XCTAssertTrue(lock.isLocked, "Sensitive content must remain covered")
        XCTAssertEqual(lock.lastError, BiometricResult.passcodeGuidance)
    }

    func testCancellationLockoutAndFailureRemainDistinct() {
        XCTAssertEqual(LAContextAuthenticator.result(for: .userCancel), .cancelled)
        XCTAssertEqual(
            LAContextAuthenticator.result(for: .biometryLockout),
            .lockout("Biometrics locked out — enter your device passcode.")
        )
        XCTAssertEqual(
            LAContextAuthenticator.result(for: .authenticationFailed),
            .failure("Face ID / Touch ID not recognised.")
        )
        XCTAssertEqual(LAContextAuthenticator.result(for: .passcodeNotSet), .passcodeNotSet)
        XCTAssertNotEqual(
            DeviceOwnerAuthenticationCapability.unavailable("Policy unavailable"),
            .passcodeNotSet
        )
    }

    private func waitUntilAuthenticationFinishes(_ lock: AppLock) async {
        for _ in 0..<100 where lock.isAuthenticating {
            await Task.yield()
        }
    }
}

private struct StubAuthenticator: BiometricAuthenticating {
    let capabilityValue: DeviceOwnerAuthenticationCapability
    let results: [BiometricResult]

    init(capability: DeviceOwnerAuthenticationCapability, results: [BiometricResult]) {
        capabilityValue = capability
        self.results = results
    }

    func capability() async -> DeviceOwnerAuthenticationCapability { capabilityValue }
    func evaluate(reason: String) async -> BiometricResult { results.first ?? .failure("Unexpected evaluation.") }
}

private actor SequencedAuthenticator: BiometricAuthenticating {
    let capabilityValue: DeviceOwnerAuthenticationCapability
    var results: [BiometricResult]

    init(capability: DeviceOwnerAuthenticationCapability, results: [BiometricResult]) {
        capabilityValue = capability
        self.results = results
    }

    func capability() async -> DeviceOwnerAuthenticationCapability { capabilityValue }

    func evaluate(reason: String) async -> BiometricResult {
        results.isEmpty ? .failure("Unexpected evaluation.") : results.removeFirst()
    }
}
