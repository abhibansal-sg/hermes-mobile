import SwiftUI

/// A single transcript entry.
///
/// - User: a trailing-aligned bronze bubble, capped at 78% width.
/// - Assistant: a leading-aligned, bubble-less "document" — optional thinking,
///   a tool timeline, then markdown-rendered text with a streaming cursor.
/// - System / tool: small, centered, secondary captions.
struct MessageBubble: View {
    @Environment(\.hermesTheme) private var theme
    @Environment(ConnectionStore.self) private var connectionStore
    @Environment(SessionStore.self) private var sessionStore

    /// The message to render.
    let message: ChatMessage

    // MARK: - CC-01: Streaming cursor pulse animation state
    /// Opacity driven by a repeating breathe animation while the turn streams.
    @State private var cursorPulseOpacity: Double = 1.0

    // MARK: - CC-02: Copy confirmation state (assistant message copy)
    /// Whether the assistant-message copy just fired — drives checkmark + haptic.
    @State private var didCopyMessage = false
    /// Trigger sentinel for `.sensoryFeedback` — toggled on every copy.
    @State private var copyHapticTrigger = false

    // A1: action closures are `let` (immutable inputs). They are NOT read by the
    // `nonisolated ==` (closures aren't Sendable); only their nil-ness affects what
    // renders, and that is stable per call site (ChatView passes the same handlers
    // every render), so omitting them from `==` never strands a real update.
    /// Invoked when the user chooses "Edit" on their own bubble. The host
    /// (`ChatView`) presents an edit sheet and calls `ChatStore.editAndResend`.
    /// `nil` (default) hides the Edit action — used in previews / pre-wiring.
    let onEdit: ((ChatMessage) -> Void)?
    /// Invoked when the user chooses "Retry" on an assistant message. The host
    /// calls `ChatStore.retry(fromAssistantId:)`. `nil` hides the action.
    let onRetry: ((ChatMessage) -> Void)?
    /// Invoked when the user chooses "Speak" on an assistant message. Wiring to
    /// the speech player happens later; `nil` hides the action.
    let onSpeak: ((ChatMessage) -> Void)?
    /// Invoked when the user chooses "Restore checkpoint" on their own bubble
    /// (F4A-A2): re-run the conversation from this user message, dropping later
    /// turns. The host calls `ChatStore.restoreCheckpoint(toUserMessageId:)`.
    /// `nil` hides the action.
    let onRestoreCheckpoint: ((ChatMessage) -> Void)?
    /// Invoked when the user chooses "Branch from here" on any message (F4A-A2):
    /// open a NEW chat seeded with history up to this message. The host calls
    /// `ChatStore.branchSeed(upToMessageId:)` + `SessionStore.branchSession`.
    /// `nil` hides the action.
    let onBranch: ((ChatMessage) -> Void)?
    /// Whether mutable context-menu actions (Edit, Restore checkpoint, Branch from
    /// here, Retry) are currently executable. When `false` the actions are SHOWN
    /// but disabled. Read by `==` (a Sendable `let`), so a change re-renders.
    let menuActionsEnabled: Bool

    /// Appearance identity (theme + Dynamic Type), folded into `Equatable` (A1) so
    /// a theme/type-size switch re-renders the bubble even though `.equatable()`
    /// short-circuits content-equal updates. The bubble reads the theme via
    /// `@Environment`, which the static `==` cannot observe — so it travels here as
    /// a value, supplied by `ChatView`. Defaults keep previews / standalone call
    /// sites compiling unchanged.
    let appearance: BubbleAppearance

    /// Explicit memberwise init so every comparison input can be an immutable
    /// `Sendable` `let` (required for the `nonisolated ==` under Swift 6 strict
    /// concurrency — a `View` is main-actor-isolated, so `Equatable.==` may only
    /// read immutable Sendable storage) while keeping the prior call-site defaults.
    init(
        message: ChatMessage,
        onEdit: ((ChatMessage) -> Void)? = nil,
        onRetry: ((ChatMessage) -> Void)? = nil,
        onSpeak: ((ChatMessage) -> Void)? = nil,
        onRestoreCheckpoint: ((ChatMessage) -> Void)? = nil,
        onBranch: ((ChatMessage) -> Void)? = nil,
        menuActionsEnabled: Bool = true,
        appearance: BubbleAppearance = BubbleAppearance()
    ) {
        self.message = message
        self.onEdit = onEdit
        self.onRetry = onRetry
        self.onSpeak = onSpeak
        self.onRestoreCheckpoint = onRestoreCheckpoint
        self.onBranch = onBranch
        self.menuActionsEnabled = menuActionsEnabled
        self.appearance = appearance
    }

    var body: some View {
        if case .collapsed(let label) = message.presentation {
            collapsedRow(label: label)
        } else {
            switch message.role {
            case .user:
                userBubble
                    .contextMenu { userMenu }
            case .assistant:
                assistantBody
                    .contextMenu { assistantMenu }
            case .system, .tool:
                metaRow
            }
        }
    }

    // MARK: - Context menus

