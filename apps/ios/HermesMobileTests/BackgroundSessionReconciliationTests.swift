import XCTest
import GRDB
@testable import HermesMobile

final class BackgroundSessionReconciliationTests: XCTestCase {
    func testOrphanRowAndMissingFileReachDefinedFailureStates() async throws {
        let repository = try TransferRepository(testDB: DatabaseQueue())
        var orphan = transferRecord(state: .running, taskIdentifier: 999_999,
                                    localFile: "/missing/staged.multipart")
        try await repository.insert(orphan)
        let manager = TransferManager(repository: repository,
                                      sessionIdentifier: "test.reconcile.\(UUID().uuidString)")
        await manager.reconcile()
        let fetched = try await repository.record(id: orphan.id)
        orphan = try XCTUnwrap(fetched)
        XCTAssertEqual(orphan.state, .failed)
        XCTAssertEqual(orphan.errorCode, "missing_file")
    }

    func testRelaunchUsesFrozenIdentifier() {
        XCTAssertEqual(TransferManager.backgroundSessionIdentifier,
                       "ai.hermes.app.transfers.background.v1")
    }
}
