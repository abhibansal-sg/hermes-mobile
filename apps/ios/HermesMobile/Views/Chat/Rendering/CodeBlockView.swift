import SwiftUI
import UIKit

/// A fenced code block rendered as a rounded card: a header with the language
/// badge and a copy button, then horizontally-scrollable, syntax-highlighted,
/// monospaced code. Tall blocks are clamped to a max height with an
/// expand/collapse toggle so a long file never swallows the transcript.
///
/// Visual idiom matches the surrounding chat document: the container paints
/// `theme.codeBg`, chrome reads in `theme.mutedFg`, the brand accent is reserved
/// for nothing here (the card stays neutral so code reads cleanly), and
/// `textSelection` is enabled.
struct CodeBlockView: View {
    /// The detected language hint (info string after the opening fence), or nil.
    let language: String?
    /// The raw code body (no fences).
    let code: String

    /// Collapsed code height cap, in points. Blocks taller than this show the
    /// expand affordance.
    private static let maxCollapsedHeight: CGFloat = 400

    @Environment(\.hermesTheme) private var theme

    @State private var isExpanded = false
    @State private var didCopy = false
    @State private var measuredHeight: CGFloat = 0

    var body: some View {
        #if DEBUG
        if RenderCache.expNoCodeCardChrome {
            // Conic-stroke hunt: strip ALL card chrome (bg fill + border stroke +
            // divider) to attribute the per-frame conic-gradient cost.
            return AnyView(VStack(alignment: .leading, spacing: 0) {
                header
                codeBody
            })
        }
        #endif
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(theme.border)
            codeBody
        }
        .background(theme.codeBg, in: cardShape)
        .overlay(
            cardShape
                .strokeBorder(theme.border, lineWidth: 1)
        )
        .perfRasterizeCard())
    }

    /// The card's rounded-rect shape. The corner STYLE is the round-2 scroll
    /// forensics lever: SwiftUI's default `RoundedRectangle(cornerRadius:)` uses
    /// `.continuous` (squircle) corners, whose stroke antialiasing RenderBox
    /// rasterizes via a per-pixel CONIC-GRADIENT coverage pass (`atan2f` per
    /// pixel). That pass dominated the main thread during scroll. `.circular`
    /// corners rasterize as cheap arcs. Default = circular; DEBUG
    /// `HERMES_EXP_CONTINUOUS_CORNERS=1` restores the old continuous look for A/B.
    private var cardShape: RoundedRectangle {
        #if DEBUG
        if RenderCache.expContinuousCorners {
            return RoundedRectangle(cornerRadius: 12, style: .continuous)
        }
        #endif
        return RoundedRectangle(cornerRadius: 12, style: .circular)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            languageBadge

            Spacer(minLength: 0)

            if isClampable {
                Button {
                    withAnimation(.snappy(duration: 0.22)) { isExpanded.toggle() }
                } label: {
                    Label(
                        isExpanded ? "Collapse" : "Expand",
                        systemImage: isExpanded ? "chevron.up" : "chevron.down"
                    )
                    .labelStyle(.iconOnly)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.mutedFg)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse code" : "Expand code")
            }

            copyButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var languageBadge: some View {
        Text(badgeLabel)
            .font(.caption2.monospaced().weight(.semibold))
            .foregroundStyle(theme.mutedFg)
            .textCase(.uppercase)
    }

    private var badgeLabel: String {
        if let language, !language.isEmpty { return language }
        return "code"
    }

    private var copyButton: some View {
        Button {
            copy()
        } label: {
            Label(
                didCopy ? "Copied" : "Copy",
                systemImage: didCopy ? "checkmark" : "doc.on.doc"
            )
            .labelStyle(.iconOnly)
            .font(.caption.weight(.semibold))
            .foregroundStyle(didCopy ? theme.statusOK : theme.mutedFg)
            .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(didCopy ? "Copied to clipboard" : "Copy code")
    }

    // MARK: - Body

    private var codeBody: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(highlighted)
                .perfTextSelection()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .fixedSize(horizontal: true, vertical: true)
                .background(
                    // Measure the natural (uncapped) height once so we know
                    // whether the clamp is doing anything.
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: CodeHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                )
        }
        .perfScrollIndicators()
        .frame(maxHeight: heightCap, alignment: .top)
        .perfClampClip()
        .onPreferenceChange(CodeHeightKey.self) { height in
            // Only publish a meaningfully-changed height. The measured natural
            // height is stable once laid out; re-publishing the same value on
            // every layout pass invalidated the view needlessly during scroll.
            if abs(height - measuredHeight) > 0.5 { measuredHeight = height }
        }
        .overlay(alignment: .bottom) {
            if isClampable && !isExpanded {
                fadeFooter
            }
        }
    }

    /// A gradient hint that there is more code below when collapsed. Fades into
    /// the code container's own background (`codeBg`) so the scrim reads on any
    /// theme — a `systemBackground` scrim would render light over dark themes.
    private var fadeFooter: some View {
        LinearGradient(
            colors: [theme.codeBg.opacity(0), theme.codeBg],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 24)
        .allowsHitTesting(false)
    }

    // MARK: - Derived

    /// The syntax-highlighted attributed code. ANSI-bearing output is rendered
    /// via the ANSI path; everything else goes through the highlighter.
    private var highlighted: AttributedString {
        if code.contains("\u{1B}") {
            return AnsiText.stripOrRender(code, baseColor: theme.fg)
        }
        // Memoized highlight (RenderCache): `highlighted` is a computed property
        // re-evaluated on every body pass, so a flick-scroll re-realizing this
        // code block previously re-ran the full regex highlight from scratch.
        // The cache keys on (code, language, baseColor) so a re-render of
        // unchanged code is an O(1) lookup; a theme change yields a new key.
        return RenderCache.highlight(code, language: language, baseColor: theme.fg)
    }

    /// True when the natural height exceeds the cap (so the toggle is useful).
    private var isClampable: Bool {
        measuredHeight > Self.maxCollapsedHeight + 1
    }

    private var heightCap: CGFloat? {
        guard isClampable, !isExpanded else { return nil }
        return Self.maxCollapsedHeight
    }

    // MARK: - Actions

    private func copy() {
        // Copy clean source: strip ANSI so the clipboard never carries control
        // codes, but keep the original code otherwise verbatim.
        UIPasteboard.general.string = AnsiText.strip(code)
        // Haptic confirmation — light impact mirrors the system share-sheet
        // copy action and gives immediate tactile closure.
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.snappy) { didCopy = true }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.snappy) { didCopy = false }
        }
    }
}

/// Preference key carrying the measured natural height of the code text.
private struct CodeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
