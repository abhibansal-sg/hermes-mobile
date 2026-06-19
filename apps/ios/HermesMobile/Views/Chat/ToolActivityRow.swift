import SwiftUI

/// The tool-activity area of an assistant turn — ONE consecutive-run `.tools`
/// cluster (a non-tool part closes the run, so each `ToolClusterView` is exactly
/// one cluster, not the whole turn).
///
/// Renders the cluster's `ToolActivity` timeline in one of two modes (UI-C C1):
///
/// - **Live / single-tool / not-yet-collapsed** — every tool shows as its own
///   `ToolActivityRow`, stacked with 6pt intra-cluster spacing. This is what the
///   user watches while a turn streams (rows light up and finish in place) and
///   what a cluster with a single tool keeps permanently (no summary
///   indirection — desktop transparent passthrough).
/// - **Collapsed** — once a finalized LIVE turn settles, each cluster decides
///   INDEPENDENTLY (ABH-87 Batch D / §3.2): a cluster of ≥2 consecutive tools
///   folds into ONE summary capsule "⚙ N tool calls · Xs" (expands on tap), set
///   by `ChatMessage.collapseFinishedToolClusters`. A single-tool cluster never
///   collapses — so `text→toolA→text→toolB` shows TWO lone rows, while
///   consecutive `toolA,toolB` shows one collapsed summary (fixes D8's multiple
///   "1 tool call" capsules).
///
/// Both modes share the `theme.muted` container + 12pt leading indent so the
/// tool cluster reads as one quiet block inside the assistant gutter.
struct ToolClusterView: View {
    /// This cluster's tools, in start order.
    let tools: [ToolActivity]
    /// True once this finalized cluster (which has ≥2 tools) collapsed into a
    /// summary. A single-tool cluster is always `false` (§3.2).
    let collapsed: Bool
    /// Wall-clock seconds the turn took, for the summary's "· Xs" tail. Falls
    /// back to the sum of per-tool durations when absent.
    let turnElapsed: TimeInterval?

    @Environment(\.hermesTheme) private var theme

    /// Whether the collapsed summary is currently expanded into the full
    /// timeline. Ignored when `collapsed` is false.
    @State private var isExpanded = false

    var body: some View {
        if collapsed && tools.count >= 2 {
            collapsedCluster
        } else {
            liveCluster
        }
    }

    // MARK: - Live / expanded timeline

