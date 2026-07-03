import Foundation

/// Composition root: builds the store graph once at launch.
@MainActor
final class AppEnvironment {
    let sessionStore: SessionStore
    let chatStore: ChatStore
    let connectionStore: ConnectionStore
    let attachmentStore: AttachmentStore
    let queueStore: QueueStore
    let voiceRecorder: VoiceRecorder
    let speechPlayer: SpeechPlayer
    let inboxStore: InboxStore
    let appLock: AppLock
    let themeStore: ThemeStore
    let projectsStore: ProjectsStore

    init() {
        let sessionStore = SessionStore()
        let chatStore = ChatStore()
        let attachmentStore = AttachmentStore()
        let queueStore = QueueStore()
        let voiceRecorder = VoiceRecorder()
        let speechPlayer = SpeechPlayer()
        let inboxStore = InboxStore()
        let appLock = AppLock()
        let themeStore = ThemeStore()
        let projectsStore = ProjectsStore()
        let connectionStore = ConnectionStore(
            sessionStore: sessionStore,
            chatStore: chatStore
        )
        // Stores need back-references for RPC access and cross-store flows.
        sessionStore.attach(connection: connectionStore, chat: chatStore)
        chatStore.attach(connection: connectionStore, sessions: sessionStore, attachments: attachmentStore)
        // ABH-351: ProjectsStore needs REST access (the /projects route) —
        // injected after ConnectionStore is built, same pattern as the others.
        projectsStore.attach(connection: connectionStore)
        // Offline-first cache (P3): build the ONE CacheStore actor and inject it
        // behind the session/chat stores. Construction can throw (App Support
        // unavailable, migration failure); on failure we leave the cache `nil`,
        // which makes every store fall back to the network-only path verbatim —
        // the cache is a pure accelerator, never a correctness dependency, so a
        // dead cache degrades to today's behavior rather than breaking the app.
        if let cacheStore = try? CacheStore() {
            sessionStore.attachCache(cacheStore)
            chatStore.attachCache(cacheStore)
        }
        // The inbox accumulates broadcast approval/clarify prompts and answers
        // them against each prompt's own runtime via the gateway client.
        inboxStore.attach(connection: connectionStore)
        // ConnectionStore's event router also fans approval/clarify/complete to
        // the inbox (see route(event:)); give it the back-reference.
        connectionStore.inboxStore = inboxStore
        // Turn completion drives the queue's "send next" — ChatStore holds no
        // QueueStore reference, so this closure is the seam (see ChatStore).
        // It ALSO ends the in-flight-turn Live Activity (after its own 2s grace).
        chatStore.onTurnComplete = { [weak queueStore, weak chatStore] in
            LiveActivityManager.shared.end()
            guard let queueStore, let chatStore else { return }
            Task { await queueStore.drain(chat: chatStore) }
        }
        // Queue self-heal seams (the "No active session" / queues-forever trap on
        // desktop-driven sessions). A resume that BINDS a live runtime drains the
        // outbox — prompts the composer queued while activeRuntimeId was nil (an
        // idle cold-path session emits no turn-completion to trigger a drain).
        sessionStore.onActiveRuntimeBound = { [weak queueStore, weak chatStore] in
            guard let queueStore, let chatStore else { return }
            Task { await queueStore.drain(chat: chatStore) }
        }
        // A resume that follows a compression chain tip re-stamps queued prompts
        // parent → continuation so drain's session-affinity guard doesn't skip them.
        sessionStore.onStoredIdMigrated = { [weak queueStore] oldId, newId in
            queueStore?.restamp(from: oldId, to: newId)
        }
        // Live Activity turn-lifecycle seams (X3): start on the first turn event,
        // track the running tool, and reflect a pending approval. The manager
        // no-ops when Live Activities are disabled/unavailable.
        chatStore.onTurnStart = { [weak sessionStore] in
            let title = sessionStore?.activeSummary?.displayTitle ?? "Hermes"
            // Pass the runtime session id so the LA push-token registration can
            // key the gateway's /api/push/live-activity registry by session (A3).
            LiveActivityManager.shared.start(
                sessionTitle: title,
                sessionId: sessionStore?.activeRuntimeId
            )
        }
        chatStore.onToolChange = { toolName in
            LiveActivityManager.shared.update(toolName: toolName)
        }
        chatStore.onApprovalChange = { needsApproval in
            if needsApproval {
                LiveActivityManager.shared.markNeedsApproval()
            } else {
                LiveActivityManager.shared.clearNeedsApproval()
            }
        }
        // A turn discarded WITHOUT completing (session switch, new draft,
        // connection drop, transcript rewrite) ends its Live Activity too —
        // before this seam only message.complete ended it, so every discard
        // path orphaned the activity on the Dynamic Island (R1 #26/#73).
        chatStore.onTurnDiscarded = {
            LiveActivityManager.shared.end()
        }
        // ConnectionStore drains the offline outbox after reconnect backfill.
        connectionStore.queueStore = queueStore
        // Push registration: resolve base URL + token off the connection store.
        PushRegistrar.shared.attach(connection: connectionStore)

        self.sessionStore = sessionStore
        self.chatStore = chatStore
        self.attachmentStore = attachmentStore
        self.queueStore = queueStore
        self.voiceRecorder = voiceRecorder
        self.speechPlayer = speechPlayer
        self.inboxStore = inboxStore
        self.appLock = appLock
        self.themeStore = themeStore
        self.connectionStore = connectionStore
        self.projectsStore = projectsStore

        // Publish an initial widget snapshot from the current (pre-bootstrap)
        // state so the widgets render real data immediately rather than the
        // "No data yet" placeholder, then keep it live via observation.
        writeWidgetSnapshot()
        startWidgetSnapshotObservation()
    }

