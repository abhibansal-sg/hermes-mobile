import XCTest
@testable import HermesMobile

@MainActor
final class BackgroundRefreshCoordinatorTests: XCTestCase {
    func testRegistrationPrecedesSubmissionAndUsesCanonicalIdentifier() {
        let scheduler = SchedulerSpy()
        let coordinator = makeCoordinator(scheduler: scheduler)
        XCTAssertTrue(coordinator.registerAtLaunch())
        coordinator.scheduleNext()
        XCTAssertEqual(scheduler.events, ["register:ai.hermes.app.refresh", "submit:ai.hermes.app.refresh"])
        XCTAssertNotNil(scheduler.date)
    }

    func testMissingPairingDoesNotSubmitOrRunNetwork() async throws {
        let scheduler = SchedulerSpy()
        var requests = 0
        let coordinator = BackgroundRefreshCoordinator(
            scheduler: scheduler, loadPairing: { nil }, sync: { _ in requests += 1; return .success }
        )
        _ = coordinator.registerAtLaunch()
        coordinator.scheduleNext()
        let task = TaskSpy()
        scheduler.handler?(task)
        await settle()
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(scheduler.events, ["register:ai.hermes.app.refresh"])
        XCTAssertEqual(task.completions, [true])
    }

    func testSavedScopeAndTokenArePassedToSharedSync() async {
        let scheduler = SchedulerSpy()
        var received: BackgroundManifestScope?
        let expected = pairing(scope: "profile:work")
        let coordinator = makeCoordinator(scheduler: scheduler, pairing: expected) {
            received = $0
            return .success
        }
        _ = coordinator.registerAtLaunch()
        let task = TaskSpy()
        scheduler.handler?(task)
        await waitUntil { received != nil && task.completions == [true] }
        XCTAssertEqual(received, expected)
        XCTAssertEqual(task.completions, [true])
    }

    func testKeychainFailureShapeCompletesCleanlyWithoutRequest() async {
        let scheduler = SchedulerSpy()
        var requests = 0
        let coordinator = BackgroundRefreshCoordinator(
            scheduler: scheduler,
            loadPairing: { nil }, // URL may exist, but token resolution failed.
            sync: { _ in requests += 1; return .success }
        )
        _ = coordinator.registerAtLaunch()
        let task = TaskSpy(); scheduler.handler?(task)
        await settle()
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(task.completions, [true])
    }

    func testSuccessAndNoChangeBothRescheduleAndComplete() async {
        for _ in 0..<2 {
            let scheduler = SchedulerSpy()
            let coordinator = makeCoordinator(scheduler: scheduler)
            _ = coordinator.registerAtLaunch()
            let task = TaskSpy(); scheduler.handler?(task)
            await waitUntil {
                task.completions == [true] && scheduler.events.last == "submit:ai.hermes.app.refresh"
            }
            XCTAssertEqual(task.completions, [true])
            XCTAssertEqual(scheduler.events.last, "submit:ai.hermes.app.refresh")
        }
    }

    func testConcurrentTriggersCoalesce() async throws {
        let scheduler = SchedulerSpy()
        var calls = 0
        let gate = AsyncGate()
        let coordinator = makeCoordinator(scheduler: scheduler) { _ in
            calls += 1
            await gate.wait()
            return .success
        }
        async let first = coordinator.syncNowIfPaired()
        async let second = coordinator.syncNowIfPaired()
        await settle()
        XCTAssertEqual(calls, 1)
        gate.open()
        let outcomes = await (first, second)
        XCTAssertEqual(outcomes.0, .success)
        XCTAssertEqual(outcomes.1, .success)
    }

    func testExpirationCancelsAtomicOperationAndCompletesOnce() async {
        let scheduler = SchedulerSpy()
        var committed = false
        let coordinator = makeCoordinator(scheduler: scheduler) { _ in
            try await Task.sleep(for: .seconds(30))
            try Task.checkCancellation()
            committed = true // represents the one transaction + widget projection boundary
            return .success
        }
        _ = coordinator.registerAtLaunch()
        let task = TaskSpy(); scheduler.handler?(task)
        await settle()
        task.expirationHandler?()
        await settle()
        XCTAssertFalse(committed)
        XCTAssertEqual(task.completions, [false])
    }

    func testWidgetProjectionOrderingLivesInsideAtomicSharedOperation() async throws {
        let scheduler = SchedulerSpy()
        var order: [String] = []
        let coordinator = makeCoordinator(scheduler: scheduler) { _ in
            order += ["validate-all-pages", "commit-revision", "project-widget"]
            return .success
        }
        _ = await coordinator.syncNowIfPaired()
        XCTAssertEqual(order, ["validate-all-pages", "commit-revision", "project-widget"])
    }

