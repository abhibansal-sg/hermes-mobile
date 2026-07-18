import SwiftUI

/// The GENERIC tool card (docs/RELAY-PHONE-PROTOCOL.md §2) — the forward-compat
/// backbone that renders ANY `toolCall` item keyed only off its `name`, so a new
/// Hermes tool (or any wire `type` the phone doesn't recognize, which folds to
/// `.toolCall`) never breaks rendering.
///
/// Collapsed it is one quiet row: state glyph + tool name + a one-line summary,
/// inside the same `theme.muted` container the live `ToolActivityRow` uses, so a
/// relay-path tool call reads identically to a legacy-path one. Tapping expands
/// the detail — arguments, result preview, and duration — mirroring the existing
/// tool row's disclosure without depending on the live `ToolActivity` model.
struct ToolItemCard: ChatItemContentView {
    let item: ChatItem

    @Environment(\.hermesTheme) private var theme
    @State private var isExpanded = false

    init(item: ChatItem) {
        self.item = item
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if isExpanded {
                detail
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(theme.muted, in: RoundedRectangle(cornerRadius: 8))
        .animation(.snappy(duration: 0.2), value: isExpanded)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                ChatItemStatusIcon(status: item.status)
                    .frame(width: 16, height: 16)

                Text(item.toolName)
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(theme.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let summary = item.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(theme.mutedFg)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)

                if hasDetail {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(theme.mutedFg)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.snappy(duration: 0.2), value: isExpanded)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasDetail)
        .accessibilityLabel("\(item.toolName), \(item.statusWord)")
        .accessibilityValue(hasDetail ? (isExpanded ? "expanded" : "collapsed") : "")
        .accessibilityHint(hasDetail ? "Double-tap to \(isExpanded ? "collapse" : "expand") tool details" : "")
        .accessibilityIdentifier("toolItemCardHeader")
    }

    /// Whether there is anything worth expanding to: non-empty args, a result
    /// preview, or a recorded duration.
    private var hasDetail: Bool {
        !item.argsSummary.isEmpty || !item.resultPreview.isEmpty || item.durationSeconds != nil
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !item.argsSummary.isEmpty {
                detailBlock(title: "Arguments", body: item.argsSummary, isError: false)
            }
            if !item.resultPreview.isEmpty {
                detailBlock(
                    title: "Result",
                    body: item.resultPreview,
                    isError: item.status == .failed
                )
            }
            if let duration = ChatItemFormat.duration(item.durationSeconds) {
                Text("Took \(duration)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(theme.mutedFg)
            }
        }
        .padding(.top, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailBlock(title: String, body: String, isError: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isError ? theme.statusError : theme.mutedFg)
            ScrollView(.vertical, showsIndicators: true) {
                Text(body)
                    .font(.caption2.monospaced())
                    .foregroundStyle(isError ? theme.statusError : theme.fg)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
#Preview("Tool item card") {
    VStack(alignment: .leading, spacing: 12) {
        ToolItemCard(item: ChatItem(
            itemID: "t1", type: .toolCall, status: .completed, ord: 0,
            summary: "Read 220 lines",
            body: ["name": "read_file",
                   "args": ["path": "parser.swift"],
                   "result": "…220 lines…",
                   "duration_s": 0.42]
        ))
        ToolItemCard(item: ChatItem(
            itemID: "t2", type: .toolCall, status: .inProgress, ord: 1,
            summary: "grep TODO",
            body: ["name": "search", "args": ["pattern": "TODO"]]
        ))
        // Unknown wire type folds to the generic card, keyed off its real name.
        ToolItemCard(item: ChatItem(
            itemID: "t3", type: ChatItemType(wire: "quantum_flux"), rawType: "quantum_flux",
            status: .failed, ord: 2, summary: "Tool failed",
            body: ["name": "quantum_flux", "result": "flux capacitor offline"]
        ))
    }
    .padding()
}
#endif