    @ViewBuilder
    private var userMenu: some View {
        if let onEdit {
            Button {
                onEdit(message)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .disabled(!menuActionsEnabled)
        }
        Button {
            copyToPasteboard(message.text)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        if onRestoreCheckpoint != nil || onBranch != nil {
            Divider()
        }
        if let onRestoreCheckpoint {
            Button {
                onRestoreCheckpoint(message)
            } label: {
                Label("Restore checkpoint", systemImage: "clock.arrow.circlepath")
            }
            .disabled(!menuActionsEnabled)
        }
        if let onBranch {
            Button {
                onBranch(message)
            } label: {
                Label("Branch from here", systemImage: "arrow.triangle.branch")
            }
            .disabled(!menuActionsEnabled)
        }
    }

    @ViewBuilder
    private var assistantMenu: some View {
        if let onRetry {
            Button {
                onRetry(message)
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .disabled(!menuActionsEnabled)
        }
        Button {
            copyAssistantMessage()
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        if let onSpeak {
            Button {
                onSpeak(message)
            } label: {
                Label("Speak", systemImage: "speaker.wave.2")
            }
        }
        if let onBranch {
            Divider()
            Button {
                onBranch(message)
            } label: {
                Label("Branch from here", systemImage: "arrow.triangle.branch")
            }
            .disabled(!menuActionsEnabled)
        }
    }

    // MARK: - Pasteboard

    /// Copy to pasteboard with no visual feedback (user bubble context menu).
    private func copyToPasteboard(_ text: String) {
        UIPasteboard.general.string = text
    }

    /// Copy to pasteboard with checkmark confirmation + haptic (assistant action
    /// row and context menu — CC-02). Mirrors CodeBlockView.copy() exactly so
    /// every copy surface in the transcript behaves consistently.
    private func copyAssistantMessage() {
        UIPasteboard.general.string = message.text
        copyHapticTrigger.toggle()
        withAnimation(.snappy) { didCopyMessage = true }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.snappy) { didCopyMessage = false }
        }
    }

    // MARK: - Collapsed scaffolding (cron preambles, tool dumps, system prompts)

    @State private var isExpanded = false

    private func collapsedRow(label: String) -> some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ScrollView {
                Text(message.text)
                    .font(.caption2.monospaced())
                    .foregroundStyle(theme.mutedFg)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            .padding(8)
            .background(theme.muted, in: RoundedRectangle(cornerRadius: 8))
        } label: {
            Label(label, systemImage: iconForCollapsedRole)
                .font(.caption)
                .foregroundStyle(theme.mutedFg)
        }
        .tint(theme.mutedFg)
    }

    private var iconForCollapsedRole: String {
        switch message.role {
        case .tool: return "wrench.and.screwdriver"
        case .system: return "gearshape"
        default: return "clock.arrow.circlepath"
        }
    }

    // MARK: - User

    /// Whether the long user message is expanded (ephemeral, per-message-instance).
    @State private var userBubbleExpanded = false

    private var userBubble: some View {
        let attachmentInput = Self.sentImageAttachments(in: message.text)
        let displayText = attachmentInput.displayText
        return HStack {
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(attachmentInput.attachments) { attachment in
                    SentImageThumbnailView(
                        attachment: attachment,
                        rest: connectionStore.rest,
                        serverId: connectionStore.serverURLString,
                        profileId: sessionStore.activeProfile,
                        sessionId: sessionStore.activeRuntimeId ?? ""
                    )
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, displayText.isEmpty ? 8 : 0)
                }
                if !displayText.isEmpty {
                    Text(displayText)
                        .foregroundStyle(theme.userBubble.contrastingForeground)
                        .lineLimit(userBubbleExpanded ? nil : Self.userBubbleCollapsedLines)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .textSelection(.enabled)
                }
                if shouldShowReadMore(for: displayText) {
                    Button {
                        userBubbleExpanded.toggle()
                    } label: {
                        Text(userBubbleExpanded ? "Show less" : "Read more")
                            .font(.caption)
                            .foregroundStyle(theme.userBubble.contrastingForeground.opacity(0.75))
                            .padding(.horizontal, 14)
                            .padding(.bottom, 9)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Double-tap to \(userBubbleExpanded ? "collapse message" : "expand message")")
                }
            }
            // A11y: settled user bubbles get a combined VoiceOver element so the
            // turn reads as one utterance ("You said: …") rather than separate
            // focus stops for the text and the "Read more" button. Streaming is
            // never true for a user message today, but the guard mirrors the
            // assistant path so the contract is explicit and future-safe.
            .if(!message.isStreaming) { bubble in
                bubble
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(MessageBubble.bubbleAccessibilityLabel(
                        role: message.role,
                        text: displayText
                    ))
            }
            .modifier(PerfUserBubbleChrome())
            .frame(maxWidth: maxBubbleWidth, alignment: .trailing)
        }
    }

    /// Whether the "Read more" / "Show less" toggle should appear for this message.
    /// Long enough means above the collapse threshold (approximately 8 lines of
    /// prose). We estimate using character count to avoid a layout pass.
    var shouldShowReadMore: Bool {
        Self.isLongUserMessage(Self.sentImageAttachments(in: message.text).displayText)
    }

    private func shouldShowReadMore(for text: String) -> Bool {
        Self.isLongUserMessage(text)
    }

    /// Returns true when the message text is long enough to warrant the collapse
    /// toggle. Extracted as a static testable function so unit tests can cover the
    /// threshold logic without a live View.
    static func isLongUserMessage(_ text: String) -> Bool {
        // ~8 lines at ~45 chars per line on a compact device = ~360 chars.
        // We also count newlines directly: 8+ newlines means multi-paragraph.
        let lineBreaks = text.filter { $0.isNewline }.count
        return text.count > Self.userBubbleCollapsedCharThreshold || lineBreaks >= Self.userBubbleCollapsedLines
    }

    /// Character-count threshold above which a user bubble gets the Read More
    /// toggle. ~8 lines × ~45 characters per line on a 375pt wide device.
    static let userBubbleCollapsedCharThreshold = 360
    /// Maximum number of lines shown in collapsed state; also the newline-count
    /// threshold for the `isLongUserMessage` heuristic.
    static let userBubbleCollapsedLines = 8

    /// Cap user bubbles at 78% of the screen width while letting short messages
    /// hug their content.
    private var maxBubbleWidth: CGFloat {
        UIScreen.main.bounds.width * 0.78
    }

    // MARK: - Assistant

