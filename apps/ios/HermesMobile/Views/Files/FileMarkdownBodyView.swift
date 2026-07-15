import SwiftUI

/// Rendered-markdown body for the file viewer (STR-659 arm A / STR-699).
///
/// This is a *presentation* reuse of the existing chat markdown pipeline — it
/// introduces no second parser. Block/code/math structure comes from the shared
/// `RenderCache` segmenter + GFM block parser, paragraphs flow through the same
/// `RenderCache.prose` inline-markdown path the chat bubble uses, and the exact
/// same block views (`MarkdownTableBlockView`, `MarkdownBlockquoteView`,
/// `MarkdownAlertView`, `MarkdownTaskListView`, `MarkdownListBlockView`) plus
/// `CodeBlockView` / `MathSegmentView` render each piece. The only difference
/// from the chat bubble is the absence of streaming-cursor / streaming-flush
/// concerns (a file is a settled document), so this view is a thin, read-only
/// loop over the shared renderers.
///
/// Wraps (vertical-only `ScrollView` lives in `FileViewerView` so the same
/// scroll surface owns the truncation footer for both rendered and source
/// modes); this view just emits the document stack at its natural width.
struct FileMarkdownBodyView: View {
    /// The raw markdown source for the file.
    let text: String

    @Environment(\.hermesTheme) private var theme

    /// Serif body face + paragraph lead, matching the chat prose renderer so a
    /// markdown file reads the same as it would inside an assistant turn.
    private static let proseFont: Font = .system(.body, design: .serif)
    private static let proseLineSpacing: CGFloat = 3.5
    /// Spacing between top-level segments (mirrors `MessageBubble`).
    private static let segmentSpacing: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: Self.segmentSpacing) {
            ForEach(Array(RenderCache.segments(text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let body):
                    proseSegment(body)
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
    }

    /// Lay out the GFM block structure of a prose segment (paragraphs, tables,
    /// blockquotes, alerts, task lists, ordered/unordered lists) using the
    /// shared chat block views.
    @ViewBuilder
    private func proseSegment(_ body: String) -> some View {
        ForEach(Array(RenderCache.markdownBlocks(body).enumerated()), id: \.offset) { _, block in
            blockView(block)
        }
    }

    @ViewBuilder
    private func blockView(_ block: MessageBubble.MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            // Same inline-markdown path as `MessageBubble.paragraphText`: cached
            // `AttributedString(markdown:)` via `RenderCache.prose`, serif body,
            // theme foreground, selectable.
            Text(RenderCache.prose(text))
                .font(Self.proseFont)
                .foregroundStyle(theme.fg)
                .lineSpacing(Self.proseLineSpacing)
                .perfTextSelection()
                .frame(maxWidth: .infinity, alignment: .leading)
        case .table(let table):
            MarkdownTableBlockView(table: table)
        case .blockquote(let text):
            MarkdownBlockquoteView(text: text)
        case .alert(let alert):
            MarkdownAlertView(alert: alert)
        case .taskItems(let items):
            MarkdownTaskListView(items: items)
        case .listItems(let items):
            MarkdownListBlockView(items: items)
        }
    }
}
