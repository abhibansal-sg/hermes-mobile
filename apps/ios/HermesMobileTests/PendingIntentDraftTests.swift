import XCTest
@testable import HermesMobile

/// L11 App Intents LOCAL-DRAFT parity (User decision 3).
///
/// The `.newSession` intent/widget path used to eagerly RPC a server session
/// (`createSessionNow()`), orphaning an empty session whenever the user ran it
/// without sending anything. It now opens a LOCAL draft (`startDraft()`) like the
/// in-app "New chat" / desktop Cmd+N — no server state until the first prompt,
/// and no connectivity gate. These tests lock that behavior in.
@MainActor
final class PendingIntentDraftTests: XCTestCase {

    private struct Stores {
        let connection: ConnectionStore
        let sessions: SessionStore
        let chat: ChatStore
    }

    private func makeStores() -> Stores {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        return Stores(connection: connection, sessions: sessions, chat: chat)
    }

    /// Disposable defaults so parking/draining never touches the shared suite.
    private func makeDefaults() -> UserDefaults {
        let suite = "DeepLinkPendingIntentTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - .newSession → local draft

    func testNewSessionAppliesLocalDraftWhenDisconnected() {
        let s = makeStores()
        // Unconnected store. The prior RPC path would re-park and do nothing;
        // a local draft must succeed immediately even with no gateway.
        XCTAssertNotEqual(s.connection.phase, .connected)

        PendingIntentRouter.apply(
            .newSession,
            connection: s.connection,
            sessions: s.sessions,
            chat: s.chat,
            defaults: makeDefaults()
        )

        XCTAssertTrue(s.sessions.isDraft, "newSession must open a local draft")
        XCTAssertNil(s.sessions.activeStoredId, "no server session is created up front")
        XCTAssertNil(s.sessions.activeRuntimeId, "no orphaned runtime session")
    }

    func testNewSessionDoesNotRepark() {
        let s = makeStores()
        let defaults = makeDefaults()

        PendingIntentRouter.apply(
            .newSession,
            connection: s.connection,
            sessions: s.sessions,
            chat: s.chat,
            defaults: defaults
        )

        // A draft needs no connection, so the intent must NOT re-park itself for a
        // later foreground (the old connectivity-gated behavior).
        XCTAssertNil(
            PendingIntent.takePending(from: defaults),
            "newSession (local draft) must not re-park — it succeeds offline."
        )
    }

    func testNewSessionDrainsFromDefaults() {
        let s = makeStores()
        let defaults = makeDefaults()
        PendingIntent.newSession.park(in: defaults)

        PendingIntentRouter.drain(
            connection: s.connection,
            sessions: s.sessions,
            chat: s.chat,
            defaults: defaults
        )

        XCTAssertTrue(s.sessions.isDraft)
        // The parked request is consumed exactly once.
        XCTAssertNil(PendingIntent.takePending(from: defaults))
    }

    // MARK: - .openSessions still pure navigation (no draft)

    func testOpenSessionsDoesNotStartDraft() {
        let s = makeStores()
        PendingIntentRouter.apply(
            .openSessions,
            connection: s.connection,
            sessions: s.sessions,
            chat: s.chat,
            defaults: makeDefaults()
        )
        XCTAssertFalse(s.sessions.isDraft)
    }

    // MARK: - .ask still connectivity-gated (re-parks when offline)

    func testAskReparksWhenDisconnected() {
        let s = makeStores()
        let defaults = makeDefaults()

        PendingIntentRouter.apply(
            .ask(prompt: "hi there"),
            connection: s.connection,
            sessions: s.sessions,
            chat: s.chat,
            defaults: defaults
        )

        // `.ask` needs a live gateway to create + send, so an offline apply must
        // re-park the prompt rather than lose it.
        let reparked = PendingIntent.takePending(from: defaults)
        XCTAssertEqual(reparked, .ask(prompt: "hi there"))
        // It did not create a draft/session in the offline case.
        XCTAssertFalse(s.sessions.isDraft)
    }

    func testAskReparksWhenSendIsNotAccepted() async {
        let defaults = makeDefaults()
        var didCreateSession = false
        var sentPrompts: [String] = []

        await PendingIntentRouter.deliverAskPrompt(
            "retry me",
            defaults: defaults,
            createSessionNow: {
                didCreateSession = true
            },
            currentSessionIdentity: { ("stored-1", "runtime-1") },
            send: { prompt in
                sentPrompts.append(prompt)
                return .refusedAfterSubmitAttempt
            },
            cleanupSession: { _ in
                XCTFail("an ambiguous post-submit refusal must never trigger cleanup")
            }
        )

        XCTAssertTrue(didCreateSession, "the prompt path should still create a session before sending")
        XCTAssertEqual(sentPrompts, ["retry me"])
        XCTAssertEqual(
            PendingIntent.takePending(from: defaults),
            .ask(prompt: "retry me"),
            "a refused send must re-park the Ask Hermes prompt for retry"
        )
    }

    // MARK: - STR-815: orphan-session cleanup on a refused send

    /// A send refused BEFORE `prompt.submit` ever reached the server
    /// (`.refusedBeforeSubmit`) is demonstrably never delivered — the prompt is
    /// re-parked AND the session created solely for this delivery is cleaned up.
    func testAskCleansUpJustCreatedSessionWhenRefusedBeforeSubmit() async {
        let defaults = makeDefaults()
        var cleanedUpIds: [String] = []

        await PendingIntentRouter.deliverAskPrompt(
            "clean me up",
            defaults: defaults,
            createSessionNow: {},
            currentSessionIdentity: { ("stored-just-created", "runtime-just-created") },
            send: { _ in .refusedBeforeSubmit },
            cleanupSession: { storedId in cleanedUpIds.append(storedId) }
        )

        XCTAssertEqual(
            PendingIntent.takePending(from: defaults),
            .ask(prompt: "clean me up"),
            "the prompt must still be re-parked even when cleanup also runs"
        )
        XCTAssertEqual(cleanedUpIds, ["stored-just-created"],
                       "the just-created (still-active) session is cleaned up")
    }

    /// If the active session drifted away from the one this delivery created
    /// (user navigated elsewhere, another create/open raced in) between capture
    /// and the refused send, cleanup must NOT touch whatever is active now — the
    /// prompt is still re-parked, but nothing is deleted through the drifted
    /// active-session path.
    func testAskDoesNotCleanUpWhenActiveSessionDriftedBeforeRefusal() async {
        let defaults = makeDefaults()
        var identityReads = 0
        var cleanupCalls = 0

        await PendingIntentRouter.deliverAskPrompt(
            "drifted",
            defaults: defaults,
            createSessionNow: {},
            currentSessionIdentity: {
                // Simulate drift: the FIRST read (right after create) captures
                // the just-created session; every read after that (the
                // pre-cleanup drift check) reports a DIFFERENT active session,
                // as if the app navigated elsewhere in between.
                identityReads += 1
                return identityReads == 1 ? ("stored-created", "runtime-created") : ("stored-elsewhere", "runtime-elsewhere")
            },
            send: { _ in .refusedBeforeSubmit },
            cleanupSession: { _ in cleanupCalls += 1 }
        )

        XCTAssertEqual(
            PendingIntent.takePending(from: defaults),
            .ask(prompt: "drifted"),
            "the prompt is still re-parked despite the drift"
        )
        XCTAssertEqual(cleanupCalls, 0, "a drifted active session must never be cleaned up")
        XCTAssertEqual(identityReads, 2, "identity is captured after create and re-read fresh at cleanup time, not cached")
    }
}

private func makeWorkRepositoryTestConfiguration(
    protectedDataAvailable: @escaping @Sendable () -> Bool = { true }
) throws -> (configuration: WorkRepositoryConfiguration, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PendingIntentTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (
        WorkRepositoryConfiguration(
            containerURL: directory,
            protectedDataAvailable: protectedDataAvailable
        ),
        directory
    )
}

private func workTestScope(
    serverID: String = "https://gateway.example",
    profileID: String = "default"
) throws -> WorkScope {
    try WorkScope(serverID: serverID, profileID: profileID)
}

final class AppIntentWorkRepositoryTests: XCTestCase {
    func testRapidInvocationsAreIndependentAndFIFO() async throws {
        let test = try makeWorkRepositoryTestConfiguration()
        defer { try? FileManager.default.removeItem(at: test.directory) }
        let repository = try WorkRepository(configuration: test.configuration)
        let start = Date(timeIntervalSince1970: 1_000)

        for index in 0..<5 {
            _ = try await repository.enqueueAppIntent(
                kind: .askHermes,
                text: "request \(index)",
                now: start.addingTimeInterval(Double(index))
            )
        }

        let jobs = try await repository.jobs().filter { $0.kind == .appIntent }
        XCTAssertEqual(jobs.map(\.text), (0..<5).map { "request \($0)" })
        XCTAssertEqual(Set(jobs.map(\.clientMessageID)).count, 5)
        XCTAssertTrue(jobs.allSatisfy { $0.state == .waitingForScope })
    }

