import SwiftUI

/// The subagent delegation tree for the active turn (F4A-A2).
///
/// Renders ``ChatStore/subagentRoots`` + ``ChatStore/subagentChildren(of:)`` as a
/// native indented `List`: each branch shows its goal, a running/terminal status
/// glyph, the latest activity line, and — once complete — a stats footer
/// (duration, tokens, api calls, cost, files touched). FULL NATIVE: system
/// `List`, `Label`, `DisclosureGroup`-style indentation via depth padding; no
/// custom chrome. Identity is carried by `.tint`.
///
/// Surfaced two ways (both owned by A2's mounting code): an iPhone `.sheet` and
/// an iPad inspector tab. Gated on `capabilities.subagentEvents == .available`
/// (passive) and on the store actually having activity.
///
/// STR-145 / ABH-413: a running node with a real (server-issued) `subagent_id`
/// shows a Stop button so a runaway subagent can be killed from the phone.
struct SubagentTreeView: View {
    let chatStore: ChatStore

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        Group {
            if chatStore.hasSubagentActivity {
                List {
                    ForEach(flattened) { row in
                        SubagentRowView(node: row.node, depth: row.depth, chatStore: chatStore)
                    }
                }
                .listStyle(.plain)
            } else {
                ContentUnavailableView(
                    "No subagents",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Delegated tasks appear here when the agent spawns subagents.")
                )
            }
        }
        .navigationTitle("Subagents")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// One renderable row: a node paired with its render depth.
    private struct Row: Identifiable {
        let node: SubagentNode
        let depth: Int
        var id: String { node.id }
    }

    /// Depth-first flatten of the tree into ordered rows (roots, then each root's
    /// children recursively). Depth drives the leading indent.
    private var flattened: [Row] {
        var rows: [Row] = []
        func visit(_ node: SubagentNode, depth: Int) {
            rows.append(Row(node: node, depth: depth))
            for child in chatStore.subagentChildren(of: node) {
                visit(child, depth: depth + 1)
            }
        }
        for root in chatStore.subagentRoots { visit(root, depth: 0) }
        return rows
    }
}

/// A single subagent branch row.
private struct SubagentRowView: View {
    let node: SubagentNode
    let depth: Int
    let chatStore: ChatStore

    @Environment(\.hermesTheme) private var theme

    /// STR-145: this node's interrupt state (absent == `.idle`).
    private var interruptState: ChatStore.SubagentInterruptState {
        chatStore.subagentInterruptStates[node.id] ?? .idle
    }

    private var interruptFailureMessage: String? {
        if case .failed(let message) = interruptState { return message }
        return nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            statusIcon
                .frame(width: 18, height: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(node.goal)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.fg)
                    .lineLimit(2)
                if !node.activity.isEmpty {
                    Text(node.activity)
                        .font(.caption)
                        .foregroundStyle(theme.mutedFg)
                        .lineLimit(2)
                }
                if let model = node.model, !model.isEmpty {
                    Text(model)
                        .font(.caption2.monospaced())
                        .foregroundStyle(theme.mutedFg)
                }
                // STR-145: only a genuine RPC/transport failure surfaces here —
                // the benign "already finished" (found:false) case is a silent
                // no-op and never reaches this text.
                if let message = interruptFailureMessage {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(theme.statusError)
                        .lineLimit(2)
                }
                if node.status != .running {
                    statsFooter
                }
            }
            Spacer(minLength: 0)
            stopButton
        }
        // Indent children under their parent (8pt per depth level).
        .padding(.leading, CGFloat(depth) * 16)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel)
    }

    /// A concise combined label for VoiceOver: status + goal + optional activity.
    private var rowAccessibilityLabel: String {
        let statusText: String
        switch node.status {
        case .running: statusText = "Running"
        case .completed: statusText = "Completed"
        case .timeout: statusText = "Timed out"
        case .error: statusText = "Error"
        }
        var parts = [statusText, node.goal]
        if !node.activity.isEmpty { parts.append(node.activity) }
        if let message = interruptFailureMessage { parts.append("Stop failed: \(message)") }
        return parts.joined(separator: ", ")
    }

    /// The Stop control, shown only for interruptible running nodes (or a
    /// running node currently mid-retry after a genuine failure). Idle/failed
    /// show a tappable red stop icon; stopping shows a disabled spinner;
    /// stopped shows a quiet "Stopping…" label until the terminal complete
    /// frame lands. Not over-designed: no confirmation sheet, no haptics.
    private var stopButton: some View {
        guard node.status == .running, node.hasServerSubagentId else {
            return AnyView(EmptyView())
        }
        switch interruptState {
        case .idle, .failed:
            return AnyView(
                Button {
                    Task { await chatStore.interruptSubagent(nodeId: node.id) }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.statusError)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(interruptFailureMessage != nil ? "Retry stop subagent" : "Stop subagent")
            )
        case .stopping:
            return AnyView(
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 28, height: 28)
                    .accessibilityLabel("Stopping subagent")
            )
        case .stopped:
            return AnyView(
                Text("Stopping…")
                    .font(.caption2)
                    .foregroundStyle(theme.mutedFg)
                    .accessibilityLabel("Stop signal sent, waiting for subagent to end")
            )
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch node.status {
        case .running:
            if interruptState == .stopped {
                Image(systemName: "stop.circle.fill")
                    .foregroundStyle(theme.statusWarn)
            } else {
                ProgressView().controlSize(.small)
            }
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(theme.statusOK)
        case .timeout:
            Image(systemName: "clock.badge.exclamationmark.fill")
                .foregroundStyle(theme.statusWarn)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(theme.statusError)
        }
    }

    /// Compact completion stats: duration · tokens · api calls · cost, plus a
    /// files-touched line. Only the values that are present render.
    @ViewBuilder
    private var statsFooter: some View {
        let parts = statParts
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(theme.mutedFg)
                .monospacedDigit()
        }
        if let summary = node.summary, !summary.isEmpty {
            Text(summary)
                .font(.caption2)
                .foregroundStyle(theme.mutedFg)
                .lineLimit(3)
        }
        let files = node.filesRead.count + node.filesWritten.count
        if files > 0 {
            Text("\(node.filesRead.count) read · \(node.filesWritten.count) written")
                .font(.caption2)
                .foregroundStyle(theme.mutedFg)
        }
    }

    private var statParts: [String] {
        var parts: [String] = []
        if let duration = node.durationSeconds, duration > 0 {
            parts.append(String(format: "%.1fs", duration))
        }
        let tokens = (node.inputTokens ?? 0) + (node.outputTokens ?? 0)
        if tokens > 0 {
            parts.append("\(UsageStats.formatK(tokens)) tok")
        }
        if let calls = node.apiCalls, calls > 0 {
            parts.append("\(calls) call\(calls == 1 ? "" : "s")")
        }
        if let cost = node.costUsd, cost > 0 {
            parts.append(String(format: "$%.4f", cost))
        }
        return parts
    }
}
