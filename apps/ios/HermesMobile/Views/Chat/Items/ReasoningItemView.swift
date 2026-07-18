import SwiftUI

/// A `reasoning` item (docs/RELAY-PHONE-PROTOCOL.md §2) — the assistant's private
/// chain of thought, rendered as the same collapsible "Thinking…" disclosure the
/// legacy path uses so relay-path and legacy-path reasoning are visually
/// identical. It delegates to ``ThinkingView`` (auto-open while streaming,
/// auto-collapse once settled, first-toggle-wins) rather than re-implementing the
/// accordion.
///
/// The item lifecycle maps straight onto `ThinkingView`'s `streaming` flag: an
/// `in_progress` reasoning item is still streaming; a `completed`/`failed` one is
/// settled. Rendered only when there is reasoning text to show.
struct ReasoningItemView: ChatItemContentView {
    let item: ChatItem

    init(item: ChatItem) {
        self.item = item
    }

    var body: some View {
        let text = item.textBody
        if !text.isEmpty {
            ThinkingView(
                thinking: text,
                streaming: item.status == .inProgress
            )
        }
    }
}

#if DEBUG
#Preview("Reasoning item") {
    VStack(alignment: .leading, spacing: 16) {
        ReasoningItemView(item: ChatItem(
            itemID: "r1", type: .reasoning, status: .completed, ord: 0,
            body: ["text": "Reading the parser, then applying a patch to handle the edge case."]
        ))
        ReasoningItemView(item: ChatItem(
            itemID: "r2", type: .reasoning, status: .inProgress, ord: 1,
            body: ["text": "Considering whether to memoize the segmenter…"]
        ))
    }
    .padding()
}
#endif
