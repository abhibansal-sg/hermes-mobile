import Foundation
import XCTest

final class WorkRepositoryLeaseTests: XCTestCase {
    func testClaimIsAtomicAndDeterministic() async throws {
        let test = try makeWorkRepositoryTestConfiguration()
        defer { try? FileManager.default.removeItem(at: test.directory) }
        let firstConnection = try WorkRepository(configuration: test.configuration)
        let secondConnection = try WorkRepository(configuration: test.configuration)
        let createdAt = Date(timeIntervalSince1970: 100)
        let lower = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let higher = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        _ = try await firstConnection.enqueue(WorkJobInput(
            jobID: higher,
            kind: .prompt,
            scope: workTestScope(),
            text: "second",
            createdAt: createdAt
        ))
        _ = try await firstConnection.enqueue(WorkJobInput(
            jobID: lower,
            kind: .prompt,
            scope: workTestScope(),
            text: "first",
            createdAt: createdAt
        ))

        let now = Date(timeIntervalSince1970: 200)
        async let firstClaim = firstConnection.claimNextJob(
            owner: "worker-a", now: now, leaseDuration: 30
        )
        async let secondClaim = secondConnection.claimNextJob(
            owner: "worker-b", now: now, leaseDuration: 30
        )
        let claimed = try await [firstClaim, secondClaim].compactMap { $0 }
        XCTAssertEqual(Set(claimed.map(\.jobID)), Set([
            lower.uuidString.lowercased(), higher.uuidString.lowercased(),
        ]))
        let lowerClaim = try XCTUnwrap(claimed.first { $0.jobID == lower.uuidString.lowercased() })
        XCTAssertEqual(lowerClaim.attemptCount, 1)
    }

    func testExpiredLeaseRecoversWithoutChangingStage() async throws {
        let test = try makeWorkRepositoryTestConfiguration()
        defer { try? FileManager.default.removeItem(at: test.directory) }
        let repositoryA = try WorkRepository(configuration: test.configuration)
        let repositoryB = try WorkRepository(configuration: test.configuration)
        let job = try await repositoryA.enqueue(WorkJobInput(
            kind: .prompt,
            scope: workTestScope(),
            state: .submitting,
            text: "recover"
        ))
        let start = Date(timeIntervalSince1970: 100)
        let first = try await repositoryA.claimNextJob(
            owner: "worker-a", now: start, leaseDuration: 10
        )
        XCTAssertEqual(first?.jobID, job.jobID)
        let beforeExpiry = try await repositoryB.claimNextJob(
            owner: "worker-b",
            now: Date(timeIntervalSince1970: 109),
            leaseDuration: 10
        )
        XCTAssertNil(beforeExpiry)
        let recovered = try await repositoryB.claimNextJob(
            owner: "worker-b",
            now: Date(timeIntervalSince1970: 110),
            leaseDuration: 10
        )
        XCTAssertEqual(recovered?.jobID, job.jobID)
        XCTAssertEqual(recovered?.state, .submitting)
        XCTAssertEqual(recovered?.attemptCount, 2)
    }

    func testStateTransitionRequiresExpectedStateAndLeaseOwner() async throws {
        let test = try makeWorkRepositoryTestConfiguration()
        defer { try? FileManager.default.removeItem(at: test.directory) }
        let repository = try WorkRepository(configuration: test.configuration)
        let job = try await repository.enqueue(WorkJobInput(
            kind: .prompt,
            scope: workTestScope(),
            text: "transition"
        ))
        _ = try await repository.claimNextJob(
            owner: "owner", now: Date(), leaseDuration: 30
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await repository.transitionJob(
                id: job.jobID, from: .queued, to: .submitting, owner: "other"
            )
        }
        let submitting = try await repository.transitionJob(
            id: job.jobID, from: .queued, to: .submitting, owner: "owner"
        )
        XCTAssertEqual(submitting.state, .submitting)
    }

    func testAssetSurvivesUntilDraftAndJobReferencesAreGone() async throws {
        let test = try makeWorkRepositoryTestConfiguration()
        defer { try? FileManager.default.removeItem(at: test.directory) }
        let repository = try WorkRepository(configuration: test.configuration)
        let job = try await repository.enqueue(
            WorkJobInput(kind: .share, scope: nil, text: "asset"),
            assets: [WorkAssetInput(
                data: Data("bytes".utf8), mimeType: "image/jpeg", fileExtension: "jpg"
            )]
        )
        let jobAssets = try await repository.assets(jobID: job.jobID)
        let asset = try XCTUnwrap(jobAssets.first)
        let draft = try await repository.upsertDraft(
            scope: workTestScope(), contextKey: "new", text: "draft"
        )
        try await repository.attachAsset(asset.assetID, toDraft: draft.draftID, ordinal: 0)

        try await repository.deleteJob(id: job.jobID)
        let existsAfterJobDelete = try await repository.assetFileExists(relativePath: asset.relativePath)
        XCTAssertTrue(existsAfterJobDelete)
        try await repository.deleteDraft(id: draft.draftID)
        let existsAfterDraftDelete = try await repository.assetFileExists(relativePath: asset.relativePath)
        XCTAssertFalse(existsAfterDraftDelete)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        // Expected.
    }
}
