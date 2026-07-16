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
