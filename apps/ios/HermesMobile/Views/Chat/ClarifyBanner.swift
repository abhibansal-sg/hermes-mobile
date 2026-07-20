import SwiftUI

/// A native-material gate card pinned above the composer when the agent needs
/// the user to pick a choice or answer a question. Resolves via
/// ``ChatStore.respondClarification``.
///
/// QA-2 R7–R10 + A4 + C1 rebuild. The pre-QA-2 card was a hand-rolled
/// `theme.card` rect with a 1pt stroke, bubble-identical `.bordered` choice
/// chips, a pure-black `.roundedBorder` free-text field, and a plain arrow
/// glyph — it read as a foreign object on the transcript
/// (`docs/qa2-image-ledger.md` IMG_2534/2537/2539). This rebuild puts the card
/// on the SAME native surface idiom the composer uses (``GateCardSurface`` →
/// `glassEffect(.regular.interactive())` on iOS 26+, themed fallback below),
/// bounds the question inside a scrollable header so long text never grows the
/// card past the nav bar (R10), wraps long choices to multi-line inside the
/// proposed width so they never hard-clip (R10), and dismisses the keyboard on
/// appear so composer + card + keyboard never stack (R9).
///
/// Transport-agnostic: it reads `chatStore.pendingClarification` (set identically
/// by the gateway-direct router and the QA-1 B10 relay gate bridge) and calls
/// `respondClarification` (which routes over the relay or the gateway client).
/// Only the VIEW layer changed; the §5 relay wire shape is untouched.
struct ClarifyBanner: View {
    /// The pending clarification to present.
    let clarification: PendingClarification
    /// The chat store that owns the clarification response RPC.
    let chatStore: ChatStore

    @Environment(\.hermesTheme) private var theme

    @State private var freeText = ""
    /// True while a respond RPC is in flight — gates re-entry and disables
    /// the chips/send so a double-tap can't double-respond (release audit P1).
    @State private var isResponding = false
    /// R9: the free-text field is COLLAPSED by default ("Type answer" row) so
    /// the card stays compact (C2) and the keyboard is dismissed on appear.
    /// Tapping the row reveals the field AND focuses it — "type answer" brings
    /// the keyboard back per the spec.
    @State private var isComposingFreeText = false
    @FocusState private var freeTextFocused: Bool

    /// Cap the question header so a long prompt scrolls inside the card instead
    /// of growing the card past the nav bar (R10, IMG_2537). ~5 lines at
    /// subheadline is enough to read the question in context; the rest scrolls.
    private let questionHeaderMaxHeight: CGFloat = 132

    var body: some View {
        let request = clarification.request
        VStack(alignment: .leading, spacing: 12) {
            questionHeader(request)

            if !request.choices.isEmpty {
                choicesList(request)
            }

            freeTextSection
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .gateCardSurface(theme: theme, cornerRadius: 18)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(theme.border.opacity(0.6), lineWidth: 0.5)
        )
        // R9: dismiss the composer's keyboard the instant the card mounts, so
        // composer + card + keyboard never stack (IMG_2534/2537). The composer
        // owns its own @FocusState; resigning first responder app-wide is the
        // single chokepoint (same seam RootView uses on drawer open).
        .onAppear { KeyboardDismissal.resign() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Clarification request")
    }

    // MARK: - Question (R10: bounded scroll header)

    @ViewBuilder
    private func questionHeader(_ request: ClarifyRequestPayload) -> some View {
        ScrollView {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "questionmark.bubble")
                    .font(.subheadline)
                    .foregroundStyle(theme.midground)
                    .accessibilityHidden(true)
                Text(request.question)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.fg)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .frame(maxHeight: questionHeaderMaxHeight)
    }

    // MARK: - Choices (R10: wrap to multi-line inside the width, never clip)

    @ViewBuilder
    private func choicesList(_ request: ClarifyRequestPayload) -> some View {
        ChoiceFlowLayout(spacing: 8) {
            ForEach(request.choices, id: \.self) { choice in
                Button {
                    respond(choice)
                } label: {
                    // R10: plain Text wraps at the layout's proposed width by
                    // default (no fixedSize, no maxWidth:.infinity — those would
                    // either prevent wrapping or stretch short chips to full
                    // width). The flow layout proposes a bounded width per chip
                    // so a long choice wraps inside the card instead of
                    // hard-clipping off-screen (IMG_2539); a short choice keeps
                    // its natural compact width.
                    Text(choice)
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.bordered)
                .tint(theme.midground)
                .disabled(isResponding)
                .accessibilityHint("Double-tap to select this answer")
            }
        }
    }

    // MARK: - Free text (R9: collapsed "Type answer" → reveal + focus)

