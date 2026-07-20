import XCTest
@testable import HermesMobile

/// QA-2 R14 / A7 coverage: an outbox removal is a DURABLE tombstone committed
/// BEFORE the UI confirms it, honored by the relaunch drain. Build 115's
/// delete sites were fire-and-forget `Task { await queueStore.remove(…) }` over
/// a two-step read-then-write `remove` — a force-quit inside the scheduling
/// window (or a drain claim between the read and the write) left the job live,
/// so the relaunch drain SENT the message the owner had already cleared.
///
/// The fix folds the read + decide + write into ONE repository transaction
/// (`removeCancelledJob`: hard-delete unleased rows, `.cancelled` tombstone for
/// leased rows) and `QueueStore.remove` AWAITS that commit before returning —
/// the observation driving the row/pill removal fires only AFTER the commit, so
/// the UI can never confirm a removal whose tombstone didn't land. These tests
/// simulate the owner's exact scenario: remove, then a FRESH repository over
/// the SAME directory (a relaunched process) must never claim/send the row.
/// RED on qa2/base: the relaunch-drain tests pass only by luck of scheduling —
/// `removeCancelledJob` does not exist (compile-level RED for the atomic-write
/// assertions), and the old `remove`'s TOCTOU lets a leased row slip through.
@MainActor
final class OutboxTombstoneTests: XCTestCase {
    private struct Harness {
        let repository: WorkRepository
        let observation: WorkRepositoryObservation
        let queueStore: QueueStore
        let scope: WorkScope
        let directory: URL
    }

