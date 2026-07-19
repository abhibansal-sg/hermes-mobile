import XCTest
@testable import HermesMobile

/// Wave 25 — Turn Dock: coverage for the two genuinely new pure seams — the
/// ChatStore latest-todo accessor the dock's task box mirrors, and the dock's
/// priority resolver (approval > clarify > tasks > queued). The SwiftUI surfaces
/// (task box, queued strip, sheet) are structural; the test target has no
/// view-inspection harness, so these exercise the model-level contracts.
@MainActor
final class TurnDockTests: XCTestCase {

    // MARK: - Helpers

    private func todosArray(_ json: String) -> [JSONValue] {
        let data = Data(json.utf8)
        let decoded = try! JSONDecoder().decode(JSONValue.self, from: data)
        return decoded["todos"]!.arrayValue!
    }

    private func todoTool(id: String, todosJSON: String) -> ToolActivity {
        ToolActivity(
            id: id, name: TodoList.toolName, argsSummary: "", progressText: "",
            resultPreview: "", state: .done, durationMs: nil,
            todos: todosArray(todosJSON)
        )
    }

    private func shellTool(id: String) -> ToolActivity {
        ToolActivity(
            id: id, name: "shell", argsSummary: "", progressText: "",
            resultPreview: "ok", state: .done, durationMs: 10, todos: nil
        )
    }

    private func assistant(_ tools: [ToolActivity], clusterID: String) -> ChatMessage {
        ChatMessage(role: .assistant, parts: [
            .tools(id: clusterID, tools: tools, collapsed: false, turnElapsed: nil)
        ])
    }

    // MARK: - latestTodoList / latestTodoToolID

    func testNoMessagesYieldsNoTodoList() {
        let chat = ChatStore()
        XCTAssertNil(chat.latestTodoList)
        XCTAssertNil(chat.latestTodoToolID)
    }

    func testStructuredTodoParsesFromToolsArray() {
        let chat = ChatStore()
        chat.messages = [assistant([
            todoTool(id: "t1", todosJSON: #"""
            {"todos":[{"id":"1","content":"Read auth.py","status":"completed"},
                      {"id":"2","content":"Run migration 35","status":"in_progress"},
                      {"id":"3","content":"Open a PR","status":"pending"}]}
            """#)
        ], clusterID: "c1")]

        XCTAssertEqual(chat.latestTodoToolID, "t1")
        let list = chat.latestTodoList
        XCTAssertEqual(list?.items.count, 3)
        XCTAssertEqual(list?.items[1].status, .inProgress)
        XCTAssertEqual(list?.items[1].content, "Run migration 35")
    }

    func testNewestTodoListWinsAcrossMessages() {
        let chat = ChatStore()
        chat.messages = [
            assistant([todoTool(id: "old", todosJSON:
                #"{"todos":[{"id":"1","content":"Old task","status":"pending"}]}"#)],
                clusterID: "c1"),
            ChatMessage(role: .user, parts: [.text(id: "u", text: "go on")]),
            assistant([todoTool(id: "new", todosJSON:
                #"{"todos":[{"id":"1","content":"New A","status":"completed"},{"id":"2","content":"New B","status":"pending"}]}"#)],
                clusterID: "c2"),
        ]

        XCTAssertEqual(chat.latestTodoToolID, "new", "reverse scan returns the most recent todo activity")
        XCTAssertEqual(chat.latestTodoList?.items.first?.content, "New A")
        XCTAssertEqual(chat.latestTodoList?.items.count, 2)
    }

    func testNonTodoToolsAreIgnored() {
        let chat = ChatStore()
        chat.messages = [assistant([shellTool(id: "s1"), shellTool(id: "s2")], clusterID: "c1")]
        XCTAssertNil(chat.latestTodoList)
        XCTAssertNil(chat.latestTodoToolID)
    }

    func testEmptyTodoListSkippedSoAccessorFallsThrough() {
        // A todo tool whose list is empty yields no parseable TodoList (nothing to
        // show); the accessor must skip it and keep scanning, returning the older
        // non-empty list rather than a spurious hit.
        let chat = ChatStore()
        chat.messages = [
            assistant([todoTool(id: "real", todosJSON:
                #"{"todos":[{"id":"1","content":"Keep me","status":"pending"}]}"#)],
                clusterID: "c1"),
            assistant([todoTool(id: "empty", todosJSON: #"{"todos":[]}"#)], clusterID: "c2"),
        ]
        XCTAssertEqual(chat.latestTodoToolID, "real")
        XCTAssertEqual(chat.latestTodoList?.items.first?.content, "Keep me")
    }

    func testLastTodoWithinAMessageWins() {
        // A single message carrying two todo clusters: the LAST one is the live list.
        let chat = ChatStore()
        let earlier = todoTool(id: "earlier", todosJSON:
            #"{"todos":[{"id":"1","content":"first","status":"completed"}]}"#)
        let later = todoTool(id: "later", todosJSON:
            #"{"todos":[{"id":"1","content":"second","status":"in_progress"}]}"#)
        chat.messages = [ChatMessage(role: .assistant, parts: [
            .tools(id: "c1", tools: [earlier], collapsed: false, turnElapsed: nil),
            .text(id: "t", text: "…"),
            .tools(id: "c2", tools: [later], collapsed: false, turnElapsed: nil),
        ])]
        XCTAssertEqual(chat.latestTodoToolID, "later")
        XCTAssertEqual(chat.latestTodoList?.items.first?.content, "second")
    }

    // MARK: - Dock priority resolver

    func testResolvePriorityOrder() {
        // approval beats everything
        XCTAssertEqual(
            TurnDockContent.resolve(hasApproval: true, hasClarification: true, hasTasks: true, hasQueued: true),
            .approval)
        // clarify beats tasks + queued
        XCTAssertEqual(
            TurnDockContent.resolve(hasApproval: false, hasClarification: true, hasTasks: true, hasQueued: true),
            .clarify)
        // tasks beats queued
        XCTAssertEqual(
            TurnDockContent.resolve(hasApproval: false, hasClarification: false, hasTasks: true, hasQueued: true),
            .tasks)
        // queued is the floor
        XCTAssertEqual(
            TurnDockContent.resolve(hasApproval: false, hasClarification: false, hasTasks: false, hasQueued: true),
            .queued)
        // nothing → none
        XCTAssertEqual(
            TurnDockContent.resolve(hasApproval: false, hasClarification: false, hasTasks: false, hasQueued: false),
            .none)
    }
}
