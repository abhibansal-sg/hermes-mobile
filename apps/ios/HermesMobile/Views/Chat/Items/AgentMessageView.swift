import SwiftUI

/// An `agentMessage` item (docs/RELAY-PHONE-PROTOCOL.md §2) — the assistant's
/// prose, streamed. It renders through the SAME memoized segmentation pipeline
/// the legacy transcript uses (`RenderCache.segments` → prose / code / math /
/// embed), so relay-path assistant text is byte-identical to legacy-path text:
/// serif prose paragraphs, `CodeBlockView` for fenced code, `MathSegmentView`
/// for LaTeX, and `RichURLEmbedCardView` for bare-URL embeds.
///
/// In the render mapping an `agentMessage` item projects onto the legacy `.text`
/// part, which `MessageBubble` already draws; this view is the render-lane
/// renderer for the same content (item-driven previews/tests, and the fallback
/// should an `agentMessage` ever be dispatched as a raw item).
struct AgentMessageView: ChatItemContentView {
    let item: ChatItem

    @Environment(\.hermesTheme) private var theme

    init(item: ChatItem) {
        self.item = item
    }

    /// Serif body face for prose, matching `MessageBubble.proseFont` (F3). Code,
    /// math, and embeds keep their own faces.
    private static let proseFont: Font = .system(.body, design: .serif)
    private static let segmentSpacing: CGFloat = 12
    private static let proseLineSpacing: CGFloat = 3.5

    var body: some View {
        let text = item.textBody
        let segments = RenderCache.segments(text)
        VStack(alignment: .leading, spacing: Self.segmentSpacing) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let body):
                    Text(RenderCache.prose(body))
                        .font(Self.proseFont)
                        .foregroundStyle(theme.fg)
                        .lineSpacing(Self.proseLineSpacing)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(let language, let body):
                    CodeBlockView(language: language, code: body)
                case .math(let latex, let display):
                    MathSegmentView(latex: latex, display: display)
                case .embed(let descriptor):
                    RichURLEmbedCardView(descriptor: descriptor)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("agentMessageItem")
    }
}

#if DEBUG
#Preview("Agent message item") {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            AgentMessageView(item: ChatItem(
                itemID: "m1", type: .agentMessage, status: .completed, ord: 0,
                body: ["text": "Here is the plan, rendered as **markdown** with a `code` span.\n\n1. Read the parser\n2. Apply the patch"]
            ))
            AgentMessageView(item: ChatItem(
                itemID: "m2", type: .agentMessage, status: .completed, ord: 1,
                body: ["text": "A fenced block:\n\n```swift\nlet x = 1\nprint(x)\n```"]
            ))
        }
        .padding()
    }
}
#endif
