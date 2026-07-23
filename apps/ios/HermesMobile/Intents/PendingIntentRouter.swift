import Foundation

extension Notification.Name {
    static let hermesOpenSessionsIntent = Notification.Name("HermesOpenSessionsIntent")
}

/// Applies durable App Intent work to the live stores.
///
/// All work is `@MainActor`: it drives the same `@Observable` stores the UI
/// binds to, so the navigation/transcript changes are observed immediately.
@MainActor
enum PendingIntentRouter {

    /// Drains the durable App Intent queue on foreground. Navigation-only jobs
    /// complete locally and in FIFO order. Ask Hermes stays durable and wakes the
    /// common outbox, which owns destination creation and idempotent submission.
    static func drainDurable(
        repository: WorkRepository,
        scope: WorkScope?,
        sessions: SessionStore,
        queue: QueueStore
    ) async {
        if let scope {
            try? await repository.bindPendingAppIntents(to: scope)
        }
        guard let jobs = try? await repository.pendingAppIntents() else { return }

        for job in jobs {
            switch job.intentKind {
            case .openSessions:
                // S9 (QA-3, 3rd recurrence): the dismissal latch is a one-shot
                // consumed at first-paint/300ms, but THIS re-open edge is
                // unserialized against it. A foreground transition (background
                // → foreground to check a stuck turn) re-drains durable
                // `.openSessions` jobs that were queued by an OLDER gesture
                // (widget tap, Siri, Handoff); the
                // job's `createdAt` predates the user's more recent in-app
                // drawer navigation (row tap during in-flight load, or "New
                // chat"). Last writer would otherwise win = the intent re-opens
                // the drawer over the load the user just chose. Drop the open
                // (and the clobbering `closeActive`) when the user gestured at
                // or after the intent's queue time; the job is still marked
                // complete so it doesn't redrain next foreground. The user's
                // gesture wins, the drawer always dismisses into the session.
                let queuedAt = Date(timeIntervalSince1970: job.createdAt)
                let gestureEpochAtStart = sessions.currentDrawerUserGestureEpoch()
                let userGestureSinceQueue = sessions.drawerUserGestureHappenedSince(queuedAt)
                if !userGestureSinceQueue {
                    // The wall-clock comparison can miss if the gesture and the
                    // queue are within the same timestamp tick (or the job was
                    // queued milliseconds before the gesture); re-check the
                    // monotonic epoch AFTER `closeActive`'s await too, so a
                    // gesture that lands during the await is also caught.
                    await sessions.closeActive()
                    if sessions.drawerUserGestureEpochAdvanced(since: gestureEpochAtStart) {
                        try? await repository.completeNavigationAppIntent(id: job.jobID)
                        continue
                    }
                    NotificationCenter.default.post(name: .hermesOpenSessionsIntent, object: nil)
                }
                try? await repository.completeNavigationAppIntent(id: job.jobID)
            case .newSession:
                sessions.startDraft()
                try? await repository.completeNavigationAppIntent(id: job.jobID)
            case .askHermes:
                // The oldest network job is the FIFO barrier. Do not apply later
                // navigation until this prompt has left the pending queue.
                queue.wake()
                return
            case nil:
                return
            }
        }
        await queue.refresh()
    }

}
