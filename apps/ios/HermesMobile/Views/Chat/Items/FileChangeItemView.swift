import SwiftUI

/// A `fileChange` item (docs/RELAY-PHONE-PROTOCOL.md §2) — a tool call that
/// carried an `inline_diff`, rendered as a native diff card. It reuses the
/// existing ``DiffRendering`` classifier + stats and the same green/red line
/// tinting `ToolActivityRow` applies to file-edit diffs, so a relay-path patch
/// reads identically to a legacy-path one.
///
/// The diff starts EXPANDED (parity with `ToolActivityRow.defaultExpanded`): a
/// file edit's whole point is the diff, so it must be visible without an extra
/// tap. A `failed` file change keeps its error/summary legible above the diff.
struct FileChangeItemView: ChatItemContentView {
    let item: ChatItem

    @Environment(\.hermesTheme) private var theme
    @State private var isExpanded = true

    init(item: ChatItem) {
        self.item = item
    }

    private var path: String {
        item.body["path"]?.stringValue ?? item.toolName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if item.status == .failed, let summary = item.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(theme.statusError)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if isExpanded, let diff = item.inlineDiff, !diff.isEmpty {
                diffBlock(diff)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(theme.muted, in: RoundedRectangle(cornerRadius: 8))
        .animation(.snappy(duration: 0.2), value: isExpanded)
        .accessibilityIdentifier("fileChangeItemCard")
    }

    private var header: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                ChatItemStatusIcon(status: item.status)
                    .frame(width: 16, height: 16)
                Image(systemName: "doc.text")
                    .font(.caption2)
                    .foregroundStyle(theme.mutedFg)
                Text(path)
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(theme.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let stat = statLabel {
                    Text(stat)
                        .font(.caption2.monospaced().weight(.semibold))
                        .foregroundStyle(theme.mutedFg)
                }
                Spacer(minLength: 0)
                if hasDiff {
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
        .disabled(!hasDiff)
        .accessibilityLabel("File change \(path), \(item.statusWord)\(statLabel.map { ", \($0)" } ?? "")")
        .accessibilityValue(hasDiff ? (isExpanded ? "expanded" : "collapsed") : "")
    }

    private var hasDiff: Bool {
        (item.inlineDiff?.isEmpty == false)
    }

    /// "+N / -M" from the diff, or nil when there is no diff.
    private var statLabel: String? {
        guard let diff = item.inlineDiff, !diff.isEmpty else { return nil }
        let stats = DiffRendering.stats(for: diff)
        return "+\(stats.added) / -\(stats.removed)"
    }

    private func diffBlock(_ diff: String) -> some View {
        let lines = DiffRendering.lines(in: diff)
        return ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.caption2.monospaced())
                        .foregroundStyle(diffLineForeground(line.kind))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .background(diffLineBackground(line.kind))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 280)
    }

    private func diffLineForeground(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .add: return theme.statusOK
        case .remove: return theme.statusError
        case .context: return theme.mutedFg
        }
    }

    private func diffLineBackground(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .add: return theme.statusOK.opacity(0.12)
        case .remove: return theme.statusError.opacity(0.12)
        case .context: return .clear
        }
    }
}

#if DEBUG
#Preview("File change item") {
    VStack(alignment: .leading, spacing: 12) {
        FileChangeItemView(item: ChatItem(
            itemID: "f1", type: .fileChange, status: .completed, ord: 0,
            summary: "Patched parser.swift",
            body: ["name": "patch", "path": "parser.swift",
                   "inline_diff": "@@ -1,2 +1,3 @@\n context line\n-old line\n+new line\n+added line"]
        ))
        FileChangeItemView(item: ChatItem(
            itemID: "f2", type: .fileChange, status: .failed, ord: 1,
            summary: "Patch did not apply cleanly",
            body: ["name": "patch", "path": "broken.swift",
                   "inline_diff": "@@ -1 +1 @@\n-a\n+b"]
        ))
    }
    .padding()
}
#endif
