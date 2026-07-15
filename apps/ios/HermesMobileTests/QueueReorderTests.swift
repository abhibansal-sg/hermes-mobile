import XCTest
@testable import HermesMobile

@MainActor
final class QueueReorderTests: XCTestCase {
    private func makeQueue(
        configuration: WorkRepositoryConfiguration? = nil
    ) throws -> (QueueStore, WorkRepository, WorkRepositoryConfiguration, URL) {
        let directory = configuration?.databaseURL.deletingLastPathComponent()
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("QueueReorder-\(UUID().uuidString)", isDirectory: true)
        let resolved = configuration ?? WorkRepositoryConfiguration(containerURL: directory)
        let observation = WorkRepositoryObservation()
        let repository = try WorkRepository(configuration: resolved, observation: observation)
        let scope = try WorkScope(serverID: "https://gateway.test", profileID: "default")
        return (
            QueueStore(repository: repository, observation: observation, scopeProvider: { scope }),
            repository,
            resolved,
            directory
        )
    }

    func testMovePersistsNewOrderAcrossRepositoryRelaunch() async throws {
        let (queue, _, configuration, directory) = try makeQueue()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = await queue.enqueue("a")
        _ = await queue.enqueue("b")
        _ = await queue.enqueue("c")

        await queue.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(queue.items.map(\.text), ["c", "a", "b"])

        let (relaunched, _, _, _) = try makeQueue(configuration: configuration)
        await relaunched.refresh()
        XCTAssertEqual(relaunched.items.map(\.text), ["c", "a", "b"])
    }

    func testMovePreservesSessionAffinityAndClientIdentity() async throws {
        let (queue, _, _, directory) = try makeQueue()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = await queue.enqueue("alpha", storedSessionId: "session-A")
        _ = await queue.enqueue("beta", storedSessionId: "session-B")
        _ = await queue.enqueue("gamma", storedSessionId: "session-C")
        let identities = Dictionary(uniqueKeysWithValues: queue.items.map { ($0.text, $0.clientMessageID) })

        await queue.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        XCTAssertEqual(queue.items.map(\.storedSessionId), ["session-C", "session-A", "session-B"])
        XCTAssertEqual(queue.items.map(\.clientMessageID), queue.items.map { identities[$0.text]! })
    }

    func testClaimedJobCannotBeEditedOrReordered() async throws {
        let (queue, repository, _, directory) = try makeQueue()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = await queue.enqueue("first", storedSessionId: "session-A")
        _ = await queue.enqueue("second", storedSessionId: "session-A")
        let scope = try WorkScope(serverID: "https://gateway.test", profileID: "default")
        let claimed = try await repository.claimNextJob(
            scope: scope,
            owner: "test-owner",
            now: Date(),
            leaseDuration: 60
        )
        XCTAssertNotNil(claimed)

        await queue.update(id: queue.items[0].id, text: "mutated")
        await queue.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        XCTAssertEqual(queue.items.map(\.text), ["first", "second"])
        XCTAssertEqual(queue.items.first?.clientMessageID, claimed?.clientMessageID)
    }

    func testMoveNoOpsForEmptyAndSingleItemQueues() async throws {
        let (queue, _, _, directory) = try makeQueue()
        defer { try? FileManager.default.removeItem(at: directory) }
        await queue.move(fromOffsets: IndexSet(integer: 0), toOffset: 0)
        XCTAssertTrue(queue.items.isEmpty)
        _ = await queue.enqueue("only")
        await queue.move(fromOffsets: IndexSet(integer: 0), toOffset: 0)
        XCTAssertEqual(queue.items.map(\.text), ["only"])
    }
}
