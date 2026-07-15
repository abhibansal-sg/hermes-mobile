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
        NotificationService.approvalActionSender = nil
        NotificationService.clarifyReplySender = nil
        super.tearDown()
    }

    func testKilledLaunchApproveAndDenyUsePersistedProviderWithoutTapAttachment() async {
        let coordinator = NotificationLaunchCoordinator()
        coordinator.attachActionEndpointProvider { self.endpoint }
        var choices: [Bool] = []
        NotificationService.approvalActionSender = { _, _, approve in
            choices.append(approve)
            return .resolved
        }
        let approve = NotificationService.ApprovalActionPayload(
            sessionId: "cold", requestId: "approve-id", storedSessionId: nil,
            destructive: false, approvalTitle: nil
        )
        let deny = NotificationService.ApprovalActionPayload(
            sessionId: "cold", requestId: "deny-id", storedSessionId: nil,
            destructive: false, approvalTitle: nil
        )
        var completions = 0
        coordinator.receive(.approval(true, approve, .init { completions += 1 }))
        coordinator.receive(.approval(false, deny, .init { completions += 1 }))

        for _ in 0..<20 where completions < 2 { await Task.yield() }
        XCTAssertEqual(choices, [true, false])
        XCTAssertEqual(completions, 2)
    }

    func testActionRoutesBeforeTapHandlerAttachesAndDuplicateRequestCompletesOnce() async {
        let coordinator = NotificationLaunchCoordinator()
        coordinator.attachActionEndpointProvider { self.endpoint }
        var sends = 0
        NotificationService.clarifyReplySender = { _, _, _ in
            sends += 1
            return .resolved
        }
        let action = NotificationService.ClarifyReplyActionPayload(
            sessionId: "cold-session", approvalId: "request-1"
        )
        var completions = 0
        coordinator.receive(.reply("first", action, .init { completions += 1 }))
        coordinator.receive(.reply("duplicate", action, .init { completions += 1 }))

        for _ in 0..<20 where completions < 2 { await Task.yield() }
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(completions, 2)
    }

    func testTapDrainsAsSoonAsItsOwnDependencyAttaches() {
        let coordinator = NotificationLaunchCoordinator()
        var routed: [NotificationService.Tap] = []
        let tap = NotificationService.Tap.attention(sessionId: "cold")

        coordinator.receive(.tap(tap))
        coordinator.attachTapHandler { routed.append($0) }
        XCTAssertEqual(routed, [tap])

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
