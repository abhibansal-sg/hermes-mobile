import Foundation
import XCTest

final class WorkRepositoryLeaseTests: XCTestCase {
    func testQuarantinedLegacyWorkCannotBeClaimed() async throws {
        let test = try makeWorkRepositoryTestConfiguration()
        defer { try? FileManager.default.removeItem(at: test.directory) }
        let repository = try WorkRepository(configuration: test.configuration)
        let legacy = try workTestScope(serverID: "https://gateway.test", profileID: "default")
        let authority = try AuthorityScopeV1(
            gatewayID: "gw_AAAAAAAAAAAAAAAAAAAAAA",
            profileID: "pf_BBBBBBBBBBBBBBBBBBBBBB",
            authorityEpoch: "ae_CCCCCCCCCCCCCCCCCCCCCC"
        )
        let verified = try WorkScope(
            serverID: "https://gateway.test",
            authority: authority
        )
        let legacyJob = try await repository.enqueue(
            WorkJobInput(kind: .prompt, scope: legacy, text: "old authority")
        )
        let verifiedJob = try await repository.enqueue(
            WorkJobInput(kind: .prompt, scope: verified, text: "current authority")
        )

        let quarantinedCount = try await repository.quarantineLegacyWork(
            serverID: legacy.serverID
        )
        XCTAssertEqual(quarantinedCount, 1)
        let quarantinedJob = try await repository.job(id: legacyJob.jobID)
        XCTAssertEqual(quarantinedJob?.authorityState, .quarantined)
        let claimed = try await repository.claimNextJob(
            owner: "worker", now: Date(), leaseDuration: 30
        )
        XCTAssertEqual(claimed?.jobID, verifiedJob.jobID)
        XCTAssertEqual(claimed?.authorityState, .verified)
    }

    func testReplacingOneAuthorityQuarantinesOnlyThatProfileEpoch() async throws {
        let test = try makeWorkRepositoryTestConfiguration()
        defer { try? FileManager.default.removeItem(at: test.directory) }
        let repository = try WorkRepository(configuration: test.configuration)
        let oldAuthority = try AuthorityScopeV1(
            gatewayID: "gw_AAAAAAAAAAAAAAAAAAAAAA",
            profileID: "pf_BBBBBBBBBBBBBBBBBBBBBB",
            authorityEpoch: "ae_CCCCCCCCCCCCCCCCCCCCCC"
        )
        let siblingAuthority = try AuthorityScopeV1(
            gatewayID: oldAuthority.gatewayID,
            profileID: "pf_DDDDDDDDDDDDDDDDDDDDDD",
            authorityEpoch: "ae_EEEEEEEEEEEEEEEEEEEEEE"
        )
        let oldScope = try WorkScope(serverID: "https://gateway.test", authority: oldAuthority)
        let siblingScope = try WorkScope(serverID: "https://gateway.test", authority: siblingAuthority)
        let oldJob = try await repository.enqueue(
            WorkJobInput(kind: .prompt, scope: oldScope, text: "old profile")
        )
        let siblingJob = try await repository.enqueue(
            WorkJobInput(kind: .prompt, scope: siblingScope, text: "sibling profile")
        )

        let count = try await repository.quarantineAuthority(
            gatewayID: oldAuthority.gatewayID,
            profileID: oldAuthority.profileID,
            authorityEpoch: oldAuthority.authorityEpoch
        )

        XCTAssertEqual(count, 1)
        let quarantined = try await repository.job(id: oldJob.jobID)
        let sibling = try await repository.job(id: siblingJob.jobID)
        let claimed = try await repository.claimNextJob(
            owner: "worker",
            now: Date(),
            leaseDuration: 30
        )
        XCTAssertEqual(quarantined?.authorityState, .quarantined)
        XCTAssertEqual(sibling?.authorityState, .verified)
        XCTAssertEqual(claimed?.jobID, siblingJob.jobID)
    }

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

