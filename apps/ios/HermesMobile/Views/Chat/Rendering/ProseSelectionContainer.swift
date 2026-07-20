import SwiftUI
import UIKit

// MARK: - B11 / QA-1 A6: word-granularity native selection across agent prose
//
// The daily-driver QA build (B11, IMG_2519) rendered each contiguous prose run as
// an INDEPENDENT selection island (`SelectableProseText`): long-press swapped the
// run for a first-responding `UITextView` that auto-selected the ENTIRE run and
// offered a manual "Done" exit. Selection therefore started whole-paragraph (no
// word granularity) and could never extend past the paragraph (sibling islands),
// which is exactly what the owner reported.
//
// The ratified restructure (docs/qa1-root-causes.md B11, spec B11/A6) folds every
// contiguous prose run of an assistant message into ONE `UITextView`-backed
// container:
//
//   * Long-press is the SYSTEM gesture — word-level selection at the touch point
//     with native drag handles; dragging a handle extends the selection across
//     paragraph / list / blockquote / alert boundaries (they are not walls).
//   * No swap gesture, no `selectAll` on mount, no "Done" button — exit by
//     tapping away (standard UIKit selection dismissal).
//   * Cards (code, math, embeds, tables, images) stay NON-SELECTABLE islands:
//     they split the prose flow and render as their existing dedicated views
//     between prose containers.
//   * No Copy|Share pill (N5 islands rules) — the system edit menu on the live
//     selection provides Copy.
//
// The flattener (`ProseFlowBuilder`) and the inline-markdown bridge
// (`ProseInlineBridge`) are pure statics so unit tests pin the contract without
// a hosted view.

/// Style inputs for the single-container prose renderer. All values are resolved
/// from the ambient theme at the call site, so a theme / Dynamic-Type change
/// produces a new style (and a new cache key) rather than a stale render.
struct ProseFlowStyle: Equatable {
    /// Serif body face for prose runs (F3 / Amendment E) — matches the old
    /// `SelectableProseText` face so settled prose reads identically.
    var bodyFont: UIFont
    /// Monospaced face for inline code runs.
    var monoFont: UIFont
    /// Default prose foreground.
    var fg: UIColor
    /// Muted foreground (list markers, blockquote text, unchecked boxes).
    var mutedFg: UIColor
    /// Link tint + underline colour (Wave 25 link style).
    var linkColor: UIColor
    /// Blockquote line tint (the old `theme.muted.opacity(0.18)` card bg, now a
    /// per-line highlight — UITextView cannot draw the rounded card + left bar).
    var quoteBackground: UIColor
    /// Checked-task checkbox tint.
    var taskCheckTint: UIColor
    /// Extra leading between wrapped lines inside a block (UI-C C1).
    var lineSpacing: CGFloat
    /// Gap between blocks inside one container (mirrors `segmentSpacing`).
    var paragraphSpacing: CGFloat

    /// Value fingerprint for `RenderCache.proseFlowPieces` — a theme switch
    /// yields a new key and re-flattens once, never a stale tint.
    var cacheKey: String {
        [
            bodyFont.fontName, "\(bodyFont.pointSize)",
            monoFont.fontName, "\(monoFont.pointSize)",
            "\(fg)", "\(mutedFg)", "\(linkColor)", "\(quoteBackground)", "\(taskCheckTint)",
            "\(lineSpacing)", "\(paragraphSpacing)",
        ].joined(separator: "\u{1F}")
    }
}

/// Folds a prose segment body (already hoisted for markdown images by
/// `MessageBubble.chatProseEntries`) into render pieces: one attributed string
/// per contiguous run of prose blocks (paragraphs / lists / task lists /
/// blockquotes / alerts), with tables and images as non-selectable island
/// pieces that split the flow. Pure and deterministic — unit-tested directly.
/// `@MainActor` because it consumes the `@MainActor` `RenderCache` memo layer.
@MainActor
enum ProseFlowBuilder {

    /// One render piece of a prose segment.
    enum Piece: Equatable {
        /// A selectable prose container payload — one or more flattened prose
        /// blocks merged into a single attributed string.
        case prose(NSAttributedString)
        /// A non-selectable native table island.
        case table(MessageBubble.MarkdownTable)
        /// A non-selectable native image island (STR-695 hoist).
        case image(alt: String, source: String)

        static func == (lhs: Piece, rhs: Piece) -> Bool {
            switch (lhs, rhs) {
            case let (.prose(a), .prose(b)): return a.isEqual(to: b)
            case let (.table(a), .table(b)): return a == b
            case let (.image(a1, s1), .image(a2, s2)): return a1 == a2 && s1 == s2
            default: return false
            }
        }
    }

