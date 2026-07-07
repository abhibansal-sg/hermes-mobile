import XCTest
@testable import HermesMobile

/// STR-545 coverage for `ChatStore.latestCompletedAssistantReply(excluding:)`
/// — the read-only seam the hands-free conversation loop (STR-532) polls to
/// find what to speak next. Must ignore streaming/pending rows, non-assistant
/// rows, and blank assistant turns, and must dedupe by stable `ChatMessage.id`.
@MainActor
final class ChatStoreLatestAssistantReplyTests: XCTestCase {

    func testReturnsMostRecentCompletedAssistantReply() {
        let store = ChatStore()
        let first = ChatMessage(role: .assistant, text: "first reply")
        let second = ChatMessage(role: .assistant, text: "second reply")
        store.messages = [
            ChatMessage(role: .user, text: "hi"),
            first,
            ChatMessage(role: .user, text: "again"),
            second,
        ]

        let reply = store.latestCompletedAssistantReply()

        XCTAssertEqual(reply?.id, second.id)
        XCTAssertEqual(reply?.text, "second reply")
    }

    func testIgnoresStreamingAssistantRow() {
        let store = ChatStore()
        let completed = ChatMessage(role: .assistant, text: "done talking")
        let streaming = ChatMessage(role: .assistant, text: "still typing…", isStreaming: true)
        store.messages = [completed, streaming]

        let reply = store.latestCompletedAssistantReply()

        XCTAssertEqual(reply?.id, completed.id)
    }

    func testIgnoresUserRows() {
        let store = ChatStore()
        let assistantReply = ChatMessage(role: .assistant, text: "the answer")
        store.messages = [assistantReply, ChatMessage(role: .user, text: "thanks")]

        let reply = store.latestCompletedAssistantReply()

        XCTAssertEqual(reply?.id, assistantReply.id)
    }

    func testIgnoresEmptyOrWhitespaceOnlyAssistantRow() {
        let store = ChatStore()
        let real = ChatMessage(role: .assistant, text: "a real reply")
        let blank = ChatMessage(role: .assistant, text: "   \n  ")
        let toolOnly = ChatMessage(role: .assistant, tools: [
            ToolActivity(id: "t1", name: "search", argsSummary: "", progressText: "",
                         resultPreview: "ok", state: .done, durationMs: 50, todos: nil),
        ])
        store.messages = [real, blank, toolOnly]

        let reply = store.latestCompletedAssistantReply()

        XCTAssertEqual(reply?.id, real.id)
    }

    func testNoQualifyingRowReturnsNil() {
        let store = ChatStore()
        store.messages = [
            ChatMessage(role: .user, text: "hello"),
            ChatMessage(role: .assistant, text: "", isStreaming: true),
        ]

        XCTAssertNil(store.latestCompletedAssistantReply())
    }

    func testDedupesByStableMessageId() {
        let store = ChatStore()
        let reply = ChatMessage(role: .assistant, text: "only reply")
        store.messages = [reply]

        XCTAssertEqual(store.latestCompletedAssistantReply(excluding: nil)?.id, reply.id)
        // Same id already "seen" — must not be handed back again.
        XCTAssertNil(store.latestCompletedAssistantReply(excluding: reply.id))
        // A different id was seen — this reply is still new.
        XCTAssertEqual(store.latestCompletedAssistantReply(excluding: UUID())?.id, reply.id)
    }

    func testNewerReplyIsNotSuppressedByAStaleExcludedId() {
        let store = ChatStore()
        let first = ChatMessage(role: .assistant, text: "first")
        store.messages = [first]
        XCTAssertEqual(store.latestCompletedAssistantReply(excluding: nil)?.id, first.id)

        let second = ChatMessage(role: .assistant, text: "second")
        store.messages.append(second)

        // Excluding the FIRST reply's id must not suppress the newer, distinct one.
        XCTAssertEqual(store.latestCompletedAssistantReply(excluding: first.id)?.id, second.id)
    }
}
