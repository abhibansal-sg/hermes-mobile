import LocalAuthentication
import SwiftUI
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

@MainActor
final class PrivacyShieldAppLockTests: XCTestCase {
    private let defaultsKey = DefaultsKeys.appLockEnabled

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        super.tearDown()
    }

    func testBriefInactiveVisitPreservesAuthenticationGracePeriod() async {
        UserDefaults.standard.set(true, forKey: defaultsKey)
        var instant = Date(timeIntervalSince1970: 1_000)
        let authenticator = AuthenticationSpy()
        let lock = AppLock(authenticator: authenticator, now: { instant })

        lock.authenticateAtLaunch()
        await waitUntil { !lock.isLocked }
        let launchCalls = await authenticator.callCount

        lock.handleScenePhase(.inactive)
        instant.addTimeInterval(2)
        lock.handleScenePhase(.active)

        XCTAssertFalse(lock.isLocked)
        XCTAssertFalse(lock.isPrivacyShieldVisible)
        let callsAfterReturn = await authenticator.callCount
        XCTAssertEqual(callsAfterReturn, launchCalls)
    }

    func testReturnAfterGracePeriodKeepsCoverUntilAuthenticationSucceeds() async {
        UserDefaults.standard.set(true, forKey: defaultsKey)
        var instant = Date(timeIntervalSince1970: 2_000)
        let authenticator = AuthenticationSpy()
        let lock = AppLock(authenticator: authenticator, now: { instant })

        lock.authenticateAtLaunch()
        await waitUntil { !lock.isLocked }
        await authenticator.suspendNextEvaluation()

        lock.handleScenePhase(.background)
        instant.addTimeInterval(AppLock.foregroundGracePeriod)
        lock.handleScenePhase(.active)

        XCTAssertTrue(lock.isLocked, "the opaque lock cover must replace the snapshot shield")
        XCTAssertFalse(lock.isPrivacyShieldVisible)
        await authenticator.resolveSuspendedEvaluation()
        await waitUntil { !lock.isLocked }
        XCTAssertFalse(lock.isLocked)
    }

    // GitHub #207: even with App Lock enabled, `.inactive` must not raise the
    // opaque snapshot shield (the live app stays visible during Control Center /
    // notification shade), while `.background` still raises it before the
    // app-switcher snapshot and a post-grace `.active` still re-locks.
    func testEnabledInactiveKeepsAppVisibleWhileBackgroundStillShieldsAndRelocks() async {
        UserDefaults.standard.set(true, forKey: defaultsKey)
        var instant = Date(timeIntervalSince1970: 3_000)
        let authenticator = AuthenticationSpy()
        let lock = AppLock(authenticator: authenticator, now: { instant })

        lock.authenticateAtLaunch()
        await waitUntil { !lock.isLocked }

        lock.handleScenePhase(.inactive)
        XCTAssertFalse(lock.isPrivacyShieldVisible, "#207: .inactive must keep the live app visible")
        XCTAssertFalse(lock.isLocked)

        lock.handleScenePhase(.background)
        XCTAssertTrue(lock.isPrivacyShieldVisible, "app-switcher snapshot must be shielded")

        await authenticator.suspendNextEvaluation()
        instant.addTimeInterval(AppLock.foregroundGracePeriod)
        lock.handleScenePhase(.active)

        XCTAssertFalse(lock.isPrivacyShieldVisible)
        XCTAssertTrue(lock.isLocked, "App Lock re-lock challenge must be preserved")
        await authenticator.resolveSuspendedEvaluation()
        await waitUntil { !lock.isLocked }
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        // A bare `Task.yield()` loop does not reliably drain a cross-actor
        // continuation resume (the suspended biometric evaluation hopping back to
        // the MainActor), so poll on a short real-time sleep instead — deterministic
        // without weakening the assertion.
        for _ in 0..<200 where !predicate() {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(predicate(), file: file, line: line)
    }
}

private actor AuthenticationSpy: BiometricAuthenticating {
    private(set) var callCount = 0
    private var shouldSuspend = false
    private var continuation: CheckedContinuation<BiometricResult, Never>?

    func suspendNextEvaluation() {
        shouldSuspend = true
    }

    func resolveSuspendedEvaluation() async {
        // `authenticate()` calls `evaluate` from a detached Task, so the suspended
        // continuation may not be stored yet when the test asks to resolve. Await
        // it (each yield releases actor isolation so the pending `evaluate` can run
        // and store the continuation) to remove the pre-existing resume-vs-suspend
        // race that otherwise leaves the lock stuck locked.
        while continuation == nil {
            await Task.yield()
        }
        continuation?.resume(returning: .success)
        continuation = nil
    }

    func evaluate(reason: String) async -> BiometricResult {
        callCount += 1
        guard shouldSuspend else { return .success }
        shouldSuspend = false
        return await withCheckedContinuation { continuation = $0 }
    }

    func capability() async -> DeviceOwnerAuthenticationCapability { .biometrics }
}
