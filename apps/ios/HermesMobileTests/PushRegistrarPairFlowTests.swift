import UserNotifications
import XCTest
@testable import HermesMobile

@MainActor
final class PushRegistrarPairFlowTests: XCTestCase {

    private var registrar: PushRegistrar { PushRegistrar.shared }
    private let pushDefaultsKeys = [
        DefaultsKeys.pushEnabled,
        DefaultsKeys.pushLastDeviceToken,
        DefaultsKeys.pushLastEvents,
        DefaultsKeys.pushLastEnv,
        DefaultsKeys.notificationsDidRequestAuthorization,
        DefaultsKeys.pushEventApproval,
        DefaultsKeys.pushEventClarify,
        DefaultsKeys.pushEventTurnComplete,
    ]

    override func setUp() async throws {
        try await super.setUp()
        resetRegistrarState()
    }

    override func tearDown() async throws {
        resetRegistrarState()
        try await super.tearDown()
    }

    func testPairRequestsAPNsAndPostsTokenOnceAcrossForeground() async {
        var apnsRegisterCalls = 0
        var postedRegistrations: [(token: String, events: [String]?)] = []

        registrar.authorizationRequester = { _ in .authorized }
        registrar.remoteNotificationsRegistrar = {
            apnsRegisterCalls += 1
        }
        registrar.tokenRegisterOverride = { token, events in
            postedRegistrations.append((token: token, events: events))
            return .success
        }

        // Fresh pair: the push preference is unset, so pair reconciliation defaults
        // it on and asks iOS for an APNs token.
        registrar.ensureRegisteredForPairedGateway()
        await waitUntil(apnsRegisterCalls == 1, "pair should request APNs registration")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: DefaultsKeys.pushEnabled))

        registrar.didRegister(deviceToken: Data([0xde, 0xad, 0xbe, 0xef]))
        await waitUntil(postedRegistrations.count == 1, "first APNs token should POST once")
        XCTAssertEqual(postedRegistrations[0].token, "deadbeef")
        XCTAssertEqual(postedRegistrations[0].events, ["approval", "clarify", "turn_complete"])
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: DefaultsKeys.pushLastDeviceToken),
            "deadbeef"
        )

        // Foreground reconciliation may ask APNs to re-deliver the current token;
        // the registrar must dedupe the server POST after a successful first write.
        registrar.ensureRegisteredForPairedGateway()
        await waitUntil(apnsRegisterCalls == 2, "foreground should re-request APNs registration")
        registrar.didRegister(deviceToken: Data([0xde, 0xad, 0xbe, 0xef]))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(postedRegistrations.count, 1, "unchanged token/events/env must not POST twice")
    }

    func testDeniedAuthorizationDoesNotFakeRegisteredState() async {
        var apnsRegisterCalls = 0

        registrar.authorizationRequester = { _ in .denied }
        registrar.remoteNotificationsRegistrar = {
            apnsRegisterCalls += 1
        }
        registrar.tokenRegisterOverride = { _, _ in
            XCTFail("denied notification access must not POST a token")
            return .success
        }

        registrar.ensureRegisteredForPairedGateway()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(apnsRegisterCalls, 0)
        XCTAssertEqual(SettingsView.notificationPermissionLabel(for: .denied), "Not authorized")
        XCTAssertEqual(SettingsView.pushTokenRegistrationLabel(token: nil), "Not registered")
    }

    func testNotificationToggleReregisterWaitsBehindForegroundRegisterAndWins() async {
        let token = "deadbeef"
        let currentEnv = PushRegistrar.apnsEnvironment
        var invocations: [(token: String, events: [String]?)] = []
        var completions: [(token: String, events: [String]?)] = []
        var firstContinuation: CheckedContinuation<PushTokenPoster.Outcome, Never>?

        UserDefaults.standard.set(true, forKey: DefaultsKeys.pushEnabled)
        UserDefaults.standard.set(token, forKey: DefaultsKeys.pushLastDeviceToken)
        UserDefaults.standard.set(["approval"], forKey: DefaultsKeys.pushLastEvents)
        UserDefaults.standard.set(currentEnv, forKey: DefaultsKeys.pushLastEnv)

        registrar.authorizationRequester = { _ in .denied }
        registrar.setEnabled(true)
        registrar.tokenRegisterOverride = { token, events in
            invocations.append((token: token, events: events))
            if invocations.count == 1 {
                let outcome: PushTokenPoster.Outcome = await withCheckedContinuation { continuation in
                    firstContinuation = continuation
                }
                completions.append((token: token, events: events))
                return outcome
            }
            completions.append((token: token, events: events))
            return .success
        }

        // Foreground APNs re-delivery captures the old event intent (A) and then
        // pauses mid-flight, simulating a slow network response.
        registrar.didRegister(deviceToken: Data([0xde, 0xad, 0xbe, 0xef]))
        await waitUntil(invocations.count == 1, "foreground register should start")
        XCTAssertEqual(invocations[0].events, ["approval", "clarify", "turn_complete"])

        // The user flips a Settings toggle while A is in flight. This is the new
        // latest intent (B), and it must not race A as an independent POST.
        UserDefaults.standard.set(false, forKey: DefaultsKeys.pushEventClarify)
        registrar.reRegisterEvents()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(
            invocations.count,
            1,
            "toggle re-register should wait behind the in-flight foreground register"
        )

        firstContinuation?.resume(returning: .success)
        await waitUntil(completions.count == 2, "foreground and toggle registrations should settle")

        let latestEvents = ["approval", "turn_complete"]
        XCTAssertEqual(invocations.map(\.events), [
            ["approval", "clarify", "turn_complete"],
            latestEvents,
        ])
        XCTAssertEqual(completions.last?.events, latestEvents)
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: DefaultsKeys.pushLastEvents), latestEvents)
        XCTAssertEqual(UserDefaults.standard.string(forKey: DefaultsKeys.pushLastDeviceToken), token)
        XCTAssertEqual(UserDefaults.standard.string(forKey: DefaultsKeys.pushLastEnv), currentEnv)
    }

    private func resetRegistrarState() {
        registrar.authorizationRequester = nil
        registrar.remoteNotificationsRegistrar = nil
        registrar.tokenRegisterOverride = nil
        for key in pushDefaultsKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        registrar.setEnabled(false)
        for key in pushDefaultsKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func waitUntil(
        _ condition: @autoclosure @MainActor () -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<50 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(message, file: file, line: line)
    }
}