    func testTwentyJobCapIsEnforcedTransactionally() async throws {
        let test = try makeWorkRepositoryTestConfiguration()
        defer { try? FileManager.default.removeItem(at: test.directory) }
        let first = try WorkRepository(configuration: test.configuration)
        let second = try WorkRepository(configuration: test.configuration)
        let now = Date(timeIntervalSince1970: 2_000)

        for index in 0..<WorkRepository.appIntentJobLimit {
            let writer = index.isMultiple(of: 2) ? first : second
            _ = try await writer.enqueueAppIntent(
                kind: .askHermes,
                text: "request \(index)",
                now: now.addingTimeInterval(Double(index))
            )
        }

        do {
            _ = try await second.enqueueAppIntent(kind: .newSession, now: now.addingTimeInterval(30))
            XCTFail("The twenty-first active App Intent must be rejected")
        } catch {
            XCTAssertEqual(error as? WorkRepositoryError, .appIntentQueueFull)
        }
        let jobs = try await first.jobs().filter { $0.kind == .appIntent }
        XCTAssertEqual(jobs.count, WorkRepository.appIntentJobLimit)
    }

    func testExpiredJobsAreMarkedBeforeCapacityIsEvaluated() async throws {
        let test = try makeWorkRepositoryTestConfiguration()
        defer { try? FileManager.default.removeItem(at: test.directory) }
        let repository = try WorkRepository(configuration: test.configuration)
        let start = Date(timeIntervalSince1970: 3_000)

        for index in 0..<WorkRepository.appIntentJobLimit {
            _ = try await repository.enqueueAppIntent(
                kind: .openSessions,
                now: start.addingTimeInterval(Double(index))
            )
        }
        let afterExpiry = start.addingTimeInterval(WorkRepository.appIntentLifetime + 30)
        let replacement = try await repository.enqueueAppIntent(kind: .newSession, now: afterExpiry)

        let jobs = try await repository.jobs().filter { $0.kind == .appIntent }
        XCTAssertEqual(jobs.filter { $0.state == .expired }.count, WorkRepository.appIntentJobLimit)
        XCTAssertEqual(jobs.last?.jobID, replacement.jobID)
        XCTAssertEqual(replacement.state, .waitingForScope)
    }

