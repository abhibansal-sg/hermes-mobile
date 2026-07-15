import XCTest
import UserNotifications
@testable import HermesMobile

@MainActor
final class NotificationAuthorityTests: XCTestCase {
    private var defaults: UserDefaults!
    private var requests: [UNNotificationRequest] = []
    private var haptics: [NotificationService.AlertKind] = []

    override func setUp() {
        super.setUp()
        let suite = "NotificationAuthorityTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        requests = []
        haptics = []
        NotificationService.localRequestSink = { [weak self] in self?.requests.append($0) }
        NotificationService.hapticSink = { [weak self] in self?.haptics.append($0) }
        NotificationService.setDeliveryLedgerForTesting(
            NotificationDeliveryLedger(defaults: defaults, storageKey: "ledger")
        )
        NotificationService.setPresentationContextProvider {
            .init(
                deviceScope: "device-a",
                activeRuntimeId: nil,
                activeStoredId: nil,
                pushIsAuthoritative: true
            )
        }
    }

    override func tearDown() {
        NotificationService.localRequestSink = nil
        NotificationService.hapticSink = nil
        NotificationService.presentationContextProvider = nil
        super.tearDown()
    }

    func testAPNsThenLiveFallbackProducesOneSystemAlert() {
        let alert = correlatedAlert()
        let options = NotificationService.foregroundPresentationOptions(
            userInfo: remoteUserInfo(alert)
        )
        XCTAssertTrue(options.contains(.banner))
        XCTAssertTrue(options.contains(.sound))

        NotificationService.handleLiveAlert(
            alert,
            title: "Approval required",
            body: "Review this",
            deviceScope: "device-a",
            pushIsAuthoritative: false,
            isActiveSession: false
        )
        XCTAssertTrue(requests.isEmpty, "APNs already reserved the logical alert")
    }

    func testLiveFallbackThenAPNsProducesOneSystemAlert() throws {
        let alert = correlatedAlert()
        NotificationService.handleLiveAlert(
            alert,
            title: "Approval required",
            body: "Review this",
            deviceScope: "device-a",
            pushIsAuthoritative: false,
            isActiveSession: false
        )
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.content.userInfo["session_id"] as? String, "runtime-1")
        XCTAssertEqual(request.content.userInfo["stored_session_id"] as? String, "stored-1")
        XCTAssertEqual(request.content.userInfo["gateway_scope"] as? String, "gateway-a")

        let options = NotificationService.foregroundPresentationOptions(
            userInfo: remoteUserInfo(alert)
        )
        XCTAssertTrue(options.isEmpty, "local fallback already reserved the logical alert")
        XCTAssertEqual(requests.count, 1)
    }

    func testHealthyPushRegistrationLeavesAlertOwnershipToAPNs() {
        NotificationService.handleLiveAlert(
            correlatedAlert(),
            title: "Approval required",
            body: "Review this",
            deviceScope: "device-a",
            pushIsAuthoritative: true,
            isActiveSession: false
        )
        XCTAssertTrue(requests.isEmpty)
    }

    func testActiveForegroundSessionGetsHapticWithoutBannerOrSound() {
        let alert = correlatedAlert()
        NotificationService.setPresentationContextProvider {
            .init(
                deviceScope: "device-a",
                activeRuntimeId: "runtime-1",
                activeStoredId: "stored-1",
                pushIsAuthoritative: true
            )
        }

        let options = NotificationService.foregroundPresentationOptions(
            userInfo: remoteUserInfo(alert)
        )
        XCTAssertTrue(options.isEmpty)
        XCTAssertEqual(haptics, [.approval])
    }

    func testActiveLiveThenAPNsProducesOneHapticAndNoAlert() {
        let alert = correlatedAlert()
        NotificationService.setPresentationContextProvider {
            .init(
                deviceScope: "device-a",
                activeRuntimeId: "runtime-1",
                activeStoredId: "stored-1",
                pushIsAuthoritative: true
            )
        }
        NotificationService.handleLiveAlert(
            alert,
            title: "Approval required",
            body: "Review this",
            deviceScope: "device-a",
            pushIsAuthoritative: true,
            isActiveSession: true
        )
        let options = NotificationService.foregroundPresentationOptions(
            userInfo: remoteUserInfo(alert)
        )
        XCTAssertTrue(options.isEmpty)
        XCTAssertEqual(haptics, [.approval])
        XCTAssertTrue(requests.isEmpty)
    }

    func testLedgerIsGatewayDeviceScopedTTLBounded() {
        let ledger = NotificationDeliveryLedger(
            defaults: defaults,
            storageKey: "bounded",
            ttl: 10,
            maximumEntries: 2
        )
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(ledger.claim(namespace: "gateway-a|device-a", eventId: "same", now: start))
        XCTAssertFalse(ledger.claim(namespace: "gateway-a|device-a", eventId: "same", now: start))
        XCTAssertTrue(ledger.claim(namespace: "gateway-b|device-a", eventId: "same", now: start))
        XCTAssertTrue(ledger.claim(namespace: "gateway-a|device-b", eventId: "same", now: start))
        XCTAssertLessThanOrEqual(ledger.entryCount, 2)
        XCTAssertTrue(
            ledger.claim(
                namespace: "gateway-a|device-a",
                eventId: "same",
                now: start.addingTimeInterval(11)
            ),
            "expired entries must not suppress a valid later event"
        )
    }

    private func correlatedAlert() -> NotificationService.CorrelatedAlert {
        .init(
            kind: .approval,
            eventId: "evt-stable-1",
            gatewayScope: "gateway-a",
            sessionId: "runtime-1",
            storedSessionId: "stored-1"
        )
    }

    private func remoteUserInfo(
        _ alert: NotificationService.CorrelatedAlert
    ) -> [AnyHashable: Any] {
        ["hermes": [
            "event_type": alert.kind.rawValue,
            "event_id": alert.eventId,
            "gateway_scope": alert.gatewayScope,
            "session_id": alert.sessionId,
            "stored_session_id": alert.storedSessionId ?? "",
        ]]
    }
}
