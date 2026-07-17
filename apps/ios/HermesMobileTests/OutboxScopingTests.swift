import XCTest
@testable import HermesMobile

/// #209 — the active-composer outbox projection is pending-only and
/// session-scoped, and the badge count is reconciled to the exact rows the
/// Outbox sheet renders. These tests pin the read projection; the drain path
/// (`claimNextJob` session affinity) is exercised separately.
@MainActor
final class OutboxScopingTests: XCTestCase {
    /// Mutable stand-in for the focused composer's stored session id.
    private final class SessionBox {
        var value: String?
        init(_ value: String? = nil) { self.value = value }
    }

    private func makeQueue(
        activeSession: SessionBox
    ) throws -> (QueueStore, WorkRepository, WorkScope, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OutboxScoping-\(UUID().uuidString)", isDirectory: true)
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
            activeSessionProvider: { activeSession.value }
        )
        return (queue, repository, scope, directory)
    }

    func testSentAndCancelledRowsExcludedFromActiveProjection() async throws {
        let box = SessionBox("session-A")
        let (queue, repository, scope, directory) = try makeQueue(activeSession: box)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .queued, text: "pending", storedSessionID: "session-A"
        ))
        _ = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .accepted, text: "delivered", storedSessionID: "session-A"
        ))
        _ = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .completed, text: "sent", storedSessionID: "session-A"
        ))
        _ = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .cancelled, text: "cancelled", storedSessionID: "session-A"
        ))

        XCTAssertEqual(queue.activeItems.map(\.text), ["pending"])
        XCTAssertEqual(queue.pendingCount, 1)
        // The unscoped durable projection still sees every row (reorder/editor).
        XCTAssertEqual(queue.items.count, 4)
    }

    func testPendingRowInSessionXInvisibleFromSessionYComposer() async throws {
        let box = SessionBox("session-Y")
        let (queue, repository, scope, directory) = try makeQueue(activeSession: box)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .queued, text: "for-X", storedSessionID: "session-X"
        ))
        _ = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .queued, text: "for-Y", storedSessionID: "session-Y"
        ))

        // Composer on Y sees only Y's row; X's pending row is invisible.
        XCTAssertEqual(queue.activeItems.map(\.text), ["for-Y"])

        // Switching the composer to X flips visibility.
        box.value = "session-X"
        XCTAssertEqual(queue.activeItems.map(\.text), ["for-X"])

        // A draft composer (nil active session) sees neither session-bound row.
        box.value = nil
        XCTAssertTrue(queue.activeItems.isEmpty)
    }

    func testDraftComposerSeesOnlyUnboundRows() async throws {
        let box = SessionBox(nil) // draft composer
        let (queue, repository, scope, directory) = try makeQueue(activeSession: box)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .queued, text: "draft-row", storedSessionID: nil
        ))
        _ = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .queued, text: "bound-row", storedSessionID: "session-A"
        ))

        XCTAssertEqual(queue.activeItems.map(\.text), ["draft-row"])

        // Once a real session is focused it inherits the unbound draft row
        // (mirrors claimNextJob: a nil-session row drains into any session).
        box.value = "session-A"
        XCTAssertEqual(queue.activeItems.map(\.text), ["draft-row", "bound-row"])
    }

    func testBadgeCountMatchesSheetRows() async throws {
        let box = SessionBox("session-A")
        let (queue, repository, scope, directory) = try makeQueue(activeSession: box)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .queued, text: "a1", storedSessionID: "session-A"
        ))
        _ = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .submitting, text: "a2", storedSessionID: "session-A"
        ))
        _ = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .completed, text: "a-done", storedSessionID: "session-A"
        ))
        _ = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .queued, text: "b1", storedSessionID: "session-B"
        ))
        _ = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .queued, text: "unbound", storedSessionID: nil
        ))

        // Badge (pendingCount) and the sheet body (activeItems) are the SAME query.
        XCTAssertEqual(queue.pendingCount, queue.activeItems.count)
        // 2 pending in session-A + 1 unbound; completed and session-B excluded.
        XCTAssertEqual(queue.pendingCount, 3)
        XCTAssertEqual(queue.activeItems.map(\.text), ["a1", "a2", "unbound"])
    }

    func testCompletedRowNeverReentersActivePendingAfterReceiptRecovery() async throws {
        let box = SessionBox("session-A")
        let (queue, repository, scope, directory) = try makeQueue(activeSession: box)
        defer { try? FileManager.default.removeItem(at: directory) }
        let job = try await repository.enqueue(WorkJobInput(
            kind: .prompt, scope: scope, state: .submitting, text: "inflight", storedSessionID: "session-A"
        ))

        // In-flight (submitting) work is still pending and visible.
        XCTAssertEqual(queue.activeItems.map(\.text), ["inflight"])

        // Receipt recovery: the server acknowledges delivery, then completes.
        _ = try await repository.transitionJob(id: job.jobID, from: .submitting, to: .accepted)
        XCTAssertTrue(queue.activeItems.isEmpty, "accepted (delivered) leaves the pending projection")

        _ = try await repository.transitionJob(id: job.jobID, from: .accepted, to: .completed)
        XCTAssertTrue(queue.activeItems.isEmpty)
        XCTAssertEqual(queue.pendingCount, 0)

        // A later observation refresh must not resurrect the completed row.
        await queue.refresh()
        XCTAssertTrue(queue.activeItems.isEmpty)
        XCTAssertTrue(
            queue.items.contains { $0.jobID == job.jobID },
            "durable row is retained for history, just never pending again"
        )
    }
}