    @MainActor
    func testNavigationJobsCompleteLocallyInFIFOOrder() async throws {
        let test = try makeWorkRepositoryTestConfiguration()
        defer { try? FileManager.default.removeItem(at: test.directory) }
        let observation = WorkRepositoryObservation()
        let repository = try WorkRepository(configuration: test.configuration, observation: observation)
        let scope = try workTestScope()
        let queue = QueueStore(
            repository: repository,
            observation: observation,
            scopeProvider: { scope }
        )
        let sessions = SessionStore()
        let now = Date()
        let first = try await repository.enqueueAppIntent(
            kind: .openSessions, now: now
        )
        let second = try await repository.enqueueAppIntent(
            kind: .newSession, now: now.addingTimeInterval(1)
        )
        let openedSessions = expectation(
            forNotification: .hermesOpenSessionsIntent,
            object: nil
        )
        let suite = "DurableIntent-empty-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        await PendingIntentRouter.drainDurable(
            repository: repository,
            scope: nil,
            sessions: sessions,
            queue: queue,
            defaults: defaults
        )

        let completedFirst = try await repository.job(id: first.jobID)
        let completedSecond = try await repository.job(id: second.jobID)
        XCTAssertEqual(completedFirst?.state, .completed)
        XCTAssertEqual(completedSecond?.state, .completed)
        await fulfillment(of: [openedSessions], timeout: 0.1)
        XCTAssertTrue(sessions.isDraft)
    }

