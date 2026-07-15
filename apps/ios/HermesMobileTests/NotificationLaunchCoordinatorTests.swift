import XCTest
@testable import HermesMobile

@MainActor
final class NotificationLaunchCoordinatorTests: XCTestCase {
    private let endpoint = NotificationService.ActionEndpoint(
        baseURL: URL(string: "https://example.test")!, token: "token"
    )

    override func tearDown() {
        NotificationService.tapHandler = nil
        NotificationService.endpointProvider = nil
        super.tearDown()
    }

    func testPreAttachResponseIsBufferedUntilBothDependenciesAttach() {
        let coordinator = NotificationLaunchCoordinator()
        var routed: [NotificationService.Tap] = []
        let tap = NotificationService.Tap.attention(sessionId: "cold")

        coordinator.receive(.tap(tap))
        coordinator.attachTapHandler { routed.append($0) }
        XCTAssertTrue(routed.isEmpty)

        coordinator.attachActionEndpointProvider { self.endpoint }
        XCTAssertEqual(routed, [tap])
    }

    func testBufferedResponseDrainsOnceAndDoubleAttachmentDoesNotReplay() {
        let coordinator = NotificationLaunchCoordinator()
        var routed: [NotificationService.Tap] = []
        let tap = NotificationService.Tap.turnComplete(sessionId: "once")
        coordinator.receive(.tap(tap))

        coordinator.attachTapHandler { routed.append($0) }
        coordinator.attachActionEndpointProvider { self.endpoint }
        coordinator.attachTapHandler { routed.append($0) }
        coordinator.attachActionEndpointProvider { self.endpoint }

        XCTAssertEqual(routed, [tap])
    }

    func testWarmResponseRoutesSynchronouslyExactlyOnce() {
        let coordinator = NotificationLaunchCoordinator()
        var routed: [NotificationService.Tap] = []
        coordinator.attachTapHandler { routed.append($0) }
        coordinator.attachActionEndpointProvider { self.endpoint }

        let tap = NotificationService.Tap.attention(sessionId: "warm")
        coordinator.receive(.tap(tap))

        XCTAssertEqual(routed, [tap])
    }
}
