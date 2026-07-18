import XCTest
@testable import HermesMobile

/// WhatsApp-style send states (Lane C, C1/C2). Pins the per-bubble delivery
/// projection (`delivery(forClientMessageID:)`), the backlog pill gate
/// (`hasBacklog`/`isBacklogged`), and the Resend/Delete seams — all correlated
/// to the durable outbox row by the shared `clientMessageID`, without
/// duplicating rows.
@MainActor
final class OutboxSendStateTests: XCTestCase {
    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private func makeQueue(
        activeSession: Box<String?> = Box(nil),
        connected: Box<Bool> = Box(true)
    ) throws -> (QueueStore, WorkRepository, WorkScope, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OutboxSendState-\(UUID().uuidString)", isDirectory: true)
        let observation = WorkRepositoryObservation()
        let repository = try WorkRepository(
            configuration: WorkRepositoryConfiguration(containerURL: directory),
            observation: observation
        )
        let scope = try WorkScope(serverID: "https://gateway.test", profileID: "default")
        let queue = QueueStore(
            repository: repository,
            observation: observation,
            scopeProvider: { scope },
            activeSessionProvider: { activeSession.value },
            connectedProvider: { connected.value }
        )
        return (queue, repository, scope, directory)
    }

    // MARK: - C1: per-bubble delivery state

