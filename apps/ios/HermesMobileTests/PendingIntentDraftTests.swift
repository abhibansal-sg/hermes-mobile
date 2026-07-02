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
}

/// Share-extension inbox drain coverage. Kept beside the pending-intent foreground
/// tests because both exercise app-scope foreground drainers without live network.
@MainActor
final class SharedInboxDrainerTests: XCTestCase {

    private struct Stores {
        let connection: ConnectionStore
        let sessions: SessionStore
        let chat: ChatStore
        let attachments: AttachmentStore
    }

    private func makeStores() -> Stores {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        connection.phase = .connected
        return Stores(connection: connection, sessions: sessions, chat: chat, attachments: attachments)
    }

    func testDrainInvokesOnDrainedWithProcessedCount() async {
        let s = makeStores()
        let items = [
            SharedStore.SharedInboxItem(
                id: UUID(), text: "first", url: nil, comment: nil,
                imageFiles: [], createdAt: Date(timeIntervalSince1970: 2)
            ),
            SharedStore.SharedInboxItem(
                id: UUID(), text: "second", url: nil, comment: nil,
                imageFiles: [], createdAt: Date(timeIntervalSince1970: 1)
            ),
        ]
        let drained = expectation(description: "onDrained called")
        var observedCount: Int?
        var processedOrder: [String] = []
        var didClearInbox = false

        SharedInboxDrainer.drain(
            connection: s.connection,
            sessions: s.sessions,
            chat: s.chat,
            attachments: s.attachments,
            onDrained: { count in
                observedCount = count
                drained.fulfill()
            },
            readInbox: { items },
            clearInbox: { didClearInbox = true },
            processItem: { item in
                processedOrder.append(item.text ?? "")
                let storedId = "stored-\(item.text ?? "item")"
                s.sessions.activeStoredId = storedId
                s.sessions.activeRuntimeId = "runtime-\(item.text ?? "item")"
                return (storedId: storedId, runtimeId: s.sessions.activeRuntimeId)
            }
        )

        await fulfillment(of: [drained], timeout: 1)
        XCTAssertEqual(observedCount, 2)
        XCTAssertEqual(processedOrder, ["second", "first"], "shares drain oldest-first")
        XCTAssertTrue(didClearInbox, "a processed batch clears the one-shot inbox")
        XCTAssertEqual(s.sessions.activeStoredId, "stored-first", "the drainer lands on the newest share")
    }
}
