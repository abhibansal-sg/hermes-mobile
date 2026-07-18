import SwiftUI

// Wave-2 collapsed working-sections (owner spec, built on the relay item model —
// docs/RELAY-PHONE-PROTOCOL.md §2). A "working section" folds a consecutive run
// of reasoning + tool/file/browser/image/error ITEM parts under one summary:
//
//   - SETTLED: the whole run collapses to a one-line "Worked for N" capsule, tap
//     to expand into the reasoning accordion + every tool card. If any tool
//     inside failed the capsule carries a red failure badge so the failure is
//     never hidden behind the fold (§2: an error item is never silently hidden).
//   - LIVE (streaming): the reasoning streams inline (via `ThinkingView`) and the
//     tool timeline collapses to a SINGLE current-tool line that updates as tools
//     start/finish (many tools = one line). A manual chevron expands the full
//     timeline; there is no auto-open churn while the turn works.
//
// ADDITIVE: this path fires ONLY for the NEW `.item`-backed parts the relay/mock
// emits. Legacy `.tools` clusters and lone `.reasoning` runs are NOT
// working-eligible for a fold (see `WorkingSectionModel.isWorkingEligible`), so
// the current blob-stream rendering is byte-for-byte unchanged.

// MARK: - Grouping + summary model (pure, deterministically testable)

/// One node in the assistant transcript after working-section grouping: either a
/// standalone part (rendered exactly as before) or a folded working run.
enum AssistantRenderNode: Identifiable, Equatable {
    case part(ChatMessagePart)
    case working(id: String, parts: [ChatMessagePart])

    var id: String {
        switch self {
        case .part(let part): return part.id
        case .working(let id, _): return "working-\(id)"
        }
    }
}

/// Grouping + summary logic for the collapsed working-sections. `nonisolated
/// static` throughout so every rule is unit-testable without a SwiftUI view or an
/// actor hop.
enum WorkingSectionModel {

    /// Whether a part may belong to a working section: streamed `.reasoning`, or
    /// an item-backed special render that represents WORK (tool / file change /
    /// browser / image / error). `.text` / `.usage` / `.warning` break a run, and
    /// LEGACY `.tools` clusters are deliberately excluded so the old blob-stream
    /// rendering (`ToolClusterView`) is untouched — the fold is item-model only.
    nonisolated static func isWorkingEligible(_ part: ChatMessagePart) -> Bool {
        switch part {
        case .reasoning:
            return true
        case .item(_, let item):
            return isWorkingItem(item)
        case .text, .warning, .usage, .tools:
            return false
        }
    }

    /// Item types that render inside a working section. `agentMessage` / `usage` /
    /// `userMessage` project onto legacy parts and never arrive as `.item`, but
    /// are excluded defensively so only real work folds.
    nonisolated static func isWorkingItem(_ item: ChatItem) -> Bool {
        switch item.type {
        case .toolCall, .fileChange, .browser, .image, .error, .reasoning:
            return true
        case .agentMessage, .usage, .userMessage:
            return false
        }
    }

    /// Coalesce the assistant's ordered `parts` into render nodes. A maximal run
    /// of working-eligible parts folds into ONE `.working` node — but ONLY when it
    /// carries at least one `.item` (real work). A run of reasoning alone (the
    /// legacy path, or a pure-thinking turn) decomposes back to individual `.part`
    /// nodes so `ThinkingView` renders it exactly as today.
    nonisolated static func renderNodes(from parts: [ChatMessagePart]) -> [AssistantRenderNode] {
        var nodes: [AssistantRenderNode] = []
        var run: [ChatMessagePart] = []

        func flush() {
            guard !run.isEmpty else { return }
            if run.contains(where: { if case .item = $0 { return true } else { return false } }) {
                nodes.append(.working(id: run[0].id, parts: run))
            } else {
                for part in run { nodes.append(.part(part)) }
            }
            run.removeAll(keepingCapacity: true)
        }

        for part in parts {
            if isWorkingEligible(part) {
                run.append(part)
            } else {
                flush()
                nodes.append(.part(part))
            }
        }
        flush()
        return nodes
    }