    // MARK: - S9 (QA-3, 3rd recurrence): drawer race — programmatic open-intent
    // dropped when the user has navigated into a session since the intent queued

    /// A parked `.openSessions` App Intent queued BEFORE the user's most recent
    /// drawer-row tap must NOT re-open the drawer when `drainDurable` re-drains
    /// it on a foreground transition. This is the tap-during-in-flight-load
    /// race (S9): the user taps a drawer row, the drawer closes on first paint
    /// / 300ms deadline, then the foreground re-drain fires `closeActive` +
    /// posts `hermesOpenSessionsIntent` → the drawer snaps back open over the
    /// load the user just chose. The fix gates the open-intent on a monotonic
    /// gesture epoch + the user's most recent gesture timestamp.
    @MainActor
    func testOpenSessionsDroppedWhenUserGesturedSinceQueue() async throws {
        let test = try makeWorkRepositoryTestConfiguration()
        defer { try? FileManager.default.removeItem(at: test.directory) }
        let observation = WorkRepositoryObservation()
        let repository = try WorkRepository(configuration: test.configuration, observation: observation)
        let scope = try workTestScope()
        let queue = QueueStore(
            repository: repository,
            observation: observation,
            scopeProvider: { scope }
        )
        let sessions = SessionStore()

        // 1. Park an .openSessions job in the PAST (queued before the user gestured).
        let queueTime = Date().addingTimeInterval(-60)
        let parked = try await repository.enqueueAppIntent(
            kind: .openSessions, now: queueTime
        )

        // 2. The user taps a drawer row to navigate into a session MORE RECENTLY
        //    (in-flight load). The drawer row tap stamps the gesture epoch + time.
        sessions.recordDrawerUserGesture(now: queueTime.addingTimeInterval(60))

        // 3. Foreground transition fires drainDurable.
        let openedSessions = expectation(
            forNotification: .hermesOpenSessionsIntent,
            object: nil
        )
        openedSessions.isInverted = true

        let suite = "S9-race-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        await PendingIntentRouter.drainDurable(
            repository: repository,
            scope: scope,
            sessions: sessions,
            queue: queue,
            defaults: defaults
        )

        // 4. The drawer must NOT re-open: no hermesOpenSessionsIntent posted.
        await fulfillment(of: [openedSessions], timeout: 0.3)

