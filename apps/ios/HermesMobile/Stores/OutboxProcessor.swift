import Foundation

struct OutboxDestination: Equatable, Sendable {
    let runtimeSessionID: String
    let storedSessionID: String
}

struct OutboxUploadedAsset: Equatable, Sendable {
    let transferID: String
    let remotePath: String
    let assetID: String?
    let contentVersion: String?

    init(
        transferID: String,
        remotePath: String,
        assetID: String? = nil,
        contentVersion: String? = nil
    ) {
        self.transferID = transferID
        self.remotePath = remotePath
        self.assetID = assetID
        self.contentVersion = contentVersion
    }
}

struct StablePromptAssetReference: Equatable, Sendable {
    let assetID: String
    let contentVersion: String
    let role: String

    var json: JSONValue {
        .object([
            "asset_id": .string(assetID),
            "content_version": .string(contentVersion),
            "role": .string(role),
        ])
    }
}

struct OutboxSubmitResult: Equatable, Sendable {
    let status: String
    let accepted: Bool
    let clientMessageID: String?
    let authoritativeTurnID: String?
    let acceptedEntityRevision: Int64?
    let deduplicated: Bool

    init(json: JSONValue) {
        let responseStatus = json["status"]?.stringValue ?? "indeterminate"
        status = responseStatus
        // Prompt receipts are an optional gateway extension. Stock/older
        // gateways return only a successful legacy disposition after executing
        // the submit. Respect an explicit receipt verdict when present; without
        // one, the completed RPC plus an accepted legacy status is authoritative.
        accepted = json["accepted"]?.boolValue
            ?? ["streaming", "queued", "steered"].contains(responseStatus)
        clientMessageID = json["client_message_id"]?.stringValue
        authoritativeTurnID = json["turn_id"]?.stringValue
        acceptedEntityRevision = json["entity_revision"]?.intValue.map(Int64.init)
        deduplicated = json["deduplicated"]?.boolValue ?? false
    }

    init(
        status: String,
        accepted: Bool,
        clientMessageID: String? = nil,
        authoritativeTurnID: String? = nil,
        acceptedEntityRevision: Int64? = nil,
        deduplicated: Bool = false
    ) {
        self.status = status
        self.accepted = accepted
        self.clientMessageID = clientMessageID
        self.authoritativeTurnID = authoritativeTurnID
        self.acceptedEntityRevision = acceptedEntityRevision
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
        var processLocalAppIntent: (WorkJob) async -> Bool = { _ in false }
    }

    static let leaseDuration: TimeInterval = 120
    static let acceptedDispositions: Set<String> = ["streaming", "queued", "steered"]

    private let repository: WorkRepository
    private let owner = "ios-outbox-\(UUID().uuidString.lowercased())"
    private var dependencies: Dependencies
    private var drainTask: Task<Void, Never>?
    private var wakePending = false
    private var suspended = false

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
        guard !suspended, drainTask == nil else { return }
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

    func suspendForBackground() async {
        suspended = true
        wakePending = false
        let running = drainTask
        running?.cancel()
        await running?.value
        drainTask = nil
        try? await repository.flushForBackground(releasingLeasesOwnedBy: owner)
    }

    func resumeFromBackground() {
        suspended = false
        if wakePending { wake() }
    }

    private func drainPass() async {
        drainPassCount += 1
        activeDrainCount += 1
        maximumConcurrentDrains = max(maximumConcurrentDrains, activeDrainCount)
        defer { activeDrainCount -= 1 }

        guard let scope = dependencies.currentScope() else { return }
        while !Task.isCancelled {
            let activeStoredID = dependencies.activeStoredSessionID()
            let canProcessPrompt = dependencies.canProcessPrompt()
            let job: WorkJob
            do {
                guard let claimed = try await repository.claimNextJob(
                    scope: scope,
                    activeStoredSessionID: activeStoredID,
                    enforceSessionAffinity: true,
                    outboxOnly: true,
                    allowTransportJobs: canProcessPrompt,
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

            if job.kind == .appIntent,
               job.intentKind == .openSessions || job.intentKind == .newSession {
                if await dependencies.processLocalAppIntent(job) {
                    do {
                        try await repository.completeNavigationAppIntent(id: job.jobID)
                    } catch {
                        try? await repository.releaseLease(id: job.jobID, owner: owner)
                        return
                    }
                    continue
                }
                try? await repository.releaseLease(id: job.jobID, owner: owner)
                return
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

        // Pre-v4 crash recovery: old builds could stop between accepted and
        // completed without an authoritative turn receipt. New v4 accepted
        // rows carry a turn id and are not claimable until GRDB confirms them.
        if job.state == .accepted, job.authoritativeTurnID == nil {
            _ = try await repository.transitionJob(
                id: job.jobID, from: .accepted, to: .completed, owner: owner
            )
            try await repository.releaseLease(id: job.jobID, owner: owner)
            return true
        }

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
                    remotePath: uploaded.remotePath,
                    remoteAssetID: uploaded.assetID,
                    remoteContentVersion: uploaded.contentVersion
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
            if let authoritativeTurnID = result.authoritativeTurnID,
               !authoritativeTurnID.isEmpty {
                _ = try await repository.recordAcceptedReceipt(
                    id: job.jobID,
                    owner: owner,
                    authoritativeTurnID: authoritativeTurnID,
                    entityRevision: result.acceptedEntityRevision
                )
            } else {
                // Compatibility path for an older gateway that does not
                // advertise authoritative turn receipts. Exact convergence is
                // unavailable, so retain the legacy accepted→completed
                // behavior rather than stranding work forever.
                _ = try await repository.transitionJob(
                    id: job.jobID, from: .submitting, to: .accepted, owner: owner
                )
                _ = try await repository.transitionJob(
                    id: job.jobID, from: .accepted, to: .completed, owner: owner
                )
            }
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
        job.kind == .share
            || job.intentKind == .newSession
            || (job.kind == .appIntent && job.intentKind == .askHermes)
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
