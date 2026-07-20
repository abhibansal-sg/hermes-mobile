import SwiftUI

/// A `taskList` item (docs/RELAY-PHONE-PROTOCOL.md §2 — "taskList semantics"):
/// the agent's ONE living checklist, driven by the relay through the normal
/// `started → delta* → completed` lifecycle on a stable per-session id. The
/// relay is the sole surface that emits `.taskList` (it is the one tool the
/// relay does NOT collapse into a generic `toolCall`); on the direct (gateway)
/// path the same list arrives as a `todo` `ToolActivity` and renders through
/// `ToolActivityRow` → `TodoCardView`.
///
/// Inline-render parity: the body's parsed `TodoList` is handed straight to the
/// EXISTING `TodoCardView`, so a relay-path checklist looks IDENTICAL to a
/// direct-path one in the transcript. The Turn Dock's task box mirrors the SAME
/// list via `ChatStore.latestTodoList` (N4 bridge), and the existing
/// `dockSuppressesTodoCards` rule hides this inline card while the dock is
/// showing it — the suppression is keyed off `dockContent == .tasks`, so it
/// applies to the relay path with no extra wiring.
///
/// While the list streams (`status == .inProgress`) the card still renders so
/// the user sees the live checklist; once `completed` every task is done.
struct TaskListItemView: ChatItemContentView {
    let item: ChatItem

    @Environment(\.hermesTheme) private var theme

    init(item: ChatItem) {
        self.item = item
    }

    var body: some View {
        if let todos = item.taskListBody {
            // Map the item lifecycle onto the ToolActivity state TodoCardView
            // expects so the header glyph matches: a still-streaming taskList
            // is "running"; completed/failed is "done".
            TodoCardView(todos: todos, state: item.status == .inProgress ? .running : .done)
                .accessibilityIdentifier("taskListItemCard")
        } else {
            // Defensive fallback: a `.taskList` item whose body yielded no
            // parseable list (e.g. a first `started` skeleton before any patch).
            // Keep the surface quiet rather than flashing an empty card.
            EmptyView()
        }
    }
}

#if DEBUG
#Preview("TaskList item") {
    VStack(alignment: .leading, spacing: 12) {
        TaskListItemView(item: ChatItem(
            itemID: "s1:tasks", type: .taskList, status: .inProgress, ord: 4,
            summary: "Tasks 1/3",
            body: [
                "tasks": [
                    ["id": "1", "text": "Read auth.py", "status": "completed"],
                    ["id": "2", "text": "Run migration 35", "status": "in_progress"],
                    ["id": "3", "text": "Open a PR", "status": "pending"]
                ],
                "counts": ["total": 3, "completed": 1, "in_progress": 1, "pending": 1],
                "all_complete": false
            ]
        ))
        TaskListItemView(item: ChatItem(
            itemID: "s1:tasks", type: .taskList, status: .completed, ord: 4,
            summary: "Tasks 3/3",
            body: [
                "tasks": [
                    ["id": "1", "text": "Read auth.py", "status": "completed"],
                    ["id": "2", "text": "Run migration 35", "status": "completed"],
                    ["id": "3", "text": "Open a PR", "status": "completed"]
                ],
                "counts": ["total": 3, "completed": 3],
                "all_complete": true
            ]
        ))
    }
    .padding()
}
#endif