    // MARK: - Widget snapshot

    /// Assemble + publish the current widget snapshot. Reads only `@MainActor`
    /// store state the app already holds; `WidgetSnapshotWriter` debounces
    /// identical writes, so calling this liberally is cheap.
    func writeWidgetSnapshot() {
        let connected: Bool
        if case .connected = connectionStore.phase { connected = true } else { connected = false }
        WidgetSnapshotWriter.write(
            connected: connected,
            activeSessions: activeSessionCount,
            pendingApprovals: inboxStore.pendingCount
        )
    }

    /// Best-effort "active sessions" count for the widget. The gateway doesn't
    /// surface a live count here, so we use 1 when a session is open, else 0 —
    /// the widget shows "active sessions", and the one the user is driving is the
    /// meaningful figure on device.
    private var activeSessionCount: Int {
        sessionStore.activeStoredId != nil ? 1 : 0
    }

    /// Re-arm `withObservationTracking` so a change to any snapshot input
    /// (connection phase, pending-approval count, active session) republishes the
    /// widget snapshot. Self-perpetuating: the completion re-installs the tracker.
    private func startWidgetSnapshotObservation() {
        withObservationTracking {
            // Touch every input so Observation records a dependency on each.
            _ = connectionStore.phase
            _ = inboxStore.pendingCount
            _ = sessionStore.activeStoredId
        } onChange: { [weak self] in
            // `onChange` fires off the mutation; hop to the main actor to read the
            // stores and re-arm (both are MainActor-isolated).
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.writeWidgetSnapshot()
                self.startWidgetSnapshotObservation()
            }
        }
    }

    /// Foreground usage refresh: fetch today's tokens + cost over REST and fold
    /// them into the widget snapshot. No-op when not connected/configured. Called
    /// from the app's `scenePhase == .active` hook.
    func refreshUsageSnapshot() {
        guard let control = connectionStore.control else { return }
        Task { @MainActor in
            guard let usage = try? await control.usageAnalytics(days: 1) else { return }
            let totalsTokens = (usage.totals.totalInput ?? 0) + (usage.totals.totalOutput ?? 0)
            let todayTokens = usage.daily.last?.totalTokens ?? totalsTokens
            let todayCost = usage.daily.last?.estimatedCost ?? usage.totals.totalEstimatedCost
            WidgetSnapshotWriter.update(tokensToday: todayTokens, costTodayUSD: todayCost)
        }
    }
}
