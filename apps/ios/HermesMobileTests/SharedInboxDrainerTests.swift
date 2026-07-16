import XCTest
@testable import HermesMobile

@MainActor
extension SharedInboxDrainerTests {
    private func makeRepository() throws -> (
        directory: URL,
        repository: WorkRepository,
        queue: QueueStore
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedInboxDrainer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let observation = WorkRepositoryObservation()
        let repository = try WorkRepository(
            configuration: WorkRepositoryConfiguration(containerURL: directory),
            observation: observation
        )
        let queue = QueueStore(repository: repository, observation: observation, scopeProvider: { nil })
        return (directory, repository, queue)
    }

    func testDrainBindsUnpairedShareAndPublishesItToOutbox() async throws {
        let setup = try makeRepository()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let share = try await setup.repository.enqueueShare(
            WorkJobInput(kind: .share, scope: nil, text: "shared")
        )
        let scope = try WorkScope(serverID: "server", profileID: "profile")
        let queued = expectation(description: "share projection published")

        SharedInboxDrainer.drain(
            repository: setup.repository,
            scope: scope,
            queue: setup.queue,
            onQueued: { count in
                XCTAssertEqual(count, 1)
                queued.fulfill()
            }
        )

        await fulfillment(of: [queued], timeout: 1)
        let persisted = try await setup.repository.job(id: share.jobID)
        XCTAssertEqual(persisted?.scope, scope)
        XCTAssertEqual(persisted?.state, .queued)
        XCTAssertEqual(setup.queue.items.map(\.kind), [.share])
    }

    func testOverlappingDrainEdgesCoalesce() async throws {
        let setup = try makeRepository()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        _ = try await setup.repository.enqueueShare(
            WorkJobInput(kind: .share, scope: nil, text: "once")
        )
        let scope = try WorkScope(serverID: "server", profileID: "profile")
        let queued = expectation(description: "one drain callback")
        queued.expectedFulfillmentCount = 1
        queued.assertForOverFulfill = true
        var callbacks = 0
        let callback: (Int) -> Void = { _ in
            callbacks += 1
            queued.fulfill()
        }

        SharedInboxDrainer.drain(
            repository: setup.repository,
            scope: scope,
            queue: setup.queue,
            onQueued: callback
        )
        SharedInboxDrainer.drain(
            repository: setup.repository,
            scope: scope,
            queue: setup.queue,
            onQueued: callback
        )

        await fulfillment(of: [queued], timeout: 1)
        XCTAssertEqual(callbacks, 1)
    }

    func testConnectedTransitionInvokesDurableShareDrain() {
        var ensureRegisteredCalls = 0
        var notifyCalls = 0
        var drainCalls = 0

        SharedInboxDrainConnectionTrigger.handle(
            .connected,
            ensureRegisteredForPairedGateway: { ensureRegisteredCalls += 1 },
            notifyInboxDidChange: { notifyCalls += 1 },
            drain: { drainCalls += 1 }
        )

        XCTAssertEqual(ensureRegisteredCalls, 1)
        XCTAssertEqual(notifyCalls, 1)
        XCTAssertEqual(drainCalls, 1)
    }
}