    /// Flatten `body` into flow pieces. Consecutive prose blocks merge into ONE
    /// `.prose` container (so selection flows across paragraphs); `.table`
    /// blocks and hoisted `.image` entries flush the pending prose and emit
    /// island pieces.
    static func pieces(body: String, style: ProseFlowStyle, linkColor: Color) -> [Piece] {
        var pieces: [Piece] = []
        var pending: [MessageBubble.MarkdownBlock] = []

        func flush() {
            guard !pending.isEmpty else { return }
            let attr = attributedBlocks(pending, style: style, linkColor: linkColor)
            pending.removeAll(keepingCapacity: true)
            guard attr.length > 0 else { return }
            pieces.append(.prose(attr))
        }

        for entry in MessageBubble.chatProseEntries(body) {
            switch entry {
            case .blocks(let blocks):
                for block in blocks {
                    if case .table(let table) = block {
                        flush()
                        pieces.append(.table(table))
                    } else {
                        pending.append(block)
                    }
                }
            case .image(let alt, let source):
                flush()
                pieces.append(.image(alt: alt, source: source))
            }
        }
        flush()
        return pieces
    }

    // MARK: Block flattening

    /// Merge prose blocks into one attributed string. Each block keeps its own
    /// paragraph styling; the gap between blocks is `style.paragraphSpacing`
    /// (applied to the last paragraph of every block except the final one, so
    /// the container carries no dangling bottom gap).
    static func attributedBlocks(
        _ blocks: [MessageBubble.MarkdownBlock],
        style: ProseFlowStyle,
        linkColor: Color
    ) -> NSAttributedString {
        let rendered = blocks.map { attributedBlock($0, style: style, linkColor: linkColor) }
        let joined = NSMutableAttributedString()
        for (index, block) in rendered.enumerated() {
            let isLast = index == rendered.count - 1
            if isLast {
                joined.append(block)
            } else {
                let spaced = NSMutableAttributedString(attributedString: block)
                setParagraphSpacing(style.paragraphSpacing, onLastParagraphOf: spaced)
                joined.append(spaced)
                joined.append(NSAttributedString(string: "\n"))
            }
        }
        return joined
    }

    private static func attributedBlock(
        _ block: MessageBubble.MarkdownBlock,
        style: ProseFlowStyle,
        linkColor: Color
    ) -> NSAttributedString {
        switch block {
        case .paragraph(let text):
            return inlineParagraph(text, style: style, linkColor: linkColor, paragraph: baseParagraph(style: style))
        case .listItems(let items):
            return listItems(items, style: style, linkColor: linkColor)
        case .taskItems(let items):
            return taskItems(items, style: style, linkColor: linkColor)
        case .blockquote(let text):
            return blockquote(text, style: style, linkColor: linkColor)
        case .alert(let alert):
            return alertBlock(alert, style: style, linkColor: linkColor)
        case .table:
            // Tables are flushed as island pieces and never reach here.
            return NSAttributedString()
        }
    }

