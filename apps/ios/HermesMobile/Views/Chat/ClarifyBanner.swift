import SwiftUI

/// A material card pinned above the composer when the agent needs the user to
/// pick a choice or answer a question. Resolves via
/// `ChatStore.respondClarification`.
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

    var body: some View {
        let request = clarification.request
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble")
                    .foregroundStyle(theme.midground)
                    .accessibilityHidden(true)
                Text(request.question)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.fg)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !request.choices.isEmpty {
                ChoiceFlowLayout(spacing: 8) {
                    ForEach(request.choices, id: \.self) { choice in
                        Button {
                            respond(choice)
                        } label: {
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

            HStack(spacing: 8) {
                TextField("Type an answer…", text: $freeText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
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
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 14))
        // VC-03: use theme.border (the semantic hairline token) rather than
        // midground.opacity(0.35) so the stroke tracks the active theme palette
        // and reads correctly in both light and dark modes.
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(theme.border, lineWidth: 1)
        )
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
                    proposal: ProposedViewSize(item.size)
                )
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

    private func layout(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needsWrap = !current.items.isEmpty && x + size.width > maxWidth
            if needsWrap {
                rows.append(current)
                let nextY = current.y + current.rowHeight + spacing
                current = Row(items: [], y: nextY, rowHeight: 0)
                x = 0
            }
            current.items.append(Item(index: index, size: size))
            current.rowHeight = max(current.rowHeight, size.height)
            x += size.width + spacing
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