    @ViewBuilder
    private var freeTextSection: some View {
        if isComposingFreeText {
            HStack(spacing: 8) {
                TextField("Type an answer…", text: $freeText, axis: .vertical)
                    .font(.callout)
                    .foregroundStyle(theme.fg)
                    .focused($freeTextFocused)
                    .lineLimit(1...4)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(theme.input.opacity(0.5))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(theme.border, lineWidth: 0.5)
                    )
                    .onSubmit(submitFreeText)

                Button {
                    submitFreeText()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSubmitFreeText ? theme.midground : theme.mutedFg)
                .disabled(!canSubmitFreeText || isResponding)
                .accessibilityLabel("Submit answer")
            }
            .onAppear { freeTextFocused = true }
        } else {
            Button {
                isComposingFreeText = true
            } label: {
                Label("Type answer", systemImage: "text.bubble")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
            }
            .buttonStyle(.bordered)
            .tint(theme.midground.opacity(0.85))
            .disabled(isResponding)
            .accessibilityHint("Brings the keyboard back so you can type a custom answer")
        }
    }

    private var canSubmitFreeText: Bool {
        !freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitFreeText() {
        let trimmed = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        respond(trimmed)
    }

    private func respond(_ answer: String) {
        // In-flight guard (release audit P1): two rapid taps on a choice chip
        // previously fired two concurrent clarify responds — the second went
        // out after `pendingClarification` cleared and duplicated the answer.
        guard !isResponding else { return }
        isResponding = true
        freeText = ""
        Task {
            await chatStore.respondClarification(answer)
            isResponding = false
        }
    }
}

/// A minimal wrapping layout: places subviews left-to-right, flowing onto a new
/// line when the current row would overflow the proposed width.
///
/// QA-2 R10 fix: the layout now PROPOSES the row's remaining width to each
/// subview (not `.unspecified`). The pre-QA-2 layout asked each choice for its
/// ideal (single-line) width and placed it verbatim — a ≥100-char choice sized
/// to its full ideal width ran past the screen edge and hard-clipped
/// (IMG_2539). By proposing the bounded width, the choice's
/// `fixedSize(horizontal:false, vertical:true)` label wraps inside the row
/// instead. Wrapping is the ratified C1 behavior (native chips wrap).
struct ChoiceFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = layout(subviews: subviews, maxWidth: maxWidth)
        let height = rows.last.map { $0.y + $0.rowHeight } ?? 0
        let widest = rows.map(rowWidth).max() ?? 0
        return CGSize(width: min(widest, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let rows = layout(subviews: subviews, maxWidth: bounds.width)
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: bounds.minY + row.y),
                    proposal: ProposedViewSize(width: item.size.width, height: item.size.height))
                x += item.size.width + spacing
            }
        }
    }

    private struct Item {
        let index: Int
        let size: CGSize
    }

    private struct Row {
        var items: [Item] = []
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
    }

    /// Total width consumed by a row, including inter-item spacing.
    private func rowWidth(_ row: Row) -> CGFloat {
        let items = row.items.reduce(CGFloat.zero) { $0 + $1.size.width }
        let gaps = spacing * CGFloat(max(0, row.items.count - 1))
        return items + gaps
    }

    /// Canonical wrap layout. For each subview we propose the REMAINING row
    /// width (or the FULL card width when starting a fresh row) — never
    /// `.unspecified`. A plain `Text` label (the choice chip) returns its
    /// intrinsic width when short, and wraps to multi-line within the proposed
    /// width when long. This is the R10 fix: the pre-QA-2 layout asked each
    /// chip for its ideal (`.unspecified`) width, so a ≥100-char choice sized
    /// to its full single-line width and ran past the screen edge
    /// (IMG_2539). When a chip does not fit the remaining row, we wrap to a
    /// new line and RE-measure it at the full card width so a long choice
    /// wraps to its own row instead of a cramped narrow column.
    private func layout(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0

        func measure(_ index: Int, proposedWidth: CGFloat) -> CGSize {
            subviews[index].sizeThatFits(
                ProposedViewSize(width: max(0, proposedWidth), height: nil))
        }

        for index in subviews.indices {
            let proposedWidth: CGFloat = current.items.isEmpty ? maxWidth : (maxWidth - x)
            let size = measure(index, proposedWidth: proposedWidth)
            let needsWrap = !current.items.isEmpty && x + size.width > maxWidth
            if needsWrap {
                rows.append(current)
                let nextY = current.y + current.rowHeight + spacing
                current = Row(items: [], y: nextY, rowHeight: 0)
                x = 0
                // Re-measure at the full row width so a long choice wraps on
                // its own line at the card's content width, not the narrow
                // remainder it just rejected.
                let fullSize = measure(index, proposedWidth: maxWidth)
                current.items.append(Item(index: index, size: fullSize))
                current.rowHeight = max(current.rowHeight, fullSize.height)
                x += fullSize.width + spacing
            } else {
                current.items.append(Item(index: index, size: size))
                current.rowHeight = max(current.rowHeight, size.height)
                x += size.width + spacing
            }
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
