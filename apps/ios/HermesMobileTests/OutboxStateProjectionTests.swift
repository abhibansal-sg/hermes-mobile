import XCTest
@testable import HermesMobile

@MainActor
final class OutboxStateProjectionTests: XCTestCase {
    private func makeQueue() throws -> (QueueStore, WorkRepository, WorkScope, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OutboxProjection-\(UUID().uuidString)", isDirectory: true)
        let observation = WorkRepositoryObservation()
        let repository = try WorkRepository(
            configuration: WorkRepositoryConfiguration(containerURL: directory),
            observation: observation
        )
        let scope = try WorkScope(serverID: "https://gateway.test", profileID: "default")
        return (
            QueueStore(repository: repository, observation: observation, scopeProvider: { scope }),
            repository, scope, directory
        )
    }

    func testRepositoryStatesProjectToRequiredUserFacingStates() async throws {
        let (queue, repository, scope, directory) = try makeQueue()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .queued, text: "waiting"
        ))
        _ = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .uploading, text: "uploading"
        ))
        _ = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .submitting, text: "sending"
        ))
        _ = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .completed, text: "sent"
        ))
        _ = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .failed, text: "failed"
        ))
        _ = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .cancelled, text: "cancelled"
        ))

        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: queue.items.map { ($0.text, $0.displayState.title) }),
            // Wave 1.2 humanized the outbox labels (owner request): "Waiting for
            // connection" and "Needs retry" replace the terse "Waiting"/"Failed — Retry".
            [
                "waiting": "Waiting for connection", "uploading": "Uploading", "sending": "Sending",
                "sent": "Sent", "failed": "Needs retry", "cancelled": "Cancelled",
            ]
        )
    }

    func testInProgressAndIndeterminateRemainVisible() async throws {
        for status in ["in_progress", "indeterminate"] {
            let (queue, repository, scope, directory) = try makeQueue()
            defer { try? FileManager.default.removeItem(at: directory) }
            let job = try await repository.enqueue(WorkJobInput(
                kind: .prompt, scope: scope, state: .submitting, text: status
            ))
            _ = try await repository.claimNextJob(
                scope: scope, owner: "projection", now: Date(), leaseDuration: 60
            )
            try await repository.retainPendingJob(
                id: job.jobID, owner: "projection", status: status
            )

            XCTAssertEqual(queue.items.count, 1)
            XCTAssertEqual(queue.items.first?.displayState,
                           status == "in_progress" ? .inProgress : .indeterminate)
        }
    }

    func testFailedRetryPreservesClientIDAndDeleteRemovesJob() async throws {
        let (queue, repository, scope, directory) = try makeQueue()
        defer { try? FileManager.default.removeItem(at: directory) }
        let job = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .failed, text: "retry me"
        ))
        let id = queue.items[0].id

        await queue.retry(id: id)
        var persisted = try await repository.job(id: job.jobID)
        XCTAssertEqual(persisted?.state, .queued)
        XCTAssertEqual(persisted?.clientMessageID, job.clientMessageID)

        await queue.remove(id: id)
        persisted = try await repository.job(id: job.jobID)
        XCTAssertNil(persisted)
    }

    func testFailedShareIsVisibleRetryableAndUsesComposedBody() async throws {
        let (queue, repository, scope, directory) = try makeQueue()
        defer { try? FileManager.default.removeItem(at: directory) }
        let job = try await repository.enqueueShare(WorkJobInput(
            kind: .share,
            scope: scope,
            state: .failed,
            text: "article",
            sourceURL: "https://example.com",
            comment: "review this"
        ))

        let item = try XCTUnwrap(queue.items.first)
        XCTAssertEqual(item.kind, .share)
        XCTAssertEqual(item.displayState, .failed)
        XCTAssertTrue(item.canRetry)
        XCTAssertFalse(item.isEditable)
        XCTAssertEqual(
            item.text,
            "Shared from iPhone: review this\narticle\nhttps://example.com"
        )

        await queue.retry(id: item.id)
        let persisted = try await repository.job(id: job.jobID)
        XCTAssertEqual(persisted?.state, .queued)
        XCTAssertEqual(persisted?.clientMessageID, job.clientMessageID)
    }
}