    func testAppIntentInvocationsKeepStableFIFOIdentity() async throws {
        let test = try makeWorkRepositoryTestConfiguration()
        defer { try? FileManager.default.removeItem(at: test.directory) }
        let repository = try WorkRepository(configuration: test.configuration)
        let start = Date(timeIntervalSince1970: 1_000)
        var inserted: [WorkJob] = []
        for index in 0..<5 {
            inserted.append(try await repository.enqueueAppIntent(
                kind: .askHermes,
                text: "prompt-\(index)",
                now: start.addingTimeInterval(Double(index))
            ))
        }

        let jobs = try await repository.jobs().filter { $0.kind == .appIntent }
        XCTAssertEqual(jobs.map(\.jobID), inserted.map(\.jobID))
        XCTAssertEqual(jobs.map(\.text), (0..<5).map { "prompt-\($0)" })
        XCTAssertEqual(Set(jobs.map(\.clientMessageID)).count, 5)
    }

    func testAppIntentCapacityIsAtomicAcrossWriters() async throws {
        let test = try makeWorkRepositoryTestConfiguration()
        defer { try? FileManager.default.removeItem(at: test.directory) }
        let first = try WorkRepository(configuration: test.configuration)
        let second = try WorkRepository(configuration: test.configuration)

        let results = await withTaskGroup(of: Result<WorkJob, Error>.self) { group in
            for index in 0..<21 {
                let writer = index.isMultiple(of: 2) ? first : second
                group.addTask {
                    do {
                        return .success(try await writer.enqueueAppIntent(
                            kind: .askHermes, text: "writer-\(index)"
                        ))
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var values: [Result<WorkJob, Error>] = []
            for await value in group { values.append(value) }
            return values
        }

        let successes = results.filter { if case .success = $0 { return true }; return false }
        let failures = results.compactMap { result -> WorkRepositoryError? in
            guard case .failure(let error) = result else { return nil }
            return error as? WorkRepositoryError
        }
        XCTAssertEqual(successes.count, 20)
        XCTAssertEqual(failures, [.appIntentQueueFull])
    }

    func testExpiredAppIntentsFreeCapacityTransactionally() async throws {
        let test = try makeWorkRepositoryTestConfiguration()
        defer { try? FileManager.default.removeItem(at: test.directory) }
        let repository = try WorkRepository(configuration: test.configuration)
        let start = Date(timeIntervalSince1970: 2_000)
        for index in 0..<20 {
            _ = try await repository.enqueueAppIntent(
                kind: .openSessions,
                now: start.addingTimeInterval(Double(index))
            )
        }
        let replacement = try await repository.enqueueAppIntent(
            kind: .newSession,
            now: start.addingTimeInterval(WorkRepository.appIntentLifetime + 20)
        )

        let jobs = try await repository.jobs().filter { $0.kind == .appIntent }
        XCTAssertEqual(jobs.filter { $0.state == .expired }.count, 20)
        XCTAssertEqual(jobs.last?.jobID, replacement.jobID)
    }

    func testConcurrentShareAdmissionEnforcesTwentyJobLimit() async throws {
        let (configuration, directory) = try makeWorkRepositoryTestConfiguration()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try WorkRepository(configuration: configuration)
        let second = try WorkRepository(configuration: configuration)
        let now = Date(timeIntervalSince1970: 5_000)
        for index in 0..<19 {
            _ = try await first.enqueueShare(
                WorkJobInput(kind: .share, scope: nil, text: "share-\(index)"),
                now: now
            )
        }

        let results = await withTaskGroup(of: Result<WorkJob, WorkRepositoryError>.self) { group in
            for (repository, text) in [(first, "twenty"), (second, "twenty-one")] {
                group.addTask {
                    do {
                        return .success(try await repository.enqueueShare(
                            WorkJobInput(kind: .share, scope: nil, text: text),
                            now: now
                        ))
                    } catch let error as WorkRepositoryError {
                        return .failure(error)
                    } catch {
                        return .failure(.jobNotFound)
                    }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(results.filter { if case .success = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(
            results.filter {
                if case .failure(.shareQueueFull(let limit)) = $0 { return limit == 20 }
                return false
            }.count,
            1
        )
    }

    func testOversizedShareIsRejectedBeforeWritingAssets() async throws {
        let (configuration, directory) = try makeWorkRepositoryTestConfiguration()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try WorkRepository(configuration: configuration)
        let oversized = Data(count: WorkRepository.shareByteLimit + 1)

        do {
            _ = try await repository.enqueueShare(
                WorkJobInput(kind: .share, scope: nil, text: "too large"),
                assets: [WorkAssetInput(data: oversized, mimeType: "image/jpeg", fileExtension: "jpg")]
            )
            XCTFail("oversized share must be rejected")
        } catch {
            XCTAssertEqual(
                error as? WorkRepositoryError,
                .shareStorageFull(limitBytes: WorkRepository.shareByteLimit)
            )
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: configuration.assetsDirectoryURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(files.isEmpty)
    }

    func testShareExpiryDeletesOnlyUnreferencedAssetsAndScansOrphans() async throws {
        let (configuration, directory) = try makeWorkRepositoryTestConfiguration()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try WorkRepository(configuration: configuration)
        let created = Date()
        let share = try await repository.enqueueShare(
            WorkJobInput(kind: .share, scope: nil, text: "expires"),
            assets: [WorkAssetInput(data: Data("asset".utf8), mimeType: "image/jpeg", fileExtension: "jpg")],
            now: created
        )
        let asset = try await repository.assets(jobID: share.jobID)[0]
        let orphan = configuration.assetsDirectoryURL.appendingPathComponent("orphan.jpg")
        try Data("orphan".utf8).write(to: orphan)
        try FileManager.default.setAttributes(
            [.modificationDate: created.addingTimeInterval(-WorkRepository.orphanAssetGrace - 1)],
            ofItemAtPath: orphan.path
        )

        let expired = try await repository.cleanupShareWork(
            now: created.addingTimeInterval(WorkRepository.shareLifetime + 1)
        )
        let persisted = try await repository.job(id: share.jobID)
        let assetExists = try await repository.assetFileExists(relativePath: asset.relativePath)

        XCTAssertEqual(expired, 1)
        XCTAssertNil(persisted)
        XCTAssertFalse(assetExists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testFinishedWorkRetentionPrunesOldRowsAndAssetsOnly() async throws {
        let (configuration, directory) = try makeWorkRepositoryTestConfiguration()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try WorkRepository(configuration: configuration)
        let old = Date().addingTimeInterval(-20 * 24 * 60 * 60)
        let job = try await repository.enqueue(
            WorkJobInput(kind: .prompt, scope: try workTestScope(), text: "old", createdAt: old),
            assets: [WorkAssetInput(
                data: Data("old-asset".utf8),
                mimeType: "text/plain",
                fileExtension: "txt"
            )]
        )
        try await repository.transitionJob(id: job.jobID, from: .queued, to: .submitting, now: old)
        try await repository.transitionJob(id: job.jobID, from: .submitting, to: .accepted, now: old)
        try await repository.transitionJob(id: job.jobID, from: .accepted, to: .completed, now: old)
        let snapshots = try await repository.jobAssets(jobID: job.jobID)
        let assetPath = try XCTUnwrap(snapshots.first?.asset.relativePath)

        let removed = try await repository.cleanupFinishedWork(now: Date())

        let persisted = try await repository.job(id: job.jobID)
        let assetExists = try await repository.assetFileExists(relativePath: assetPath)
        XCTAssertEqual(removed, 1)
        XCTAssertNil(persisted)
        XCTAssertFalse(assetExists)
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
