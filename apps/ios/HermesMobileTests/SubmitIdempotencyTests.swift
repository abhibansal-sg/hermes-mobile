import XCTest
@testable import HermesMobile

/// DAILY-DRIVER N2 + A3 — `client_message_id` end-to-end idempotency.
///
/// The contract: a durable outbox row gets ONE stable id (UUID) when it is
/// created; that id is PERSISTED in `work_jobs.client_message_id` (NOT NULL) so
/// it survives a process restart; and the SAME id is replayed on every retry of
/// the row. The relay SUBMIT handler keys its bounded LRU by this id so an
/// ambiguous-flap retry drives exactly one turn (see
/// `test_downstream.test_submit_dedupes_repeat_client_message_id_across_reconnect`).
///
/// This file pins the iOS half of that contract — the persistence half (the id
/// survives a process restart) and the replay half (the row's submit closure
/// receives the SAME id on retry). The retry-driven dedup is the relay's
/// responsibility and is covered by the relay pytest cited above.
@MainActor
final class SubmitIdempotencyTests: XCTestCase {

    private struct AmbiguousFlap: Error {}

    /// The cmid is durable: enqueue a row, drop the repository (process death),
    /// reopen against the SAME database, fetch the row — the cmid is byte-identical.
    /// This is what makes a retry after an app force-close recognizable to the
    /// relay's dedup LRU (A3: "survives app force-close").
    func testClientMessageIDSurvivesProcessRestart() async throws {
        let test = try makeWorkRepositoryTestConfiguration()
        defer { try? FileManager.default.removeItem(at: test.directory) }
        let scope = try workTestScope()

        let original = try await WorkRepository(configuration: test.configuration)
            .enqueue(WorkJobInput(kind: .prompt, scope: scope, text: "survive me",
                                  storedSessionID: "stored-A"))
        let cmid = original.clientMessageID
        XCTAssertFalse(cmid.isEmpty, "client_message_id is minted at enqueue (non-optional)")

        // Drop the in-memory repository — no close API by design (ARC); a fresh
        // instance against the same on-disk DB models a process restart.
        let reopened = try WorkRepository(configuration: test.configuration)
        let persisted = try await reopened.job(id: original.jobID)
        XCTAssertEqual(persisted?.clientMessageID, cmid,
                       "the stable id is persisted in work_jobs.client_message_id across a reopen")
        XCTAssertEqual(persisted?.state, .queued,
                       "the row itself survives the restart in its pre-submit state")
    }

    /// The cmid is replayed: an ambiguous-flap retry (the submit threw after the
    /// relay already ran `prompt_submit`) retains the row in `submitting` and the
    /// next wake resubmits with the SAME id. This is the iOS half the relay LRU
    /// matches against (A3: "no duplicate turn on retry after ambiguous failure").
    func testAmbiguousFlapRetriesWithSameClientMessageID() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SubmitIdempotency-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try WorkRepository(
            configuration: WorkRepositoryConfiguration(containerURL: directory),
            observation: WorkRepositoryObservation()
        )
        let scope = try WorkScope(serverID: "https://gateway.test", profileID: "default")
        let job = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, text: "once only", storedSessionID: "stored-A"
        ))

        var submittedIDs: [String] = []
        var nextAttemptShouldFail = true
        let processor = OutboxProcessor(repository: repository, dependencies: .init(
            currentScope: { scope },
            activeStoredSessionID: { "stored-A" },
            isTransportReady: { true },
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
            processLocalAppIntent: { _ in false }
        ))

        // Attempt 1: submit throws → the row is retained in `submitting` with the
        // `transport_ambiguous` status, cmid unchanged. (The relay may or may not
        // have run prompt_submit — the phone can't tell — so the row must drain
        // again with the SAME id so the relay can dedupe if it did.)
        processor.wake()
        await processor.waitUntilIdleForTesting()
        let retained = try await repository.job(id: job.jobID)
        XCTAssertEqual(retained?.state, .submitting,
                       "an ambiguous flap retains the row in submitting for redrive")
        XCTAssertEqual(retained?.lastErrorCode, "transport_ambiguous")
        XCTAssertEqual(retained?.clientMessageID, job.clientMessageID,
                       "the cmid is unchanged after the failed attempt")

        // Attempt 2: the SAME id is replayed. The relay's LRU (keyed by cmid)
        // recognizes this and suppresses the second turn — covered by the relay
        // pytest; here we only prove the iOS replay.
        processor.wake()
        await processor.waitUntilIdleForTesting()
        let completed = try await repository.job(id: job.jobID)
        XCTAssertEqual(completed?.state, .completed)
        XCTAssertEqual(submittedIDs, [job.clientMessageID, job.clientMessageID],
                       "both attempts carried the SAME stable id — never regenerated")

        let all = try await repository.jobs()
        XCTAssertEqual(all.count, 1, "no duplicate row was created on retry")
    }
}
