import Foundation

struct OutboxDestination: Equatable, Sendable {
    let runtimeSessionID: String
    let storedSessionID: String
}

struct OutboxUploadedAsset: Equatable, Sendable {
    let transferID: String
    let remotePath: String
}

struct OutboxSubmitResult: Equatable, Sendable {
    let status: String
    let accepted: Bool
    let clientMessageID: String?
    let deduplicated: Bool

    init(json: JSONValue) {
        status = json["status"]?.stringValue ?? "indeterminate"
        accepted = json["accepted"]?.boolValue ?? false
        clientMessageID = json["client_message_id"]?.stringValue
        deduplicated = json["deduplicated"]?.boolValue ?? false
    }

    init(status: String, accepted: Bool, clientMessageID: String? = nil, deduplicated: Bool = false) {
        self.status = status
        self.accepted = accepted
        self.clientMessageID = clientMessageID
        self.deduplicated = deduplicated
    }
}

/// The one app-process drainer for durable prompt work.
///
/// `wake()` is deliberately edge-triggered and coalescing. Repository leases
/// remain the cross-process authority; the task latch merely avoids overlapping
/// drains inside this process when reconnect, runtime bind, and turn completion
/// all arrive together.
@MainActor
final class OutboxProcessor {
    struct Dependencies {
        var currentScope: () -> WorkScope?
        var activeStoredSessionID: () -> String?
        var canProcessPrompt: () -> Bool
        var createDestination: (WorkJob) async throws -> OutboxDestination
        var resolveRuntime: (String) async -> String?
        var uploadAsset: (WorkJob, WorkJobAssetSnapshot) async throws -> OutboxUploadedAsset
        var willSubmit: (WorkJob, [String]) -> Void
        var submit: (WorkJob, String, [String]) async throws -> OutboxSubmitResult
    }

    static let leaseDuration: TimeInterval = 120
    static let acceptedDispositions: Set<String> = ["streaming", "queued", "steered"]

    private let repository: WorkRepository
    private let owner = "ios-outbox-\(UUID().uuidString.lowercased())"
    private var dependencies: Dependencies
    private var drainTask: Task<Void, Never>?
    private var wakePending = false

    private(set) var drainPassCount = 0
    private(set) var activeDrainCount = 0
    private(set) var maximumConcurrentDrains = 0

    init(repository: WorkRepository, dependencies: Dependencies) {
        self.repository = repository
        self.dependencies = dependencies
    }

    var isDraining: Bool { drainTask != nil }