    /// Inline-markdown paragraph with the given paragraph style.
    private static func inlineParagraph(
        _ text: String,
        style: ProseFlowStyle,
        linkColor: Color,
        paragraph: NSParagraphStyle
    ) -> NSAttributedString {
        let bridged = ProseInlineBridge.attributedString(
            from: RenderCache.prose(text, linkColor: linkColor),
            style: style
        )
        if bridged.length > 0 {
            bridged.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: bridged.length))
        }
        return bridged
    }

    private static func baseParagraph(style: ProseFlowStyle) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = style.lineSpacing
        p.paragraphSpacing = 0
        return p
    }

    // MARK: Lists

    private static func listItems(
        _ items: [MessageBubble.MarkdownListItem],
        style: ProseFlowStyle,
        linkColor: Color
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, item) in items.enumerated() {
            let indent = CGFloat(item.level) * 18
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = style.lineSpacing
            paragraph.paragraphSpacing = 0
            paragraph.firstLineHeadIndent = indent
            paragraph.headIndent = indent + 18
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent + 18)]

            let line = NSMutableAttributedString()
            // Marker run — muted, semibold; ordinals keep the serif face with
            // monospaced digits so numbered lists stay column-aligned (parity
            // with the old MarkdownListBlockView).
            var markerFont = semibold(style.bodyFont)
            if item.marker != "•" {
                markerFont = markerMonospacedDigit(style.bodyFont)
            }
            line.append(NSAttributedString(
                string: "\(item.marker)\t",
                attributes: [.font: markerFont, .foregroundColor: style.mutedFg, .paragraphStyle: paragraph]
            ))
            // Item body — inline markdown in the serif prose face.
            let body = ProseInlineBridge.attributedString(
                from: RenderCache.prose(item.text, linkColor: linkColor),
                style: style
            )
            body.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: body.length))
            line.append(body)

            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            result.append(line)
        }
        return result
    }

    // MARK: Task lists

    private static func taskItems(
        _ items: [MessageBubble.MarkdownTaskItem],
        style: ProseFlowStyle,
        linkColor: Color
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, item) in items.enumerated() {
            let indent = CGFloat(item.level) * 18
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = style.lineSpacing
            paragraph.paragraphSpacing = 0
            paragraph.firstLineHeadIndent = indent
            paragraph.headIndent = indent + 22
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent + 22)]

            let line = NSMutableAttributedString()
            // Checkbox glyph — an inline SF Symbol attachment so the native
            // checkmark.square.fill / square render exactly as before; the
            // object-replacement char keeps the glyph OUT of the copied text.
            // The glyph is the line's first character, so IT must carry the
            // paragraph style (TextKit takes first-line indent from the
            // line-start run) or nested items lose their level indent.
            if let glyph = checkboxAttachment(checked: item.checked, style: style) {
                let glyphString = NSMutableAttributedString(attachment: glyph)
                glyphString.addAttributes(
                    [.paragraphStyle: paragraph, .font: style.bodyFont],
                    range: NSRange(location: 0, length: glyphString.length)
                )
                line.append(glyphString)
            }
            line.append(NSAttributedString(
                string: "\t",
                attributes: [.font: style.bodyFont, .paragraphStyle: paragraph]
            ))
            let body = ProseInlineBridge.attributedString(
                from: RenderCache.prose(item.text, linkColor: linkColor),
                style: style
            )
            if item.checked {
                body.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                                  range: NSRange(location: 0, length: body.length))
                body.addAttribute(.strikethroughColor, value: style.mutedFg,
                                  range: NSRange(location: 0, length: body.length))
            }
            body.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: body.length))
            line.append(body)

            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            result.append(line)
        }
        return result
    }

    private static func checkboxAttachment(checked: Bool, style: ProseFlowStyle) -> NSTextAttachment? {
        let name = checked ? "checkmark.square.fill" : "square"
        let configuration = UIImage.SymbolConfiguration(font: style.bodyFont)
        let tint = checked ? style.taskCheckTint : style.mutedFg
        guard let image = UIImage(systemName: name, withConfiguration: configuration)?
            .withTintColor(tint, renderingMode: .alwaysOriginal)
        else { return nil }
        let attachment = NSTextAttachment()
        attachment.image = image
        // Center the glyph on the text cap height so it sits on the line.
        let y = (style.bodyFont.capHeight - image.size.height) / 2
        attachment.bounds = CGRect(x: 0, y: y.rounded(), width: image.size.width, height: image.size.height)
        return attachment
    }

    // MARK: Blockquotes / alerts

    private static func blockquote(
        _ text: String,
        style: ProseFlowStyle,
        linkColor: Color
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style.lineSpacing
        paragraph.paragraphSpacing = 0
        paragraph.firstLineHeadIndent = 12
        paragraph.headIndent = 12
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let bridged = ProseInlineBridge.attributedString(
                from: RenderCache.prose(line, linkColor: linkColor),
                style: style,
                defaultColor: style.mutedFg
            )
            // Per-line tint reads as the old card background within the single
            // text container (UITextView cannot draw the rounded card / bar).
            if bridged.length > 0 {
                bridged.addAttribute(.backgroundColor, value: style.quoteBackground,
                                     range: NSRange(location: 0, length: bridged.length))
                bridged.addAttribute(.paragraphStyle, value: paragraph,
                                     range: NSRange(location: 0, length: bridged.length))
            }
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            result.append(bridged)
        }
        return result
    }

    private static func alertBlock(
        _ alert: MessageBubble.MarkdownAlert,
        style: ProseFlowStyle,
        linkColor: Color
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let accent = UIColor(alert.kind.accentColor)
        let labelFont = semibold(UIFont.preferredFont(forTextStyle: .caption1))
        result.append(NSAttributedString(
            string: alert.kind.label.uppercased(),
            attributes: [
                .font: labelFont,
                .foregroundColor: accent,
                .paragraphStyle: baseParagraph(style: style),
            ]
        ))
        let body = inlineParagraph(alert.body, style: style, linkColor: linkColor, paragraph: baseParagraph(style: style))
        if body.length > 0 {
            result.append(NSAttributedString(string: "\n"))
            result.append(body)
        }
        return result
    }

    // MARK: Font helpers

    private static func semibold(_ font: UIFont) -> UIFont {
        let traits = font.fontDescriptor.symbolicTraits.union(.traitBold)
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    private static func markerMonospacedDigit(_ font: UIFont) -> UIFont {
        let mono = UIFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .semibold)
        guard let descriptor = mono.fontDescriptor.withDesign(.serif) else { return mono }
        return UIFont(descriptor: descriptor, size: mono.pointSize)
    }

    /// Set `spacing` as the `paragraphSpacing` of the final paragraph of `s`.
    private static func setParagraphSpacing(_ spacing: CGFloat, onLastParagraphOf s: NSMutableAttributedString) {
        guard s.length > 0 else { return }
        let text = s.string as NSString
        let lastNewline = text.range(of: "\n", options: .backwards).location
        let start = lastNewline == NSNotFound ? 0 : min(lastNewline + 1, s.length - 1)
        let range = NSRange(location: start, length: s.length - start)
        let existing = s.attribute(.paragraphStyle, at: start, longestEffectiveRange: nil, in: range) as? NSParagraphStyle
        let paragraph = NSMutableParagraphStyle()
        if let existing { paragraph.setParagraphStyle(existing) }
        paragraph.paragraphSpacing = spacing
        s.addAttribute(.paragraphStyle, value: paragraph, range: range)
    }
}