    /// The item parts of a run, in order.
    nonisolated static func items(in parts: [ChatMessagePart]) -> [ChatItem] {
        parts.compactMap { part in
            if case .item(_, let item) = part { return item }
            return nil
        }
    }

    /// Whether any item in the run failed — a failed status OR an `error` item.
    /// Drives the collapsed section's failure badge so a fold never hides a
    /// failure (§2).
    nonisolated static func runHasFailure(_ parts: [ChatMessagePart]) -> Bool {
        items(in: parts).contains(where: isFailure)
    }

    /// A single item is a failure iff its status is `.failed` or its type is
    /// `.error` (a failed tool surfaces as either on the wire).
    nonisolated static func isFailure(_ item: ChatItem) -> Bool {
        item.status == .failed || item.type == .error
    }

    /// The tool `body.duration_s` for an item, if present.
    nonisolated static func duration(of item: ChatItem) -> TimeInterval? {
        item.body["duration_s"]?.doubleValue
    }

    /// Wall-clock seconds a settled working section took: the turn's stamped
    /// duration when known, else the sum of the items' own `duration_s`, else nil
    /// (the label then omits the time tail).
    nonisolated static func runDurationSeconds(
        _ parts: [ChatMessagePart],
        settled: TimeInterval?
    ) -> TimeInterval? {
        if let settled, settled > 0 { return settled }
        let summed = items(in: parts).reduce(into: 0.0) { acc, item in
            if let d = duration(of: item), d > 0 { acc += d }
        }
        return summed > 0 ? summed : nil
    }

    /// The current (most recent) tool line shown while the turn is live: the last
    /// still-in-progress item, else simply the last item in the run.
    nonisolated static func currentWorkingItem(in parts: [ChatMessagePart]) -> ChatItem? {
        let its = items(in: parts)
        return its.last(where: { $0.status == .inProgress }) ?? its.last
    }

    /// "Worked for 12s" / "Worked for 2m 3s" / "Worked" (no known duration).
    nonisolated static func workedLabel(seconds: TimeInterval?) -> String {
        guard let seconds, seconds > 0 else { return "Worked" }
        let total = Int(seconds.rounded())
        if total < 60 { return "Worked for \(total)s" }
        return "Worked for \(total / 60)m \(total % 60)s"
    }

    /// VoiceOver label for the collapsed capsule: the worked label plus an
    /// explicit failure clause when the section hid a failed step.
    nonisolated static func summaryAccessibilityLabel(
        seconds: TimeInterval?,
        hasFailure: Bool
    ) -> String {
        let base = workedLabel(seconds: seconds)
        return hasFailure ? "\(base), contains a failed step" : base
    }
}

// MARK: - View

/// Renders one folded working run (see `WorkingSectionModel`). Draws reasoning via
/// the existing `ThinkingView` and every tool/file/browser/image/error item via
/// the Lane-A `ChatItemView` render seam.
struct WorkingSectionView: View {
    /// The run's parts (reasoning + working items), in wire order.
    let parts: [ChatMessagePart]
    /// Whether the owning turn is still streaming — selects the live vs. settled
    /// presentation.
    var streaming: Bool = false
    /// Turn start for the live reasoning elapsed label (from `ChatStore`).
    var liveTurnStartedAt: Date?
    /// Settled turn duration stamped on the message, for the "Worked for N" label.
    var settledDuration: TimeInterval?

    @Environment(\.hermesTheme) private var theme

    /// Manual expansion of the folded timeline. Settled sections start collapsed;
    /// live sections keep the streaming reasoning visible and start with the tool
    /// timeline collapsed to the single current-tool line.
    @State private var isExpanded = false

    private var items: [ChatItem] { WorkingSectionModel.items(in: parts) }
    private var hasFailure: Bool { WorkingSectionModel.runHasFailure(parts) }
    private var durationSeconds: TimeInterval? {
        WorkingSectionModel.runDurationSeconds(parts, settled: settledDuration)
    }