    func wake() {
        wakePending = true
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            guard let self else { return }
            while self.wakePending, !Task.isCancelled {
                self.wakePending = false
                await self.drainPass()
            }
            self.drainTask = nil
        }
    }

    func waitUntilIdleForTesting() async {
        while let task = drainTask { await task.value }
    }

    private func drainPass() async {
        drainPassCount += 1
        activeDrainCount += 1
        maximumConcurrentDrains = max(maximumConcurrentDrains, activeDrainCount)
        defer { activeDrainCount -= 1 }

        guard let scope = dependencies.currentScope() else { return }
        while !Task.isCancelled {
            let activeStoredID = dependencies.activeStoredSessionID()
            let job: WorkJob
            do {
                guard let claimed = try await repository.claimNextJob(
                    scope: scope,
                    activeStoredSessionID: activeStoredID,
                    enforceSessionAffinity: true,
                    owner: owner,
                    now: Date(),
                    leaseDuration: Self.leaseDuration
                ) else { return }
                job = claimed
            } catch {
                return
            }

            if job.state == .accepted {
                do {
                    _ = try await repository.transitionJob(
                        id: job.jobID, from: .accepted, to: .completed, owner: owner
                    )
                    try await repository.releaseLease(id: job.jobID, owner: owner)
                } catch { return }
                continue
            }

            guard dependencies.canProcessPrompt() else {
                try? await repository.releaseLease(id: job.jobID, owner: owner)
                return
            }

            do {
                let mayContinue = try await process(job)
                if !mayContinue { return }
            } catch {
                await recordFailure(jobID: job.jobID, fallbackState: job.state, error: error)
                return
            }

            // A streaming/queued/steered acceptance normally flips ChatStore's
            // local turn token, so stop here. A test or non-chat consumer that
            // remains idle may continue through the FIFO.
            if !dependencies.canProcessPrompt() { return }
        }
    }

    private func process(_ claimed: WorkJob) async throws -> Bool {
        var job = claimed

        if job.state == .retryWait {
            let assets = try await repository.jobAssets(jobID: job.jobID)
            let resume: WorkJobState
            if job.destinationSessionID == nil && job.storedSessionID == nil
                && Self.requiresNewDestination(job) {
                resume = .creatingDestination
            } else if assets.contains(where: { $0.link.state != "uploaded" }) {
                resume = .uploading
            } else {
                resume = .submitting
            }
            let destinationID: String?
            if resume == .creatingDestination {
                destinationID = nil
            } else {
                guard let resolved = job.destinationSessionID
                    ?? job.storedSessionID
                    ?? dependencies.activeStoredSessionID() else {
                    throw OutboxProcessorError.destinationUnavailable
                }
                destinationID = resolved
            }
            job = try await repository.transitionJob(
                id: job.jobID,
                from: .retryWait,
                to: resume,
                owner: owner,
                destinationSessionID: destinationID
            )
        }

        if job.state == .queued {
            if job.destinationSessionID == nil && job.storedSessionID == nil
                && Self.requiresNewDestination(job) {
                job = try await repository.transitionJob(
                    id: job.jobID, from: .queued, to: .creatingDestination, owner: owner
                )
            } else {
                let assets = try await repository.jobAssets(jobID: job.jobID)
                let next: WorkJobState = assets.isEmpty ? .submitting : .uploading
                let destinationID = job.destinationSessionID
                    ?? job.storedSessionID
                    ?? dependencies.activeStoredSessionID()
                guard let destinationID else { throw OutboxProcessorError.destinationUnavailable }
                job = try await repository.transitionJob(
                    id: job.jobID,
                    from: .queued,
                    to: next,
                    owner: owner,
                    destinationSessionID: destinationID
                )
            }
        }

        if job.state == .creatingDestination {
            if job.destinationSessionID == nil {
                // State was committed before session.create. The returned stable
                // destination is committed before upload or prompt submission.
                let destination = try await dependencies.createDestination(job)
                let assets = try await repository.jobAssets(jobID: job.jobID)
                let next: WorkJobState = assets.isEmpty ? .submitting : .uploading
                job = try await repository.transitionJob(
                    id: job.jobID,
                    from: .creatingDestination,
                    to: next,
                    owner: owner,
                    destinationSessionID: destination.storedSessionID
                )
            } else {
                let assets = try await repository.jobAssets(jobID: job.jobID)
                let next: WorkJobState = assets.isEmpty ? .submitting : .uploading
                job = try await repository.transitionJob(
                    id: job.jobID, from: .creatingDestination, to: next, owner: owner
                )
            }
        }

        if job.state == .uploading {
            let assets = try await repository.jobAssets(jobID: job.jobID)
            for snapshot in assets where snapshot.link.state != "uploaded" {
                try await repository.updateJobAsset(
                    jobID: job.jobID,
                    ordinal: snapshot.link.ordinal,
                    owner: owner,
                    state: "transferring"
                )
                let uploaded = try await dependencies.uploadAsset(job, snapshot)
                try await repository.updateJobAsset(
                    jobID: job.jobID,
                    ordinal: snapshot.link.ordinal,
                    owner: owner,
                    state: "uploaded",
                    transferID: uploaded.transferID,
                    remotePath: uploaded.remotePath
                )
            }
            job = try await repository.transitionJob(
                id: job.jobID, from: .uploading, to: .submitting, owner: owner
            )
        }

        guard job.state == .submitting else { return false }
        guard let destinationID = job.destinationSessionID ?? job.storedSessionID,
              let runtimeID = await dependencies.resolveRuntime(destinationID) else {
            throw OutboxProcessorError.destinationUnavailable
        }
        let remotePaths = try await repository.jobAssets(jobID: job.jobID).compactMap(\.link.remotePath)
        dependencies.willSubmit(job, remotePaths)
        let result: OutboxSubmitResult
        do {
            result = try await dependencies.submit(job, runtimeID, remotePaths)
        } catch {
            // The request may have reached the gateway. Keep `submitting` and
            // release the lease; the next wake retries the same client id.
            try await repository.retainPendingJob(
                id: job.jobID,
                owner: owner,
                status: "transport_ambiguous",
                message: error.localizedDescription
            )
            return false
        }

        if result.accepted,
           Self.acceptedDispositions.contains(result.status),
           result.clientMessageID == nil || result.clientMessageID == job.clientMessageID {
            _ = try await repository.transitionJob(
                id: job.jobID, from: .submitting, to: .accepted, owner: owner
            )
            _ = try await repository.transitionJob(
                id: job.jobID, from: .accepted, to: .completed, owner: owner
            )
            try await repository.releaseLease(id: job.jobID, owner: owner)
            return true
        }

        // `in_progress` and `indeterminate` are protocol truth, not failures.
        // Both stay visible and retain the stable identity for later reconcile.
        try await repository.retainPendingJob(
            id: job.jobID,
            owner: owner,
            status: result.status,
            message: result.accepted ? "Unrecognized accepted disposition" : nil
        )
        return false
    }

    private func recordFailure(jobID: String, fallbackState: WorkJobState, error: Error) async {
        let latest: WorkJob
        do {
            guard let fetched = try await repository.job(id: jobID) else { return }
            latest = fetched
        } catch {
            return
        }
        let state = latest.state
        guard !state.isTerminal else {
            try? await repository.releaseLease(id: jobID, owner: owner)
            return
        }
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let retryable = latest.attemptCount < 3
        do {
            _ = try await repository.transitionJob(
                id: jobID,
                from: state,
                to: retryable ? .retryWait : .failed,
                owner: owner,
                errorCode: String(describing: type(of: error)),
                errorMessage: message
            )
            try await repository.releaseLease(id: jobID, owner: owner)
        } catch {
            // A crash/lease expiry leaves the durable stage intact for a later
            // claimant. Never delete on an error path.
            _ = fallbackState
        }
    }

    private static func requiresNewDestination(_ job: WorkJob) -> Bool {
        job.kind == .share || job.intentKind == .newSession
    }
}

enum OutboxProcessorError: Error, LocalizedError {
    case destinationUnavailable

    var errorDescription: String? {
        switch self {
        case .destinationUnavailable:
            "The queued prompt’s destination session is not active."
        }
    }
}
