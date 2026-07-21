import Foundation

extension Notification.Name {
    static let hermesOpenSessionsIntent = Notification.Name("HermesOpenSessionsIntent")
}

/// Applies durable and one-release legacy App Intent work to the live stores.
///
/// Current invocations drain through ``drainDurable(repository:scope:sessions:queue:defaults:)``.
/// ``drain(connection:sessions:chat:defaults:)`` remains only for the previous
/// version's single-slot `UserDefaults` handoff.
///
/// All work is `@MainActor`: it drives the same `@Observable` stores the UI
/// binds to, so the navigation/transcript changes are observed immediately.
@MainActor
enum PendingIntentRouter {

    /// Take whatever request is parked and apply it, if any.
    ///
    /// Idempotent across foregrounds: the request is *removed* from `UserDefaults`
    /// as it is read, so a second `scenePhase == .active` with nothing newly
    /// parked is a no-op. Safe to call before the connection is ready — `.ask`
    /// needs a live gateway (to create + send), so it is re-parked until connect;
    /// `.newSession` (local draft) and `.openSessions` (pure navigation) need no
    /// connection and always succeed.
    ///
    /// - Parameters:
    ///   - connection: the connection store, used to gate on connectivity.
    ///   - sessions: the session store (create/activate).
    ///   - chat: the chat store (send the prompt once a session is live).
    ///   - defaults: the backing store, injectable for tests.
    static func drain(
        connection: ConnectionStore,
        sessions: SessionStore,
        chat: ChatStore,
        defaults: UserDefaults = .standard
    ) {
        guard let intent = PendingIntent.takePending(from: defaults) else { return }
        apply(intent, connection: connection, sessions: sessions, chat: chat, defaults: defaults)
    }