        // 5. The job is still marked complete — it was handled by deliberately
        //    not re-opening, so it doesn't re-drain next foreground.
        let completed = try await repository.job(id: parked.jobID)
        XCTAssertEqual(completed?.state, .completed)
    }

    /// The wall-clock path resolves ties conservatively for the user: when the
    /// gesture timestamp EQUALS the job's queue time (same timestamp tick —
    /// possible when the gesture and the queue happen within the same
    /// `Date()` resolution), the open is still dropped. `>=` (not `>`) is
    /// intentional: a same-instant gesture is treated as "the user acted" — the
    /// alternative (fire) would re-open the drawer over an in-flight load the
    /// user just chose. The legitimate widget-tap path has its queue time
    /// strictly AFTER any prior in-app gesture, so it still fires (proven by
    /// the next test).
    @MainActor
    func testOpenSessionsDroppedWhenGestureTiesQueueTimestamp() async throws {
        let test = try makeWorkRepositoryTestConfiguration()
        defer { try? FileManager.default.removeItem(at: test.directory) }
        let observation = WorkRepositoryObservation()
        let repository = try WorkRepository(configuration: test.configuration, observation: observation)
        let scope = try workTestScope()
        let queue = QueueStore(
            repository: repository,
            observation: observation,
            scopeProvider: { scope }
        )
        let sessions = SessionStore()

        // Park a job "now" so the wall-clock comparison cannot tell it apart
        // from a user gesture that happens "now" too.
        let now = Date()
        let parked = try await repository.enqueueAppIntent(
            kind: .openSessions, now: now
        )
        // No gesture yet — epoch is 0, gesture timestamp is distantPast.

        let openedSessions = expectation(
            forNotification: .hermesOpenSessionsIntent,
            object: nil
        )
        openedSessions.isInverted = true

        // Inject the user's gesture IMMEDIATELY before drainDurable so it lands
        // synchronously on the main actor while the drain is between its
        // capture and the post (closeActive awaits on the main actor, yielding
        // the executor; the gesture bumps the epoch on that yield).
        let suite = "S9-epoch-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Bump BEFORE drainDurable's openSessions branch runs but AFTER the
        // job was queued. The wall-clock comparison ties (both `now`); the
        // epoch comparison catches it: epoch captured by drainDurable (0) is
        // strictly less than the gestured epoch (1).
        sessions.recordDrawerUserGesture(now: now)

        await PendingIntentRouter.drainDurable(
            repository: repository,
            scope: scope,
            sessions: sessions,
            queue: queue,
            defaults: defaults
        )

        await fulfillment(of: [openedSessions], timeout: 0.3)
        let completed = try await repository.job(id: parked.jobID)
        XCTAssertEqual(completed?.state, .completed)
    }

    /// Sanity: a fresh `.openSessions` App Intent whose queue time is at-or-after
    /// the user's most recent gesture (the widget tap that queued it IS the most
    /// recent user action) MUST still open the drawer. The gate is precise, not
    /// a blanket suppression — the legitimate "tap widget to open drawer" path
    /// continues to work.
    @MainActor
    func testOpenSessionsFiresWhenIntentIsNewerThanUserGesture() async throws {
        let test = try makeWorkRepositoryTestConfiguration()
        defer { try? FileManager.default.removeItem(at: test.directory) }
        let observation = WorkRepositoryObservation()
        let repository = try WorkRepository(configuration: test.configuration, observation: observation)
        let scope = try workTestScope()
        let queue = QueueStore(
            repository: repository,
            observation: observation,
            scopeProvider: { scope }
        )
        let sessions = SessionStore()

        // An older in-app gesture (the user opened a session 5 minutes ago).
        sessions.recordDrawerUserGesture(now: Date().addingTimeInterval(-300))

        // The widget tap is MORE RECENT (just now) — it queued the openSessions.
        let parked = try await repository.enqueueAppIntent(kind: .openSessions)

        let openedSessions = expectation(
            forNotification: .hermesOpenSessionsIntent,
            object: nil
        )

        let suite = "S9-fresh-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        await PendingIntentRouter.drainDurable(
            repository: repository,
            scope: scope,
            sessions: sessions,
            queue: queue,
            defaults: defaults
        )

        await fulfillment(of: [openedSessions], timeout: 1.0)
        let completed = try await repository.job(id: parked.jobID)
        XCTAssertEqual(completed?.state, .completed)
    }

    @MainActor
    func testOfflineAskRemainsVisibleInQueueProjection() async throws {
        let test = try makeWorkRepositoryTestConfiguration()
        defer { try? FileManager.default.removeItem(at: test.directory) }
        let observation = WorkRepositoryObservation()
        let repository = try WorkRepository(configuration: test.configuration, observation: observation)
        let queue = QueueStore(
            repository: repository,
            observation: observation,
            scopeProvider: { nil }
        )
        let job = try await repository.enqueueAppIntent(kind: .askHermes, text: "offline")

        XCTAssertEqual(queue.items.map(\.jobID), [job.jobID])
        XCTAssertEqual(queue.items.first?.displayState, .waiting)
    }
}

