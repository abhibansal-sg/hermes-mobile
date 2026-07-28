import XCTest
@testable import HermesMobile

/// DAILY-DRIVER N2 + A3 — `client_message_id` end-to-end idempotency.
///
/// The contract: a durable outbox row gets ONE stable id (UUID) when it is
/// created; that id is PERSISTED in `work_jobs.client_message_id` (NOT NULL) so
/// it survives a process restart; and the SAME id is replayed only when the
/// configured gateway has proved its receipt-dedup seam.
///
/// This file pins the iOS half of that contract — the persistence half (the id
/// survives a process restart) and the replay half (the row's submit closure
/// receives the SAME id on a safe retry).
@MainActor
final class SubmitIdempotencyTests: XCTestCase {
    private struct Harness {
        let repository: WorkRepository
        let scope: WorkScope
        let directory: URL
    }

    private func makeHarness(scopeServerID: String = "https://gateway.test") throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SubmitIdempotency-\(UUID().uuidString)", isDirectory: true)
        let configuration = WorkRepositoryConfiguration(containerURL: directory)
        let repository = try WorkRepository(
            configuration: configuration,
            observation: WorkRepositoryObservation()
        )
        return Harness(
            repository: repository,
            scope: try WorkScope(serverID: scopeServerID, profileID: "default"),
            directory: directory
        )
    }

    func testReceiptProofRequiresMatchingClientMessageIDAndCanReset() {
        let chat = ChatStore()
        chat.observePromptReceipt(clientMessageID: "other", expected: "expected")
        XCTAssertFalse(chat.promptReceiptsObserved)

        chat.observePromptReceipt(clientMessageID: "expected", expected: "expected")
        XCTAssertTrue(chat.promptReceiptsObserved)

        chat.resetPromptReceiptObservation()
        XCTAssertFalse(chat.promptReceiptsObserved)
    }

    private struct AmbiguousFlap: Error {}

    /// The cmid is durable: enqueue a row, drop the repository (process death),
    /// reopen against the SAME database, fetch the row — the cmid is byte-identical.
    /// This is what makes a retry after an app force-close recognizable to the
    /// gateway receipt provider (A3: "survives app force-close").
    func testClientMessageIDSurvivesProcessRestart() async throws {
        let config = try makeHarness()
        defer { try? FileManager.default.removeItem(at: config.directory) }

        let original = try await config.repository.enqueue(WorkJobInput(
            kind: .prompt, scope: config.scope, text: "survive me",
            storedSessionID: "stored-A"
        ))
        let cmid = original.clientMessageID
        XCTAssertFalse(cmid.isEmpty, "client_message_id is minted at enqueue (non-optional)")

        // Drop the in-memory repository — no close API by design (ARC); a fresh
        // instance against the same on-disk DB models a process restart.
        let reopened = try WorkRepository(
            configuration: WorkRepositoryConfiguration(containerURL: config.directory),
            observation: WorkRepositoryObservation()
        )
        let persisted = try await reopened.job(id: original.jobID)
        XCTAssertEqual(persisted?.clientMessageID, cmid,
                       "the stable id is persisted in work_jobs.client_message_id across a reopen")
        XCTAssertEqual(persisted?.state, .queued,
                       "the row itself survives the restart in its pre-submit state")
    }

    /// After receipt support is proven, an ambiguous flap retains the row in
    /// `submitting` and retries with the SAME id.
    func testAmbiguousFlapRetriesWithSameClientMessageID() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let job = try await harness.repository.enqueue(WorkJobInput(
            kind: .prompt, scope: harness.scope, text: "once only", storedSessionID: "stored-A"
        ))

        var submittedIDs: [String] = []
        var nextAttemptShouldFail = true
        let processor = OutboxProcessor(repository: harness.repository, dependencies: .init(
            currentScope: { harness.scope },
            activeStoredSessionID: { "stored-A" },
            isTransportReady: { true },
            canRetryAmbiguousSubmit: { true },
            createDestination: { _ in XCTFail("existing-session job must not create"); throw AmbiguousFlap() },
            resolveRuntime: { _ in "runtime-A" },
            uploadAsset: { _, _ in XCTFail("no assets on a plain prompt"); throw AmbiguousFlap() },
            willSubmit: { _, _ in },
            submit: { submitted, _, _ in
                submittedIDs.append(submitted.clientMessageID)
                if nextAttemptShouldFail {
                    nextAttemptShouldFail = false
                    throw AmbiguousFlap()
                }
                return OutboxSubmitResult(
                    status: "streaming",
                    accepted: true,
                    clientMessageID: submitted.clientMessageID
                )
            },
            processLocalAppIntent: { _ in false },
            retryDelay: { _ in 0.01 }
        ))

        // Attempt 1: submit throws → the row is retained in `submitting` with the
        // `transport_ambiguous` status, cmid unchanged. The gateway may or may
        // not have accepted it; proven receipt support makes replay safe.
        processor.wake()
        await processor.waitUntilIdleForTesting()
        let retained = try await harness.repository.job(id: job.jobID)
        XCTAssertEqual(retained?.state, .submitting,
                       "an ambiguous flap retains the row in submitting for redrive")
        XCTAssertEqual(retained?.lastErrorCode, "transport_ambiguous")
        XCTAssertEqual(retained?.clientMessageID, job.clientMessageID,
                       "the cmid is unchanged after the failed attempt")

        // Attempt 2: the SAME id is replayed. The proven gateway receipt seam
        // recognizes it and suppresses the second turn; here we prove iOS never
        // regenerates the id.
        try? await Task.sleep(for: .milliseconds(30))
        await processor.waitUntilIdleForTesting()
        let completed = try await harness.repository.job(id: job.jobID)
        XCTAssertEqual(completed?.state, .completed)
        XCTAssertEqual(submittedIDs, [job.clientMessageID, job.clientMessageID],
                       "both attempts carried the SAME stable id — never regenerated")

        let all = try await harness.repository.jobs()
        XCTAssertEqual(all.count, 1, "no duplicate row was created on retry")
    }

    func testAmbiguousFlapWithoutReceiptProofDoesNotBlindlyRetry() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let job = try await harness.repository.enqueue(WorkJobInput(
            kind: .prompt, scope: harness.scope, text: "uncertain delivery",
            storedSessionID: "stored-A"
        ))

        var submittedIDs: [String] = []
        let processor = OutboxProcessor(repository: harness.repository, dependencies: .init(
            currentScope: { harness.scope },
            activeStoredSessionID: { "stored-A" },
            isTransportReady: { true },
            createDestination: { _ in throw AmbiguousFlap() },
            resolveRuntime: { _ in "runtime-A" },
            uploadAsset: { _, _ in throw AmbiguousFlap() },
            willSubmit: { _, _ in },
            submit: { submitted, _, _ in
                submittedIDs.append(submitted.clientMessageID)
                throw AmbiguousFlap()
            },
            retryDelay: { _ in 0.01 }
        ))

        processor.wake()
        await processor.waitUntilIdleForTesting()
        try? await Task.sleep(for: .milliseconds(40))
        await processor.waitUntilIdleForTesting()
        processor.wake() // A reconnect-style wake must not replay uncertainty.
        await processor.waitUntilIdleForTesting()

        let retained = try await harness.repository.job(id: job.jobID)
        XCTAssertEqual(submittedIDs, [job.clientMessageID],
                       "without proven receipt dedup, an ambiguous transport loss must not resubmit")
        XCTAssertEqual(retained?.state, .failed)
        XCTAssertEqual(retained?.lastErrorCode, "transport_ambiguous")
        XCTAssertNil(retained?.nextAttemptAt)

        let manualRetry = try await harness.repository.retryFailedJob(id: job.jobID)
        XCTAssertEqual(manualRetry.clientMessageID, job.clientMessageID)
        XCTAssertEqual(manualRetry.state, .queued)
    }
}
