import Foundation
#if canImport(UIKit)
import UIKit
#endif

struct SilentSyncInvalidation: Sendable, Equatable {
    enum Reason: String, Sendable, Decodable, CaseIterable {
        case sessions, attention, activeTurns = "active_turns", transcript, widget, pushRegistry = "push_registry", coalesced
    }

    let scope: String
    let revision: Int64
    let reason: Reason

    static func decode(_ userInfo: [AnyHashable: Any]) -> Self? {
        guard userInfo.count == 2,
              let aps = userInfo["aps"] as? [String: Any], aps.count == 1,
              let available = aps["content-available"] as? NSNumber, available.intValue == 1,
              let sync = userInfo["sync"] as? [String: Any], sync.count == 3,
              let scope = sync["scope"] as? String, isValid(scope: scope),
              let number = sync["revision"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.int64Value >= 0,
              let rawReason = sync["reason"] as? String,
              let reason = Reason(rawValue: rawReason)
        else { return nil }
        return Self(scope: scope, revision: number.int64Value, reason: reason)
    }

    private static func isValid(scope: String) -> Bool {
        guard !scope.isEmpty, scope.lengthOfBytes(using: .utf8) <= 256 else { return false }
        if scope == "all" { return true }
        guard scope.hasPrefix("profile:") else { return false }
        let profile = String(scope.dropFirst("profile:".count))
        return !profile.isEmpty && profile.removingPercentEncoding != nil
    }
}

enum SilentSyncResult: Sendable, Equatable { case newData, noData, failed }

protocol SilentSyncCoordinating: Sendable {
    func synchronize(for invalidation: SilentSyncInvalidation) async -> SilentSyncResult
}

/// Coalesces invalidation high-water marks. `fetchApply` is the common manifest
/// transaction entry point; widget projection is deliberately part of that
/// operation so callers cannot publish it before the commit succeeds.
actor ManifestInvalidationCoordinator: SilentSyncCoordinating {
    typealias FetchApply = @Sendable (SilentSyncInvalidation) async throws -> Bool
    private let fetchApply: FetchApply
    private var committed: [String: Int64] = [:]
    private var inFlight: [String: Task<SilentSyncResult, Never>] = [:]

    init(fetchApply: @escaping FetchApply) { self.fetchApply = fetchApply }

    func synchronize(for invalidation: SilentSyncInvalidation) async -> SilentSyncResult {
        if (committed[invalidation.scope] ?? -1) >= invalidation.revision { return .noData }
        if let task = inFlight[invalidation.scope] { return await task.value }
        let operation = fetchApply
        let task = Task<SilentSyncResult, Never> {
            guard !Task.isCancelled else { return .failed }
            do { return try await operation(invalidation) ? .newData : .noData }
            catch { return .failed }
        }
        inFlight[invalidation.scope] = task
        let result = await task.value
        inFlight[invalidation.scope] = nil
        // The coalescing task above is unstructured, so the CALLER's
        // cancellation never reaches it — honor the caller here: a cancelled
        // background window reports .failed (and does NOT record the commit
        // high-water, so the next wake re-checks) even if the fetch itself
        // finished. Pre-existing bug pinned by
        // SilentSyncPushTests.testCancellationAndFailureReturnFailed.
        if Task.isCancelled { return .failed }
        if result != .failed {
            committed[invalidation.scope] = max(committed[invalidation.scope] ?? -1, invalidation.revision)
        }
        return result
    }
}

/// Process-wide handoff used because UIKit may deliver a launch notification
/// before SwiftUI has finished constructing AppEnvironment.
actor SilentSyncBridge {
    static let shared = SilentSyncBridge()
    private var coordinator: (any SilentSyncCoordinating)?

    func attach(_ coordinator: any SilentSyncCoordinating) {
        self.coordinator = coordinator
    }

    func handle(_ invalidation: SilentSyncInvalidation) async -> SilentSyncResult {
        // Leave headroom inside UIKit's background execution window. Polling is
        // intentional: unlike a parked continuation it remains cancellable and
        // cannot strand the fetch completion if app construction never finishes.
        let deadline = ContinuousClock.now.advanced(by: .seconds(25))
        while coordinator == nil && ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return .failed }
        }
        guard let coordinator, !Task.isCancelled else { return .failed }
        return await coordinator.synchronize(for: invalidation)
    }
}

#if canImport(UIKit)
final class BackgroundFetchCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((UIBackgroundFetchResult) -> Void)?
    init(_ callback: @escaping (UIBackgroundFetchResult) -> Void) { self.callback = callback }
    func call(_ result: UIBackgroundFetchResult) {
        lock.lock(); let callback = self.callback; self.callback = nil; lock.unlock()
        callback?(result)
    }
}
#endif