    /// Reasoning runs with renderable (non-empty, cleaned) text, so an empty
    /// reasoning placeholder never mounts an empty `ThinkingView`.
    private var reasoningRuns: [ReasoningRun] {
        parts.compactMap { part in
            guard case .reasoning(let id, let text) = part,
                  !ThinkingDisplay.cleanedText(text).isEmpty else { return nil }
            return ReasoningRun(id: id, text: text)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if streaming {
                liveSection
            } else {
                settledSection
            }
        }
        .padding(.leading, 12)
        .animation(.snappy(duration: 0.2), value: isExpanded)
        .accessibilityIdentifier("workingSection")
    }

    // MARK: - Settled: "Worked for N" fold

    @ViewBuilder
    private var settledSection: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            workedCapsule
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            WorkingSectionModel.summaryAccessibilityLabel(seconds: durationSeconds, hasFailure: hasFailure)
        )
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
        .accessibilityHint("Double-tap to \(isExpanded ? "collapse" : "expand") what the assistant did")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("workingSectionSummary")

        if isExpanded {
            expandedTimeline(includeReasoning: true)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var workedCapsule: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.caption2)
                .foregroundStyle(theme.mutedFg)
            Text(WorkingSectionModel.workedLabel(seconds: durationSeconds))
                .font(.caption.weight(.medium))
                .foregroundStyle(theme.mutedFg)
                .monospacedDigit()
            if hasFailure { failureBadge }
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(theme.mutedFg)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.muted, in: Capsule())
        .contentShape(Capsule())
    }

    // MARK: - Live: streaming reasoning + single current-tool line

    @ViewBuilder
    private var liveSection: some View {
        // Reasoning streams inline while the turn works (never behind the fold).
        ForEach(reasoningRuns) { run in
            ThinkingView(
                thinking: run.text,
                streaming: true,
                liveTurnStartedAt: liveTurnStartedAt,
                settledDuration: nil
            )
        }

        Button {
            withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            currentToolLine
        }
        .buttonStyle(.plain)
        .accessibilityLabel(currentToolAccessibilityLabel)
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
        .accessibilityHint("Double-tap to \(isExpanded ? "collapse" : "expand") the full tool timeline")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("workingSectionCurrentTool")

        if isExpanded {
            // Reasoning is already visible above while live, so the expanded body
            // reveals only the full tool timeline.
            expandedTimeline(includeReasoning: false)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var currentToolLine: some View {
        HStack(spacing: 8) {
            if let item = WorkingSectionModel.currentWorkingItem(in: parts) {
                statusIcon(for: item.status)
                    .frame(width: 16, height: 16)
                Text(item.toolName)
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(theme.fg)
                    .lineLimit(1)
                if let summary = item.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(theme.mutedFg)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Text("Working…")
                    .font(.caption)
                    .italic()
                    .foregroundStyle(theme.mutedFg)
            }
            Spacer(minLength: 0)
            if hasFailure { failureBadge }
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(theme.mutedFg)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.muted, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    private var currentToolAccessibilityLabel: String {
        guard let item = WorkingSectionModel.currentWorkingItem(in: parts) else {
            return "Working"
        }
        let base = "Current tool: \(item.toolName)"
        return hasFailure ? "\(base), contains a failed step" : base
    }

    // MARK: - Expanded timeline (reasoning accordion + item cards)

    @ViewBuilder
    private func expandedTimeline(includeReasoning: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if includeReasoning {
                ForEach(reasoningRuns) { run in
                    ThinkingView(
                        thinking: run.text,
                        streaming: false,
                        settledDuration: nil
                    )
                }
            }
            ForEach(items) { item in
                ChatItemView(item: item)
            }
        }
    }

    // MARK: - Shared chrome

    private var failureBadge: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.caption2)
            .foregroundStyle(theme.statusError)
            .accessibilityLabel("contains a failed step")
    }

    @ViewBuilder
    private func statusIcon(for status: ChatItemStatus) -> some View {
        switch status {
        case .inProgress:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Tool running")
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(theme.statusOK)
                .accessibilityLabel("Tool completed")
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(theme.statusError)
                .accessibilityLabel("Tool failed")
        }
    }
}

/// A renderable reasoning run inside a working section (`Identifiable` for the
/// `ForEach`, keyed on the reasoning part's stable id).
private struct ReasoningRun: Identifiable, Equatable {
    let id: String
    let text: String
}
