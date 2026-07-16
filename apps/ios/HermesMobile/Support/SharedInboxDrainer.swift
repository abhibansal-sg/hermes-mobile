import Foundation

/// Foreground/connection-edge coordinator for durable share work.
///
/// The share extension commits directly to `WorkRepository`; this type performs
/// no file decoding and no networking. It binds previously unpaired shares,
/// removes expired/orphaned local work, refreshes the user-visible projection,
/// and wakes the leased outbox processor.
@MainActor
enum SharedInboxDrainer {
    private static var isDraining = false

    static func drain(
        repository: WorkRepository,
        scope: WorkScope?,
        queue: QueueStore,
        onQueued: ((Int) -> Void)? = nil
    ) {
        guard !isDraining else { return }
        isDraining = true
        Task { @MainActor in
            defer { isDraining = false }
            do {
                _ = try await repository.cleanupShareWork()
                if let scope {
                    try await repository.bindPendingShares(to: scope)
                }
                await queue.refresh()
                let count = queue.items.filter {
                    $0.kind == .share
                        && $0.displayState != .sent
                        && $0.displayState != .cancelled
                }.count
                queue.wake()
                if count > 0 { onQueued?(count) }
            } catch {
                // Protected data can be unavailable before first unlock. The
                // durable rows remain untouched and the next edge retries.
            }
        }
    }
}
