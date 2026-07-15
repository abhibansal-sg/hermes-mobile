import XCTest
@testable import HermesMobile

/// Pins `QueueStore.move(fromOffsets:toOffset:)` — the reorder mutation added
/// by Inc-5 feature-parity work (queue drag-to-reorder).
///
/// Harness mirrors `QueueSelfHealTests.makeQueue()`: isolated `UserDefaults`
/// suite per test so tests never share state and can be run in parallel.
@MainActor
final class QueueReorderTests: XCTestCase {

    private func makeQueue() -> (QueueStore, UserDefaults) {
        let suite = "test.hermes.queuereorder.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (QueueStore(defaults: defaults), defaults)
    }

    private func makeStores() -> (ChatStore, SessionStore) {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        return (chat, sessions)
    }

    // MARK: - move persists new order

    func testMovePersistsNewOrder() {
        // Enqueue [a, b, c]; move index-2 (c) to front → [c, a, b].
        // Reload from the same UserDefaults suite and assert the order survived.
        let (queue, defaults) = makeQueue()
        queue.enqueue("a")
        queue.enqueue("b")
        queue.enqueue("c")

        queue.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        XCTAssertEqual(queue.items.map(\.text), ["c", "a", "b"],
                       "items array reflects the move immediately")

        // Persistence: a fresh store from the same suite must see the new order.
        let reloaded = QueueStore(defaults: defaults)
        XCTAssertEqual(reloaded.items.map(\.text), ["c", "a", "b"],
                       "new order survives a relaunch (UserDefaults round-trip)")
    }

    // MARK: - move preserves session stamps

    func testMovePreservesSessionStamps() {
        // Each item carries a distinct storedSessionId; after a move the stamps
        // must travel with their rows — the FIFO session-affinity guard in drain
        // depends on the stamp staying bound to the correct prompt text.
        let (queue, _) = makeQueue()
        queue.enqueue("alpha",   storedSessionId: "session-A")
        queue.enqueue("beta",    storedSessionId: "session-B")
        queue.enqueue("gamma",   storedSessionId: "session-C")

        // Move gamma (index 2) to front.
        queue.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        let texts  = queue.items.map(\.text)
        let stamps = queue.items.map(\.storedSessionId)

        XCTAssertEqual(texts,  ["gamma", "alpha", "beta"])
        XCTAssertEqual(stamps, ["session-C", "session-A", "session-B"],
                       "each stamp travels with its prompt through the move")
    }

    // MARK: - drain respects reordered order

    func testDrainRespectsReorderedOrder() async {
        // Enqueue [first, second]; reorder to [second, first]; then drain.
        // The first item ATTEMPTED by drain should be "second" (the new head).
        // We observe the drain order via chat.messages: the first user bubble
        // appended is the first item drain attempted (regardless of accepted/not).
        let (queue, _) = makeQueue()
        let (chat, sessions) = makeStores()

        queue.enqueue("first",  storedSessionId: "s1")
        queue.enqueue("second", storedSessionId: "s1")

        // Reorder: move index-1 (second) to front.
        queue.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(queue.items.map(\.text), ["second", "first"])

        // Bind a runtime so drain reaches the send() call (mirrors QueueSelfHealTests
        // testRestampMakesAChainTipPromptDrainEligible pattern).
        sessions.activeRuntimeId = "rt"
        sessions.activeStoredId = "s1"

        await queue.drain(chat: chat)

        // The first user bubble in chat.messages is the first item drain attempted.
        XCTAssertEqual(chat.messages.first(where: { $0.role == .user })?.text, "second",
                       "drain honours the reordered head — 'second' was attempted first")
    }

    // MARK: - move is a no-op on 0- and 1-item queues

    func testMoveNoOpOnEmptyQueue() {
        let (queue, _) = makeQueue()
        // Must not crash; items stays empty.
        queue.move(fromOffsets: IndexSet(integer: 0), toOffset: 0)
        XCTAssertTrue(queue.items.isEmpty)
    }

    func testMoveNoOpOnSingleItemQueue() {
        let (queue, _) = makeQueue()
        queue.enqueue("only")
        queue.move(fromOffsets: IndexSet(integer: 0), toOffset: 0)
        XCTAssertEqual(queue.items.map(\.text), ["only"])
    }
}