    private var assistantBody: some View {
        // `parts` is the sole content source of truth (ABH-87 §3.1) — render it
        // directly in wire order, no `assistantRenderParts` indirection.
        let parts = message.parts
        let lastTextPartID = parts.lastTextPartID
        // A freshly-created streaming bubble has no `.text` part yet; show a
        // standalone cursor so the turn reads as in-progress (the prior model
        // injected an empty streaming text placeholder for this).
        let needsStandaloneCursor = message.isStreaming && lastTextPartID == nil

        // CC-05/CC-07: bump part spacing from 8 → 10 for consistent vertical
        // rhythm that matches the user bubble's ~9pt vertical breathing room.
        //
        // A11y: the outer VStack holds TWO distinct concerns:
        //   1. `proseContainer` — all rendered parts (reasoning, tools, text,
        //      warning, usage). Gets `.accessibilityElement(children: .combine)`
        //      on SETTLED turns so VoiceOver reads the turn as one utterance
        //      ("Assistant said: …"). No combine while streaming — zero extra
        //      work on the hot streaming path.
        //   2. `assistantActionRow` — copy / share / speak / retry buttons.
        //      Kept OUTSIDE the combined element so each action remains a
        //      separately-reachable VoiceOver target.
        return VStack(alignment: .leading, spacing: 10) {
            // --- Prose / parts container (combine target) ---
            VStack(alignment: .leading, spacing: 10) {
                ForEach(parts) { part in
                    assistantPart(part, showsCursor: message.isStreaming && part.id == lastTextPartID)
                }
                if needsStandaloneCursor {
                    // CC-01: standalone cursor inherits the pulse animation.
                    cursorView
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            // A11y: combine ONLY on settled turns. Streaming bubbles keep their
            // children individually accessible (and the Equatable short-circuit in
            // ChatView already skips re-evaluating settled bubbles entirely, so
            // this branch never runs at streaming frequency for settled rows).
            .if(!message.isStreaming) { prose in
                prose
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(MessageBubble.bubbleAccessibilityLabel(
                        role: message.role,
                        text: message.text
                    ))
            }

            // Action row under each COMPLETED assistant turn (F3): thin line
            // icons, no backgrounds. Hidden while streaming and on empty turns so
            // a tool-only / in-progress turn shows no dangling actions.
            //
            // §3.5 (D10): visibility keys on RENDERED TEXT PRESENCE — a non-empty
            // `.text` PART — via the derived `hasRenderedText`, not any legacy
            // scalar. Because Copy/Share read `message.text` (the ordered concat of
            // the same `.text` parts, Batch A) the copied string is exactly the
            // displayed prose; on a parts-only turn the row is therefore present
            // and correct by construction.
            if !message.isStreaming && hasRenderedText {
                assistantActionRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // CC-02: haptic fires once per copy trigger toggle (success feel).
        .sensoryFeedback(.success, trigger: copyHapticTrigger)
    }

    /// True iff this turn has at least one non-empty `.text` part — the rendered
    /// prose presence the action row keys on (§3.5). Equivalent to
    /// `!message.text.isEmpty` since the derived `text` is the concat of these
    /// parts, but stated against `parts` to make the part-keyed contract explicit.
    private var hasRenderedText: Bool {
        message.parts.contains { part in
            if case .text(_, let t) = part { return !t.isEmpty }
            return false
        }
    }

    @ViewBuilder
    private func assistantPart(_ part: ChatMessagePart, showsCursor: Bool) -> some View {
        switch part {
        case .reasoning(_, let text):
            if !text.isEmpty {
                // Wire-position thinking (§3.3): the accordion renders exactly
                // where this `.reasoning` part sits in `parts` (never hoisted to
                // the top) and auto-opens while the turn streams, collapsing when
                // it settles. `message.isStreaming` drives that default.
                ThinkingView(thinking: text, streaming: message.isStreaming)
            }
        case .tools(_, let tools, let collapsed, let turnElapsed):
            if !tools.isEmpty {
                ToolClusterView(
                    tools: tools,
                    collapsed: collapsed,
                    turnElapsed: turnElapsed
                )
            }
        case .text(_, let text):
            if !text.isEmpty || showsCursor {
                assistantText(text, showsCursor: showsCursor)
            }
        case .warning(_, let text):
            if !text.isEmpty {
                Label(text, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(theme.statusWarn)
            }
        case .usage(_, let stats):
            usageFooter(stats)
        }
    }

    /// Render the assistant text as ordered prose / code segments (E3 segmenter):
    /// prose runs become inline-markdown `Text`, fenced code becomes a
    /// `CodeBlockView`. The streaming cursor rides the last prose segment — or
    /// stands alone when the streaming tail is a code block, so the code card
    /// never gets a stray glyph.
    private func assistantText(_ text: String, showsCursor: Bool) -> some View {
        // Memoized segmentation (RenderCache): a flick-scroll re-realizes this
        // row without changing `text`, so the segment scan is an O(1) cache hit
        // instead of an O(n) re-scan of the whole body. A streaming flush extends
        // `text` → new key → fresh scan only for the genuinely-new content.
        let segments = RenderCache.segments(text)

        return VStack(alignment: .leading, spacing: Self.segmentSpacing) {
            // POSITIONAL identity (release audit P1): keying on `\.element.id`
            // (a content hash) gave every streaming delta a NEW id — ForEach
            // tore down and rebuilt the prose Text on every flush, breaking
            // in-progress text selection. Segments are append-only during a
            // stream, so the offset is the stable identity and SwiftUI diffs
            // the text in place.
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                switch segment {
                case .prose(let body):
                    // Serif applies ONLY to prose segments (F3 / Amendment E) —
                    // never code (`CodeBlockView`, mono) nor the streaming cursor
                    // (its own `Text` keeps the system face).
                    //
                    // ABH-360 extends the prose renderer with a cached GFM block
                    // pass. Regular paragraphs still flow through the existing
                    // RenderCache.prose → AttributedString markdown path, while
                    // tables/task lists/blockquotes/lists become native SwiftUI
                    // blocks so GFM does not collapse into raw dashes and pipes.
                    ForEach(Array(RenderCache.markdownBlocks(body).enumerated()), id: \.offset) { _, block in
                        markdownBlock(block)
                    }
                case .code(let language, let body):
                    CodeBlockView(language: language, code: body)
                }
            }
            // CC-01 / round-2: the breathing streaming cursor is a single
            // standalone sibling for ALL cases (rides prose, tail-is-code, or
            // no-prose-yet). Keeping it OFF the prose `Text` means the pulse
            // animation never re-composites the (large) prose block — only this
            // tiny glyph view animates. It sits just after the segment stack,
            // reading as the live tail of the turn.
            if showsCursor {
                cursorView
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Spacing between prose / code segments (UI-C C1 paragraph spacing).
    private static let segmentSpacing: CGFloat = 12
    /// Extra leading between wrapped prose lines (UI-C C1).
    private static let proseLineSpacing: CGFloat = 3.5
    /// The assistant prose face: serif at body size (F3 / Amendment E — observed
    /// reference: "Assistant text is full-width serif"). Code + cursor keep the
    /// system face.
    private static let proseFont: Font = .system(.body, design: .serif)

    @ViewBuilder
    private func markdownBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            paragraphText(text)
        case .table(let table):
            MarkdownTableBlockView(table: table)
        case .blockquote(let text):
            MarkdownBlockquoteView(text: text)
        case .taskItems(let items):
            MarkdownTaskListView(items: items)
        case .listItems(let items):
            MarkdownListBlockView(items: items)
        }
    }

    private func paragraphText(_ text: String) -> some View {
        (Text(RenderCache.prose(text)).font(Self.proseFont))
            .foregroundStyle(theme.fg)
            .lineSpacing(Self.proseLineSpacing)
            .perfTextSelection()
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - ABH-360 GFM block parsing

    struct MarkdownTable: Equatable, Sendable {
        enum Alignment: Equatable, Sendable { case leading, center, trailing }

        let headers: [String]
        let alignments: [Alignment]
        let rows: [[String]]
    }

    struct MarkdownTaskItem: Equatable, Sendable {
        let checked: Bool
        let text: String
        let level: Int
    }

    struct MarkdownListItem: Equatable, Sendable {
        let marker: String
        let text: String
        let level: Int
    }

    enum MarkdownBlock: Equatable, Sendable {
        case paragraph(String)
        case table(MarkdownTable)
        case blockquote(String)
        case taskItems([MarkdownTaskItem])
        case listItems([MarkdownListItem])
    }

    /// Parse GFM block constructs that `AttributedString(markdown:)` cannot lay
    /// out as native chat UI. The parser is intentionally conservative: if a run
    /// is not a clear GFM table / task-list / blockquote / list, it falls back to
    /// the existing inline markdown path unchanged.
    static func markdownBlocks(_ text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: "\n")
        guard !lines.isEmpty else { return [] }

        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let body = paragraph.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { blocks.append(.paragraph(body)) }
            paragraph.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let table = markdownTable(startingAt: index, lines: lines) {
                flushParagraph()
                blocks.append(.table(table.table))
                index = table.nextIndex
                continue
            }

            if let quote = blockquoteRun(startingAt: index, lines: lines) {
                flushParagraph()
                blocks.append(.blockquote(quote.text))
                index = quote.nextIndex
                continue
            }

            if let tasks = taskListRun(startingAt: index, lines: lines) {
                flushParagraph()
                blocks.append(.taskItems(tasks.items))
                index = tasks.nextIndex
                continue
            }

            if let list = listRun(startingAt: index, lines: lines) {
                flushParagraph()
                blocks.append(.listItems(list.items))
                index = list.nextIndex
                continue
            }

            paragraph.append(line)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    private static func markdownTable(
        startingAt index: Int,
        lines: [String]
    ) -> (table: MarkdownTable, nextIndex: Int)? {
        guard index + 1 < lines.count,
              lines[index].contains("|"),
              lines[index + 1].contains("|")
        else { return nil }

        let headers = pipeCells(lines[index])
        let delimiters = pipeCells(lines[index + 1])
        guard !headers.isEmpty,
              headers.count == delimiters.count,
              delimiters.allSatisfy(isTableDelimiterCell)
        else { return nil }

        var rows: [[String]] = []
        var cursor = index + 2
        while cursor < lines.count, lines[cursor].contains("|") {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { break }
            rows.append(normalizedTableRow(pipeCells(lines[cursor]), count: headers.count))
            cursor += 1
        }

        return (
            MarkdownTable(
                headers: headers,
                alignments: delimiters.map(tableAlignment),
                rows: rows
            ),
            cursor
        )
    }

    private static func pipeCells(_ line: String) -> [String] {
        var body = line.trimmingCharacters(in: .whitespaces)
        if body.first == "|" { body.removeFirst() }
        if body.last == "|" { body.removeLast() }

        var cells: [String] = []
        var current = ""
        var escaped = false
        for char in body {
            if escaped {
                current.append(char)
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else if char == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(char)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func isTableDelimiterCell(_ cell: String) -> Bool {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        let body = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        return !body.isEmpty && body.allSatisfy { $0 == "-" }
    }

    private static func tableAlignment(_ delimiter: String) -> MarkdownTable.Alignment {
        let trimmed = delimiter.trimmingCharacters(in: .whitespaces)
        let leading = trimmed.hasPrefix(":")
        let trailing = trimmed.hasSuffix(":")
        if leading && trailing { return .center }
        if trailing { return .trailing }
        return .leading
    }

    private static func normalizedTableRow(_ row: [String], count: Int) -> [String] {
        if row.count == count { return row }
        if row.count > count { return Array(row.prefix(count)) }
        return row + Array(repeating: "", count: count - row.count)
    }

    private static func blockquoteRun(
        startingAt index: Int,
        lines: [String]
    ) -> (text: String, nextIndex: Int)? {
        guard let first = blockquoteText(lines[index]) else { return nil }
        var quoted = [first]
        var cursor = index + 1
        while cursor < lines.count, let text = blockquoteText(lines[cursor]) {
            quoted.append(text)
            cursor += 1
        }
        return (quoted.joined(separator: "\n"), cursor)
    }

    private static func blockquoteText(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(">") else { return nil }
        var text = String(trimmed.dropFirst())
        if text.first == " " { text.removeFirst() }
        return text
    }

    private static func taskListRun(
        startingAt index: Int,
        lines: [String]
    ) -> (items: [MarkdownTaskItem], nextIndex: Int)? {
        guard let first = taskItem(lines[index]) else { return nil }
        var items = [first]
        var cursor = index + 1
        while cursor < lines.count, let item = taskItem(lines[cursor]) {
            items.append(item)
            cursor += 1
        }
        return (items, cursor)
    }

    private static func taskItem(_ line: String) -> MarkdownTaskItem? {
        let (leading, rest) = splitLeadingSpaces(line)
        guard rest.hasPrefix("- [") || rest.hasPrefix("* [") || rest.hasPrefix("+ [") else { return nil }
        let chars = Array(rest)
        guard chars.count >= 6,
              chars[1] == " ",
              chars[2] == "[",
              chars[4] == "]",
              chars[5] == " ",
              chars[3] == " " || chars[3].lowercased() == "x"
        else { return nil }
        return MarkdownTaskItem(
            checked: chars[3].lowercased() == "x",
            text: String(chars.dropFirst(6)),
            level: nestingLevel(forLeadingSpaces: leading)
        )
    }

    private static func listRun(
        startingAt index: Int,
        lines: [String]
    ) -> (items: [MarkdownListItem], nextIndex: Int)? {
        guard let first = listItem(lines[index]) else { return nil }
        var items = [first]
        var cursor = index + 1
        while cursor < lines.count, let item = listItem(lines[cursor]) {
            items.append(item)
            cursor += 1
        }
        return (items, cursor)
    }

    private static func listItem(_ line: String) -> MarkdownListItem? {
        let (leading, rest) = splitLeadingSpaces(line)
        guard !rest.isEmpty else { return nil }
        let level = nestingLevel(forLeadingSpaces: leading)
        if rest.hasPrefix("- ") || rest.hasPrefix("* ") || rest.hasPrefix("+ ") {
            return MarkdownListItem(marker: "•", text: String(rest.dropFirst(2)), level: level)
        }
        var digits = ""
        var cursor = rest.startIndex
        while cursor < rest.endIndex, rest[cursor].isNumber {
            digits.append(rest[cursor])
            cursor = rest.index(after: cursor)
        }
        guard !digits.isEmpty,
              cursor < rest.endIndex,
              rest[cursor] == "." || rest[cursor] == ")"
        else { return nil }
        let delimiter = rest[cursor]
        let afterDelimiter = rest.index(after: cursor)
        guard afterDelimiter < rest.endIndex, rest[afterDelimiter] == " " else { return nil }
        let textStart = rest.index(after: afterDelimiter)
        return MarkdownListItem(marker: "\(digits)\(delimiter)", text: String(rest[textStart...]), level: level)
    }

    private static func splitLeadingSpaces(_ line: String) -> (Int, Substring) {
        var count = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == " " {
            count += 1
            index = line.index(after: index)
        }
        return (count, line[index...])
    }

    private static func nestingLevel(forLeadingSpaces spaces: Int) -> Int {
        min(spaces / 2, 4)
    }

    // MARK: - CC-01: Streaming cursor

    /// A standalone animated cursor view — the single breathing cursor glyph for
    /// the streaming tail (round-2 ROOT D: lifted off the prose `Text` so the
    /// pulse never re-composites the prose block). Starts/stops the pulse
    /// animation in sync with `message.isStreaming`.
    private var cursorView: some View {
        Text(" ▌")
            .foregroundColor(theme.midground)
            .opacity(message.isStreaming ? cursorPulseOpacity : 1.0)
            .onAppear {
                guard message.isStreaming else { return }
                startCursorPulse()
            }
            .onChange(of: message.isStreaming) { _, streaming in
                if streaming {
                    startCursorPulse()
                } else {
                    // Turn complete: snap back to full opacity.
                    withAnimation(.easeOut(duration: 0.15)) {
                        cursorPulseOpacity = 1.0
                    }
                }
            }
    }

    /// Kick off the repeating breathe animation for the streaming cursor.
    private func startCursorPulse() {
        withAnimation(
            .easeInOut(duration: 0.6)
            .repeatForever(autoreverses: true)
        ) {
            cursorPulseOpacity = 0.25
        }
    }

    private func usageFooter(_ usage: UsageStats) -> some View {
        Text(Self.usageLine(usage))
            .font(.caption2)
            .foregroundStyle(theme.mutedFg)
            .padding(.top, 2)
    }

    // MARK: - Assistant action row (F3)

    /// Thin line-icon action row under a completed assistant turn: copy, share,
    /// speak (existing `onSpeak`), retry (existing `onRetry`). 16pt glyphs,
    /// `theme.mutedFg`, 20pt spacing, no backgrounds (observed reference). Speak
    /// and retry render only when their hook is supplied (mirrors the context
    /// menu's existing gating); copy + share are always available.
    ///
    /// CC-02: copy button shows a checkmark confirmation (+ haptic) matching
    /// CodeBlockView's copy UX so every copy surface in the transcript is consistent.
    /// CC-07: top padding raised from 4 → 8 for better separation from prose.
    private var assistantActionRow: some View {
        HStack(spacing: 20) {
            // CC-02: confirm copy with checkmark + color change (mirrors CodeBlockView).
            Button {
                copyAssistantMessage()
            } label: {
                Image(systemName: didCopyMessage ? "checkmark" : "doc.on.doc")
                    .font(.body)
                    .foregroundStyle(didCopyMessage ? theme.statusOK : theme.mutedFg)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(didCopyMessage ? "Copied to clipboard" : "Copy")

            ShareLink(item: message.text) {
                Image(systemName: "square.and.arrow.up")
                    .font(.body)
                    .foregroundStyle(theme.mutedFg)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Share")
            if let onSpeak {
                actionIcon("speaker.wave.2", label: "Speak") {
                    onSpeak(message)
                }
            }
            if let onRetry {
                actionIcon("arrow.counterclockwise", label: "Retry") {
                    onRetry(message)
                }
            }
            Spacer(minLength: 0)
        }
        // CC-07: 8pt top gap gives the action row clear breathing room from prose.
        .padding(.top, 8)
    }

    /// One thin line-icon action button (no background).
    private func actionIcon(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body)
                .foregroundStyle(theme.mutedFg)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - System / tool

    private var metaRow: some View {
        Text(message.text)
            .font(.caption2)
            .foregroundStyle(theme.mutedFg)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Formatting

    /// Render markdown inline, preserving whitespace, falling back to plain text.
    static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    // MARK: - Prose list rendering (UI-C C1)

    /// Hanging indent applied to detected list lines: the first line starts at
    /// the margin (the marker sits at 0) and wrapped continuation lines indent
    /// so they align under the text after the marker.
    private static let listFirstLineHeadIndent: CGFloat = 0
    private static let listHeadIndent: CGFloat = 18

    /// Build the prose attributed string for a segment, detecting markdown
    /// ordered/unordered list lines and giving them a hanging indent so wrapped
    /// continuations align under the item text. Ordinals are monospaced-digit so
    /// numbered lists stay column-aligned. Non-list prose keeps the existing
    /// inline-markdown rendering verbatim.
    static func prose(_ text: String) -> AttributedString {
        let lines = text.components(separatedBy: "\n")
        guard lines.contains(where: { listMarker($0) != nil }) else {
            return attributed(text)
        }

        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            var lineAttr = attributed(line)
            if let marker = listMarker(line) {
                let paragraph = NSMutableParagraphStyle()
                paragraph.firstLineHeadIndent = listFirstLineHeadIndent
                paragraph.headIndent = listHeadIndent
                lineAttr.paragraphStyle = paragraph
                if marker == .ordered {
                    // Keep numbered ordinals column-aligned across items, in the
                    // serif prose face (F3) so list text matches surrounding prose.
                    lineAttr.font = .system(.body, design: .serif).monospacedDigit()
                }
            }
            result += lineAttr
            if index != lines.count - 1 {
                result += AttributedString("\n")
            }
        }
        return result
    }

    private enum ListMarker { case ordered, unordered }

    /// Classify a line as an ordered (`1.` / `1)`) or unordered (`- ` / `* ` /
    /// `+ `) list item, ignoring up to a few leading spaces. `nil` otherwise.
    private static func listMarker(_ line: String) -> ListMarker? {
        var scalars = Substring(line)
        // Allow modest leading indentation (nested lists / soft wraps).
        var leading = 0
        while let first = scalars.first, first == " ", leading < 6 {
            scalars = scalars.dropFirst()
            leading += 1
        }
        guard let first = scalars.first else { return nil }
        if first == "-" || first == "*" || first == "+" {
            let rest = scalars.dropFirst()
            if rest.first == " " { return .unordered }
            return nil
        }
        if first.isNumber {
            var digits = scalars
            while let d = digits.first, d.isNumber { digits = digits.dropFirst() }
            // A delimiter (. or )) followed by a space marks an ordered item.
            if let delim = digits.first, delim == "." || delim == ")" {
                let after = digits.dropFirst()
                if after.first == " " { return .ordered }
            }
        }
        return nil
    }

    /// "1,234 tokens · $0.0123 · ctx 142K" — omits the cost when absent and the
    /// "ctx N" clause when the turn's usage carried no context occupancy (H1).
    static func usageLine(_ usage: UsageStats) -> String {
        var parts: [String] = []
        if let total = usage.total ?? combinedTokens(usage) {
            parts.append("\(total) tokens")
        }
        if let cost = usage.costUsd {
            parts.append(String(format: "$%.4f", cost))
        }
        if let ctx = usage.contextUsed {
            parts.append("ctx \(UsageStats.formatK(ctx))")
        }
        return parts.joined(separator: " · ")
    }

    private static func combinedTokens(_ usage: UsageStats) -> Int? {
        guard usage.input != nil || usage.output != nil else { return nil }
        return (usage.input ?? 0) + (usage.output ?? 0)
    }

    // MARK: - Sent-image attachment hints

    struct SentImageAttachment: Identifiable, Sendable, Equatable {
        let name: String
        let filename: String

        var id: String { name }
    }

    struct SentImageAttachmentInput: Sendable, Equatable {
        let displayText: String
        let attachments: [SentImageAttachment]
    }

    /// Parse the gateway's image-attachment hint lines out of a user message.
    ///
    /// ``image.attach`` / native image routing stores text like
    /// `[Image attached at: ~/.hermes/uploads/<opaque>.jpg]` in the persisted user
    /// row. The human bubble should render the actual image thumbnail and keep the
    /// prose caption, not show that machine hint as chat text. If a hint is present
    /// but unsafe/unsupported, return the original text unchanged so the user still
    /// gets an honest filename fallback.
    nonisolated static func sentImageAttachments(in text: String) -> SentImageAttachmentInput {
        let lines = text.components(separatedBy: .newlines)
        var displayLines: [String] = []
        var attachments: [SentImageAttachment] = []

        for line in lines {
            guard let target = attachmentTarget(from: line) else {
                displayLines.append(line)
                continue
            }
            guard let attachment = sentImageAttachment(from: target) else {
                return SentImageAttachmentInput(displayText: text, attachments: [])
            }
            attachments.append(attachment)
        }

        guard !attachments.isEmpty else {
            return SentImageAttachmentInput(displayText: text, attachments: [])
        }
        let cleaned = displayLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SentImageAttachmentInput(displayText: cleaned, attachments: attachments)
    }

    private nonisolated static func attachmentTarget(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["[Image attached at: ", "[User attached image: "] {
            guard trimmed.hasPrefix(prefix), trimmed.hasSuffix("]") else { continue }
            let start = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
            let end = trimmed.index(before: trimmed.endIndex)
            return String(trimmed[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private nonisolated static func sentImageAttachment(from target: String) -> SentImageAttachment? {
        guard !target.isEmpty,
              !target.contains(".."),
              !target.contains("\\")
        else { return nil }
        let name = target.split(separator: "/").last.map(String.init) ?? target
        guard name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              name.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil,
              !name.contains(".."),
              sentImageExtensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased())
        else { return nil }
        return SentImageAttachment(name: name, filename: name)
    }

    private nonisolated static let sentImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif"
    ]

    // MARK: - A11y: combined element label construction

    /// Returns the VoiceOver label for a settled bubble's combined accessibility
    /// element: "You said: {text}" for user turns, "Assistant said: {text}" for
    /// assistant turns. Extracted as a testable `static` so unit tests can verify
    /// the label without instantiating a View.
    ///
    /// `nonisolated` so the function can be called from any concurrency context
    /// (e.g. test cases running off the main actor) without a warning — it is a
    /// pure function over two `Sendable` value types.
    ///
    /// `text` should be the concatenated prose from `ChatMessage.text` (the ordered
    /// `.text`-part concat); callers pass it in so the function is pure.
    nonisolated static func bubbleAccessibilityLabel(role: ChatRole, text: String) -> String {
        switch role {
        case .user:
            return "You said: \(text)"
        case .assistant:
            return "Assistant said: \(text)"
        case .system:
            return "System: \(text)"
        case .tool:
            return "Tool: \(text)"
        }
    }
}

private extension Array where Element == ChatMessagePart {
    var lastTextPartID: String? {
        for part in reversed() {
            if case .text(let id, _) = part { return id }
        }
        return nil
    }
}

private struct MarkdownTableBlockView: View {
    @Environment(\.hermesTheme) private var theme

    let table: MessageBubble.MarkdownTable

    private static let minCellWidth: CGFloat = 116
    private static let maxCellWidth: CGFloat = 240

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                row(table.headers, isHeader: true, rowIndex: 0)
                if table.rows.isEmpty {
                    emptyRow
                } else {
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, cells in
                        row(cells, isHeader: false, rowIndex: rowIndex)
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .background(theme.codeBg, in: RoundedRectangle(cornerRadius: 12, style: .circular))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .circular)
                    .strokeBorder(theme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .circular))
        }
        .perfScrollIndicators()
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Markdown table with \(table.headers.count) columns and \(table.rows.count) rows")
    }

    private func row(_ cells: [String], isHeader: Bool, rowIndex: Int) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { columnIndex, cell in
                cellView(
                    text: cell,
                    columnIndex: columnIndex,
                    isHeader: isHeader,
                    rowIndex: rowIndex
                )
            }
        }
    }

    private var emptyRow: some View {
        Text("No rows")
            .font(.caption.weight(.medium))
            .foregroundStyle(theme.mutedFg)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minWidth: CGFloat(max(table.headers.count, 1)) * Self.minCellWidth, alignment: .leading)
            .background(theme.muted.opacity(0.22))
            .overlay(Rectangle().stroke(theme.border.opacity(0.7), lineWidth: 0.5))
    }

    private func cellView(
        text: String,
        columnIndex: Int,
        isHeader: Bool,
        rowIndex: Int
    ) -> some View {
        let alignment = table.alignments.indices.contains(columnIndex)
            ? table.alignments[columnIndex]
            : .leading
        let background = isHeader
            ? theme.muted.opacity(0.42)
            : (rowIndex.isMultiple(of: 2) ? theme.card.opacity(0.22) : Color.clear)
        let displayedText = text.isEmpty ? "—" : text

        return Text(RenderCache.prose(displayedText))
            .font(.system(isHeader ? .subheadline : .body, design: .serif).weight(isHeader ? .semibold : .regular))
            .foregroundStyle(isHeader ? theme.fg : (text.isEmpty ? theme.mutedFg : theme.fg))
            .lineLimit(nil)
            .multilineTextAlignment(textAlignment(for: alignment))
            .padding(.horizontal, 12)
            .padding(.vertical, isHeader ? 9 : 10)
            .frame(minWidth: Self.minCellWidth, maxWidth: Self.maxCellWidth, alignment: frameAlignment(for: alignment))
            .background(background)
            .overlay(Rectangle().stroke(theme.border.opacity(0.72), lineWidth: 0.5))
            .perfTextSelection()
    }

    private func frameAlignment(for alignment: MessageBubble.MarkdownTable.Alignment) -> Alignment {
        switch alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func textAlignment(for alignment: MessageBubble.MarkdownTable.Alignment) -> TextAlignment {
        switch alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

private struct MarkdownBlockquoteView: View {
    @Environment(\.hermesTheme) private var theme

    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .circular)
                .fill(theme.midground.opacity(0.72))
                .frame(width: 3)
            Text(RenderCache.prose(text))
                .font(.system(.body, design: .serif))
                .foregroundStyle(theme.mutedFg)
                .lineSpacing(3.5)
                .perfTextSelection()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(theme.muted.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .circular))
        .accessibilityLabel("Quote: \(text)")
    }
}

private struct MarkdownTaskListView: View {
    @Environment(\.hermesTheme) private var theme

    let items: [MessageBubble.MarkdownTaskItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: item.checked ? "checkmark.square.fill" : "square")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(item.checked ? theme.statusOK : theme.mutedFg)
                        .accessibilityHidden(true)
                    Text(RenderCache.prose(item.text))
                        .font(.system(.body, design: .serif))
                        .foregroundStyle(theme.fg)
                        .strikethrough(item.checked, color: theme.mutedFg)
                        .perfTextSelection()
                }
                .padding(.leading, CGFloat(item.level) * 18)
                .accessibilityLabel("\(item.checked ? "Completed" : "Incomplete") task: \(item.text)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownListBlockView: View {
    @Environment(\.hermesTheme) private var theme

    let items: [MessageBubble.MarkdownListItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.marker)
                        .font(.system(.body, design: .serif).monospacedDigit().weight(.semibold))
                        .foregroundStyle(theme.mutedFg)
                        .frame(width: item.marker == "•" ? 14 : 28, alignment: .trailing)
                    Text(RenderCache.prose(item.text))
                        .font(.system(.body, design: .serif))
                        .foregroundStyle(theme.fg)
                        .lineSpacing(3.5)
                        .perfTextSelection()
                }
                .padding(.leading, CGFloat(item.level) * 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SentImageThumbnailView: View {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded(UIImage)
        case failed(String)
    }

    @Environment(\.hermesTheme) private var theme

    let attachment: MessageBubble.SentImageAttachment
    let rest: RestClient?
    let serverId: String
    let profileId: String
    let sessionId: String

    @State private var phase: Phase = .idle

    var body: some View {
        Group {
            switch phase {
            case .idle, .loading:
                loadingView
            case .loaded(let image):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                    .clipped()
                    .accessibilityLabel("Attached image \(attachment.filename)")
            case .failed:
                failedView
            }
        }
        .frame(width: thumbnailSize.width, height: thumbnailSize.height)
        .background(theme.userBubble.contrastingForeground.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(theme.userBubble.contrastingForeground.opacity(0.16), lineWidth: 1)
        )
        .task(id: attachment.name) { await load() }
    }

    private var thumbnailSize: CGSize {
        let width = min(UIScreen.main.bounds.width * 0.58, 220)
        return CGSize(width: width, height: min(width * 0.72, 160))
    }

    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
                .tint(theme.userBubble.contrastingForeground.opacity(0.75))
            Text("Loading image…")
                .font(.caption2)
                .foregroundStyle(theme.userBubble.contrastingForeground.opacity(0.70))
        }
    }

    private var failedView: some View {
        VStack(spacing: 7) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.title3)
            Text("Image unavailable")
                .font(.caption.weight(.semibold))
            Text(attachment.filename)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Retry") {
                Task { await load(force: true) }
            }
            .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(theme.userBubble.contrastingForeground.opacity(0.78))
        .padding(10)
    }

    private func load(force: Bool = false) async {
        if case .loaded = phase, !force { return }
        guard let rest else {
            phase = .failed("Not connected")
            return
        }

        let key = cacheKey
        if !force, let key, let image = AttachmentBlobCache.shared.image(for: key) {
            phase = .loaded(image)
            return
        }

        phase = .loading
        do {
            let data = try await rest.attachmentData(name: attachment.name)
            guard let image = UIImage(data: data) else {
                phase = .failed("Attachment is not a decodable image")
                return
            }
            if let key {
                AttachmentBlobCache.shared.store(data, for: key)
            }
            phase = .loaded(image)
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private var cacheKey: AttachmentBlobCache.Key? {
        let server = serverId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !server.isEmpty else { return nil }
        return AttachmentBlobCache.Key(
            serverId: server,
            profileId: profileId,
            sessionId: sessionId,
            path: "uploads/\(attachment.name)",
            size: 0
        )
    }
}

/// The user-bubble background + border chrome. Factored into a modifier so the
/// DEBUG conic-stroke hunt can strip it (`HERMES_EXP_NO_BUBBLE_BG`) and attribute
/// the per-frame angular-gradient render cost. Production = bg fill + stroke.
private struct PerfUserBubbleChrome: ViewModifier {
    @Environment(\.hermesTheme) private var theme

    func body(content: Content) -> some View {
        #if DEBUG
        if RenderCache.expNoBubbleBg {
            return AnyView(content)
        }
        #endif
        return AnyView(content
            .background(theme.userBubble, in: RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(theme.userBubbleBorder, lineWidth: 1)
            ))
    }
}

// MARK: - A1: Equatable short-circuit (scarf RichMessageBubble pattern)

/// Appearance inputs that affect a bubble's render but reach `MessageBubble` via
/// `@Environment` (theme, color scheme, Dynamic Type). They are carried as a value
/// so the static `==` can compare them — otherwise `.equatable()` could skip the
/// body on a theme/scheme/type-size change and strand stale styling. `ChatView`
/// builds this from `\.hermesTheme.id` + `\.colorScheme` + `\.dynamicTypeSize`.
/// `themeID` catches theme switches; `colorScheme` catches an adaptive theme's
/// light↔dark flip (where the name is unchanged); `typeSize` catches Dynamic Type.
struct BubbleAppearance: Equatable, Sendable {
    var themeID: String = ""
    var colorScheme: ColorScheme = .dark
    var typeSize: DynamicTypeSize = .large
}

extension MessageBubble: Equatable {
    /// Two bubbles render identically iff their content (`message`), the menu-action
    /// gating, and the appearance token match. `nonisolated` is required under
    /// Swift 6 strict concurrency: `Equatable.==` is a nonisolated requirement but a
    /// `View` is main-actor-isolated, so the witness may only read immutable
    /// `Sendable` storage — all three reads below are `let`s of `Sendable` type.
    /// The action closures are intentionally excluded (not `Sendable`; their nil-ness
    /// is stable per call site), so they cannot strand a real update.
    ///
    /// A11y note: `bubbleAccessibilityLabel` is derived from `message.role` and
    /// `message.text`, both of which are already compared via `message ==` above —
    /// so the combined element's label is implicitly covered by the existing `==`.
    /// No changes to the short-circuit logic are needed.
    nonisolated static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        lhs.message == rhs.message
            && lhs.menuActionsEnabled == rhs.menuActionsEnabled
            && lhs.appearance == rhs.appearance
    }
}

// MARK: - View.if conditional modifier

private extension View {
    /// Conditionally applies a modifier transform to a View.
    ///
    /// Used in `MessageBubble` to apply `.accessibilityElement(children: .combine)`
    /// ONLY on settled (non-streaming) bubbles, so the streaming hot-path carries
    /// zero accessibility overhead. Swift's type system requires the conditional to
    /// return the same opaque type in both branches — `@ViewBuilder` achieves that.
    ///
    /// - Parameters:
    ///   - condition: When `true` the transform is applied; `false` returns the
    ///     receiver unchanged.
    ///   - transform: A `@ViewBuilder` closure that applies the desired modifier(s).
    @ViewBuilder func `if`<T: View>(
        _ condition: Bool,
        transform: (Self) -> T
    ) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