    /// Drains the durable App Intent queue on foreground. Navigation-only jobs
    /// complete locally and in FIFO order. Ask Hermes stays durable and wakes the
    /// common outbox, which owns destination creation and idempotent submission.
    static func drainDurable(
        repository: WorkRepository,
        scope: WorkScope?,
        sessions: SessionStore,
        queue: QueueStore,
        defaults: UserDefaults = .standard
    ) async {
        // One-release bridge for requests written by the previous app version.
        try? await repository.importLegacyWork(
            from: LegacyWorkImportSource(appDefaults: defaults, scope: scope)
        )
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
                // (widget tap, Siri, Handoff, legacy `importLegacyWork`); the
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

    /// Apply a specific request. Exposed (vs. only `drain`) so a future
    /// custom-URL-scheme or Handoff path can reuse the same activation logic.
    static func apply(
        _ intent: PendingIntent,
        connection: ConnectionStore,
        sessions: SessionStore,
        chat: ChatStore,
        defaults: UserDefaults = .standard
    ) {
        switch intent {
        case .openSessions:
            // Pure navigation: drop any active session so the list takes over.
            Task { await sessions.closeActive() }
            NotificationCenter.default.post(name: .hermesOpenSessionsIntent, object: nil)

        case .newSession:
            // LOCAL-DRAFT PARITY (User decision 3): "New session" must behave like
            // the app's "New chat" and desktop Cmd+N — open a LOCAL draft, NOT an
            // eager server session. The prior `createSessionNow()` RPC'd a real
            // session immediately, orphaning an empty session every time the user
            // ran the intent/widget without sending anything. A draft creates no
            // server state (it materializes lazily on the first prompt via
            // `ChatStore.send`), so it also needs no connectivity gate and no
            // re-park — it succeeds offline and lands the user on the composer.
            sessions.startDraft()

        case .ask(let prompt):
            guard isConnected(connection) else {
                intent.park(in: defaults)
                return
            }
            Task {
                await deliverAskPrompt(
                    prompt,
                    defaults: defaults,
                    createSessionNow: { try await sessions.createSessionNow() },
                    currentSessionIdentity: {
                        guard let storedId = sessions.activeStoredId,
                              let runtimeId = sessions.activeRuntimeId else { return nil }
                        return (storedId, runtimeId)
                    },
                    send: { prompt in
                        let accepted = await chat.send(text: prompt)
                        if accepted { return .accepted }
                        // `chat.send` never got as far as `prompt.submit`: the
                        // refusal is entirely local (no connection, no
                        // resolvable runtime, attachment upload failure), so
                        // the just-created session demonstrably never received
                        // this prompt and is safe to clean up.
                        guard chat.lastSendReachedServer else { return .refusedBeforeSubmit }
                        // `prompt.submit` was dispatched but refused/failed —
                        // this includes the ambiguous case where a transport
                        // failure means the server may have silently accepted
                        // it. Never guess-delete here.
                        return .refusedAfterSubmitAttempt
                    },
                    cleanupSession: { storedId in
                        // `SessionStore.delete` routes through `clearActive()`,
                        // which resets `chat` (including `lastError`) as part
                        // of tearing down the active transcript. That would
                        // clobber the send-refusal reason `deliverAskPrompt`
                        // just parked for the user — preserve/restore it so a
                        // best-effort cleanup failure (or its own reset side
                        // effect) never replaces the real failure the user
                        // needs to see.
                        let preservedError = chat.lastError
                        await sessions.delete(
                            SessionSummary(
                                id: storedId,
                                title: nil,
                                preview: nil,
                                startedAt: nil,
                                messageCount: nil,
                                source: nil,
                                lastActive: nil,
                                cwd: nil,
                                profile: nil
                            )
                        )
                        chat.lastError = preservedError
                    }
                )
            }
        }
    }

    /// Outcome of attempting to deliver `.ask`'s prompt into the session this
    /// delivery just created via `createSessionNow()`.
    enum AskSendOutcome {
        /// `prompt.submit` was accepted by the server.
        case accepted
        /// Refused before `prompt.submit` ever reached the server (no
        /// connection, no resolvable runtime, attachment-upload failure) —
        /// demonstrably never delivered, so the just-created session is safe
        /// to also clean up, not just re-park the prompt.
        case refusedBeforeSubmit
        /// `prompt.submit` was dispatched but its outcome could not be
        /// observed (busy rejection, or a transport failure that may mean the
        /// server actually accepted it). Re-park the prompt; never delete the
        /// session — we cannot rule out the server having accepted it.
        case refusedAfterSubmitAttempt
    }

    static func deliverAskPrompt(
        _ prompt: String,
        defaults: UserDefaults,
        createSessionNow: @escaping @MainActor () async throws -> Void,
        currentSessionIdentity: @escaping @MainActor () -> (storedId: String, runtimeId: String)?,
        send: @escaping @MainActor (String) async -> AskSendOutcome,
        cleanupSession: @escaping @MainActor (String) async -> Void
    ) async {
        let intent = PendingIntent.ask(prompt: prompt)
        do {
            try await createSessionNow()
        } catch {
            // Could not create a session: re-park so we don't lose the user's
            // prompt; they'll get it on the next good foreground.
            intent.park(in: defaults)
            return
        }
        // Capture the identity of the session we just created for this
        // delivery, so a refused send can be safely cleaned up ONLY when it's
        // still the active session (see the drift check below).
        let createdIdentity = currentSessionIdentity()

        // `createSessionNow()` sets `activeRuntimeId`; `send` can still refuse
        // the prompt (busy, transport failure, lost runtime). Preserve it for a
        // later foreground instead of silently dropping it.
        let outcome = await send(prompt)
        switch outcome {
        case .accepted:
            return
        case .refusedAfterSubmitAttempt:
            intent.park(in: defaults)
        case .refusedBeforeSubmit:
            intent.park(in: defaults)
            // Best-effort orphan cleanup: only when the active session still
            // matches what THIS delivery created. If the user/app navigated
            // elsewhere, opened another session, or a concurrent create/send
            // raced in between capture and now, the active pointers will have
            // drifted — skip cleanup rather than risk deleting a session this
            // delivery didn't create. Re-parking the prompt above is already
            // sufficient in that case.
            if let createdIdentity,
               let stillActive = currentSessionIdentity(),
               stillActive.storedId == createdIdentity.storedId,
               stillActive.runtimeId == createdIdentity.runtimeId {
                await cleanupSession(createdIdentity.storedId)
            }
        }
    }

    /// Whether the gateway is in a state where a prompt can actually be sent.
    /// `.connected` only — `.reconnecting`/`.offline`/`.needsSetup` would drop
    /// the prompt (`ChatStore.send` requires `activeRuntimeId`), so we re-park.
    private static func isConnected(_ connection: ConnectionStore) -> Bool {
        if case .connected = connection.phase { return true }
        return false
    }
}
