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

    private let repository: WorkRepository
    private let observation: WorkRepositoryObservation
    private let scopeProvider: () -> WorkScope?
    /// Stored-session identity of the composer that is currently focused, or
    /// `nil` for a not-yet-materialized draft composer. Drives the
    /// active-composer projection (#209) so the badge and Outbox sheet reflect
    /// only the work that will drain into the visible composer.
    private let activeSessionProvider: () -> String?
    private var processor: OutboxProcessor?

    init(
        repository: WorkRepository,
        observation: WorkRepositoryObservation,
        scopeProvider: @escaping () -> WorkScope?,
        activeSessionProvider: @escaping () -> String? = { nil }
    ) {
        self.repository = repository
        self.observation = observation
        self.scopeProvider = scopeProvider
        self.activeSessionProvider = activeSessionProvider
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
    }
}