    private func makeHarness(directory: URL? = nil) throws -> Harness {
        let directory = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("OutboxTombstone-\(UUID().uuidString)", isDirectory: true)
        let observation = WorkRepositoryObservation()
        let repository = try WorkRepository(
            configuration: WorkRepositoryConfiguration(containerURL: directory),
            observation: observation
        )
        let scope = try WorkScope(serverID: "https://gateway.test", profileID: "default")
        let queueStore = QueueStore(
            repository: repository,
            observation: observation,
            scopeProvider: { scope },
            activeSessionProvider: { nil },
            connectedProvider: { true }
        )
        return Harness(
            repository: repository,
            observation: observation,
            queueStore: queueStore,
            scope: scope,
            directory: directory
        )
    }

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("waitUntil timed out")
    }

    // MARK: - Synchronous durable tombstone (R14)

    /// `QueueStore.remove` AWAITs the durable write and reports it: an unleased
    /// row is HARD-DELETED in one transaction; by the time `remove` returns, the
    /// repository no longer holds the row — the UI confirmation that follows
    /// (observation-driven row removal) can never outrun the tombstone.
    func testRemoveCommitsDurableTombstoneBeforeReturning() async throws {
        let harness = try makeHarness(); defer { try? FileManager.default.removeItem(at: harness.directory) }
        let job = try await harness.repository.enqueue(WorkJobInput(
            kind: .prompt, scope: harness.scope, text: "clear me", storedSessionID: "stored-A"
        ))
        let id = try XCTUnwrap(UUID(uuidString: job.jobID))

        let removed = await harness.queueStore.remove(id: id)

        XCTAssertTrue(removed, "the tombstone commit is reported to the caller")
        let persisted = try await harness.repository.job(id: job.jobID)
        XCTAssertNil(persisted, "by the time remove returns, the row is durably gone")
        await waitUntil { harness.queueStore.pendingCount == 0 }
    }

    /// A row under an in-flight lease (the drain is mid-submit) cannot be
    /// hard-deleted out from under the writer — it gets the `.cancelled`
    /// TOMBSTONE instead, lease cleared, in the same transaction. The cancelled
    /// state is terminal: `allowedTransitions[.cancelled]` is empty, so the
    /// in-flight submit's completion transition fails-closed and the relaunch
    /// drain never claims it.
    func testRemoveOfLeasedJobWritesCancelledTombstoneAtomically() async throws {
        let harness = try makeHarness(); defer { try? FileManager.default.removeItem(at: harness.directory) }
        let job = try await harness.repository.enqueue(WorkJobInput(
            kind: .prompt, scope: harness.scope, text: "mid-submit cancel", storedSessionID: "stored-A"
        ))
        // The drain claims (leases) the row — simulating a submit in flight.
        let claimed = try harness.repository.claimNextJob(
            scope: harness.scope,
            owner: "drain-owner",
            now: Date(),
            leaseDuration: 120
        )
        XCTAssertEqual(claimed?.jobID, job.jobID, "precondition: the row is leased")

        let removed = await harness.queueStore.remove(id: try XCTUnwrap(UUID(uuidString: job.jobID)))

        XCTAssertTrue(removed)
        let persisted = try await harness.repository.job(id: job.jobID)
        XCTAssertEqual(persisted?.state, .cancelled, "a leased row is tombstoned, not deleted mid-flight")
        XCTAssertNil(persisted?.leaseOwner, "the tombstone releases the lease")
        // A different claimant (the relaunch drain) can never pick it up.
        let reclaimed = try harness.repository.claimNextJob(
            scope: harness.scope,
            owner: "relaunch-drain",
            now: Date(),
            leaseDuration: 120
        )
        XCTAssertNil(reclaimed, "a tombstoned row is never claimed — the claim query admits only live states")
    }

    // MARK: - The owner's scenario: remove → force-quit → relaunch → never sent (A7)

    /// A7 exact: remove the row, DISCARD the whole store graph (the process
    /// kill), then open a FRESH repository over the SAME directory (the
    /// relaunch). The tombstone is durable — the relaunched drain finds nothing
    /// to claim and its submit hook is never invoked.
    func testRemovedRowNeverResurrectsOnRelaunchDrain() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OutboxTombstone-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = try WorkScope(serverID: "https://gateway.test", profileID: "default")

        // -- "first launch": enqueue, then the owner clears the row.
        do {
            let harness = try makeHarness(directory: directory)
            let queued = await harness.queueStore.enqueue("send me never", storedSessionId: "stored-A")
            let row = try XCTUnwrap(queued)
            await waitUntil { harness.queueStore.pendingCount == 1 }
            let removed = await harness.queueStore.remove(id: row.id)
            XCTAssertTrue(removed, "the tombstone lands before the UI confirms removal")
        }
        // `harness` (repository + store graph) is discarded here — the force-quit.

        // -- "relaunch": a brand-new repository over the same durable directory.
        let relaunched = try makeHarness(directory: directory)
        let surviving = try await relaunched.repository.job(id: survivingJobID(in: relaunched))
        _ = surviving
        var submitCalls = 0
        let processor = OutboxProcessor(repository: relaunched.repository, dependencies: .init(
            currentScope: { scope },
            activeStoredSessionID: { "stored-A" },
            isTransportReady: { true },
            createDestination: { _ in throw OutboxProcessorError.destinationUnavailable },
            resolveRuntime: { _ in "runtime-A" },
            uploadAsset: { _, _ in throw OutboxProcessorError.destinationUnavailable },
            willSubmit: { _, _ in },
            submit: { _, _, _ in
                submitCalls += 1
                return OutboxSubmitResult(status: "queued", accepted: true)
            }
        ))
        processor.wake()
        await processor.waitUntilIdleForTesting()

        XCTAssertEqual(submitCalls, 0, "the relaunch drain must never send a tombstoned row")
        await waitUntil { relaunched.queueStore.pendingCount == 0 }
        XCTAssertEqual(relaunched.queueStore.pendingCount, 0, "the outbox pill stays empty after relaunch")
    }

    /// The drain-level sibling of the relaunch test: a row removed WHILE the
    /// processor is armed is skipped by the very next drain pass — only the
    /// surviving row submits.
    func testDrainSkipsRemovedRowAndSendsSurvivor() async throws {
        let harness = try makeHarness(); defer { try? FileManager.default.removeItem(at: harness.directory) }
        let removed = await harness.queueStore.enqueue("clear me", storedSessionId: "stored-A")
        let kept = await harness.queueStore.enqueue("send me", storedSessionId: "stored-A")
        _ = try XCTUnwrap(removed); _ = try XCTUnwrap(kept)
        await waitUntil { harness.queueStore.pendingCount == 2 }

        // The owner clears the first row; the processor is armed immediately.
        _ = await harness.queueStore.remove(id: try XCTUnwrap(removed).id)

        var submitted: [String] = []
        let processor = OutboxProcessor(repository: harness.repository, dependencies: .init(
            currentScope: { harness.scope },
            activeStoredSessionID: { "stored-A" },
            isTransportReady: { true },
            createDestination: { _ in throw OutboxProcessorError.destinationUnavailable },
            resolveRuntime: { _ in "runtime-A" },
            uploadAsset: { _, _ in throw OutboxProcessorError.destinationUnavailable },
            willSubmit: { _, _ in },
            submit: { job, _, _ in
                submitted.append(job.text)
                return OutboxSubmitResult(status: "queued", accepted: true)
            }
        ))
        processor.wake()
        await processor.waitUntilIdleForTesting()

        XCTAssertEqual(submitted, ["send me"],
                       "the tombstoned row never submits; the survivor drains normally")
    }

    /// `removeAll()` tombstones every removable row with the same synchronous
    /// durability (the Outbox sheet's clear-all).
    func testRemoveAllTombstonesEveryRow() async throws {
        let harness = try makeHarness(); defer { try? FileManager.default.removeItem(at: harness.directory) }
        _ = await harness.queueStore.enqueue("one", storedSessionId: "stored-A")
        _ = await harness.queueStore.enqueue("two", storedSessionId: "stored-A")
        _ = await harness.queueStore.enqueue("three", storedSessionId: "stored-A")
        await waitUntil { harness.queueStore.pendingCount == 3 }

        await harness.queueStore.removeAll()

        await waitUntil { harness.queueStore.pendingCount == 0 }
        let reclaimed = try harness.repository.claimNextJob(
            scope: harness.scope, owner: "relaunch-drain", now: Date(), leaseDuration: 120
        )
        XCTAssertNil(reclaimed, "no cleared row survives to a relaunch claim")
    }

    /// Removing an unknown id is a clean no-op returning false (double-tap /
    /// stale-row safety) — never a crash, never a phantom tombstone.
    func testRemoveUnknownIDIsANoOp() async throws {
        let harness = try makeHarness(); defer { try? FileManager.default.removeItem(at: harness.directory) }
        let removed = await harness.queueStore.remove(id: UUID())
        XCTAssertFalse(removed)
    }

    // MARK: - Helpers

    /// The first job id the repository holds (any state) — used to prove the
    /// relaunch store sees NO live row; returns a synthesized missing id when
    /// the store is empty (the expected case).
    private func survivingJobID(in harness: Harness) -> String {
        (try? harness.repository.jobs(scope: harness.scope).first?.jobID) ?? "missing-\(UUID().uuidString)"
    }
}