    /// Every tool as its own row, 6pt apart, each in its muted container.
    private var liveCluster: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(tools) { tool in
                // A `todo` tool result renders as a native checklist card rather
                // than a generic tool row (F4A-A2). Parsed from the STRUCTURED
                // `tool.todos` retained verbatim off the wire (ABH-46 item 10)
                // — never from `resultPreview`, whose 300-char truncation breaks
                // the JSON re-parse for any real list. The preview-parse remains
                // only as a fallback for seeded/legacy activities that predate
                // the structured field. Falls back to the standard row when
                // neither yields a list (e.g. mid-run).
                if tool.name == TodoList.toolName,
                   let todos = tool.todos.flatMap({ TodoList(todosArray: $0) })
                    ?? TodoList(resultJSON: tool.resultPreview) {
                    TodoCardView(todos: todos, state: tool.state)
                } else {
                    ToolActivityRow(activity: tool)
                }
            }
        }
        .padding(.leading, 12)
    }

    // MARK: - Collapsed summary capsule

    @ViewBuilder
    private var collapsedCluster: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                summaryCapsule
            }
            .buttonStyle(.plain)
            // A11y: the capsule contains a decorative gearshape + text fragments;
            // without an explicit label VoiceOver reads the image name. Provide a
            // synthesised label matching the visible text, plus the expanded state.
            .accessibilityLabel(summaryText)
            .accessibilityValue(isExpanded ? "expanded" : "collapsed")
            .accessibilityHint("Double-tap to \(isExpanded ? "collapse" : "expand") tool details")
            .accessibilityAddTraits(.isButton)

            if isExpanded {
                liveCluster
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.leading, 12)
        // CC-04: animate the container height with the content so expanding
        // and collapsing eases smoothly rather than snapping to size.
        .animation(.snappy(duration: 0.2), value: isExpanded)
    }

    private var summaryCapsule: some View {
        HStack(spacing: 6) {
            Image(systemName: "gearshape")
                .font(.caption2)
                .foregroundStyle(theme.mutedFg)
            Text(summaryText)
                .font(.caption.weight(.medium))
                .foregroundStyle(theme.mutedFg)
                .monospacedDigit()
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

    /// "N tool calls · Xs". Elapsed prefers the turn wall-clock; otherwise sums
    /// the per-tool durations; otherwise omits the time tail entirely.
    ///
    /// Extracted as `nonisolated static` (matching ``MessageBubble/bubbleAccessibilityLabel``
    /// pattern) so unit tests can verify the a11y label format without constructing
    /// a SwiftUI view or entering an actor context.
    nonisolated static func summaryLabel(toolCount: Int, elapsedSeconds: TimeInterval?) -> String {
        let noun = toolCount == 1 ? "tool call" : "tool calls"
        if let seconds = elapsedSeconds {
            return String(format: "%d %@ · %.0fs", toolCount, noun, seconds)
        }
        return "\(toolCount) \(noun)"
    }

    private var summaryText: String {
        Self.summaryLabel(toolCount: tools.count, elapsedSeconds: elapsedSeconds)
    }

    /// Turn wall-clock if known, else the sum of per-tool `durationMs`.
    private var elapsedSeconds: TimeInterval? {
        if let turnElapsed, turnElapsed > 0 { return turnElapsed }
        let summed = tools.compactMap(\.durationMs).reduce(0, +)
        return summed > 0 ? summed / 1000 : nil
    }
}

/// One row in an assistant turn's tool-activity timeline.
///
/// Collapsed: leading state icon + tool name + a one-line summary, inside a
/// `theme.muted` container. Tapping expands an inline panel showing the call
/// arguments and a preview of the result.
struct ToolActivityRow: View {
    /// The tool call to render. Updates in place as progress/result arrive.
    let activity: ToolActivity

    @Environment(\.hermesTheme) private var theme

    @State private var isExpanded = false

    /// Product (summary) vs technical (raw args + result) verbosity for the
    /// expanded panel (F4A-A2). Persisted in DefaultsKeys (default = product);
    /// `@AppStorage` keeps every expanded row in sync and survives relaunch.
    @AppStorage(DefaultsKeys.toolTechnicalDetail) private var technicalDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    stateIcon
                        .frame(width: 16, height: 16)

                    Text(activity.name)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(theme.fg)

                    Text(AnsiText.strip(activity.summaryLine))
                        .font(.caption2)
                        .foregroundStyle(theme.mutedFg)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(theme.mutedFg)
                        // CC-09: animate the chevron rotation so it pivots
                        // smoothly with the expand/collapse gesture.
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.snappy(duration: 0.2), value: isExpanded)
                        // The chevron is a decorative affordance; the parent
                        // Button already announces "Tool details" + expanded state.
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // A11y: surface as a named button whose value reflects expanded state;
            // VoiceOver reads "Tool details, expanded/collapsed, button" and swipe
            // to toggle. Uses .isButton (already implied on Button but explicit here
            // for `.accessibilityAddTraits` completeness per DrawerSessionRow pattern).
            .accessibilityLabel("Tool details")
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isExpanded ? "expanded" : "collapsed")
            .accessibilityIdentifier("toolDetailDisclosure")

            if isExpanded {
                expandedDetail
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(theme.muted, in: RoundedRectangle(cornerRadius: 8))
        // CC-09: animate the row container height so it grows/shrinks with
        // the detail panel rather than snapping.
        .animation(.snappy(duration: 0.2), value: isExpanded)
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch activity.state {
        case .running:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Tool running")
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(theme.statusOK)
                .accessibilityLabel("Tool completed")
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(theme.statusError)
                .accessibilityLabel("Tool failed")
        }
    }

    @ViewBuilder
    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The product/technical toggle (F4A-A2): a native `Toggle` bound to the
            // persisted DefaultsKey, so flipping it here changes verbosity for
            // every expanded row and survives a relaunch.
            Toggle("Show technical detail", isOn: $technicalDetail)
                .font(.caption2)
                .tint(theme.midground)
                .foregroundStyle(theme.mutedFg)

            if technicalDetail {
                // TECHNICAL: raw call arguments + result preview.
                if !activity.argsSummary.isEmpty {
                    detailBlock(title: "Arguments", body: activity.argsSummary)
                }
                if !activity.resultPreview.isEmpty {
                    // Result output may carry shell ANSI colour codes — render them.
                    detailBlock(title: "Result", attributed: AnsiText.stripOrRender(activity.resultPreview))
                }
            } else {
                // PRODUCT: the human one-liner only (the calm default).
                detailBlock(title: "Summary", body: AnsiText.strip(activity.summaryLine))
            }
        }
        .padding(.top, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailBlock(title: String, body: String) -> some View {
        detailBlock(title: title) {
            Text(body)
                .font(.caption2.monospaced())
                .foregroundStyle(theme.fg)
        }
    }

    /// Result variant: the body is a pre-styled `AttributedString` (ANSI-rendered).
    private func detailBlock(title: String, attributed: AttributedString) -> some View {
        detailBlock(title: title) {
            Text(attributed)
                .font(.caption2.monospaced())
        }
    }

    private func detailBlock(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(theme.mutedFg)
            content()
                .lineLimit(8)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Native checklist card for a `todo` tool result (F4A-A2).
///
/// Renders a ``TodoList`` (derived from the tool's `tool.complete` result JSON)
/// as a system checklist: one row per item with a state glyph + the content,
/// completed/cancelled items struck through and dimmed. A header shows the
/// progress ("3 of 7 done"). FULL NATIVE — `Label`/`Image(systemName:)` glyphs,
/// no custom drawing; sits in the same `theme.muted` container as a tool row so
/// it reads as part of the tool cluster.
struct TodoCardView: View {
    let todos: TodoList
    /// The owning tool's state — a running todo write still shows its list.
    let state: ToolActivity.State

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            ForEach(todos.items) { item in
                row(for: item)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(theme.muted, in: RoundedRectangle(cornerRadius: 8))
    }

    private var header: some View {
        let done = todos.items.filter { $0.status == .completed }.count
        let total = todos.items.count
        return HStack(spacing: 6) {
            Image(systemName: "checklist")
                .font(.caption2)
                .foregroundStyle(theme.mutedFg)
            Text("\(done) of \(total) done")
                .font(.caption.weight(.medium))
                .foregroundStyle(theme.mutedFg)
                .monospacedDigit()
        }
    }

    private func row(for item: TodoItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            glyph(for: item.status)
                .frame(width: 16, height: 16)
            Text(item.content)
                .font(.caption)
                .foregroundStyle(textColor(for: item.status))
                .strikethrough(item.status == .completed || item.status == .cancelled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func glyph(for status: TodoItem.Status) -> some View {
        switch status {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(theme.statusOK)
        case .inProgress:
            Image(systemName: "circle.dotted.circle")
                .foregroundStyle(theme.midground)
        case .cancelled:
            Image(systemName: "minus.circle")
                .foregroundStyle(theme.mutedFg)
        case .pending, .other:
            Image(systemName: "circle")
                .foregroundStyle(theme.mutedFg)
        }
    }

    private func textColor(for status: TodoItem.Status) -> Color {
        switch status {
        case .completed, .cancelled: return theme.mutedFg
        default: return theme.fg
        }
    }
}
