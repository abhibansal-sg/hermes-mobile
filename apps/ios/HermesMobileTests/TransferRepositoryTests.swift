import XCTest
import GRDB
@testable import HermesMobile

final class TransferRepositoryTests: XCTestCase {
    func testInsertAndBindTaskCommitsDurableIdentityWithoutCredentials() async throws {
        let db = try DatabaseQueue()
        let repository = try TransferRepository(testDB: db)
        let record = transferRecord(owner: "job-1")
        try await repository.insert(record)
        try await repository.bindTask(transferId: record.id, taskIdentifier: 42)

        let fetched = try await repository.record(id: record.id)
        let stored = try XCTUnwrap(fetched)
        XCTAssertEqual(stored.taskIdentifier, 42)
        XCTAssertEqual(stored.state, .running)
        let columns = try db.read { try Row.fetchOne($0, sql: "SELECT * FROM transfers")!.columnNames }
        XCTAssertFalse(columns.contains { $0.localizedCaseInsensitiveContains("auth") })
        XCTAssertFalse(columns.contains { $0.localizedCaseInsensitiveContains("header") })
        XCTAssertFalse(columns.contains { $0.localizedCaseInsensitiveContains("token") })
    }

    func testOwnerWakeCanBeClaimedExactlyOnce() async throws {
        let repository = try TransferRepository(testDB: DatabaseQueue())
        var record = transferRecord(owner: "owner")
        record.state = .completed
        try await repository.insert(record)
        let first = try await repository.claimOwnerWake(transferId: record.id)
        let second = try await repository.claimOwnerWake(transferId: record.id)
        XCTAssertEqual(first, "owner")
        XCTAssertNil(second)
    }
}

func transferRecord(owner: String? = nil, state: TransferState = .staged,
                    taskIdentifier: Int? = nil, localFile: String? = nil) -> TransferRecord {
    TransferRecord(id: UUID().uuidString, kind: .upload, state: state,
                   remoteURL: "https://example.invalid/upload", localFilePath: localFile,
                   destinationFilePath: nil, taskIdentifier: taskIdentifier,
                   ownerJobId: owner, ownerWakeDelivered: false, responseBody: nil,
                   resumeData: nil, retryCount: 0, nextRetryAt: nil, httpStatus: nil,
                   errorCode: nil, createdAt: 1, updatedAt: 1)
}