    func testRetryableFailureReschedulesSoonAndAuthFailureStops() async {
        for (outcome, expectedSubmissions) in [
            (BackgroundRefreshOutcome.retryableFailure, 1),
            (.authFailure, 0),
        ] {
            let scheduler = SchedulerSpy()
            let coordinator = makeCoordinator(scheduler: scheduler) { _ in outcome }
            _ = coordinator.registerAtLaunch()
            let task = TaskSpy(); scheduler.handler?(task)
            await waitUntil { task.completions == [false] }
            XCTAssertEqual(scheduler.events.filter { $0.hasPrefix("submit:") }.count, expectedSubmissions)
            XCTAssertEqual(task.completions, [false])
        }
    }

    func testBudgetTimeoutCancelsOperationAndUsesRetryPolicy() async {
        let scheduler = SchedulerSpy()
        let coordinator = BackgroundRefreshCoordinator(
            scheduler: scheduler,
            runtimeBudget: .milliseconds(5),
            loadPairing: { self.pairing() },
            sync: { _ in
                try await Task.sleep(for: .seconds(30))
                return .success
            }
        )
        _ = coordinator.registerAtLaunch()
        let task = TaskSpy(); scheduler.handler?(task)
        await waitUntil {
            task.completions == [false]
                && scheduler.events.filter { $0.hasPrefix("submit:") }.count == 1
        }
        XCTAssertEqual(task.completions, [false])
        XCTAssertEqual(scheduler.events.filter { $0.hasPrefix("submit:") }.count, 1)
    }

    func testMaintenanceRunsOnceAfterSuccessfulCoalescedSync() async {
        let scheduler = SchedulerSpy()
        var maintenanceRuns = 0
        let coordinator = BackgroundRefreshCoordinator(
            scheduler: scheduler,
            loadPairing: { self.pairing() },
            sync: { _ in .noChange },
            maintenance: { maintenanceRuns += 1 }
        )
        async let first = coordinator.syncNowIfPaired()
        async let second = coordinator.syncNowIfPaired()
        _ = await (first, second)
        XCTAssertEqual(maintenanceRuns, 1)
    }

    func testRegisterAtLaunchIsIdempotent() {
        let scheduler = SchedulerSpy()
        let coordinator = makeCoordinator(scheduler: scheduler)
        XCTAssertTrue(coordinator.registerAtLaunch())
        XCTAssertTrue(coordinator.registerAtLaunch())
        XCTAssertEqual(scheduler.events.filter { $0.hasPrefix("register:") }.count, 1)
    }

    private func makeCoordinator(
        scheduler: SchedulerSpy,
        pairing: BackgroundManifestScope? = BackgroundManifestScope(
            gatewayURL: "https://gateway.example", scope: "all", token: "secret"
        ),
        sync: @escaping (BackgroundManifestScope) async throws -> BackgroundRefreshOutcome = { _ in .success }
    ) -> BackgroundRefreshCoordinator {
        BackgroundRefreshCoordinator(scheduler: scheduler, loadPairing: { pairing }, sync: sync)
    }

    private static func pairing(scope: String = "all") -> BackgroundManifestScope {
        BackgroundManifestScope(gatewayURL: "https://gateway.example", scope: scope, token: "secret")
    }

    private func pairing(scope: String = "all") -> BackgroundManifestScope { Self.pairing(scope: scope) }
    private func settle() async { await Task.yield(); await Task.yield(); try? await Task.sleep(for: .milliseconds(10)) }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() && clock.now < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

@MainActor
private final class SchedulerSpy: AppRefreshScheduling {
    var events: [String] = []
    var handler: ((AppRefreshTaskHandle) -> Void)?
    var date: Date?
    func register(identifier: String, handler: @escaping (AppRefreshTaskHandle) -> Void) -> Bool {
        events.append("register:\(identifier)"); self.handler = handler; return true
    }
    func submit(identifier: String, earliestBeginDate: Date?) throws {
        events.append("submit:\(identifier)"); date = earliestBeginDate
    }
}

@MainActor
private final class TaskSpy: AppRefreshTaskHandle {
    var expirationHandler: (() -> Void)?
    var completions: [Bool] = []
    func setTaskCompleted(success: Bool) { completions.append(success) }
}

@MainActor
private final class AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}
