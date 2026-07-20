import SwiftUI

// Wave-2 render-lane seam (docs/RELAY-PHONE-PROTOCOL.md §2/§7). MessageBubble
// routes every `.item` ChatMessagePart here. This file owns the DISPATCH: given a
// resolved `ChatItem`, pick the right per-type renderer. The renderers live in
// `Views/Chat/Items/` — one SwiftUI view per item type — and each conforms to
// `ChatItemContentView` (init from a `ChatItem`). The dispatch SURFACE the client/
// store lane depends on is unchanged: `ChatItemRendering` / `DefaultChatItemRenderer`
// / `ChatItemView(item:)` are the stable contract; only which view each `type`
// maps to lives below.

/// A per-type item renderer: a SwiftUI view constructed from one resolved
/// `ChatItem`. Every view under `Views/Chat/Items/` conforms, so `ChatItemView`
/// can dispatch to them uniformly and tests can construct any renderer the same way.
protocol ChatItemContentView: View {
    init(item: ChatItem)
}

/// The render-dispatch seam the render lane implements: given a fully-resolved
/// `ChatItem`, produce its SwiftUI view. Keeping this a protocol lets a caller
/// swap in a test double or an alternate renderer without touching `MessageBubble`.
protocol ChatItemRendering {
    associatedtype Content: View
    @MainActor @ViewBuilder func view(for item: ChatItem) -> Content
}

/// Default renderer used by `ChatItemView`. Delegates straight to `ChatItemView`,
/// which owns the per-type dispatch.
struct DefaultChatItemRenderer: ChatItemRendering {
    @MainActor
    func view(for item: ChatItem) -> some View {
        ChatItemView(item: item)
    }
}

/// Dispatches a Wave-2 item-backed part to its per-type renderer (`Views/Chat/Items/`).
///
/// The special-render kinds (`toolCall`/`taskList`/`fileChange`/`image`/
/// `browser`/`error`) are what actually flow through `ChatMessagePart.item`;
/// the text-shaped kinds (`agentMessage`/`reasoning`/`usage`) normally project
/// onto legacy parts via `ChatItem.renderPart`, but are dispatched here too so
/// this view can render ANY item type standalone (previews, tests, and a
/// defensive fallback). An unrecognized wire `type` has already folded to
/// `.toolCall` upstream, so the generic `ToolItemCard` is the forward-compat
/// catch-all.
struct ChatItemView: View {
    let item: ChatItem

    var body: some View {
        switch item.type {
        case .toolCall:
            ToolItemCard(item: item)
        case .taskList:
            TaskListItemView(item: item)
        case .fileChange:
            FileChangeItemView(item: item)
        case .image:
            ImageItemView(item: item)
        case .browser:
            BrowserItemView(item: item)
        case .error:
            ErrorItemView(item: item)
        case .reasoning:
            ReasoningItemView(item: item)
        case .usage:
            UsageFooterView(item: item)
        case .agentMessage, .userMessage:
            AgentMessageView(item: item)
        }
    }
}

#if DEBUG
#Preview("All item renderers") {
    ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(RelayFixtures.sampleTurn().compactMap(\.item).enumerated()), id: \.offset) { _, item in
                ChatItemView(item: item)
            }
        }
        .padding()
    }
}
#endif
