import Foundation

/// Observable projection of prompt jobs in the protected WorkRepository.
///
/// This type intentionally owns no second persistence format. Legacy
/// `UserDefaults` rows are imported by `WorkRepository.openAppGroup`; every
/// mutation here is an atomic repository operation.
@MainActor
@Observable
final class QueueStore {
    struct QueuedPrompt: Identifiable, Equatable, Sendable {
        enum DisplayState: Equatable, Sendable {
            case waiting
            case uploading
            case sending
            case sent
            case failed
            case cancelled
            case inProgress
            case indeterminate

            var title: String {
                switch self {
                case .waiting: "Waiting"
                case .uploading: "Uploading"
                case .sending: "Sending"
                case .sent: "Sent"
                case .failed: "Failed — Retry"
                case .cancelled: "Cancelled"
                case .inProgress: "In progress"
                case .indeterminate: "Indeterminate"
                }
            }
        }

        let id: UUID
        let jobID: String
        let kind: WorkJobKind
        let clientMessageID: String
        var text: String
        let createdAt: Date
        let storedSessionId: String?
        let state: WorkJobState
        let displayState: DisplayState
        let errorMessage: String?
        let isClaimed: Bool

        var isEditable: Bool { kind == .prompt && state == .queued && !isClaimed }
        var canRetry: Bool { state == .failed }
        var canDelete: Bool { state == .failed || state.isTerminal || !isClaimed }

        /// Not-yet-delivered: excludes `sent` (accepted/completed) and
        /// `cancelled` (cancelled/expired) terminal rows. Mirrors the
        /// `activeItems` pending filter so the badge/pill/sheet share one notion
        /// of "still in the outbox".
        var isPending: Bool { displayState != .sent && displayState != .cancelled }

        init(job: WorkJob) {
            id = UUID(uuidString: job.jobID) ?? UUID()
            jobID = job.jobID
            kind = job.kind
            clientMessageID = job.clientMessageID
            text = job.submissionText
            createdAt = Date(timeIntervalSince1970: job.createdAt)
            storedSessionId = job.destinationSessionID ?? job.storedSessionID
            state = job.state
            errorMessage = job.lastErrorMessage
            isClaimed = job.leaseOwner != nil
            switch job.lastErrorCode {
            case "in_progress": displayState = .inProgress
            case "indeterminate", "transport_ambiguous": displayState = .indeterminate
            default:
                switch job.state {
                case .waitingForScope, .queued, .creatingDestination, .retryWait:
                    displayState = .waiting
                case .uploading:
                    displayState = .uploading
                case .submitting:
                    displayState = .sending
                case .accepted, .completed:
                    displayState = .sent
                case .failed:
                    displayState = .failed
                case .cancelled, .expired:
                    displayState = .cancelled
                }
            }
        }
    }

    /// WhatsApp-style delivery state of ONE transcript bubble, correlated to its
    /// durable outbox row by the shared `clientMessageID` (C1). Sendable +
    /// Equatable so it can travel into `MessageBubble` as an immutable value the
    /// `nonisolated ==` short-circuit compares.
    enum SendDelivery: Equatable, Sendable {
        /// No live outbox row for this echo — delivered, cancelled, or a
        /// server-seeded row that never had one. No affordance.
        case none
        /// Pending and healthy: in transit within the stuck threshold while
        /// connected, or reached-server-but-ambiguous (`in_progress`/
        /// `indeterminate`). No badge — the send is proceeding normally.
        case inTransit
        /// Undelivered past the threshold, terminally failed / `retryWait` while
        /// connected, or queued while offline. Drives the red error badge; the
        /// associated `id` is the outbox row so Resend/Delete act on it without
        /// duplicating the row.
        case failed(id: UUID)
    }

    /// Single named threshold (C3): a still-undelivered send older than this,
    /// while connected, is "stuck" and surfaces the transcript error badge and
    /// the composer backlog pill. WhatsApp's own affordance appears after ~5-10s.
    static let stuckThreshold: TimeInterval = 7

