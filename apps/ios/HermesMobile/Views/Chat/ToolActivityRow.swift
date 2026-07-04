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
    /// timeline. Ignored when `collapsed` is false.
    @State private var isExpanded = false
    /// Tracks row disclosures owned by this cluster so opening any tool can
    /// immediately break the live bounded window back out to the readable flat
    /// timeline without losing the row's expanded state during that layout swap.
    @State private var expandedToolIDs: Set<String> = []
    @State private var liveScrollTarget: String? = Self.liveToolWindowBottomID

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
        Group {
            if usesBoundedLiveToolWindow {
                boundedLiveToolWindow
            } else {
                flatToolRows
            }
        }
        .onChange(of: tools.map(\.id)) { _, ids in
            expandedToolIDs = expandedToolIDs.intersection(Set(ids))
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
        ForEach(tools, id: \.id) { tool in
            toolCard(for: tool)
        }
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
            ToolActivityRow(activity: tool, isExpanded: expansionBinding(for: tool))
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
/// arguments and the result directly (ABH-358: no second 'Show technical
/// detail' toggle — expanding IS the intent to see detail).
struct ToolActivityRow: View {
    /// The tool call to render. Updates in place as progress/result arrive.
    let activity: ToolActivity

    @Environment(\.hermesTheme) private var theme

    private let externalExpansion: Binding<Bool>?
    @State private var localIsExpanded = false

    init(activity: ToolActivity, isExpanded: Binding<Bool>? = nil) {
        self.activity = activity
        self.externalExpansion = isExpanded
    }

    private var expansion: Binding<Bool> {
        externalExpansion ?? $localIsExpanded
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

    @ViewBuilder
    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            // ABH-358: expanding a tool row shows the technical detail
            // (arguments + result) DIRECTLY — no second 'Show technical
            // detail' toggle. The collapsed row is already the summary;
            // expanding = intent to see the detail.
            if !activity.argsSummary.isEmpty {
                detailBlock(title: "Arguments", body: activity.argsSummary)
            }

            resultBlock
        }
        .padding(.top, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                withAnimation(.snappy(duration: 0.2)) { showRawReference.toggle() }
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
            .accessibilityHint("Double-tap to \(showRawReference ? "hide" : "show") the image path")
            .accessibilityIdentifier("generatedImageToolImage")

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
            cacheBlob(decoded.data, rest: rest, sessionId: sessionId, size: imageResult.size)
        } catch let error as FSReadError {
            localPhase = .failed(error.errorDescription ?? "Couldn't load image")
        } catch {
            localPhase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func cacheBlob(_ data: Data, rest: RestClient, sessionId: String, size: Int) {
        let key = AttachmentBlobCache.Key(
            serverId: rest.baseURL.absoluteString,
            profileId: sessions.activeProfile,
            sessionId: sessionId,
            path: result.reference,
            size: size
        )
        AttachmentBlobCache.shared.store(data, for: key)
    }

    private static func decodeDataURL(_ dataURL: String) -> (image: UIImage, data: Data)? {
        guard dataURL.hasPrefix("data:"),
              let commaIndex = dataURL.firstIndex(of: ",") else { return nil }
        let header = dataURL[dataURL.startIndex..<commaIndex]
        guard header.contains(";base64") else { return nil }
        let payload = String(dataURL[dataURL.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]),
              let image = UIImage(data: data) else { return nil }
        return (image, data)
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
