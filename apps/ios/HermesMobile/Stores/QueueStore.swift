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
    private var processor: OutboxProcessor?

    init(
        repository: WorkRepository,
        observation: WorkRepositoryObservation,
        scopeProvider: @escaping () -> WorkScope?
    ) {
        self.repository = repository
        self.observation = observation
        self.scopeProvider = scopeProvider
    }

    var items: [QueuedPrompt] {
        observation.snapshot.jobs
            .filter { $0.kind == .prompt || $0.kind == .share }
            .map(QueuedPrompt.init(job:))
    }

    var pendingCount: Int {
        items.filter { $0.displayState != .sent && $0.displayState != .cancelled }.count
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

    func refresh() async {
        try? await repository.refreshObservation()
    }
}
