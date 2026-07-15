import BackgroundTasks
import Foundation

struct BackgroundManifestScope: Equatable, Sendable {
    let gatewayURL: String
    let scope: String
    let token: String
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

/// Owns only iOS scheduling/lifetime policy. The injected operation is the same
/// atomic manifest sync used by foreground and silent-push triggers; this type
/// deliberately has no page, cursor, database, or widget implementation of its own.
@MainActor
final class BackgroundRefreshCoordinator {
    static let identifier = "ai.hermes.app.refresh"
    static let shared = BackgroundRefreshCoordinator(scheduler: SystemAppRefreshScheduler())

    private let scheduler: AppRefreshScheduling
    private var loadPairing: () -> BackgroundManifestScope?
    private var sync: (BackgroundManifestScope) async throws -> Void
    private var inFlight: Task<Void, Error>?
    private(set) var registered = false

    init(
        scheduler: AppRefreshScheduling,
        loadPairing: @escaping () -> BackgroundManifestScope? = { nil },
        sync: @escaping (BackgroundManifestScope) async throws -> Void = { _ in
            throw CancellationError()
        }
    ) {
        self.scheduler = scheduler
        self.loadPairing = loadPairing
        self.sync = sync
    }

    func configure(
        loadPairing: @escaping () -> BackgroundManifestScope?,
        sync: @escaping (BackgroundManifestScope) async throws -> Void
    ) {
        self.loadPairing = loadPairing
        self.sync = sync
    }

    @discardableResult
    func registerAtLaunch() -> Bool {
        guard !registered else { return true }
        registered = scheduler.register(identifier: Self.identifier) { [weak self] task in
            self?.handle(task)
        }
        return registered
    }

    /// Requests an opportunity, never an execution time guarantee.
    func scheduleNext() {
        guard registered, loadPairing() != nil else { return }
        try? scheduler.submit(
            identifier: Self.identifier,
            earliestBeginDate: Date().addingTimeInterval(15 * 60)
        )
    }

    func syncNowIfPaired() async throws {
        guard let pairing = loadPairing() else { return }
        if let inFlight { return try await inFlight.value }
        let operation = Task { try await sync(pairing) }
        inFlight = operation
        defer { inFlight = nil }
        try await operation.value
    }

    private func handle(_ task: AppRefreshTaskHandle) {
        let completion = Completion(task)
        let run = Task { [weak self] in
            guard let self else { completion.finish(false); return }
            guard self.loadPairing() != nil else {
                completion.finish(true)
                return
            }
            do {
                try await self.syncNowIfPaired()
                guard !Task.isCancelled else { throw CancellationError() }
                self.scheduleNext()
                completion.finish(true)
            } catch {
                self.scheduleNext()
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
