import Foundation

enum UITestAudioGuard {
#if DEBUG
    nonisolated(unsafe) static var argumentsForTesting: (() -> [String])?

    static var isUITestAudioMuted: Bool {
        (argumentsForTesting?() ?? ProcessInfo.processInfo.arguments).contains("--uitest-mute-audio")
    }
#else
    static var isUITestAudioMuted: Bool { false }
#endif
}

/// Composition root: builds the store graph once at launch.
@MainActor
final class AppEnvironment {
    let sessionStore: SessionStore
    let chatStore: ChatStore
    let connectionStore: ConnectionStore
    let attachmentStore: AttachmentStore
    let queueStore: QueueStore
    let workRepository: WorkRepository
    let voiceRecorder: VoiceRecorder
    let speechPlayer: SpeechPlayer
    let voiceConversationController: VoiceConversationController
    let inboxStore: InboxStore
    let appLock: AppLock
    let themeStore: ThemeStore
    let projectsStore: ProjectsStore
    let stateFlushCoordinator: StateFlushCoordinator
    private let syncCoordinator: ManifestInvalidationCoordinator

    init() {
        let sessionStore = SessionStore()
        let chatStore = ChatStore()
        let attachmentStore = AttachmentStore()
        let workObservation = WorkRepositoryObservation()
        let workRepository: WorkRepository
        do {
            workRepository = try WorkRepository(
                configuration: .appGroup(),
                observation: workObservation
            )
        } catch {
            fatalError("Unable to open protected Hermes work repository: \(error.localizedDescription)")
        }
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
        let queueStore = QueueStore(
            repository: workRepository,
            observation: workObservation,
            scopeProvider: { [weak sessionStore] in sessionStore?.durableWorkScope },
            activeSessionProvider: { [weak sessionStore] in sessionStore?.activeStoredId },
            // A send is only "healthy in transit" while the live socket is ready;
            // the instant it is not, pending rows are queued-while-offline and
            // surface the badge/pill (C1/C2). Mirrors the drain readiness gate.
            connectedProvider: { [weak connectionStore] in connectionStore?.isTransportReady ?? false }
        )
        let voiceConversationController = VoiceConversationController(
            dependencies: .init(
                startListening: { [weak voiceRecorder, weak connectionStore] in
                    guard let rest = connectionStore?.rest else { return }
                    await voiceRecorder?.start(rest: rest)
                },
                stopAndTranscribe: { [weak voiceRecorder, weak connectionStore] in
                    guard let recorder = voiceRecorder, let rest = connectionStore?.rest else { return nil }
                    return await recorder.stopAndTranscribe(rest: rest)
                },
                cancelListening: { [weak voiceRecorder] in
                    voiceRecorder?.cancel()
                },
                submitTranscript: { [weak chatStore] transcript in
                    _ = await chatStore?.send(text: transcript, includeAttachments: false)
                },
                speak: { [weak speechPlayer, weak connectionStore] text in
                    guard let player = speechPlayer, let rest = connectionStore?.rest else { return }
                    _ = await player.speak(text: text, rest: rest)
                },
                stopSpeaking: { [weak speechPlayer] in
                    speechPlayer?.stop()
                },
                level: { [weak voiceRecorder] in
                    voiceRecorder?.level ?? 0
                }
            )
        )
        let voiceAutoSpeak = VoiceConversationAutoSpeakCoordinator()
        let voiceAmbientAutoSpeak = VoiceConversationAmbientAutoSpeakCoordinator()
        // Stores need back-references for RPC access and cross-store flows.
        sessionStore.attach(connection: connectionStore, chat: chatStore, attachments: attachmentStore)
        sessionStore.attachWorkRepository(workRepository)
        chatStore.attach(connection: connectionStore, sessions: sessionStore, attachments: attachmentStore)
        chatStore.attachOutbox(queueStore)
        let outboxProcessor = OutboxProcessor(
            repository: workRepository,
            dependencies: .init(
                currentScope: { [weak sessionStore] in sessionStore?.durableWorkScope },
                activeStoredSessionID: { [weak sessionStore] in sessionStore?.activeStoredId },
                isTransportReady: { [weak connectionStore] in
                    guard let connectionStore else { return false }
                    // Presentation grace intentionally retains `.connected` so
                    // cached chat stays calm. Durable prompts may drain only
                    // after the live socket completed `gateway.ready`.
                    return connectionStore.isTransportReady
                },
                busySessionID: { [weak chatStore] in
                    // Per-session serialization (Lane C fix 1): a turn streaming —
                    // or a local turn in flight — belongs to the ACTIVE session.
                    // Report its stored id so the processor holds only that
                    // session's queued prompts and drains every other session
                    // now, instead of the old global "any turn streams" block.
                    guard let chatStore,
                          chatStore.isStreaming || chatStore.localTurnInFlight else {
                        return nil
                    }
                    return chatStore.activeStoredSessionId
                },
                createDestination: { [weak sessionStore] _ in
                    guard let sessionStore else { throw OutboxProcessorError.destinationUnavailable }
                    return try await sessionStore.createOutboxDestination()
                },
                resolveRuntime: { [weak sessionStore] storedID in
                    await sessionStore?.runtimeForOutboxDestination(storedID)
                },
                uploadAsset: { [weak connectionStore, weak workRepository] job, snapshot in
                    guard let connectionStore,
                          let rest = connectionStore.rest,
                          let workRepository else {
                        throw AttachmentError.notConfigured
                    }
                    let client = connectionStore.client
                    let data = try await workRepository.assetData(snapshot.asset)
                    let upload = try await rest.uploadDurable(
                        data: data,
                        filename: "\(snapshot.asset.assetID).jpg",
                        mimeType: snapshot.asset.mimeType,
                        ownerJobID: job.jobID
                    )
                    guard let runtimeID = await sessionStore.runtimeForOutboxDestination(
                        job.destinationSessionID ?? job.storedSessionID ?? ""
                    ) else { throw OutboxProcessorError.destinationUnavailable }
                    _ = try await client.requestRaw(
                        "image.attach",
                        params: .object([
                            "session_id": .string(runtimeID),
                            "path": .string(upload.upload.path),
                        ]),
                        timeout: .seconds(30)
                    )
                    return OutboxUploadedAsset(
                        transferID: upload.transferID,
                        remotePath: upload.upload.path
                    )
                },
                willSubmit: { [weak chatStore] job, paths in
                    chatStore?.prepareOutboxSubmission(job: job, remotePaths: paths)
                },
                submit: { [weak chatStore] job, runtimeID, paths in
                    guard let chatStore else { throw GatewayError.notConnected }
                    return try await chatStore.submitOutboxPrompt(
                        job: job,
                        runtimeSessionID: runtimeID,
                        remotePaths: paths
                    )
                },
                processLocalAppIntent: { [weak sessionStore] job in
                    guard let sessionStore else { return false }
                    switch job.intentKind {
                    case .openSessions:
                        await sessionStore.closeActive()
                        NotificationCenter.default.post(
                            name: .hermesOpenSessionsIntent,
                            object: nil
                        )
                        return true
                    case .newSession:
                        sessionStore.startDraft()
                        return true
                    case .askHermes, nil:
                        return false
                    }
                }
            )
        )
        queueStore.installProcessor(outboxProcessor)
        Task {
            try? await workRepository.importLegacyWork(
                from: LegacyWorkImportSource(scope: sessionStore.durableWorkScope)
            )
            _ = try? await workRepository.cleanupShareWork()
            if let scope = sessionStore.durableWorkScope {
                try? await workRepository.bindPendingShares(to: scope)
            }
            await queueStore.refresh()
            queueStore.wake()
        }
        // ABH-351: ProjectsStore needs REST access (the /projects route) —
        // injected after ConnectionStore is built, same pattern as the others.
        projectsStore.attach(connection: connectionStore)
        // Offline-first cache (P3): build the ONE CacheStore actor and inject it
        // behind the session/chat stores. Construction can throw (App Support
        // unavailable, migration failure); on failure we leave the cache `nil`,
        // which makes every store fall back to the network-only path verbatim —
        // the cache is a pure accelerator, never a correctness dependency, so a
        // dead cache degrades to today's behavior rather than breaking the app.
        let cacheStore = try? CacheStore()
        if let cacheStore {
            sessionStore.attachCache(cacheStore)
            chatStore.attachCache(cacheStore)
            inboxStore.attachCache(cacheStore)
            connectionStore.cacheStore = cacheStore
            // Cache-first Projects: share the SESSION list's active
            // (serverId, profileId) partition so a profile/server switch
            // re-partitions Projects in lockstep. Seeds from disk immediately.
            projectsStore.attachCache(cacheStore, scope: { [weak sessionStore] in
                sessionStore?.projectsCacheScope
            })
        }
        // The inbox accumulates broadcast approval/clarify prompts and answers
        // them against each prompt's own runtime via the gateway client.
        inboxStore.attach(connection: connectionStore)
        inboxStore.onCommittedSnapshot = { snapshot in
            var patch = WidgetSnapshotWriter.Patch()
            patch.pendingAttentionCount = .set(snapshot.pendingCount)
            if let metadata = snapshot.metadata {
                patch.serverRevision = .set(String(metadata.revision))
                patch.fetchedAt = .set(Date(timeIntervalSince1970: metadata.updatedAt))
            }
            WidgetSnapshotWriter.write(patch)
        }
        // ConnectionStore's event router also fans approval/clarify/complete to
        // the inbox (see route(event:)); give it the back-reference.
        connectionStore.inboxStore = inboxStore
        // Turn completion drives the queue's "send next" — ChatStore holds no
        // QueueStore reference, so this closure is the seam (see ChatStore).
        // It ALSO ends the in-flight-turn Live Activity (after its own 2s grace).
        let turnCompletionPipeline = VoiceConversationTurnCompletionPipeline(
            drainQueue: { [weak queueStore, weak chatStore] in
                guard let queueStore, let chatStore else { return }
                queueStore.wake()
            },
            completeVoiceTurn: { [weak chatStore, weak voiceConversationController, voiceAutoSpeak] in
                guard let chatStore, let voiceConversationController else { return }
                Task {
                    await voiceAutoSpeak.handleTurnComplete(
                        chat: chatStore,
                        controller: voiceConversationController
                    )
                }
            },
            speakAmbientReply: { [
                weak chatStore, weak voiceConversationController, weak speechPlayer, weak connectionStore,
                voiceAmbientAutoSpeak
            ] in
                guard let chatStore, let voiceConversationController else { return }
                Task {
                    await voiceAmbientAutoSpeak.handleTurnComplete(
                        chat: chatStore,
                        conversationModeActive: voiceConversationController.isEnabled,
                        autoTTSEnabled: DefaultsKeys.voiceAutoTTSValue(),
                        speak: { [weak speechPlayer, weak connectionStore] reply in
                            guard let player = speechPlayer, let rest = connectionStore?.rest else { return }
                            _ = await player.speak(text: reply.text, messageId: reply.id, rest: rest)
                        }
                    )
                }
            }
        )
        chatStore.onTurnComplete = {
            LiveActivityManager.shared.end()
            turnCompletionPipeline.run()
        }
        // Queue self-heal seams (the "No active session" / queues-forever trap on
        // desktop-driven sessions). A resume that BINDS a live runtime drains the
        // outbox — prompts the composer queued while activeRuntimeId was nil (an
        // idle cold-path session emits no turn-completion to trigger a drain).
        sessionStore.onActiveRuntimeBound = { [weak queueStore, weak chatStore] in
            guard let queueStore, let chatStore else { return }
            queueStore.wake()
        }
        // A resume that follows a compression chain tip re-stamps queued prompts
        // parent → continuation so drain's session-affinity guard doesn't skip them.
        sessionStore.onStoredIdMigrated = { [weak queueStore] oldId, newId in
            Task { await queueStore?.restamp(from: oldId, to: newId) }
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
        // Silent pushes are invalidation hints only. Route them through the same
        // authoritative refresh used by foreground recovery, then project the
        // widget after that refresh has completed.
        let syncCoordinator = ManifestInvalidationCoordinator { [weak sessionStore, weak connectionStore] _ in
            guard let sessionStore, let connectionStore else { throw CancellationError() }
            try Task.checkCancellation()
            await sessionStore.refresh()
            try Task.checkCancellation()
            await MainActor.run {
                let connected: Bool
                if case .connected = connectionStore.phase { connected = true } else { connected = false }
                var patch = WidgetSnapshotWriter.Patch()
                patch.connectionState = .set(connected ? .connected : .offline)
                patch.activeTurnCount = .set(sessionStore.activeStoredId == nil ? 0 : 1)
                WidgetSnapshotWriter.write(patch)
            }
            return true
        }
        self.syncCoordinator = syncCoordinator
        Task { await SilentSyncBridge.shared.attach(syncCoordinator) }

        // Push registration: resolve base URL + token off the connection store.
        PushRegistrar.shared.attach(connection: connectionStore)
        BackgroundRefreshCoordinator.shared.configure(
            loadPairing: {
                let defaults = UserDefaults.standard
                guard let url = defaults.string(forKey: DefaultsKeys.serverURL)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !url.isEmpty,
                      let token = KeychainService.loadToken(server: url), !token.isEmpty else { return nil }
                let profile = defaults.string(forKey: DefaultsKeys.activeProfile) ?? DefaultsKeys.allProfilesScope
                return BackgroundManifestScope(gatewayURL: url, scope: profile, token: token)
            },
            sync: { [weak sessionStore] _ in
                guard let sessionStore else { return .retryableFailure }
                let outcome = await sessionStore.refreshOutcome()
                try Task.checkCancellation()
                return outcome
            },
            maintenance: { [weak workRepository, weak queueStore] in
                guard let workRepository else { return }
                try await workRepository.cleanupShareWork()
                try await workRepository.cleanupFinishedWork()
                if let cacheStore {
                    _ = try await cacheStore.evictStaleTranscripts()
                }
                await AttachmentBlobCache.shared.respondToLowAvailableCapacity()
                await queueStore?.refresh()
                WidgetSnapshotWriter.flush()
            }
        )

        let stateFlushCoordinator = StateFlushCoordinator(dependencies: .init(
            flushDraft: { [weak sessionStore] in
                await sessionStore?.flushComposerDraftDurably()
            },
            suspendOutbox: { [weak queueStore] in
                await queueStore?.suspendForBackground()
            },
            flushSyncCursor: { [weak sessionStore] in
                sessionStore?.flushSessionListDeltaCursors()
            },
            flushWidgetSnapshot: { [weak connectionStore] in
                var patch = WidgetSnapshotWriter.Patch()
                if case .connected = connectionStore?.phase {
                    patch.connectionState = .set(.connected)
                } else {
                    patch.connectionState = .set(.offline)
                    patch.isStale = .set(true)
                }
                WidgetSnapshotWriter.write(patch)
                WidgetSnapshotWriter.flush()
            },
            flushPendingNavigation: { [weak workRepository] in
                PendingIntent.flushPendingStorage()
                try? await workRepository?.flushForBackground()
            }
        ))

        self.sessionStore = sessionStore
        self.chatStore = chatStore
        self.attachmentStore = attachmentStore
        self.queueStore = queueStore
        self.workRepository = workRepository
        self.voiceRecorder = voiceRecorder
        self.speechPlayer = speechPlayer
        self.voiceConversationController = voiceConversationController
        self.inboxStore = inboxStore
        self.appLock = appLock
        self.themeStore = themeStore
        self.connectionStore = connectionStore
        self.projectsStore = projectsStore
        self.stateFlushCoordinator = stateFlushCoordinator

        // Do not publish process-local defaults before bootstrap. The shared
        // disk snapshot remains authoritative until committed server state is
        // available; observation below only patches connection state.
        startWidgetSnapshotObservation()
    }

    // MARK: - Widget snapshot

    /// Assemble + publish the current widget snapshot. Reads only `@MainActor`
    /// store state the app already holds; `WidgetSnapshotWriter` debounces
    /// identical writes, so calling this liberally is cheap.
    func writeWidgetSnapshot() {
        var patch = WidgetSnapshotWriter.Patch()
        if case .connected = connectionStore.phase {
            patch.connectionState = .set(.connected)
        } else {
            patch.connectionState = .set(.offline)
            patch.isStale = .set(true)
        }
        WidgetSnapshotWriter.write(patch)
    }

    /// Re-arm `withObservationTracking` so a change to any snapshot input
    /// (connection phase, pending-approval count, active session) republishes the
    /// widget snapshot. Self-perpetuating: the completion re-installs the tracker.
    private func startWidgetSnapshotObservation() {
        withObservationTracking {
            // Touch every input so Observation records a dependency on each.
            _ = connectionStore.phase
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

/// Coordinates the completed-turn reply hand-off for hands-free voice mode.
///
/// `ChatStore` remains the source of truth for transcript rows; this helper
/// keeps only the stable assistant id that has already been handed to the voice
/// loop so duplicate `onTurnComplete`/backfill paths do not re-speak it.
@MainActor
final class VoiceConversationAutoSpeakCoordinator {
    private var lastSpokenAssistantReplyId: UUID?

    func handleTurnComplete(
        chat: ChatStore,
        controller: VoiceConversationController
    ) async {
        guard !UITestAudioGuard.isUITestAudioMuted else { return }

        let reply = chat.latestCompletedAssistantReply(excluding: lastSpokenAssistantReplyId)
        if let reply {
            lastSpokenAssistantReplyId = reply.id
        }
        await controller.handleTurnComplete(replyText: reply?.text)
    }
}

/// Ambient (non-conversation-mode) read-aloud: speaks each newly completed
/// assistant reply via TTS when hands-free conversation mode is NOT active and
/// the user has opted in via ``DefaultsKeys/voiceAutoTTS``. Conversation mode
/// owns its own reply hand-off (``VoiceConversationAutoSpeakCoordinator``) —
/// this is a separate leg with its own dedup state so the two never fight over
/// or double-speak the same utterance.
@MainActor
final class VoiceConversationAmbientAutoSpeakCoordinator {
    private var lastSpokenAssistantReplyId: UUID?

    func handleTurnComplete(
        chat: ChatStore,
        conversationModeActive: Bool,
        autoTTSEnabled: Bool,
        speak: (ChatMessage) async -> Void
    ) async {
        guard !conversationModeActive, autoTTSEnabled else { return }
        guard let reply = chat.latestCompletedAssistantReply(excluding: lastSpokenAssistantReplyId) else { return }
        lastSpokenAssistantReplyId = reply.id
        await speak(reply)
    }
}

/// Tiny composition seam for the app's turn-complete side effects. Keeping the
/// queue drain and voice hand-offs as peers makes it testable that installing
/// conversation-mode plumbing does not clobber the existing queue callback.
/// `speakAmbientReply` defaults to a no-op so pre-existing 2-arg construction
/// sites (and their pinning tests) keep compiling unchanged.
@MainActor
struct VoiceConversationTurnCompletionPipeline {
    var drainQueue: () -> Void
    var completeVoiceTurn: () -> Void
    var speakAmbientReply: () -> Void = {}

    func run() {
        drainQueue()
        completeVoiceTurn()
        speakAmbientReply()
    }
}