    private let repository: WorkRepository
    private let observation: WorkRepositoryObservation
    private let scopeProvider: () -> WorkScope?
    /// Stored-session identity of the composer that is currently focused, or
    /// `nil` for a not-yet-materialized draft composer. Drives the
    /// active-composer projection (#209) so the badge and Outbox sheet reflect
    /// only the work that will drain into the visible composer.
    private let activeSessionProvider: () -> String?
    /// Whether the live gateway transport is ready. A pending row is "stuck" the
    /// instant this is false (queued while offline), independent of age (C1/C2).
    private let connectedProvider: () -> Bool
    private var processor: OutboxProcessor?

    /// Bumped by the single per-store threshold timer when the oldest healthy
    /// pending row crosses `stuckThreshold`. The backlog/delivery projections
    /// read it so SwiftUI recomputes the pill + badges exactly once at the
    /// boundary — never a per-second, per-bubble poll (C3).
    private(set) var evaluationTick: UInt64 = 0
    /// The one scheduled re-evaluation (one timer per store, not per row).
    private var thresholdTimer: Task<Void, Never>?

    init(
        repository: WorkRepository,
        observation: WorkRepositoryObservation,
        scopeProvider: @escaping () -> WorkScope?,
        activeSessionProvider: @escaping () -> String? = { nil },
        connectedProvider: @escaping () -> Bool = { true }
    ) {
        self.repository = repository
        self.observation = observation
        self.scopeProvider = scopeProvider
        self.activeSessionProvider = activeSessionProvider
        self.connectedProvider = connectedProvider
    }

    /// The full durable outbox across every session (unscoped). This is the
    /// management/reorder projection: it feeds cross-session reorder, self-heal,
    /// and the shared-inbox share count. It intentionally includes terminal
    /// rows so the reorder editor can see the whole durable queue. The
    /// active-composer surfaces (badge + Outbox sheet) use `activeItems`.
    var items: [QueuedPrompt] {
        observation.snapshot.jobs
            .filter {
                $0.kind == .prompt
                    || $0.kind == .share
                    || ($0.kind == .appIntent && $0.intentKind == .askHermes)
            }
            .map(QueuedPrompt.init(job:))
    }

    /// Active-composer projection (#209): pending, session-scoped rows that will
    /// drain into the currently-focused composer. This mirrors the drain path's
    /// `claimNextJob` session affinity — a row is in scope when its session
    /// identity is `nil` (unbound work claimable by whatever session is active)
    /// or equals the active composer's stored session. A draft composer (`nil`
    /// active session) therefore shows only `nil`-session rows. "Pending" means
    /// not yet delivered: `sent` (accepted/completed) and `cancelled`
    /// (cancelled/expired) terminal rows are excluded so a completed row can
    /// never re-enter this projection after receipt recovery.
    var activeItems: [QueuedPrompt] {
        let activeSession = activeSessionProvider()
        return items.filter { prompt in
            guard prompt.displayState != .sent, prompt.displayState != .cancelled else {
                return false
            }
            guard let session = prompt.storedSessionId else { return true }
            return session == activeSession
        }
    }

    /// Badge/sheet count for the active composer. Reconciled to `activeItems`
    /// (the exact rows the Outbox sheet renders) so the count can never diverge
    /// from the list (#209).
    var pendingCount: Int { activeItems.count }

    /// Cross-session count of pending durable share jobs for the shared inbox.
    /// Deliberately unscoped (share work is not bound to any one composer
    /// session) so it is unaffected by the active-composer scoping above.
    var pendingShareCount: Int {
        items.filter {
            $0.kind == .share
                && $0.displayState != .sent
                && $0.displayState != .cancelled
        }.count
    }

    var isDraining: Bool { processor?.isDraining == true }

    // MARK: - WhatsApp send-state projection (C1/C2)

