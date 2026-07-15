import SwiftUI
import UIKit

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
    private static let liveToolWindowThreshold = 3
    private static let liveToolWindowHeight: CGFloat = 172
    private static let liveToolWindowBottomID = "live-tool-window-bottom"

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
    /// timeline. Ignored when `collapsed` is false. Seeded `true` when any tool
    /// in the cluster defaults to expanded (STR-460 retry): a summary capsule
    /// must not hide a file-edit diff (or a failed file-edit's error) behind an
    /// extra tap.
    @State private var isExpanded: Bool
    /// Tracks row disclosures owned by this cluster so opening any tool can
    /// immediately break the live bounded window back out to the readable flat
    /// timeline without losing the row's expanded state during that layout swap.
    @State private var expandedToolIDs: Set<String>
    /// View-only/session-local hidden rows (STR-518, parity with desktop's
    /// `tool-dismiss.ts`). Keyed by stable `ToolActivity.id`; never mutates
    /// `ChatStore` or stored messages. Pruned to the current tool ids when the
    /// cluster's tool list changes so stale hides don't survive a remount.
    @State private var dismissedToolIDs: Set<String> = []
    @State private var liveScrollTarget: String? = Self.liveToolWindowBottomID

    init(tools: [ToolActivity], collapsed: Bool, turnElapsed: TimeInterval?) {
        self.tools = tools
        self.collapsed = collapsed
        self.turnElapsed = turnElapsed
        // File-edit diff rows must be visible without an extra tap (STR-460):
        // seed the disclosure set with any tool whose default state is expanded
        // (a diff, or a failed file-edit tool whose error must stay legible).
        _expandedToolIDs = State(initialValue: Set(
            tools.filter(ToolActivityRow.defaultExpanded(for:)).map(\.id)
        ))
        _isExpanded = State(initialValue: Self.defaultExpanded(for: tools))
    }

    /// A cluster whose summary capsule would otherwise start collapsed must
    /// start expanded when any tool inside it defaults to expanded (STR-460
    /// retry) — otherwise a common `read_file -> patch` or `patch -> test` run
    /// hides the diff (or a failed file-edit's error) behind the "N tool
    /// calls" capsule until the user taps it. Static so tests can pin the rule
    /// without constructing a view.
    nonisolated static func defaultExpanded(for tools: [ToolActivity]) -> Bool {
        tools.contains(where: ToolActivityRow.defaultExpanded(for:))
    }

    var body: some View {
        Group {
            if collapsed && tools.count >= 2 {
                collapsedCluster
            } else {
                liveCluster
            }
        }
        // Dismissed-id pruning MUST attach at the body level (not inside
        // `liveCluster`) so it fires on every tool-id change regardless of
        // whether the cluster renders collapsed, expanded, or live. A collapsed
        // cluster never mounts `liveCluster`, so a `.onChange` living only there
        // would let stale dismissed ids survive a tool-id change in the
        // collapsed/summary path — which the STR-518 review flagged. The
        // `expandedToolIDs` + scroll reset below remain live-cluster-specific.
        .onChange(of: tools.map(\.id)) { _, ids in
            let idSet = Set(ids)
            dismissedToolIDs = Self.prunedDismissedIDs(dismissedToolIDs, toolIDs: idSet)
        }
        // STR-608: `expandedToolIDs`/`isExpanded` are seeded once in `init` —
        // a live `tool.start` -> `tool.complete` update reuses the SAME tool
        // id, so `tools`' identity (`.map(\.id)`, watched below for pruning /
        // scroll) never changes and that seed never re-runs. Without this,
        // a diff (or a failed file-edit's error) that arrives after the row
        // is already rendered stays hidden behind a tap. Watching `tools`
        // itself (content-equal, not just id-equal) catches that same-id
        // transition and re-applies the STR-460 rule live.
        .onChange(of: tools) { oldTools, newTools in
            let sync = Self.syncExpansion(
                previousTools: oldTools,
                previousExpandedToolIDs: expandedToolIDs,
                tools: newTools
            )
            expandedToolIDs = sync.expandedToolIDs
            if sync.clusterShouldExpand {
                isExpanded = true
            }
        }
    }

    /// Result of ``syncExpansion(previousTools:previousExpandedToolIDs:tools:)``.
    struct ExpansionSync: Equatable {
        /// The row-level expansion set after pruning removed ids and adding
        /// any tool that newly satisfies `ToolActivityRow.defaultExpanded`.
        let expandedToolIDs: Set<String>
        /// Whether the outer (possibly-collapsed) cluster must be forced open
        /// because some tool newly satisfies `defaultExpanded` this update.
        let clusterShouldExpand: Bool
    }

    /// STR-608: pure helper for the live same-id transition, matched by `id`
    /// against the tools array from BEFORE this update. A tool id that was
    /// already `defaultExpanded` (and may have been manually collapsed by the
    /// user since) is left alone — only a genuine transition (e.g. running/
    /// no-diff -> done/fullDiff, or -> failed) forces it open. Ids no longer
    /// present are pruned. `nonisolated static` so tests can verify the sync
    /// contract without constructing a view.
    nonisolated static func syncExpansion(
        previousTools: [ToolActivity],
        previousExpandedToolIDs: Set<String>,
        tools: [ToolActivity]
    ) -> ExpansionSync {
        let previousByID = Dictionary(uniqueKeysWithValues: previousTools.map { ($0.id, $0) })
        let currentIDs = Set(tools.map(\.id))
        var expanded = previousExpandedToolIDs.intersection(currentIDs)
        var clusterShouldExpand = false
        for tool in tools {
            let wasDefaultExpanded = previousByID[tool.id].map(ToolActivityRow.defaultExpanded(for:)) ?? false
            guard !wasDefaultExpanded, ToolActivityRow.defaultExpanded(for: tool) else { continue }
            expanded.insert(tool.id)
            clusterShouldExpand = true
        }
        return ExpansionSync(expandedToolIDs: expanded, clusterShouldExpand: clusterShouldExpand)
    }

    // MARK: - Live / expanded timeline

    /// Every tool as its own row, 6pt apart, each in its muted container.
    private var liveCluster: some View {
        Group {
            if usesBoundedLiveToolWindow {
                boundedLiveToolWindow
            } else {
                flatToolRows
            }
        }
        .onChange(of: tools.map(\.id)) { _, ids in
            let idSet = Set(ids)
            expandedToolIDs = expandedToolIDs.intersection(idSet)
            // dismissed-id pruning is handled at the body level so it also runs
            // for collapsed/summary clusters (STR-518 review fix).
            liveScrollTarget = Self.liveToolWindowBottomID
        }
    }

    private var usesBoundedLiveToolWindow: Bool {
        !collapsed
            && tools.count >= Self.liveToolWindowThreshold
            && expandedToolIDs.isEmpty
    }

    private var flatToolRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            toolRows
        }
        .padding(.leading, 12)
    }

    private var boundedLiveToolWindow: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 6) {
                    toolRows

                    Color.clear
                        .frame(height: 1)
                        .id(Self.liveToolWindowBottomID)
                }
                .padding(.leading, 12)
                .scrollTargetLayout()
            }
            .scrollPosition(id: $liveScrollTarget, anchor: .bottom)
            .frame(height: Self.liveToolWindowHeight)
            .mask(alignment: .top) {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.16),
                        .init(color: .black, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .accessibilityIdentifier("boundedLiveToolWindow")
            .onAppear {
                liveScrollTarget = Self.liveToolWindowBottomID
                proxy.scrollTo(Self.liveToolWindowBottomID, anchor: .bottom)
            }
            .onChange(of: tools.map(\.id)) { _, _ in
                liveScrollTarget = Self.liveToolWindowBottomID
                proxy.scrollTo(Self.liveToolWindowBottomID, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private var toolRows: some View {
        // `ToolActivity.id` is the gateway `tool_call_id`; keeping this exact
        // ForEach id stable across the 2→3 live-window threshold preserves row
        // identity while only the surrounding scroll container changes.
        // Dismissed rows are filtered out here so only that row disappears;
        // siblings keep their identity (STR-518, parity with desktop).
        ForEach(visibleTools, id: \.id) { tool in
            toolCard(for: tool)
        }
    }

    /// `tools` minus the session-locally dismissed rows. Filtering (rather than
    /// rendering an empty placeholder) makes a dismissed row truly disappear.
    private var visibleTools: [ToolActivity] {
        dismissedToolIDs.isEmpty ? tools : tools.filter { !dismissedToolIDs.contains($0.id) }
    }

    @ViewBuilder
    private func toolCard(for tool: ToolActivity) -> some View {
        // A `todo` tool result renders as a native checklist card rather
        // than a generic tool row (F4A-A2). Parsed from the STRUCTURED
        // `tool.todos` retained verbatim off the wire (ABH-46 item 10)
        // — never from `resultPreview`, whose 300-char truncation breaks
        // the JSON re-parse for any real list. The preview-parse remains
        // only as a fallback for seeded/legacy activities that predate
        // the structured field. Falls back to the standard row when
        // neither yields a list (e.g. mid-run).
        if let generatedImage = Self.generatedImageResult(for: tool) {
            GeneratedImageToolCard(result: generatedImage, state: tool.state)
        } else if tool.name == TodoList.toolName,
                  let todos = tool.todos.flatMap({ TodoList(todosArray: $0) })
            ?? TodoList(resultJSON: tool.resultPreview) {
            TodoCardView(todos: todos, state: tool.state)
        } else {
            // Dismiss is offered only for completed/failed rows; running rows
            // are never dismissible (STR-518). The closure mutates this view's
            // session-local `dismissedToolIDs` only — no history mutation.
            ToolActivityRow(
                activity: tool,
                isExpanded: expansionBinding(for: tool),
                onDismiss: Self.canDismiss(state: tool.state) ? { dismiss(tool.id) } : nil
            )
        }
    }

    private func dismiss(_ toolID: String) {
        withAnimation(.snappy(duration: 0.2)) {
            dismissedToolIDs.insert(toolID)
        }
    }

    private func expansionBinding(for tool: ToolActivity) -> Binding<Bool> {
        Binding {
            expandedToolIDs.contains(tool.id)
        } set: { isExpanded in
            var next = expandedToolIDs
            if isExpanded {
                next.insert(tool.id)
            } else {
                next.remove(tool.id)
            }
            expandedToolIDs = next
        }
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

    /// Returns a parsed generated-image result only for the image-generation tool.
    /// Kept static so tests can prove the native image branch is selected without
    /// needing to instantiate SwiftUI's environment-backed view tree.
    nonisolated static func generatedImageResult(for tool: ToolActivity) -> GeneratedImageToolResult? {
        guard tool.name == GeneratedImageToolResult.toolName else { return nil }
        return GeneratedImageToolResult(resultJSON: tool.resultPreview)
    }

    /// A row is dismissible only once it has reached a terminal state
    /// (`.done` / `.failed`). Running rows must stay visible (STR-518).
    /// Kept static + nonisolated so tests can assert the gate directly.
    nonisolated static func canDismiss(state: ToolActivity.State) -> Bool {
        state == .done || state == .failed
    }

    /// Drops dismissed ids that no longer appear in the current tool list so a
    /// cluster remount / tool-id change sheds stale hides. Matches desktop's
    /// session-memory semantics (view-only, pruned on tool-id change).
    nonisolated static func prunedDismissedIDs(_ dismissed: Set<String>, toolIDs: Set<String>) -> Set<String> {
        dismissed.intersection(toolIDs)
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
/// `theme.muted` container. Tapping expands an inline panel whose content
/// depends on the global product/technical preference
/// (`DefaultsKeys.toolTechnicalDetail`, STR-464): PRODUCT mode (default)
/// shows the content-aware summary/error line from the STR-463 summary
/// contract; TECHNICAL mode shows the raw call arguments + result preview
/// (ABH-358's original "expanding IS the intent to see detail" behavior,
/// now gated behind the explicit technical toggle rather than always-on).
struct ToolActivityRow: View {
    /// The tool call to render. Updates in place as progress/result arrive.
    let activity: ToolActivity

    @Environment(\.hermesTheme) private var theme

    /// Global product/technical preference for the expanded detail panel.
    /// Persisted so the choice survives relaunch and applies to every row.
    @AppStorage(DefaultsKeys.toolTechnicalDetail) private var technicalDetailEnabled = false

    private let externalExpansion: Binding<Bool>?
    /// Dismiss handler; non-`nil` only for dismissible (`.done`/`.failed`) rows.
    /// Mutates the owning `ToolClusterView`'s session-local hide set only.
    private let onDismiss: (() -> Void)?
    @State private var localIsExpanded = false
    /// Transient "Copied" confirmation, mirroring `CodeBlockView`'s feedback.
    @State private var didCopy = false

    init(activity: ToolActivity, isExpanded: Binding<Bool>? = nil, onDismiss: (() -> Void)? = nil) {
        self.activity = activity
        self.externalExpansion = isExpanded
        self.onDismiss = onDismiss
        _localIsExpanded = State(initialValue: Self.defaultExpanded(for: activity))
    }

    private var expansion: Binding<Bool> {
        externalExpansion ?? $localIsExpanded
    }

    /// A file-edit tool row with a diff (or a failed file-edit tool, whose
    /// error text must stay legible) starts expanded — the diff/error must be
    /// visible without an extra tap (STR-460). Static so tests can pin the
    /// rule without constructing a view.
    nonisolated static func defaultExpanded(for activity: ToolActivity) -> Bool {
        guard InlineFileDiff.isFileEditTool(activity.name) else { return false }
        if let diff = activity.fullDiff, !diff.isEmpty { return true }
        return activity.state == .failed
    }

    private var isExpanded: Bool {
        expansion.wrappedValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expansion.wrappedValue.toggle() }
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

    /// What the expanded panel shows, gated by the global technical-detail
    /// preference (STR-464, `DefaultsKeys.toolTechnicalDetail`). Product mode
    /// (default) surfaces the STR-463 content-aware summary/error line — never
    /// raw JSON. Technical mode carries the row's raw arguments + result
    /// preview, matching ABH-358's original always-on debugging affordance.
    /// `nonisolated static` (matching the row's other pure helpers) so tests
    /// can verify the branch without constructing a view.
    enum DetailContent: Equatable {
        case summary(String)
        case raw(argumentsSummary: String, resultPreview: String)
    }

    nonisolated static func detailContent(for activity: ToolActivity, technicalDetailEnabled: Bool) -> DetailContent {
        technicalDetailEnabled
            ? .raw(argumentsSummary: activity.argsSummary, resultPreview: activity.resultPreview)
            : .summary(AnsiText.strip(activity.summaryLine))
    }

    @ViewBuilder
    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Expanding a tool row shows detail sized to the global
            // product/technical preference, surfaced via `detailModeToggle`
            // below — no per-row second toggle beyond that single global
            // control. The collapsed row is already the summary; expanding =
            // intent to see MORE, either the calm product summary or the raw
            // technical detail.
            detailActions

            switch Self.detailContent(for: activity, technicalDetailEnabled: technicalDetailEnabled) {
            case .summary(let text):
                productSummaryBlock(text)
            case .raw:
                technicalDetailBlocks
            }

            // Inline diff for file-edit tools (STR-315/STR-582) renders in
            // BOTH detail modes; the failure carve-out (STR-460) keeps the
            // error/result text legible — the diff view never replaces it.
            // The non-diff result content is already surfaced by the
            // product/technical switch above (STR-464), so no bare
            // resultBlock fallback here.
            if let diff = activity.fullDiff, !diff.isEmpty {
                diffBlock(diff)
                if activity.state == .failed {
                    resultBlock
                }
            }
        }
        .padding(.top, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// PRODUCT mode: the content-aware summary/error line, never raw JSON.
    /// Falls back to the same calm running/duration/failed lines the
    /// collapsed header already shows (STR-463) — never a fabricated success.
    private func productSummaryBlock(_ text: String) -> some View {
        detailBlock(
            title: "Result",
            titleTint: activity.state == .failed ? theme.statusError : nil
        ) {
            Text(text)
                .font(.caption2.monospaced())
                .foregroundStyle(activity.state == .failed ? theme.statusError : theme.fg)
        }
    }

    /// TECHNICAL mode: raw call arguments + raw result preview, unchanged
    /// from the row's original always-on behavior.
    @ViewBuilder
    private var technicalDetailBlocks: some View {
        if !activity.argsSummary.isEmpty {
            detailBlock(title: "Arguments", body: activity.argsSummary)
        }

        resultBlock
    }

    /// The global product/technical mode control (STR-464). Lives on the
    /// tool-row surface itself — not buried in Settings — since expanding a
    /// row is the moment the preference actually matters. Tapping flips
    /// `technicalDetailEnabled`, which is `@AppStorage`-backed, so every
    /// expanded row (this turn and future ones) re-renders in the new mode
    /// immediately and the choice survives relaunch.
    private var detailModeToggle: some View {
        Button {
            withAnimation(.snappy) { technicalDetailEnabled.toggle() }
        } label: {
            Label(
                technicalDetailEnabled ? "Technical" : "Product",
                systemImage: technicalDetailEnabled ? "curlybraces" : "text.alignleft"
            )
            .font(.caption2.weight(.medium))
            .foregroundStyle(theme.mutedFg)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Tool detail mode")
        .accessibilityValue(technicalDetailEnabled ? "Technical" : "Product")
        .accessibilityHint("Toggles every tool row between a product summary and raw technical detail")
        .accessibilityIdentifier("toolDetailModeToggle")
    }

    /// Mode toggle + Copy + Dismiss controls live in the EXPANDED body (not
    /// the header) so they never compete with the disclosure caret's hit
    /// target — the same lesson desktop applied when it moved copy out of
    /// the trailing slot (STR-518 parity). All three are muted, plain-styled.
    @ViewBuilder
    private var detailActions: some View {
        HStack(spacing: 14) {
            detailModeToggle

            Spacer(minLength: 0)

            if hasCopyableDetail {
                Button {
                    copyResult()
                } label: {
                    Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(theme.mutedFg)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy tool result")
                .accessibilityIdentifier("toolResultCopyButton")
            }

            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(theme.mutedFg)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss tool row")
                .accessibilityIdentifier("toolResultDismissButton")
            }
        }
    }

    /// Native diff rendering for file-edit tool rows: a compact `+N / -M` stat
    /// header, then every line color-tinted by `DiffRendering.classify` (added
    /// green, removed red, context/header muted) — mirrors desktop's
    /// `diff-lines.tsx` tinting.
    @ViewBuilder
    private func diffBlock(_ diff: String) -> some View {
        let stats = DiffRendering.stats(for: diff)
        let lines = DiffRendering.lines(in: diff)
        detailBlock(title: "Diff") {
            VStack(alignment: .leading, spacing: 4) {
                Text("+\(stats.added) / -\(stats.removed)")
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(theme.mutedFg)

                ScrollView(.vertical, showsIndicators: true) {
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
        }
    }

    /// True when there's something worth copying beyond the bare tool name —
    /// non-empty arguments or a non-empty (ANSI-stripped) result preview.
    private var hasCopyableDetail: Bool {
        let args = activity.argsSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !args.isEmpty { return true }
        let result = AnsiText.strip(activity.resultPreview).trimmingCharacters(in: .whitespacesAndNewlines)
        return !result.isEmpty
    }

    private func copyResult() {
        // Copy the full uncapped payload (ANSI stripped), not just the visible
        // fragment — mirrors desktop's `toolCopyPayload` precedence (STR-518).
        UIPasteboard.general.string = Self.copyPayload(for: activity)
        // Light haptic + transient checkmark mirrors `CodeBlockView`'s feedback.
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.snappy) { didCopy = true }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.snappy) { didCopy = false }
        }
    }

    /// Deterministic clipboard payload for a tool row (STR-518 parity with
    /// desktop's `toolCopyPayload`). Precedence:
    /// 1. substantial (>16 char, matching desktop's `hasSubstantialOutput`
    ///    threshold) ANSI-stripped result preview;
    /// 2. non-empty arguments;
    /// 3. any non-empty (possibly short) ANSI-stripped result preview — desktop
    ///    (fallback-model/index.ts:1216-1218) falls back to `detail` before the
    ///    `title`, so a short result like "no hits" must be copied as the result,
    ///    NOT the tool name;
    /// 4. the tool name (last resort).
    /// `nonisolated static` so unit tests can verify the payload without a view.
    nonisolated static func copyPayload(for activity: ToolActivity) -> String {
        let result = AnsiText.strip(activity.resultPreview)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if result.count > 16 { return result }
        let args = activity.argsSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !args.isEmpty { return args }
        if !result.isEmpty { return result }
        return activity.name
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

    /// Result block: monospace, scroll-in-card (bounded height so huge outputs
    /// don't flood the transcript), honest error tinting for failed tools.
    /// Mirrors desktop's `max-h-* overflow-auto` pre block pattern.
    @ViewBuilder
    private var resultBlock: some View {
        // Running with no result yet → honest placeholder, not a fake "ok".
        if activity.state == .running && activity.resultPreview.isEmpty {
            detailBlock(title: "Result", body: "Running…")
        } else if !activity.resultPreview.isEmpty {
            let isError = activity.state == .failed
            detailBlock(
                title: "Result",
                titleTint: isError ? theme.statusError : nil,
            ) {
                ScrollView(.vertical, showsIndicators: true) {
                    // ANSI-aware: terminal color codes render as styled runs.
                    Text(AnsiText.stripOrRender(activity.resultPreview))
                        .font(.caption2.monospaced())
                        .foregroundStyle(isError ? theme.statusError : theme.fg)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            }
        }
    }

    private func detailBlock(title: String, body: String) -> some View {
        detailBlock(title: title, titleTint: nil) {
            Text(body)
                .font(.caption2.monospaced())
                .foregroundStyle(theme.fg)
        }
    }

    private func detailBlock(
        title: String,
        titleTint: Color? = nil,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(titleTint ?? theme.mutedFg)
            content()
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Classification of one unified-diff line, mirroring desktop's `diffKind`
/// (`apps/desktop/src/components/chat/diff-lines.tsx`): `+++`/`---` file-header
/// markers are NOT additions/removals — they classify as context so they don't
/// pollute the `+N / -M` stat and render in the muted/default style like any
/// other header or hunk line.
enum DiffLineKind: Sendable, Equatable {
    case add
    case remove
    case context
}

/// One displayable line of a parsed diff.
struct ToolDiffLine: Sendable, Equatable, Identifiable {
    let id: Int
    let kind: DiffLineKind
    let text: String
}

/// Parses/classifies a unified diff for native rendering. Pure and
/// `nonisolated` so tests can verify classification and stats without SwiftUI.
enum DiffRendering {
    static func classify(_ line: String) -> DiffLineKind {
        if line.hasPrefix("+"), !line.hasPrefix("+++") { return .add }
        if line.hasPrefix("-"), !line.hasPrefix("---") { return .remove }
        return .context
    }

    static func lines(in diff: String) -> [ToolDiffLine] {
        diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, substring in
            let text = String(substring)
            return ToolDiffLine(id: index, kind: classify(text), text: text)
        }
    }

    /// `(added, removed)` counts, excluding `+++`/`---` file-header markers.
    static func stats(for diff: String) -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            switch classify(String(line)) {
            case .add: added += 1
            case .remove: removed += 1
            case .context: break
            }
        }
        return (added, removed)
    }
}

/// Parsed result for the `image_generate` tool.
///
/// The gateway/tool result can expose the generated image under a few historical
/// keys. The first non-empty locator wins, matching the task contract, and can be
/// either a remote URL, a data URL, or a server-local path.
struct GeneratedImageToolResult: Sendable, Equatable {
    static let toolName = "image_generate"
    private static let locatorKeys = ["host_image", "image", "agent_visible_image"]

    let reference: String

    init?(resultJSON text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let json = try? JSONDecoder().decode(JSONValue.self, from: data) {
            if let reference = Self.reference(in: json) {
                self.reference = reference
                return
            }
            return nil
        }

        // Defensive fallback for older/local emitters that surface the locator as
        // the preview itself instead of a JSON object. This branch is still gated
        // by `tool.name == image_generate`, so it cannot steal generic tool rows.
        self.reference = trimmed
    }

    var remoteURL: URL? {
        guard reference.hasPrefix("http://") || reference.hasPrefix("https://") else { return nil }
        return URL(string: reference)
    }

    var isDataURL: Bool { reference.hasPrefix("data:") }
    var isServerLocalPath: Bool { remoteURL == nil && !isDataURL }

    var displayName: String {
        guard !isDataURL else { return "inline image" }
        let last = reference.components(separatedBy: "/").last ?? reference
        return last.isEmpty ? reference : last
    }

    private static func reference(in json: JSONValue) -> String? {
        if let object = json.objectValue {
            for key in locatorKeys {
                guard let raw = object[key]?.stringValue else { continue }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        } else if let raw = json.stringValue {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}

/// Native image card for an assistant-generated image tool result.
///
/// Remote URLs use `AsyncImage`. Server-local paths reuse the existing file-read
/// REST surface (`fsReadAsDataURL`) and blob cache, instead of adding a bespoke
/// route. All failure paths provide a retry plus a raw-locator reveal affordance.
struct GeneratedImageToolCard: View {
    let result: GeneratedImageToolResult
    let state: ToolActivity.State

    @Environment(ConnectionStore.self) private var connection
    @Environment(SessionStore.self) private var sessions
    @Environment(\.hermesTheme) private var theme

    @State private var localPhase: LocalImagePhase = .idle
    @State private var remoteRetryID = UUID()
    @State private var showRawReference = false
    @State private var presentZoom = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(theme.muted, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("generatedImageToolCard")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo")
                .font(.caption2)
                .foregroundStyle(theme.mutedFg)
            Text("Generated image")
                .font(.caption.weight(.medium))
                .foregroundStyle(theme.mutedFg)
            Spacer(minLength: 0)
            if state == .running {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Generated image loading")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if state == .failed {
            failurePanel(message: "Image generation failed.")
        } else if let remoteURL = result.remoteURL {
            remoteImage(url: remoteURL)
        } else if result.isDataURL {
            dataURLImage
        } else {
            localImage
        }
    }

    private func remoteImage(url: URL) -> some View {
        AsyncImage(url: url, transaction: Transaction(animation: .snappy(duration: 0.2))) { phase in
            switch phase {
            case .empty:
                loadingPlaceholder
            case .success(let image):
                renderedImage(image)
            case .failure:
                failurePanel(message: "Couldn't load the generated image.")
            @unknown default:
                failurePanel(message: "Couldn't load the generated image.")
            }
        }
        .id(remoteRetryID)
    }

    @ViewBuilder
    private var dataURLImage: some View {
        if let decoded = Self.decodeDataURL(result.reference) {
            renderedImage(Image(uiImage: decoded.image))
        } else {
            failurePanel(message: "Couldn't decode the generated image.")
        }
    }

    @ViewBuilder
    private var localImage: some View {
        Group {
            switch localPhase {
            case .idle, .loading:
                loadingPlaceholder
            case .loaded(let image):
                renderedImage(Image(uiImage: image))
            case .failed(let message):
                failurePanel(message: message)
            }
        }
        .task(id: result.reference) {
            await loadLocalImage(force: false)
        }
    }

    private var loadingPlaceholder: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(theme.bg.opacity(0.5))
            .overlay {
                VStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading image…")
                        .font(.caption2)
                        .foregroundStyle(theme.mutedFg)
                }
            }
            .frame(maxWidth: 360, minHeight: 180)
            .accessibilityLabel("Loading generated image")
    }

    private func renderedImage(_ image: Image) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                presentZoom = true
            } label: {
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 360, maxHeight: 420, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(theme.mutedFg.opacity(0.18), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Generated image")
            .accessibilityHint("Double-tap to zoom")
            .accessibilityIdentifier("generatedImageToolImage")

            Button(showRawReference ? "Hide path" : "Show path") {
                withAnimation(.snappy(duration: 0.2)) { showRawReference.toggle() }
            }
            .font(.caption.weight(.medium))
            .buttonStyle(.plain)
            .foregroundStyle(theme.midground)

            if showRawReference {
                Text(result.reference)
                    .font(.caption2.monospaced())
                    .foregroundStyle(theme.fg)
                    .lineLimit(4)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .fullScreenCover(isPresented: $presentZoom) {
            // STR-574: reuse the same ZoomableImageView lightbox the assistant-
            // prose markdown image path uses, instead of a divergent non-zoom
            // preview. Source precedence mirrors `content` above.
            if let remoteURL = result.remoteURL {
                ZoomableImageView(title: "Generated image", remoteURL: remoteURL)
            } else if result.isDataURL {
                ZoomableImageView(title: "Generated image", dataURL: result.reference)
            } else if case .loaded(let loaded) = localPhase {
                ZoomableImageView(title: "Generated image", image: loaded)
            } else {
                ZoomableImageView(title: "Generated image")
            }
        }
    }

    private func failurePanel(message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(theme.statusError)
            HStack(spacing: 10) {
                Button("Retry") {
                    if result.remoteURL != nil {
                        remoteRetryID = UUID()
                    } else if result.isServerLocalPath {
                        Task { await loadLocalImage(force: true) }
                    }
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(theme.midground)

                Button(showRawReference ? "Hide path" : "Show path") {
                    withAnimation(.snappy(duration: 0.2)) { showRawReference.toggle() }
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(theme.midground)
            }
            if showRawReference {
                Text(result.reference)
                    .font(.caption2.monospaced())
                    .foregroundStyle(theme.fg)
                    .lineLimit(4)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
    }

    @MainActor
    private func loadLocalImage(force: Bool) async {
        guard result.isServerLocalPath, state != .failed else { return }
        if !force {
            if case .loaded = localPhase { return }
            if case .loading = localPhase { return }
        }
        guard let rest = connection.rest else {
            localPhase = .failed("Connect to the gateway to load this generated image.")
            return
        }
        guard let sessionId = sessions.activeRuntimeId, !sessionId.isEmpty else {
            localPhase = .failed("Open the source session to load this generated image.")
            return
        }

        localPhase = .loading
        do {
            let imageResult = try await rest.fsReadAsDataURL(sessionId: sessionId, path: result.reference)
            guard let dataURL = imageResult.dataURL,
                  let decoded = Self.decodeDataURL(dataURL) else {
                localPhase = .failed("Image preview requires an updated gateway.")
                return
            }
            localPhase = .loaded(decoded.image)
            cacheBlob(
                decoded.data,
                rest: rest,
                sessionId: sessionId,
                contentVersion: imageResult.contentVersion
            )
        } catch let error as FSReadError {
            localPhase = .failed(error.errorDescription ?? "Couldn't load image")
        } catch {
            localPhase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func cacheBlob(
        _ data: Data,
        rest: RestClient,
        sessionId: String,
        contentVersion: String?
    ) {
        guard let version = contentVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty else { return }
        let key = AttachmentBlobCache.Key(
            serverId: rest.baseURL.absoluteString,
            profileId: sessions.activeProfile,
            sessionId: sessionId,
            path: result.reference,
            contentVersion: version
        )
        Task { await AttachmentBlobCache.shared.store(data, for: key) }
    }

    private static func decodeDataURL(_ dataURL: String) -> (image: UIImage, data: Data)? {
        // STR-574: delegate to the shared `AttachmentBlobCache.decodeDataURL`
        // so this card, the prose markdown image path, and the ZoomableImageView
        // lightbox all share one data-URL contract instead of three divergent
        // base64 decoders.
        AttachmentBlobCache.decodeDataURLSynchronously(dataURL).map { ($0.image, $0.data) }
    }

    private enum LocalImagePhase {
        case idle
        case loading
        case loaded(UIImage)
        case failed(String)
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