    func testHealthyInTransitSendShowsNoBadgeWithinThreshold() async throws {
        let (queue, repository, scope, directory) = try makeQueue()
        defer { try? FileManager.default.removeItem(at: directory) }
        let job = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .submitting, text: "hi", storedSessionID: "A"
        ))
        let created = try XCTUnwrap(queue.items.first).createdAt
        // Age 0, connected → in transit, no badge.
        XCTAssertEqual(queue.delivery(forClientMessageID: job.clientMessageID, now: created), .inTransit)
    }

    func testUndeliveredCrossesToFailedAtThreshold() async throws {
        let (queue, repository, scope, directory) = try makeQueue()
        defer { try? FileManager.default.removeItem(at: directory) }
        let job = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .submitting, text: "stuck", storedSessionID: "A"
        ))
        let item = try XCTUnwrap(queue.items.first)
        let created = item.createdAt

        // Just before the boundary: still healthy.
        let justBefore = created.addingTimeInterval(QueueStore.stuckThreshold - 0.01)
        XCTAssertEqual(queue.delivery(forClientMessageID: job.clientMessageID, now: justBefore), .inTransit)

        // At/after the boundary: stuck → failed badge, carrying the row id.
        let atBoundary = created.addingTimeInterval(QueueStore.stuckThreshold)
        XCTAssertEqual(
            queue.delivery(forClientMessageID: job.clientMessageID, now: atBoundary),
            .failed(id: item.id)
        )
    }

    func testQueuedWhileOfflineIsFailedImmediately() async throws {
        let connected = Box(false)
        let (queue, repository, scope, directory) = try makeQueue(connected: connected)
        defer { try? FileManager.default.removeItem(at: directory) }
        let job = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .queued, text: "offline", storedSessionID: "A"
        ))
        let item = try XCTUnwrap(queue.items.first)
        // Offline → stuck at age 0, independent of the threshold.
        XCTAssertEqual(
            queue.delivery(forClientMessageID: job.clientMessageID, now: item.createdAt),
            .failed(id: item.id)
        )
        // Reconnecting within the threshold clears the badge back to in-transit.
        connected.value = true
        XCTAssertEqual(
            queue.delivery(forClientMessageID: job.clientMessageID, now: item.createdAt),
            .inTransit
        )
    }

    func testTerminalFailureAndRetryWaitAreFailedWhileConnected() async throws {
        for state in [WorkJobState.failed, .retryWait] {
            let (queue, repository, scope, directory) = try makeQueue()
            defer { try? FileManager.default.removeItem(at: directory) }
            let job = try await repository.enqueue(WorkJobInput(
                kind: .prompt, scope: scope, state: state, text: "err", storedSessionID: "A"
            ))
            let item = try XCTUnwrap(queue.items.first)
            // Age 0, connected — but a prior attempt already errored → failed badge.
            XCTAssertEqual(
                queue.delivery(forClientMessageID: job.clientMessageID, now: item.createdAt),
                .failed(id: item.id),
                "state \(state) must show the failed badge"
            )
        }
    }

    func testDeliveredRowClearsBadge() async throws {
        let (queue, repository, scope, directory) = try makeQueue()
        defer { try? FileManager.default.removeItem(at: directory) }
        let job = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .submitting, text: "done", storedSessionID: "A"
        ))
        // Even long past the threshold, delivery removes the badge.
        let late = Date().addingTimeInterval(3600)
        XCTAssertNotEqual(queue.delivery(forClientMessageID: job.clientMessageID, now: late), .none)

        _ = try await repository.transitionJob(id: job.jobID, from: .submitting, to: .accepted)
        XCTAssertEqual(queue.delivery(forClientMessageID: job.clientMessageID, now: late), .none)

        _ = try await repository.transitionJob(id: job.jobID, from: .accepted, to: .completed)
        XCTAssertEqual(queue.delivery(forClientMessageID: job.clientMessageID, now: late), .none)
    }

    func testInProgressAndIndeterminateAreNotFailed() async throws {
        for status in ["in_progress", "indeterminate"] {
            let (queue, repository, scope, directory) = try makeQueue()
            defer { try? FileManager.default.removeItem(at: directory) }
            let job = try await repository.enqueue(WorkJobInput(
                kind: .prompt, scope: scope, state: .submitting, text: status, storedSessionID: "A"
            ))
            _ = try await repository.claimNextJob(
                scope: scope, owner: "t", now: Date(), leaseDuration: 60
            )
            try await repository.retainPendingJob(id: job.jobID, owner: "t", status: status)
            // Reached-server-but-resolving is protocol truth, not a failed send —
            // no red badge even past the threshold.
            let late = Date().addingTimeInterval(3600)
            XCTAssertEqual(
                queue.delivery(forClientMessageID: job.clientMessageID, now: late), .inTransit
            )
        }
    }

    func testLeasedInFlightSendIsNotStuckPastThreshold() async throws {
        // Regression (leased-in-flight): a message queued while offline that only
        // begins submitting after reconnect can be leased and actively in flight
        // while its enqueue-relative age already exceeds `stuckThreshold`. It must
        // NOT show the failed badge (nor wire Delete / the pill) mid-request —
        // cancelling here would drop a send the gateway is about to accept, then
        // the accept transition would be lost (leaseLost) against a vanished echo.
        for state in [WorkJobState.submitting, .uploading] {
            let (queue, repository, scope, directory) = try makeQueue()
            defer { try? FileManager.default.removeItem(at: directory) }
            let job = try await repository.enqueue(WorkJobInput(
                kind: .prompt, scope: scope, state: state, text: "draining", storedSessionID: "A"
            ))
            // A live drain claims the row: lease owner set, request in flight.
            // claimNextJob does not itself republish the observation, so refresh
            // the store's snapshot to reflect the lease before asserting.
            _ = try await repository.claimNextJob(
                scope: scope, owner: "drain", now: Date(), leaseDuration: 60
            )
            try await repository.refreshObservation()
            let item = try XCTUnwrap(queue.items.first)
            XCTAssertTrue(item.isClaimed, "precondition: the row is leased and in flight (\(state))")

            // Far past the threshold, but leased and in flight → still in transit.
            let late = item.createdAt.addingTimeInterval(QueueStore.stuckThreshold + 3600)
            XCTAssertEqual(
                queue.delivery(forClientMessageID: job.clientMessageID, now: late),
                .inTransit,
                "a leased in-flight \(state) must not flip to the failed badge on age alone"
            )
            // No backlog pill and no user-facing Delete affordance while in flight.
            XCTAssertFalse(queue.isBacklogged(now: late), "no pill for a leased in-flight \(state)")
            XCTAssertFalse(item.canDelete, "a leased in-flight \(state) is not user-deletable")
        }
    }

    func testUnleasedSubmittingStillStuckPastThreshold() async throws {
        // Guard the narrowness of the exclusion: a `.submitting` row with NO lease
        // owner (a drain that died mid-submit, nothing re-driving it) is genuinely
        // stuck and must still surface the failed badge past the threshold.
        let (queue, repository, scope, directory) = try makeQueue()
        defer { try? FileManager.default.removeItem(at: directory) }
        let job = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .submitting, text: "orphaned", storedSessionID: "A"
        ))
        let item = try XCTUnwrap(queue.items.first)
        XCTAssertFalse(item.isClaimed, "precondition: no lease owner")
        let atBoundary = item.createdAt.addingTimeInterval(QueueStore.stuckThreshold)
        XCTAssertEqual(
            queue.delivery(forClientMessageID: job.clientMessageID, now: atBoundary),
            .failed(id: item.id),
            "an unleased submitting row is not in flight — age still marks it stuck"
        )
    }

    func testUnknownClientIDHasNoBadge() async throws {
        let (queue, _, _, directory) = try makeQueue()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(queue.delivery(forClientMessageID: "nope", now: Date()), .none)
    }

    // MARK: - C1: Resend / Delete seams

    func testResendFailedRequeuesSameRow() async throws {
        let (queue, repository, scope, directory) = try makeQueue()
        defer { try? FileManager.default.removeItem(at: directory) }
        let job = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .failed, text: "retry", storedSessionID: "A"
        ))
        let id = try XCTUnwrap(queue.items.first).id
        await queue.resend(id: id)
        let persisted = try await repository.job(id: job.jobID)
        XCTAssertEqual(persisted?.state, .queued, "resend requeues in place")
        XCTAssertEqual(persisted?.clientMessageID, job.clientMessageID, "same row, same client id")
    }

    func testResendRetryWaitClearsBackoffAndRequeues() async throws {
        let (queue, repository, scope, directory) = try makeQueue()
        defer { try? FileManager.default.removeItem(at: directory) }
        let job = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .retryWait, text: "kick", storedSessionID: "A"
        ))
        let id = try XCTUnwrap(queue.items.first).id
        await queue.resend(id: id)
        let persisted = try await repository.job(id: job.jobID)
        XCTAssertEqual(persisted?.state, .queued)
        XCTAssertNil(persisted?.nextAttemptAt, "backoff cleared so the next drain claims it now")
        XCTAssertEqual(persisted?.clientMessageID, job.clientMessageID)
    }

    func testDeleteCancelsRowAndRemovesEcho() async throws {
        let (queue, repository, scope, directory) = try makeQueue()
        defer { try? FileManager.default.removeItem(at: directory) }
        let job = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .failed, text: "bye", storedSessionID: "A"
        ))
        let id = try XCTUnwrap(queue.items.first).id

        // The transcript echo carries the same client id.
        let chat = ChatStore()
        chat.messages = [ChatMessage(role: .user, clientMessageID: job.clientMessageID, text: "bye")]

        await queue.remove(id: id)
        chat.removeLocalEcho(clientMessageID: job.clientMessageID)

        // Failed rows are deleted outright (never leased) — gone from durable store.
        let persisted = try await repository.job(id: job.jobID)
        XCTAssertNil(persisted)
        XCTAssertTrue(chat.messages.isEmpty, "the local echo is removed from the transcript")
    }

    // MARK: - C2: backlog pill semantics

    func testHealthySendNeverSurfacesPill() async throws {
        let box = Box<String?>("A")
        let (queue, repository, scope, directory) = try makeQueue(activeSession: box)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .submitting, text: "hi", storedSessionID: "A"
        ))
        let created = try XCTUnwrap(queue.items.first).createdAt
        // In transit and within threshold → no pill, even though it is pending.
        XCTAssertFalse(queue.isBacklogged(now: created))
        XCTAssertEqual(queue.pendingCount, 1, "the row is still pending / in the sheet")
        // Past the threshold it becomes backlog.
        XCTAssertTrue(queue.isBacklogged(now: created.addingTimeInterval(QueueStore.stuckThreshold)))
    }

    func testOfflineBacklogInSessionAShowsPillInAOnly() async throws {
        let box = Box<String?>("A")
        let connected = Box(false)
        let (queue, repository, scope, directory) = try makeQueue(activeSession: box, connected: connected)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .queued, text: "offline-A", storedSessionID: "A"
        ))
        let now = try XCTUnwrap(queue.items.first).createdAt

        // Composer on A: offline-queued row is backlog → pill shows.
        XCTAssertTrue(queue.isBacklogged(now: now))
        // Switch the composer to B: A's backlog is out of scope → no pill in B.
        box.value = "B"
        XCTAssertFalse(queue.isBacklogged(now: now))
        // Back to A: pill returns.
        box.value = "A"
        XCTAssertTrue(queue.isBacklogged(now: now))
    }

    func testPillCountAgreesWithSheetWhenSurfaced() async throws {
        let box = Box<String?>("A")
        let connected = Box(false)
        let (queue, repository, scope, directory) = try makeQueue(activeSession: box, connected: connected)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .queued, text: "a1", storedSessionID: "A"
        ))
        _ = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .submitting, text: "a2", storedSessionID: "A"
        ))
        // When the pill is warranted, its count is the full session pending set
        // (== the Outbox sheet's rows), so pill and sheet never diverge.
        XCTAssertTrue(queue.isBacklogged(now: Date()))
        XCTAssertEqual(queue.pendingCount, queue.activeItems.count)
        XCTAssertEqual(queue.pendingCount, 2)
    }

    // MARK: - Lane C fix 2: human-readable Outbox row labels

    /// Every Outbox row label is plain words the owner can act on — no raw
    /// internal state name (notably "Indeterminate") ever reaches the sheet.
    func testOutboxRowLabelsAreHumanReadable() {
        typealias State = QueueStore.QueuedPrompt.DisplayState
        XCTAssertEqual(State.waiting.title, "Waiting for connection")
        XCTAssertEqual(State.uploading.title, "Uploading")
        XCTAssertEqual(State.sending.title, "Sending")
        XCTAssertEqual(State.sent.title, "Sent")
        XCTAssertEqual(State.failed.title, "Needs retry")
        XCTAssertEqual(State.cancelled.title, "Cancelled")
        XCTAssertEqual(State.inProgress.title, "In progress")
        // Reached-server-but-resolving reads as an ordinary in-flight send.
        XCTAssertEqual(State.indeterminate.title, "Sending")

        let allStates: [State] = [
            .waiting, .uploading, .sending, .sent, .failed, .cancelled, .inProgress, .indeterminate,
        ]
        for state in allStates {
            XCTAssertFalse(
                state.title.contains("Indeterminate"),
                "no raw internal state name may surface in the Outbox sheet"
            )
        }
    }

    // MARK: - Lane C fix 3: red error line reserved for genuine failures

    /// A merely-queued / retrying / indeterminate row must not paint red — only a
    /// terminal failure surfaces its raw error line in the Outbox sheet.
    func testOnlyGenuinelyFailedRowsSurfaceTheRedErrorLine() async throws {
        let (queue, repository, scope, directory) = try makeQueue()
        defer { try? FileManager.default.removeItem(at: directory) }

        let queued = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .queued, text: "waiting", storedSessionID: "A"
        ))
        let retrying = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .retryWait, text: "retrying", storedSessionID: "A"
        ))
        let failed = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .failed, text: "failed", storedSessionID: "A"
        ))

        func row(_ jobID: String) throws -> QueueStore.QueuedPrompt {
            try XCTUnwrap(queue.items.first { $0.jobID == jobID })
        }
        XCTAssertFalse(try row(queued.jobID).showsError,
                       "a queued-offline row is waiting for the connection, not failed")
        XCTAssertFalse(try row(retrying.jobID).showsError,
                       "a row still retrying after a transport error is not a terminal failure")
        XCTAssertTrue(try row(failed.jobID).showsError,
                      "a terminal failure paints its row red so the owner can retry")
    }

    /// Reached-the-gateway-but-indeterminate is protocol truth, not a failure —
    /// its row reads "Sending" and shows no red error line.
    func testIndeterminateRowShowsNoErrorLine() async throws {
        let (queue, repository, scope, directory) = try makeQueue()
        defer { try? FileManager.default.removeItem(at: directory) }
        let job = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .submitting, text: "indet", storedSessionID: "A"
        ))
        _ = try await repository.claimNextJob(scope: scope, owner: "t", now: Date(), leaseDuration: 60)
        try await repository.retainPendingJob(id: job.jobID, owner: "t", status: "indeterminate")
        let row = try XCTUnwrap(queue.items.first { $0.jobID == job.jobID })
        XCTAssertEqual(row.displayState, .indeterminate)
        XCTAssertFalse(row.showsError, "indeterminate is sending, not a failure")
    }
}
