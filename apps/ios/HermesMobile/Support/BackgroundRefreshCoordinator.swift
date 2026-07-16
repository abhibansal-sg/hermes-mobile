import BackgroundTasks
import Foundation

struct BackgroundManifestScope: Equatable, Sendable {
    let gatewayURL: String
    let scope: String
    let token: String
}

enum BackgroundRefreshOutcome: Sendable, Equatable {
    case success
    case noChange
    case retryableFailure
    case authFailure
    case timeout
}

@MainActor
protocol AppRefreshTaskHandle: AnyObject {
    var expirationHandler: (() -> Void)? { get set }
    func setTaskCompleted(success: Bool)
}

@MainActor
protocol AppRefreshScheduling {
    func register(identifier: String, handler: @escaping (AppRefreshTaskHandle) -> Void) -> Bool
    func submit(identifier: String, earliestBeginDate: Date?) throws
}

@MainActor
final class SystemAppRefreshScheduler: AppRefreshScheduling {
    func register(identifier: String, handler: @escaping (AppRefreshTaskHandle) -> Void) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            MainActor.assumeIsolated { handler(SystemAppRefreshTask(task)) }
        }
    }

    func submit(identifier: String, earliestBeginDate: Date?) throws {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = earliestBeginDate
        try BGTaskScheduler.shared.submit(request)
    }
}

@MainActor
private final class SystemAppRefreshTask: AppRefreshTaskHandle {
    private let task: BGAppRefreshTask
    init(_ task: BGAppRefreshTask) { self.task = task }
    var expirationHandler: (() -> Void)? {
        get { task.expirationHandler }
        set { task.expirationHandler = newValue }
    }
    func setTaskCompleted(success: Bool) { task.setTaskCompleted(success: success) }
}

/// Owns iOS scheduling and execution policy for the paired-gateway maintenance
/// cycle. The injected sync remains the same atomic operation used by foreground
/// and silent-push triggers; this type adds only budget, reschedule, and cleanup
/// policy and never starts work when pairing credentials are incomplete.
@MainActor
final class BackgroundRefreshCoordinator {
    static let identifier = "ai.hermes.app.refresh"
    static let shared = BackgroundRefreshCoordinator(scheduler: SystemAppRefreshScheduler())

    private let scheduler: AppRefreshScheduling
    private let runtimeBudget: Duration
    private var loadPairing: () -> BackgroundManifestScope?
    private var sync: (BackgroundManifestScope) async throws -> BackgroundRefreshOutcome
    private var maintenance: () async throws -> Void
    private var inFlight: Task<BackgroundRefreshOutcome, Never>?
    private(set) var registered = false

    init(
        scheduler: AppRefreshScheduling,
        runtimeBudget: Duration = .seconds(25 * 60),
        loadPairing: @escaping () -> BackgroundManifestScope? = { nil },
        sync: @escaping (BackgroundManifestScope) async throws -> BackgroundRefreshOutcome = { _ in
            throw CancellationError()
        },
        maintenance: @escaping () async throws -> Void = {}
    ) {
        self.scheduler = scheduler
        self.runtimeBudget = runtimeBudget
        self.loadPairing = loadPairing
        self.sync = sync
        self.maintenance = maintenance
    }

    func configure(
        loadPairing: @escaping () -> BackgroundManifestScope?,
        sync: @escaping (BackgroundManifestScope) async throws -> BackgroundRefreshOutcome,
        maintenance: @escaping () async throws -> Void
    ) {
        self.loadPairing = loadPairing
        self.sync = sync
        self.maintenance = maintenance
    }

    @discardableResult
    func registerAtLaunch() -> Bool {
        guard !registered else { return true }
        registered = scheduler.register(identifier: Self.identifier) { [weak self] task in
            self?.handle(task)
        }
        return registered
    }

    /// Requests an opportunity, never an execution-time guarantee.
    func scheduleNext(after delay: TimeInterval = 15 * 60) {
        guard registered, loadPairing() != nil else { return }
        try? scheduler.submit(
            identifier: Self.identifier,
            earliestBeginDate: Date().addingTimeInterval(delay)
        )
    }

    /// Coalesces all background triggers into one paired sync + maintenance cycle.
    func syncNowIfPaired() async -> BackgroundRefreshOutcome {
        guard let pairing = loadPairing() else { return .noChange }
        if let inFlight { return await inFlight.value }

        let sync = self.sync
        let maintenance = self.maintenance
        let operation = Task<BackgroundRefreshOutcome, Never> {
            do {
                let outcome = try await sync(pairing)
                try Task.checkCancellation()
                if outcome == .success || outcome == .noChange {
                    try await maintenance()
                    try Task.checkCancellation()
                }
                return outcome
            } catch is CancellationError {
                return .timeout
            } catch {
                return .retryableFailure
            }
        }
        inFlight = operation
        let budgetTask = Task {
            do {
                try await Task.sleep(for: runtimeBudget)
                operation.cancel()
            } catch {}
        }
        let outcome = await operation.value
        budgetTask.cancel()
        inFlight = nil
        return outcome
    }

    private func handle(_ task: AppRefreshTaskHandle) {
        let completion = Completion(task)
        let run = Task { [weak self] in
            guard let self else { completion.finish(false); return }
            guard self.loadPairing() != nil else {
                completion.finish(true)
                return
            }
            let outcome = await self.syncNowIfPaired()
            guard !Task.isCancelled else {
                completion.finish(false)
                return
            }
            switch outcome {
            case .success, .noChange:
                self.scheduleNext()
                completion.finish(true)
            case .retryableFailure, .timeout:
                self.scheduleNext(after: 5 * 60)
                completion.finish(false)
            case .authFailure:
                // A foreground pairing change is the only safe retry trigger.
                completion.finish(false)
            }
        }
        task.expirationHandler = { [weak self] in
            run.cancel()
            self?.inFlight?.cancel()
            completion.finish(false)
        }
    }
}

@MainActor
private final class Completion {
    private weak var task: AppRefreshTaskHandle?
    private var completed = false
    init(_ task: AppRefreshTaskHandle) { self.task = task }
    func finish(_ success: Bool) {
        guard !completed else { return }
        completed = true
        task?.setTaskCompleted(success: success)
    }
}