/// Durable share foreground-coordinator coverage lives in
/// `SharedInboxDrainerTests.swift`.
@MainActor
final class SharedInboxDrainerTests: XCTestCase {}

@MainActor
final class StateFlushCoordinatorTests: XCTestCase {
    func testBackgroundFlushRunsLocalOwnersInOrderAndCoalescesEdges() async {
        var expiration: (() -> Void)?
        var ended: [UIBackgroundTaskIdentifier] = []
        var order: [String] = []
        let token = UIBackgroundTaskIdentifier(rawValue: 7)
        let coordinator = StateFlushCoordinator(
            backgroundTasks: BackgroundTaskClient(
                begin: { _, handler in expiration = handler; return token },
                end: { ended.append($0) }
            ),
            dependencies: .init(
                flushDraft: { order.append("draft") },
                suspendOutbox: { order.append("outbox") },
                flushSyncCursor: { order.append("cursor") },
                flushWidgetSnapshot: { order.append("widget") },
                flushPendingNavigation: { order.append("navigation") }
            )
        )

        coordinator.enterBackground()
        coordinator.enterBackground()
        await coordinator.waitUntilIdleForTesting()

        XCTAssertNotNil(expiration)
        XCTAssertEqual(order, ["draft", "outbox", "cursor", "widget", "navigation"])
        XCTAssertEqual(ended, [token])
    }

    func testExpirationCancelsAndEndsExactlyOnce() async {
        var expiration: (() -> Void)?
        var endCount = 0
        let token = UIBackgroundTaskIdentifier(rawValue: 8)
        let coordinator = StateFlushCoordinator(
            backgroundTasks: BackgroundTaskClient(
                begin: { _, handler in expiration = handler; return token },
                end: { _ in endCount += 1 }
            ),
            dependencies: .init(
                flushDraft: { try? await Task.sleep(for: .seconds(30)) },
                suspendOutbox: {},
                flushSyncCursor: {},
                flushWidgetSnapshot: {},
                flushPendingNavigation: {}
            )
        )

        coordinator.enterBackground()
        await Task.yield()
        expiration?()
        expiration?()
        await coordinator.waitUntilIdleForTesting()

        XCTAssertEqual(endCount, 1)
    }

    func testForceFlushCommitsLatestDraftRevisionBeforeReturning() async throws {
        let test = try makeWorkRepositoryTestConfiguration()
        defer { try? FileManager.default.removeItem(at: test.directory) }
        let suiteName = "StateFlushDraft-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = try WorkRepository(configuration: test.configuration)
        let sessions = SessionStore(defaults: defaults)
        let chat = ChatStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        connection.serverURLString = "https://gateway.test"
        sessions.attach(connection: connection, chat: chat)
        sessions.attachWorkRepository(repository)
        sessions.setComposerDraft("latest unsent revision", for: sessions.activeComposerDraftKey)

        await sessions.flushComposerDraftDurably()

        let scope = try WorkScope(
            serverID: "https://gateway.test",
            profileID: DefaultsKeys.allProfilesScope
        )
        let persisted = try await repository.draft(
            scope: scope,
            contextKey: SessionStore.composerDraftFallbackKey
        )
        XCTAssertEqual(persisted?.draft.text, "latest unsent revision")
    }
}