    /// Whether a single pending row is "stuck" — the shared predicate behind both
    /// the transcript error badge (C1) and the composer backlog pill (C2). A row
    /// is stuck when it is terminally `failed` or `retryWait` (a prior attempt
    /// already errored), OR queued while offline, OR still undelivered past
    /// `stuckThreshold` while connected. A row that reached the server but whose
    /// disposition is still resolving (`in_progress`/`indeterminate`) is NOT
    /// stuck — that is protocol truth, not a failed send.
    private func isStuck(_ prompt: QueuedPrompt, now: Date) -> Bool {
        guard prompt.isPending else { return false }
        if prompt.displayState == .inProgress || prompt.displayState == .indeterminate {
            return false
        }
        switch prompt.state {
        case .failed, .retryWait:
            return true
        default:
            break
        }
        if !connectedProvider() { return true }
        return now.timeIntervalSince(prompt.createdAt) >= Self.stuckThreshold
    }

    /// Delivery state of the transcript bubble carrying `clientMessageID` (C1).
    /// Correlates the local echo to its outbox row by the shared client id — no
    /// new correlation key is introduced (the echo and job already share it).
    func delivery(forClientMessageID clientMessageID: String, now: Date = Date()) -> SendDelivery {
        _ = evaluationTick // observation dependency: recompute at the 7s boundary
        guard let prompt = items.first(where: {
            $0.clientMessageID == clientMessageID && $0.isPending
        }) else {
            return .none
        }
        return isStuck(prompt, now: now) ? .failed(id: prompt.id) : .inTransit
    }

    /// Whether the active composer has genuine backlog worth surfacing the pill
    /// (C2): at least one stuck/failed/offline-queued row for THIS session.
    /// Healthy in-transit sends within the threshold do NOT count, so a normal
    /// send never flashes the pill. Reads the session-scoped `activeItems`, so
    /// backlog in session A never surfaces the pill in session B.
    func isBacklogged(now: Date = Date()) -> Bool {
        activeItems.contains { isStuck($0, now: now) }
    }

    /// Observation-tracked pill gate. The count shown when it appears is still
    /// `pendingCount` (== the sheet's rows), so pill and sheet never diverge; this
    /// only decides *whether* the pill is warranted.
    var hasBacklog: Bool {
        _ = evaluationTick
        return isBacklogged(now: Date())
    }