/// Bridges the cached SwiftUI `AttributedString` inline-markdown render
/// (`MessageBubble.attributed` via `RenderCache.prose`) into a
/// `NSAttributedString` a `UITextView` can lay out. Maps SwiftUI presentation
/// intents onto UIKit font traits (bold / italic / inline code) and re-applies
/// the transcript link style, so the container reads exactly like the old
/// `Text(attributed)` render — serif body, tinted underlined links, monospaced
/// inline code — while being genuinely selectable.
@MainActor
enum ProseInlineBridge {

    static func attributedString(
        from source: AttributedString,
        style: ProseFlowStyle,
        defaultColor: UIColor? = nil
    ) -> NSMutableAttributedString {
        let base = defaultColor ?? style.fg
        let result = NSMutableAttributedString()
        for run in source.runs {
            let text = String(source[run.range].characters)
            guard !text.isEmpty else { continue }

            var font = style.bodyFont
            if let intent = run.inlinePresentationIntent {
                var traits: UIFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                if intent.contains(.code) { font = style.monoFont }
                if !traits.isEmpty,
                   let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits)) {
                    font = UIFont(descriptor: descriptor, size: font.pointSize)
                }
            }

            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            if let url = run.link {
                attributes[.link] = url
                attributes[.foregroundColor] = style.linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            } else {
                attributes[.foregroundColor] = base
            }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        return result
    }
}

/// One selectable container for a contiguous prose run of an assistant message.
///
/// Backed by a non-editable, selectable `UITextView`: the SYSTEM long-press
/// starts WORD-level selection at the touch point with native drag handles, and
/// a handle drag extends the selection across every paragraph inside the
/// container (B11 / A6). There is deliberately NO `becomeFirstResponder` /
/// `selectAll` on mount and NO custom exit affordance — exit is the standard
/// tap-away dismissal. The system edit menu on the live selection provides Copy
/// (no Copy|Share pill — N5 islands rules intact).
struct ProseSelectionContainer: UIViewRepresentable {
    /// The flattened prose payload (inline markdown + block styling baked in).
    let text: NSAttributedString

    func makeUIView(context: Context) -> SelfSizingTextView {
        let view = SelfSizingTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = []
        // Fonts are resolved from the preferred text styles at build time and
        // rebuilt when the environment's type size changes (new `text` value),
        // so UIKit must not also auto-scale them.
        view.adjustsFontForContentSizeCategory = false
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.attributedText = text
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: SelfSizingTextView, context: Context) {
        if uiView.delegate !== context.coordinator {
            uiView.delegate = context.coordinator
        }
        // Only replace the text on a real content change — a re-render (theme /
        // layout / streaming flush with an identical settled prefix) must never
        // yank an in-progress selection.
        if let current = uiView.attributedText, current.isEqual(to: text) { return }
        uiView.attributedText = text
    }

    /// Self-size to the proposed width, like the `Text` this replaces. Never
    /// reads `UIScreen.main` (STR-695).
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SelfSizingTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fit.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UITextViewDelegate {
        /// Links keep the SwiftUI `Text(.link)` behavior: the system opens the
        /// URL (Safari). Returning `true` delegates the open to the system.
        func textView(
            _ textView: UITextView,
            shouldInteractWith URL: URL,
            in characterRange: NSRange,
            interaction: UITextItemInteraction
        ) -> Bool {
            true
        }
    }
}