    /// (Re)arm the single threshold timer to fire when the earliest still-healthy
    /// pending row crosses `stuckThreshold`, bumping `evaluationTick` so the pill
    /// and badges re-evaluate once at the boundary. Idempotent and coalescing:
    /// each call cancels the prior timer and schedules the next nearest boundary
    /// (one timer per store — never one per row, never per-second polling) (C3).
    func scheduleThresholdReevaluation(now: Date = Date()) {
        thresholdTimer?.cancel()
        thresholdTimer = nil
        let connected = connectedProvider()
        // Offline rows are already stuck (no future boundary to wait for); only
        // connected, within-threshold pending rows have a pending crossing.
        guard connected else { return }
        let nextBoundary = activeItems
            .filter { prompt in
                guard prompt.isPending,
                      prompt.displayState != .inProgress,
                      prompt.displayState != .indeterminate,
                      prompt.state != .failed,
                      prompt.state != .retryWait else { return false }
                return now.timeIntervalSince(prompt.createdAt) < Self.stuckThreshold
            }
            .map { $0.createdAt.addingTimeInterval(Self.stuckThreshold) }
            .min()
        guard let nextBoundary else { return }
        let delay = max(0, nextBoundary.timeIntervalSince(now))
        thresholdTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.evaluationTick &+= 1
            self.scheduleThresholdReevaluation()
        }
    }

    func installProcessor(_ processor: OutboxProcessor) {
        self.processor = processor
    }

    @discardableResult
    func enqueue(
        _ text: String,
        storedSessionId: String? = nil,
        assets: [WorkAssetInput] = [],
        newSession: Bool = false,
        wake: Bool = false
    ) async -> QueuedPrompt? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !assets.isEmpty, let scope = scopeProvider() else { return nil }
        let outgoing = trimmed.isEmpty ? "Please look at the attached image." : trimmed
        do {
            let job = try await repository.enqueue(
                WorkJobInput(
                    kind: .prompt,
                    scope: scope,
                    intentKind: newSession ? .newSession : nil,
                    text: outgoing,
                    storedSessionID: storedSessionId
                ),
                assets: assets
            )
            if wake { processor?.wake() }
            scheduleThresholdReevaluation()
            return QueuedPrompt(job: job)
        } catch {
            return nil
        }
    }

    func update(id: UUID, text: String) async {
        try? await repository.updateQueuedPrompt(id: id.uuidString.lowercased(), text: text)
    }

    func remove(id: UUID) async {
        let key = id.uuidString.lowercased()
        do {
            guard let job = try await repository.job(id: key) else { return }
            if job.leaseOwner == nil || job.state.isTerminal || job.state == .failed {
                try await repository.deleteJob(id: key)
            } else {
                try await repository.cancelJob(id: key)
            }
        } catch {
            return
        }
    }

    func removeAll() async {
        for item in items where item.canDelete { await remove(id: item.id) }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) async {
        var ordered = items
        guard ordered.count > 1,
              source.allSatisfy({ ordered.indices.contains($0) && ordered[$0].isEditable }) else { return }
        ordered.move(fromOffsets: source, toOffset: destination)
        try? await repository.reorderQueuedPrompts(ids: ordered.filter(\.isEditable).map(\.jobID))
    }

    /// Reorder within the active-composer projection. The Outbox sheet renders
    /// `activeItems`, so its drag offsets are relative to that scoped set; this
    /// persists the new order for the scoped editable rows only (#209).
    func moveActive(fromOffsets source: IndexSet, toOffset destination: Int) async {
        var ordered = activeItems
        guard ordered.count > 1,
              source.allSatisfy({ ordered.indices.contains($0) && ordered[$0].isEditable }) else { return }
        ordered.move(fromOffsets: source, toOffset: destination)
        try? await repository.reorderQueuedPrompts(ids: ordered.filter(\.isEditable).map(\.jobID))
    }

    func restamp(from oldId: String, to newId: String) async {
        try? await repository.restampQueuedPrompts(from: oldId, to: newId)
    }

    func retry(id: UUID) async {
        guard (try? await repository.retryFailedJob(id: id.uuidString.lowercased())) != nil else { return }
        processor?.wake()
    }

    /// "Resend" a stuck/failed transcript bubble (C1). Re-drives the EXISTING
    /// outbox row — never a duplicate — reusing the repository retry seams:
    /// a `failed` row is requeued (`retryFailedJob`), a `retryWait` row has its
    /// backoff cleared so the next drain claims it immediately, and any other
    /// pending row (offline-queued / slow submit) just needs a wake. The shared
    /// `clientMessageID` is preserved throughout, so a late receipt still
    /// dedupes against the original send.
    func resend(id: UUID) async {
        let key = id.uuidString.lowercased()
        do {
            if let job = try await repository.job(id: key) {
                switch job.state {
                case .failed:
                    _ = try await repository.retryFailedJob(id: key)
                case .retryWait:
                    _ = try await repository.transitionJob(
                        id: key, from: .retryWait, to: .queued, nextAttemptAt: nil
                    )
                default:
                    break
                }
            }
        } catch {
            // Fall through to a wake — a live drain re-attempts the same row.
        }
        processor?.wake()
    }

    func cancel(id: UUID) async {
        try? await repository.cancelJob(id: id.uuidString.lowercased())
    }

    func drain(chat _: ChatStore) async {
        processor?.wake()
        await processor?.waitUntilIdleForTesting()
    }

    func wake() {
        processor?.wake()
    }

    func suspendForBackground() async {
        await processor?.suspendForBackground()
    }

    func resumeFromBackground() {
        processor?.resumeFromBackground()
    }

    func refresh() async {
        try? await repository.refreshObservation()
        scheduleThresholdReevaluation()
    }
}
