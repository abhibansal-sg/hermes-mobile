import SwiftUI
import UIKit

/// A single transcript entry.
///
/// - User: a trailing-aligned bronze bubble, capped at 78% width in compact
///   (iPhone) layouts and at the shared transcript reading measure
///   (``ChatView/transcriptReadingMeasure``) in regular (iPad) layouts.
/// - Assistant: a leading-aligned, bubble-less "document" — optional thinking,
///   a tool timeline, then markdown-rendered text with a streaming cursor.
/// - System / tool: small, centered, secondary captions.
struct MessageBubble: View {
    @Environment(\.hermesTheme) private var theme
    @Environment(ConnectionStore.self) private var connectionStore
    @Environment(SessionStore.self) private var sessionStore
    /// Drives the regular-width (iPad) user-bubble cap so it shares
    /// ``ChatView/transcriptReadingMeasure`` with the status glow and context
    /// line instead of drifting from its own 78%-of-screen formula (STR-1098).
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Honors Reduce Motion on the "Select Text" mode crossfade (approved design).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The message to render.
    let message: ChatMessage

    // MARK: - STR-695: available-width capture (size-class / split-view safe)
    /// Measured content width from the bubble's own geometry, captured via
    /// `.onGeometryChange`. Replaces every former `UIScreen.main.bounds.width`
    /// read so bubble + inline-image sizing stay correct in iPad split-view and
    /// multi-scene (where `UIScreen.main` reports the wrong scene/window).
    @State private var availableWidth: CGFloat = 0

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
    /// Invoked when the user chooses "Undo last turn" on the latest assistant
    /// message. The host calls `ChatStore.undoLastTurn()`. `nil` hides the action.
    let onUndoLastTurn: ((ChatMessage) -> Void)?
    /// Bool mirror of `onUndoLastTurn != nil`, compared by `Equatable` so the
    /// latest-assistant-only context action appears/disappears when the tail moves.
    let showsUndoLastTurnAction: Bool
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

    /// Whether the inline completed-turn assistant action row (copy/share/speak/
    /// retry) may be shown. Unlike context-menu actions, this row represents the
    /// *current turn is settled* affordance; while any local live turn is active
    /// (ABH-371 live re-entry), ChatView passes `false` so a reopened running
    /// session shows the working cursor/Stop state without a dangling end-of-turn
    /// row under older assistant prose.
    let assistantTurnActionsEnabled: Bool
    /// Active turn start from ``ChatStore.turnStartedAt``. Thinking rows use this
    /// for the live inline timer while streaming; settled rows read the duration
    /// stamped on their own message.
    let liveTurnStartedAt: Date?
    /// QA-2 R5/A3: whether the turn this row belongs to is LIVE at the store
    /// level (turn-scoped `ChatStore.isStreaming`, true for the LAST assistant
    /// row while the turn works). The working section selects its live vs.
    /// settled presentation off `message.isStreaming || liveTurnActive`, so the
    /// single "Working…" line persists across the brief all-terminal window
    /// BETWEEN two tool items of a live turn (where every item is momentarily
    /// terminal but the turn has not settled) — no "Worked ›" flash mid-turn.
    /// False for every non-last row, so settled turns never light up.
    let liveTurnActive: Bool

    /// Appearance identity (theme + Dynamic Type), folded into `Equatable` (A1) so
    /// a theme/type-size switch re-renders the bubble even though `.equatable()`
    /// short-circuits content-equal updates. The bubble reads the theme via
    /// `@Environment`, which the static `==` cannot observe — so it travels here as
    /// a value, supplied by `ChatView`. Defaults keep previews / standalone call
    /// sites compiling unchanged.
    let appearance: BubbleAppearance

    /// WhatsApp-style delivery state of this user bubble's durable outbox row
    /// (C1), correlated by `message.clientMessageID`. `.failed` shows the red
    /// error badge with Resend/Delete; `.inTransit`/`.none` show no extra
    /// affordance. A `Sendable`/`Equatable` value so the `nonisolated ==` can
    /// compare it and re-render the badge when the row transitions.
    let delivery: QueueStore.SendDelivery
    /// Invoked when the user taps "Resend" on a failed bubble — re-drives the
    /// existing outbox row. `nil` hides the action (previews / non-user rows).
    let onResend: (() -> Void)?
    /// Invoked when the user taps "Delete" on a failed bubble — cancels the row
    /// and removes the local echo. `nil` hides the action.
    let onDeleteFailedSend: (() -> Void)?

    /// Whether the Turn Dock is currently showing the task box for this session
    /// (Wave 25). When true, EVERY inline ``TodoCardView`` in the transcript is
    /// suppressed — not just the latest — because the dock is the single home for
    /// the checklist, and the same evolving list is otherwise re-snapshotted inline
    /// two or three times as the agent updates it (the owner-QA "same list shown
    /// 2-3x"). `false` ⇒ suppress nothing. Folded into `==` so a dock-visibility
    /// flip re-renders past the `.equatable()` short-circuit.
    let suppressTodoCards: Bool

    /// Explicit memberwise init so every comparison input can be an immutable
    /// `Sendable` `let` (required for the `nonisolated ==` under Swift 6 strict
    /// concurrency — a `View` is main-actor-isolated, so `Equatable.==` may only
    /// read immutable Sendable storage) while keeping the prior call-site defaults.
    init(
        message: ChatMessage,
        onEdit: ((ChatMessage) -> Void)? = nil,
        onRetry: ((ChatMessage) -> Void)? = nil,
        onUndoLastTurn: ((ChatMessage) -> Void)? = nil,
        onSpeak: ((ChatMessage) -> Void)? = nil,
        onRestoreCheckpoint: ((ChatMessage) -> Void)? = nil,
        onBranch: ((ChatMessage) -> Void)? = nil,
        menuActionsEnabled: Bool = true,
        assistantTurnActionsEnabled: Bool = true,
        liveTurnStartedAt: Date? = nil,
        liveTurnActive: Bool = false,
        appearance: BubbleAppearance = BubbleAppearance(),
        delivery: QueueStore.SendDelivery = .none,
        onResend: (() -> Void)? = nil,
        onDeleteFailedSend: (() -> Void)? = nil,
        suppressTodoCards: Bool = false
    ) {
        self.message = message
        self.onEdit = onEdit
        self.onRetry = onRetry
        self.onUndoLastTurn = onUndoLastTurn
        self.showsUndoLastTurnAction = onUndoLastTurn != nil
        self.onSpeak = onSpeak
        self.onRestoreCheckpoint = onRestoreCheckpoint
        self.onBranch = onBranch
        self.menuActionsEnabled = menuActionsEnabled
        self.assistantTurnActionsEnabled = assistantTurnActionsEnabled
        self.liveTurnStartedAt = liveTurnStartedAt
        self.liveTurnActive = liveTurnActive
        self.appearance = appearance
        self.delivery = delivery
        self.onResend = onResend
        self.onDeleteFailedSend = onDeleteFailedSend
        self.suppressTodoCards = suppressTodoCards
    }

    /// Whether this bubble's send is stuck/failed and should show the badge.
    private var isFailedSend: Bool {
        if case .failed = delivery { return true }
        return false
    }

    var body: some View {
        Group {
            if case .collapsed(let label) = message.presentation {
                collapsedRow(label: label)
            } else {
                switch message.role {
                case .user:
                    // Approved design §6: the user bubble is completely clean — zero
                    // visible affordances. Its actions live on a long-press
                    // `.contextMenu` that leads with "Select Text" (which swaps in a
                    // first-responding `SelectableTextView`); the normal render
                    // carries no `.textSelection`, so the menu owns the long-press
                    // cleanly with no gesture competition.
                    userBubble
                case .assistant:
                    // Approved design §7 + QA-1 B11/A6: agent turns get NO context
                    // menu. Each contiguous prose run renders as ONE selectable
                    // `UITextView` container (`ProseSelectionContainer`): long-press
                    // starts genuine native WORD-level selection with drag handles,
                    // extendable across paragraphs / lists / blockquotes (paragraphs
                    // are NOT selection walls); exit by tapping away; Copy lives on
                    // the system edit menu — no Copy|Share pill, no "Done" (N5
                    // islands rules intact). Code / table / math / image cards stay
                    // non-selectable islands that split the prose flow. Turn actions
                    // live on `assistantActionRow`.
                    assistantBody
                case .system, .tool:
                    metaRow
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            if abs(width - availableWidth) > 0.5 {
                availableWidth = width
            }
        }
    }

    // MARK: - Long-press context menu (user bubble) + native selection

    /// Whether the user bubble is currently in "Select Text" mode — the normal
    /// `Text` render is swapped for a first-responding ``SelectableTextView`` so
    /// the reader gets native drag-handle selection + the system edit menu. Entered
    /// from the long-press context menu's leading "Select Text" item (approved
    /// design §6). Agent turns do NOT use this — their prose is always natively
    /// selectable (no competing context menu).
    @State private var isSelectingText = false

    /// User-bubble long-press menu. Leads with "Select Text" (the deliberate entry
    /// into native selection), then Copy, then the wired mutable actions, and a
    /// destructive Delete for a failed send. The bubble stays completely clean —
    /// every action lives here behind the long-press (approved design §6).
    @ViewBuilder
    private var userMenu: some View {
        Button {
            beginTextSelection()
        } label: {
            Label("Select Text", systemImage: "selection.pin.in.out")
        }
        Button {
            copyToPasteboard(message.text)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        if onEdit != nil || onBranch != nil || onRestoreCheckpoint != nil {
            Divider()
        }
        if let onEdit {
            Button {
                onEdit(message)
            } label: {
                Label("Edit", systemImage: "pencil")
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
        if let onRestoreCheckpoint {
            Button {
                onRestoreCheckpoint(message)
            } label: {
                Label("Restore checkpoint", systemImage: "clock.arrow.circlepath")
            }
            .disabled(!menuActionsEnabled)
        }
        if let onDeleteFailedSend {
            Divider()
            Button(role: .destructive) {
                onDeleteFailedSend()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// Enter native text-selection mode (from the menu's "Select Text"). Honors
    /// Reduce Motion — no crossfade when the setting is on.
    private func beginTextSelection() {
        if reduceMotion {
            isSelectingText = true
        } else {
            withAnimation(.easeOut(duration: 0.15)) { isSelectingText = true }
        }
    }

    /// Exit text-selection mode ("Done").
    private func endTextSelection() {
        if reduceMotion {
            isSelectingText = false
        } else {
            withAnimation(.easeOut(duration: 0.15)) { isSelectingText = false }
        }
    }

    /// A trailing "Done" affordance shown under the selectable text so the reader
    /// can leave selection mode. Sentence-case, plain, muted — quiet by design.
    private var selectionDoneButton: some View {
        Button {
            endTextSelection()
        } label: {
            Text("Done")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(theme.accent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Done selecting text")
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

    /// Whether the failed-send confirmation menu (Resend / Delete) is showing.
    @State private var showDeliveryActions = false

    private var userBubble: some View {
        let attachmentInput = Self.sentImageAttachments(in: message.text)
        let displayText = attachmentInput.displayText
        return HStack(alignment: .center, spacing: 6) {
            Spacer(minLength: 0)
            // Approved design §6: the user bubble is completely clean — NO three-dots,
            // no inline affordances. Every action lives on the long-press
            // `.contextMenu` attached below (leading with "Select Text").
            if isFailedSend {
                deliveryFailureBadge
            }
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
                    if isSelectingText {
                        // Selection mode: real UITextView selection with drag handles
                        // + the system edit menu. Auto-selects all on mount; the user
                        // narrows from there.
                        VStack(alignment: .trailing, spacing: 6) {
                            SelectableTextView(
                                text: displayText,
                                font: SelectableTextView.font(textStyle: .body, serif: false),
                                textColor: UIColor(theme.userBubble.contrastingForeground)
                            )
                            selectionDoneButton
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                    } else {
                        // Normal render: a plain `Text` with NO `.textSelection`, so
                        // the long-press `.contextMenu` owns the gesture cleanly.
                        Text(displayText)
                            .foregroundStyle(theme.userBubble.contrastingForeground)
                            .lineLimit(userBubbleExpanded ? nil : Self.userBubbleCollapsedLines)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                    }
                }
                if !isSelectingText, shouldShowReadMore(for: displayText) {
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
            // focus stops for the text and the "Read more" button. Selection mode
            // drops the combine so the selectable text is its own element.
            .if(!message.isStreaming && !isSelectingText) { bubble in
                bubble
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(MessageBubble.bubbleAccessibilityLabel(
                        role: message.role,
                        text: displayText
                    ))
            }
            .modifier(PerfUserBubbleChrome())
            .frame(maxWidth: maxBubbleWidth, alignment: .trailing)
            // Approved design §6: the whole clean bubble long-presses into its
            // action menu (Select Text / Copy / Edit / Branch / Restore / Delete).
            .contextMenu { userMenu }
        }
    }

    /// The WhatsApp-style failed-send affordance (C1): a small red-circle
    /// exclamation to the left of the bubble. Tapping opens a confirmation menu
    /// with exactly two actions — Resend and Delete. Uses the existing error
    /// iconography (`exclamationmark.circle.fill`, `theme.destructive`) so it
    /// matches the app's design language with no new visual vocabulary.
    private var deliveryFailureBadge: some View {
        Button {
            showDeliveryActions = true
        } label: {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.title3)
                .foregroundStyle(theme.destructive)
                .symbolRenderingMode(.hierarchical)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Message not sent")
        .accessibilityHint("Double-tap for resend and delete options")
        .accessibilityIdentifier("messageDeliveryFailedBadge")
        .confirmationDialog(
            "Message not sent",
            isPresented: $showDeliveryActions,
            titleVisibility: .visible
        ) {
            if let onResend {
                Button("Resend") { onResend() }
            }
            if let onDeleteFailedSend {
                Button("Delete", role: .destructive) { onDeleteFailedSend() }
            }
            Button("Cancel", role: .cancel) {}
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

    /// Cap user bubbles from the MEASURED available width (STR-695), never
    /// `UIScreen.main`: compact layouts use 78% of their actual column, while
    /// regular layouts share ``ChatView/transcriptReadingMeasure`` as an upper
    /// bound (STR-1098) and still clamp to narrow iPad split-view columns.
    private var maxBubbleWidth: CGFloat {
        guard availableWidth > 0 else { return 320 }
        return Self.userBubbleMaxWidth(
            availableWidth: availableWidth,
            horizontalSizeClass: horizontalSizeClass)
    }

    /// Fraction of the compact column width a user bubble may occupy.
    static let userBubbleCompactWidthFraction: CGFloat = 0.78

    /// Pure width decision behind ``maxBubbleWidth``: the 78% measured compact
    /// cap, or the smaller of the measured regular column and the shared
    /// transcript reading measure. Static so tests can pin both branches.
    static func userBubbleMaxWidth(
        availableWidth: CGFloat,
        horizontalSizeClass: UserInterfaceSizeClass?
    ) -> CGFloat {
        guard horizontalSizeClass == .regular else {
            return availableWidth * userBubbleCompactWidthFraction
        }
        return min(availableWidth, ChatView.transcriptReadingMeasure)
    }

    // MARK: - Assistant

    private var assistantBody: some View {
        // `parts` is the sole content source of truth (ABH-87 §3.1) — render it
        // directly in wire order, no `assistantRenderParts` indirection.
        let parts = message.parts
        let lastTextPartID = parts.lastTextPartID
        // QA-3 S2/S3/A1 — ONE merged working affordance. While the turn is
        // live and no answer text flows yet, the bubble's SOLE content is the
        // merged working line — breathing cursor + inline status + per-turn
        // timer (tap to expand) — rendered with whatever parts exist (ZERO in
        // the send→first-frame window). This replaces the build-116 stack of
        // a bare standalone caret beside a separate spinner/"Working… 35s"
        // fold line (S3: two affordances), and it renders from SEND — the
        // labeled+timed affordance is no longer gated on the first relay item
        // frame (S2: it appeared ~35s late, reading the honest timer on a
        // line that waited on the model's first item). The fold and the caret
        // are the SAME surface now; item arrival only updates the line's
        // status text, never mounts a second one.
        let mergedWorkingLine = Self.showsStandaloneWorkingLine(
            isStreaming: message.isStreaming,
            liveTurnActive: liveTurnActive,
            parts: parts
        )

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
                if mergedWorkingLine {
                    // THE single working affordance (phases A + B: no answer
                    // text yet). Owns the breathing cursor glyph; renders from
                    // send with ZERO parts (the optimistic caret bubble) and
                    // keeps identity as work parts land — only the status text
                    // changes; the line never forks into two surfaces (S3).
                    WorkingSectionView(
                        parts: parts,
                        streaming: true,
                        liveTurnStartedAt: liveTurnStartedAt,
                        settledDuration: message.reasoningElapsed,
                        showsCursorGlyph: true
                    )
                } else {
                    // Wave-2 item dispatch (RELAY-PHONE-PROTOCOL §2): coalesce
                    // the ordered parts into render nodes so consecutive
                    // reasoning + tool/file/browser/image/error ITEM parts
                    // fold into one collapsed working section (owner spec).
                    // Standalone parts (text/usage/warning, legacy
                    // reasoning/tools) render exactly as before.
                    ForEach(WorkingSectionModel.renderNodes(from: parts)) { node in
                        switch node {
                        case .part(let part):
                            assistantPart(part, showsCursor: message.isStreaming && part.id == lastTextPartID)
                        case .working(_, let runParts):
                            WorkingSectionView(
                                parts: runParts,
                                streaming: message.isStreaming || liveTurnActive,
                                liveTurnStartedAt: liveTurnStartedAt,
                                settledDuration: message.reasoningElapsed,
                                // Phase C: the fold runs beside flowing answer
                                // text — the prose-tail `StreamingCursor` owns
                                // the pulse, the fold keeps status + timer only
                                // (exactly one glyph breathes at any instant).
                                showsCursorGlyph: false
                            )
                        }
                    }
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
                        text: Self.accessibilityTextForMarkdown(message.text)
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
            if Self.shouldShowAssistantActionRow(
                messageIsStreaming: message.isStreaming,
                hasRenderedText: hasRenderedText,
                hasTurnActions: hasAssistantTurnActions,
                assistantTurnActionsEnabled: assistantTurnActionsEnabled
            ) {
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

    /// Whether this turn exposes at least one TURN-LEVEL action (retry / undo /
    /// branch) — the affordances that must stay reachable on a settled turn even
    /// when it rendered no prose (tool-only / reasoning-only / error-only). These
    /// are the actions the removed whole-bubble `.contextMenu` always guaranteed;
    /// without this, a text-less settled turn would show NO action affordance.
    private var hasAssistantTurnActions: Bool {
        onRetry != nil || onBranch != nil
    }

    /// Pure action-row visibility contract for tests: a completed assistant row
    /// shows when the chat-level turn is settled AND there is something to act on
    /// — either rendered prose (copy / share / speak) OR a turn-level action
    /// (retry / undo / branch). The prose-OR-turn-action rule is what keeps a
    /// text-less settled turn (tool-only / reasoning-only / error-only) from
    /// losing every affordance the old always-attached context menu provided.
    /// The chat-level `assistantTurnActionsEnabled` gate prevents live re-entry
    /// from showing an end-of-turn row while the runtime is still working.
    nonisolated static func shouldShowAssistantActionRow(
        messageIsStreaming: Bool,
        hasRenderedText: Bool,
        hasTurnActions: Bool,
        assistantTurnActionsEnabled: Bool
    ) -> Bool {
        guard !messageIsStreaming, assistantTurnActionsEnabled else { return false }
        return hasRenderedText || hasTurnActions
    }

    /// QA-3 S2/S3/A1 — the merged working-line contract (pure, unit-pinned by
    /// `RenderConformanceTests`). TRUE iff the bubble renders the SINGLE
    /// merged working line (breathing cursor + inline status + per-turn timer)
    /// as its sole content — the pre-answer-text live window:
    ///  • phase A (send → first frame): ZERO parts — the optimistic caret
    ///    bubble; the line reads "Working… ‹local timer›" from SEND, driven by
    ///    local send state, never a relay frame (S2);
    ///  • phase B (work parts, no answer text yet): the line carries the SAME
    ///    parts the fold would — item arrival only updates the status text;
    ///    NO second standalone caret mounts beside it (the S3 double
    ///    affordance: build 116 stacked a bare caret under the spinner line).
    /// FALSE once answer text flows (phase C): the `renderNodes` ForEach takes
    /// over — the fold keeps status + timer beside the prose and the
    /// prose-tail `StreamingCursor` owns the pulse — and FALSE when settled.
    nonisolated static func showsStandaloneWorkingLine(
        isStreaming: Bool,
        liveTurnActive: Bool,
        parts: [ChatMessagePart]
    ) -> Bool {
        guard isStreaming || liveTurnActive else { return false }
        return parts.lastTextPartID == nil
    }

    /// QA-3 S3/A1 — the one-affordance invariant (pure, unit-pinned): the
    /// number of WORKING-LINE surfaces this bubble renders. Must be ≤ 1 in
    /// EVERY phase (build 116 returned 2 in phase B — the fold's spinner line
    /// + the standalone caret). The standalone line and the fold are mutually
    /// exclusive by `showsStandaloneWorkingLine` + the single-fold contract
    /// (`renderNodes` emits at most ONE `.working` node), so two surfaces are
    /// unreachable by construction. The prose-tail typing caret is NOT a
    /// working-line surface (it is the text's insertion point).
    nonisolated static func workingAffordanceCount(
        isStreaming: Bool,
        liveTurnActive: Bool,
        parts: [ChatMessagePart]
    ) -> Int {
        if showsStandaloneWorkingLine(
            isStreaming: isStreaming, liveTurnActive: liveTurnActive, parts: parts
        ) { return 1 }
        let foldNodes = WorkingSectionModel.renderNodes(from: parts)
            .reduce(into: 0) { count, node in
                if case .working = node { count += 1 }
            }
        // A fold only renders as a LIVE working line when the turn is live;
        // settled it is the "Worked for N" row — not a working affordance.
        let live = isStreaming || liveTurnActive
        return live ? foldNodes : 0
    }

    @ViewBuilder
    private func assistantPart(_ part: ChatMessagePart, showsCursor: Bool) -> some View {
        switch part {
        case .reasoning(_, let text):
            if !ThinkingDisplay.cleanedText(text).isEmpty {
                // Wire-position thinking (§3.3): the accordion renders exactly
                // where this `.reasoning` part sits in `parts` (never hoisted to
                // the top) and auto-opens while the turn streams, collapsing when
                // it settles. `message.isStreaming` drives that default.
                ThinkingView(
                    thinking: text,
                    streaming: message.isStreaming,
                    liveTurnStartedAt: liveTurnStartedAt,
                    settledDuration: message.reasoningElapsed
                )
            }
        case .tools(_, let tools, let collapsed, let turnElapsed):
            // Wave 25: while the Turn Dock shows the task box for this session, drop
            // EVERY todo tool from the cluster — not just the latest — so the one
            // evolving checklist never renders inline on top of the dock (the
            // owner-QA "same list shown 2-3x"). Filtering HERE — the render boundary
            // that already gates on `!tools.isEmpty` — means a cluster left empty by
            // the drop cleanly renders nothing (no empty themed box).
            let visibleTools = suppressTodoCards
                ? tools.filter { $0.name != TodoList.toolName }
                : tools
            if !visibleTools.isEmpty {
                ToolClusterView(
                    tools: visibleTools,
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
        case .item(_, let item):
            // Wave-2 item-backed part (RELAY-PHONE-PROTOCOL §2): the new special
            // renders (generic tool card, fileChange, image, browser, error)
            // dispatch through the render-lane seam. Skeleton today; the render
            // lane fleshes out `ChatItemView`.
            ChatItemView(item: item)
        }
    }

    /// Render the assistant text as ordered prose / code / math segments (E3
    /// segmenter) laid out as a SELECTABLE PROSE FLOW (QA-1 B11 / A6): every
    /// contiguous prose run folds into ONE `UITextView`-backed
    /// ``ProseSelectionContainer`` so long-press starts genuine native
    /// WORD-level selection with drag handles, extendable across paragraphs /
    /// lists / blockquotes / alerts — paragraphs are NOT selection walls. Cards
    /// stay non-selectable islands that split the flow: fenced code →
    /// `CodeBlockView`, LaTeX → `MathSegmentView`, rich URLs →
    /// `RichURLEmbedCardView`, GFM tables → `MarkdownTableBlockView`, markdown
    /// images → `MarkdownImageBlockView` (STR-695). The streaming cursor is a
    /// standalone sibling so cards never get a stray glyph.
    private func assistantText(_ text: String, showsCursor: Bool) -> some View {
        // Memoized segmentation (RenderCache): a flick-scroll re-realizes this
        // row without changing `text`, so the segment scan is an O(1) cache hit
        // instead of an O(n) re-scan of the whole body.
        //
        // D1: the ONE actively-streaming tail (`showsCursor`) takes the
        // incremental path, which reuses the settled blocks and re-parses only the
        // in-progress block, so a 40ms flush is O(current block) not O(total).
        // Settled rows go through the value-keyed full parse (O(1) on a cache hit),
        // and on stream completion the bubble renders non-streaming through that
        // same full parse — byte-identical to today.
        let segments = showsCursor ? RenderCache.streamingSegments(text) : RenderCache.segments(text)
        let flow = proseFlowNodes(segments)

        return VStack(alignment: .leading, spacing: Self.segmentSpacing) {
            // POSITIONAL identity (release audit P1): keying on a content hash
            // gave every streaming delta a NEW id — ForEach tore down and
            // rebuilt the prose view on every flush, breaking in-progress text
            // selection. Flow nodes are append-only during a stream, so the
            // offset is the stable identity and the container diffs its
            // attributed text in place.
            ForEach(Array(flow.enumerated()), id: \.offset) { _, node in
                proseFlowNodeView(node)
            }
            // CC-01 / round-2: the breathing streaming cursor is a single
            // standalone sibling for ALL cases (rides prose, tail-is-code, or
            // no-prose-yet). Keeping it OFF the prose container means the pulse
            // animation never re-composites the (large) prose block — only this
            // tiny glyph view animates. It sits just after the segment stack,
            // reading as the live tail of the turn.
            if showsCursor {
                StreamingCursor(isStreaming: message.isStreaming)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A rendered piece of the assistant prose flow (QA-1 B11 / A6): one
    /// selectable prose container per contiguous prose run, with cards
    /// (code / math / embed / table / image) as non-selectable islands between
    /// containers.
    private enum ProseFlowNode: Equatable {
        case prose(NSAttributedString)
        case table(MarkdownTable)
        case image(alt: String, source: String)
        case code(language: String?, body: String)
        case math(latex: String, display: Bool)
        case embed(RichURLEmbedDescriptor)

        static func == (lhs: ProseFlowNode, rhs: ProseFlowNode) -> Bool {
            switch (lhs, rhs) {
            case let (.prose(a), .prose(b)): return a.isEqual(to: b)
            case let (.table(a), .table(b)): return a == b
            case let (.image(a1, s1), .image(a2, s2)): return a1 == a2 && s1 == s2
            case let (.code(l1, b1), .code(l2, b2)): return l1 == l2 && b1 == b2
            case let (.math(x1, d1), .math(x2, d2)): return x1 == x2 && d1 == d2
            case let (.embed(a), .embed(b)): return a == b
            default: return false
            }
        }
    }

    /// Coalesce segments into flow nodes: consecutive `.prose` segments (the D1
    /// incremental path can split one prose run at a blank line) merge into a
    /// SINGLE selectable container; a card segment flushes the pending prose
    /// and renders as its own non-selectable island.
    private func proseFlowNodes(_ segments: [MessageSegmenter.Segment]) -> [ProseFlowNode] {
        var nodes: [ProseFlowNode] = []
        var proseBodies: [String] = []

        func flushProse() {
            guard !proseBodies.isEmpty else { return }
            let joined = proseBodies.joined(separator: "\n\n")
            proseBodies.removeAll(keepingCapacity: true)
            for piece in RenderCache.proseFlowPieces(
                body: joined,
                style: proseFlowStyle,
                linkColor: theme.midground
            ) {
                switch piece {
                case .prose(let attr): nodes.append(.prose(attr))
                case .table(let table): nodes.append(.table(table))
                case .image(let alt, let source): nodes.append(.image(alt: alt, source: source))
                }
            }
        }

        for segment in segments {
            switch segment {
            case .prose(let body):
                proseBodies.append(body)
            case .code(let language, let body):
                flushProse()
                nodes.append(.code(language: language, body: body))
            case .math(let latex, let display):
                flushProse()
                nodes.append(.math(latex: latex, display: display))
            case .embed(let descriptor):
                flushProse()
                nodes.append(.embed(descriptor))
            }
        }
        flushProse()
        return nodes
    }

    @ViewBuilder
    private func proseFlowNodeView(_ node: ProseFlowNode) -> some View {
        switch node {
        case .prose(let attr):
            // Single selectable container per contiguous prose run (B11 / A6):
            // long-press = native word selection with handles; paragraphs are
            // not walls; exit by tapping away; Copy lives on the system edit
            // menu — no Copy|Share pill, no "Done" (N5 islands rules intact).
            ProseSelectionContainer(text: attr)
        case .table(let table):
            MarkdownTableBlockView(table: table)
        case .image(let alt, let source):
            // STR-695: markdown images stay native block-level islands
            // (zoomable lightbox + cache pieces) — image rendering untouched.
            MarkdownImageBlockView(alt: alt, source: source)
        case .code(let language, let body):
            CodeBlockView(language: language, code: body)
        case .math(let latex, let display):
            MathSegmentView(latex: latex, display: display)
        case .embed(let descriptor):
            RichURLEmbedCardView(descriptor: descriptor)
        }
    }

    /// Resolve the prose-container style from the ambient theme. A theme or
    /// Dynamic-Type change yields new values (and a new `RenderCache` key), so
    /// the container re-flattens once rather than serving a stale render.
    private var proseFlowStyle: ProseFlowStyle {
        let bodyFont = SelectableTextView.font(textStyle: .body, serif: true)
        return ProseFlowStyle(
            bodyFont: bodyFont,
            monoFont: .monospacedSystemFont(ofSize: bodyFont.pointSize, weight: .regular),
            fg: UIColor(theme.fg),
            mutedFg: UIColor(theme.mutedFg),
            linkColor: UIColor(theme.midground),
            quoteBackground: UIColor(theme.muted).withAlphaComponent(0.18),
            taskCheckTint: UIColor(theme.statusOK),
            lineSpacing: Self.proseLineSpacing,
            paragraphSpacing: Self.segmentSpacing
        )
    }

    /// Spacing between prose / code segments (UI-C C1 paragraph spacing).
    private static let segmentSpacing: CGFloat = 12
    /// Extra leading between wrapped prose lines (UI-C C1).
    private static let proseLineSpacing: CGFloat = 3.5

    // MARK: - STR-695 assistant-prose markdown image blocks

    /// A renderable piece of an assistant prose segment. Markdown images
    /// (`![alt](source)`) are hoisted out as `.image` siblings so they render
    /// as native block-level images (parity with desktop); every other run
    /// keeps flowing through the cached GFM block parser as `.blocks`.
    enum ChatProseEntry: Equatable, Sendable {
        case blocks([MarkdownBlock])
        case image(alt: String, source: String)
    }

    /// A one-line piece produced by ``splitLineByImages(_:)`` — either a prose
    /// fragment (text surrounding an image, or a line with no image at all) or
    /// a hoisted markdown image.
    enum ChatProseLineSplit: Equatable, Sendable {
        case prose(String)
        case image(alt: String, source: String)
    }

    /// Split a prose segment body into GFM-block batches interspersed with
    /// markdown image block siblings (STR-695). A line like
    /// `before ![alt](url) after` is split in place into prose / image / prose
    /// so the surrounding paragraphs render in order around a native image
    /// block, instead of collapsing the image into inline markdown. Non-image
    /// lines are grouped and handed to the memoized `RenderCache.markdownBlocks`
    /// parser per run, so the expensive table/list/paragraph parsing stays
    /// cached and only runs once per unique chunk; the cheap per-line image
    /// scan is the only work repeated on each re-render. Image extraction is
    /// chat-local on purpose — it does not extend the shared `MarkdownBlock`
    /// enum used elsewhere, so nothing outside this file is affected.
    static func chatProseEntries(_ body: String) -> [ChatProseEntry] {
        let lines = body.components(separatedBy: "\n")
        var entries: [ChatProseEntry] = []
        var pending: [String] = []

        func flush() {
            guard !pending.isEmpty else { return }
            let chunk = pending.joined(separator: "\n")
            pending.removeAll(keepingCapacity: true)
            guard !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            entries.append(.blocks(RenderCache.markdownBlocks(chunk)))
        }

        for line in lines {
            for piece in splitLineByImages(line) {
                switch piece {
                case .prose(let fragment):
                    pending.append(fragment)
                case .image(let alt, let source):
                    flush()
                    entries.append(.image(alt: alt, source: source))
                }
            }
        }
        flush()
        return entries
    }

    /// Scan a single line for markdown image syntax `![alt](source)` anywhere
    /// in the line and return it as alternating `.prose` / `.image` / `.prose`
    /// pieces, preserving surrounding text in order (STR-695). A line with no
    /// valid image returns a single `.prose(line)` element so callers can
    /// append it verbatim. Handles backslash-escaped `]` inside alt text.
    ///
    /// Malformed syntax (missing `)`, empty source, dangling `![`) is left in
    /// place as prose rather than being partially consumed, so a sentence like
    /// "see ![note" never loses text. Source extends to the next `)`; URLs in
    /// assistant prose do not contain raw parens.
    static func splitLineByImages(_ line: String) -> [ChatProseLineSplit] {
        let chars = Array(line)
        var pieces: [ChatProseLineSplit] = []
        var segmentStart = 0
        var i = 0

        while i < chars.count {
            // Anchor on "!" only when followed by "[".
            guard chars[i] == "!",
                  i + 1 < chars.count,
                  chars[i + 1] == "[" else {
                i += 1
                continue
            }
            let bang = i
            // Alt text: from i+2 to the first unescaped "]".
            var j = i + 2
            var altChars: [Character] = []
            while j < chars.count {
                let c = chars[j]
                if c == "\\", j + 1 < chars.count {
                    altChars.append(chars[j + 1])
                    j += 2
                    continue
                }
                if c == "]" { break }
                altChars.append(c)
                j += 1
            }
            guard j < chars.count, chars[j] == "]",
                  j + 1 < chars.count, chars[j + 1] == "(" else {
                // Not an image — advance past this "!" and keep scanning so a
                // later valid image on the same line still hoists.
                i += 1
                continue
            }
            let sourceStart = j + 2
            var k = sourceStart
            while k < chars.count, chars[k] != ")" { k += 1 }
            guard k < chars.count, chars[k] == ")" else {
                i += 1
                continue
            }
            let source = String(chars[sourceStart..<k])
                .trimmingCharacters(in: .whitespaces)
            guard !source.isEmpty else {
                i += 1
                continue
            }
            // Valid image: emit any preceding prose fragment, then the image.
            if bang > segmentStart {
                let prefix = String(chars[segmentStart..<bang])
                if !prefix.isEmpty {
                    pieces.append(.prose(prefix))
                }
            }
            pieces.append(.image(alt: String(altChars), source: source))
            segmentStart = k + 1
            i = k + 1
        }

        if segmentStart < chars.count {
            let tail = String(chars[segmentStart..<chars.count])
            if !tail.isEmpty {
                pieces.append(.prose(tail))
            }
        }
        if pieces.isEmpty {
            pieces.append(.prose(line))
        }
        return pieces
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

    enum MarkdownAlertKind: String, Equatable, Sendable {
        case note
        case tip
        case important
        case warning
        case caution

        var label: String {
            switch self {
            case .note: return "Note"
            case .tip: return "Tip"
            case .important: return "Important"
            case .warning: return "Warning"
            case .caution: return "Caution"
            }
        }

        var systemImage: String {
            switch self {
            case .note: return "info.circle.fill"
            case .tip: return "bolt.fill"
            case .important: return "exclamationmark.circle.fill"
            case .warning, .caution: return "exclamationmark.triangle.fill"
            }
        }

        var accentColor: Color {
            switch self {
            case .note: return .blue
            case .tip: return .green
            case .important: return .purple
            case .warning: return .orange
            case .caution: return .pink
            }
        }
    }

    struct MarkdownAlert: Equatable, Sendable {
        let kind: MarkdownAlertKind
        let body: String
    }

    enum MarkdownBlock: Equatable, Sendable {
        case paragraph(String)
        case table(MarkdownTable)
        case blockquote(String)
        case alert(MarkdownAlert)
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
                if let alert = markdownAlert(fromBlockquoteText: quote.text) {
                    blocks.append(.alert(alert))
                } else {
                    blocks.append(.blockquote(quote.text))
                }
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

    nonisolated static func accessibilityTextForMarkdown(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var output: [String] = []
        var index = 0

        while index < lines.count {
            if let quote = blockquoteRun(startingAt: index, lines: lines),
               let alert = markdownAlert(fromBlockquoteText: quote.text) {
                output.append("\(alert.kind.label): \(alert.body)")
                index = quote.nextIndex
            } else {
                output.append(lines[index])
                index += 1
            }
        }

        return output.joined(separator: "\n")
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

    private static func markdownAlert(fromBlockquoteText text: String) -> MarkdownAlert? {
        var remainder = text[...]
        while let first = remainder.first, first == " " || first == "\t" {
            remainder.removeFirst()
        }
        guard remainder.hasPrefix("[!") else { return nil }

        guard let close = remainder.firstIndex(of: "]") else { return nil }
        let markerStart = remainder.index(remainder.startIndex, offsetBy: 2)
        let marker = String(remainder[markerStart..<close]).lowercased()
        guard let kind = MarkdownAlertKind(rawValue: marker) else { return nil }

        remainder = remainder[remainder.index(after: close)...]
        while let first = remainder.first, first == " " || first == "\t" {
            remainder.removeFirst()
        }
        if remainder.first == "\r" {
            remainder.removeFirst()
        }
        if remainder.first == "\n" {
            remainder.removeFirst()
        }

        return MarkdownAlert(kind: kind, body: String(remainder))
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
    //
    // The breathing cursor glyph lives in the reusable `StreamingCursor`
    // component (bottom of this file) for the prose-tail call site; the merged
    // working line's leading glyph is `BreathingCursorGlyph` (WorkingSectionView).
    // Both share the ONE pure `CursorBreathe` curve so the visual restyles from a
    // single place (QA-3 S1: the pulse is now a stateless function of wall-clock
    // time — the former `cursorPulseOpacity` @State + `startCursorPulse()`
    // repeatForever pattern stranded the cursor static on row remounts).

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
    /// menu's existing gating); copy + share render whenever there is rendered
    /// prose to act on. On a text-less settled turn only the turn-level actions
    /// (Retry + overflow) render — the affordance the removed context menu
    /// always guaranteed.
    ///
    /// CC-02: copy button shows a checkmark confirmation (+ haptic) matching
    /// CodeBlockView's copy UX so every copy surface in the transcript is consistent.
    /// CC-07: top padding raised from 4 → 8 for better separation from prose.
    private var assistantActionRow: some View {
        // Approved design §5: always-visible, muted, icon-only action row under a
        // settled agent turn — Copy · Retry · Branch · Share · Speak, in that order.
        // NO delete, NO overflow menu (the former undo/overflow are gone). Copy /
        // Share / Speak act on the rendered prose (`message.text`, the concat of the
        // `.text` parts), so they appear only when there IS rendered text; Retry /
        // Branch are turn-level and render whenever their hook is supplied — so a
        // text-less settled turn still exposes them (the affordance the removed
        // whole-bubble context menu used to guarantee).
        HStack(spacing: 18) {
            if hasRenderedText {
                // CC-02: confirm copy with checkmark + color change (mirrors CodeBlockView).
                // Copy grabs the whole answer body MINUS thinking + tool content
                // (§5): `message.text` is the concat of the `.text` parts only, so
                // reasoning and tool output are already excluded by construction.
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
            }
            if let onRetry {
                actionIcon("arrow.clockwise", label: "Retry") {
                    onRetry(message)
                }
            }
            if let onBranch {
                actionIcon("arrow.triangle.branch", label: "Branch") {
                    onBranch(message)
                }
            }
            if hasRenderedText {
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
            }
            Spacer(minLength: 0)
        }
        // CC-07: 8pt top gap gives the action row clear breathing room from prose.
        .padding(.top, 8)
        .accessibilityIdentifier("assistantActionRow")
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

    /// Render markdown inline, preserving whitespace, falling back to plain
    /// text; then (Wave 25 link fixes) autolink any bare `http(s)://` URL the
    /// markdown parse left as dead text, and give every link run — markdown
    /// `[label](url)` links and newly-autolinked bare URLs alike — the
    /// explicit transcript link style (`linkColor` + underline) instead of
    /// inheriting only the ambient tint.
    static func attributed(_ text: String, linkColor: Color = .accentColor) -> AttributedString {
        var result = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
        result = Self.autolinkBareURLs(in: result)
        Self.styleLinks(in: &result, color: linkColor)
        return result
    }

    /// Pure post-processor: detects bare `http://`/`https://` URLs in `attributed`
    /// that markdown's inline parse did not linkify (a pasted URL with no
    /// `[label](url)` wrapper renders as dead text otherwise) and sets `.link`
    /// on the matched run.
    ///
    /// Deliberately conservative:
    ///  - A run that already carries `.link` (a real markdown link, or one this
    ///    pass already set) is left untouched.
    ///  - A run inside inline code styling (`` `like this` ``,
    ///    `InlinePresentationIntent.code`) is left untouched — a URL shown as
    ///    code is meant to be read verbatim, not tapped.
    ///  - Only the exact `http://`/`https://` token text becomes the link
    ///    (NSDataDetector's own trailing-punctuation trimming), so a sentence
    ///    like "see https://example.com." does not swallow the period.
    ///
    /// This never runs on provider-embed URLs (YouTube/Spotify/etc.) — those
    /// are already lifted out of prose into `.embed` segments by
    /// `MessageSegmenter` before any text reaches here — and never touches the
    /// destination of a markdown inline link, because that destination is an
    /// attribute value, not rendered text, so it is never present in
    /// `attributed`'s character content for this pass to see.
    static func autolinkBareURLs(in attributed: AttributedString) -> AttributedString {
        var result = attributed
        let plain = String(attributed.characters)
        guard !plain.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return result }

        let nsRange = NSRange(plain.startIndex..<plain.endIndex, in: plain)
        let matches = detector.matches(in: plain, options: [], range: nsRange)
        for match in matches {
            guard let stringRange = Range(match.range, in: plain) else { continue }
            let token = plain[stringRange]
            let lowered = token.lowercased()
            guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") else { continue }
            guard let url = URL(string: String(token)) else { continue }
            guard let attrRange = Range(stringRange, in: result) else { continue }
            guard !hasProtectedLinkAttributes(result[attrRange]) else { continue }
            result[attrRange].link = url
        }
        return result
    }

    /// True when any run in `substring` already carries a `.link` or code
    /// (`InlinePresentationIntent.code`) attribute — either disqualifies the
    /// range from bare-URL autolinking.
    private static func hasProtectedLinkAttributes(_ substring: AttributedSubstring) -> Bool {
        for run in substring.runs {
            if run.link != nil { return true }
            if run.inlinePresentationIntent?.contains(.code) == true { return true }
        }
        return false
    }

    /// Apply the explicit transcript link style — `linkColor` tint + a single
    /// underline — to every run that carries a `.link` attribute, so links
    /// read as links rather than inheriting only the ambient global tint.
    private static func styleLinks(in attributed: inout AttributedString, color: Color) {
        for run in attributed.runs where run.link != nil {
            attributed[run.range].foregroundColor = color
            attributed[run.range].underlineStyle = .single
        }
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
    static func prose(_ text: String, linkColor: Color = .accentColor) -> AttributedString {
        let lines = text.components(separatedBy: "\n")
        guard lines.contains(where: { listMarker($0) != nil }) else {
            return attributed(text, linkColor: linkColor)
        }

        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            var lineAttr = attributed(line, linkColor: linkColor)
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

/// Internal (was file-private; QA-3 S3 lifted the single-affordance decision
/// into `WorkingSectionModel.preItemWorkingLineVisible`, which keys off the
/// same "has answer text started" question the tail-caret rule asks).
extension Array where Element == ChatMessagePart {
    var lastTextPartID: String? {
        for part in reversed() {
            if case .text(let id, _) = part { return id }
        }
        return nil
    }
}

/// Internal so the file viewer's rendered-markdown mode (STR-699) can reuse the
/// exact chat block presentation instead of a second renderer.
struct MarkdownTableBlockView: View {
    @Environment(\.hermesTheme) private var theme

    let table: MessageBubble.MarkdownTable

    private static let minCellWidth: CGFloat = 116
    private static let maxCellWidth: CGFloat = 240
    private static let horizontalCellPadding: CGFloat = 12

    var body: some View {
        let columnWidths = Self.resolvedColumnWidths(for: table)
        let tableWidth = columnWidths.reduce(0, +)

        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                tableRow(table.headers, columnWidths: columnWidths, isHeader: true, rowIndex: 0)
                if table.rows.isEmpty {
                    emptyRow
                        .frame(width: tableWidth, alignment: .leading)
                } else {
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, cells in
                        tableRow(cells, columnWidths: columnWidths, isHeader: false, rowIndex: rowIndex)
                    }
                }
            }
            .frame(width: tableWidth, alignment: .leading)
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

    private func tableRow(
        _ cells: [String],
        columnWidths: [CGFloat],
        isHeader: Bool,
        rowIndex: Int
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { columnIndex, cell in
                cellView(
                    text: cell,
                    columnIndex: columnIndex,
                    columnWidth: columnWidths[columnIndex],
                    isHeader: isHeader,
                    rowIndex: rowIndex
                )
            }
        }
        .fixedSize(horizontal: false, vertical: true)
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
        columnWidth: CGFloat,
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

        return Text(RenderCache.prose(displayedText, linkColor: theme.midground))
            .font(.system(isHeader ? .subheadline : .body, design: .serif).weight(isHeader ? .semibold : .regular))
            .foregroundStyle(isHeader ? theme.fg : (text.isEmpty ? theme.mutedFg : theme.fg))
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(textAlignment(for: alignment))
            .padding(.horizontal, Self.horizontalCellPadding)
            .padding(.vertical, isHeader ? 9 : 10)
            .frame(width: columnWidth, alignment: frameAlignment(for: alignment))
            .frame(maxHeight: .infinity, alignment: .top)
            .background(background)
            .overlay(Rectangle().stroke(theme.border.opacity(0.72), lineWidth: 0.5))
            // Selection island (N5): table cards are deliberately NON-selectable.
            // The whole-bubble "Copy message" action + per-card copy buttons cover
            // copy; making cells text-selectable would surface the old
            // `.textSelection` Copy|Share pill on a long-press and let a drag
            // escape the card boundary, breaking the prose-only selection island
            // (approved design §7 — code/table/image cards bound selection).
    }

    /// Resolve one concrete width per column before SwiftUI lays out the grid.
    /// A fixed frame then proposes that finite width through the cell padding to
    /// `Text`, so long content must compute a multi-line height instead of being
    /// measured as a single ideal-width line and clipped at the frame edge.
    private static func resolvedColumnWidths(for table: MessageBubble.MarkdownTable) -> [CGFloat] {
        table.headers.indices.map { columnIndex in
            let headerWidth = idealCellWidth(table.headers[columnIndex], isHeader: true)
            let bodyWidth = table.rows.reduce(CGFloat.zero) { widest, row in
                guard row.indices.contains(columnIndex) else { return widest }
                return max(widest, idealCellWidth(row[columnIndex], isHeader: false))
            }
            return min(max(ceil(max(headerWidth, bodyWidth)), minCellWidth), maxCellWidth)
        }
    }

    /// Cheap single-line measurement used only to choose the column clamp. The
    /// rendered SwiftUI `Text` still owns line breaking and final row height.
    private static func idealCellWidth(_ text: String, isHeader: Bool) -> CGFloat {
        let displayedText = text.isEmpty ? "—" : text
        let textStyle: UIFont.TextStyle = isHeader ? .subheadline : .body
        let weight: UIFont.Weight = isHeader ? .semibold : .regular
        let systemFont = UIFont.systemFont(
            ofSize: UIFont.preferredFont(forTextStyle: textStyle).pointSize,
            weight: weight
        )
        let descriptor = systemFont.fontDescriptor.withDesign(.serif) ?? systemFont.fontDescriptor
        let font = UIFont(descriptor: descriptor, size: systemFont.pointSize)
        let bounds = NSAttributedString(
            string: displayedText,
            attributes: [.font: font]
        ).boundingRect(
            with: CGSize(width: 100_000, height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return bounds.width + (horizontalCellPadding * 2)
    }

    private func frameAlignment(for alignment: MessageBubble.MarkdownTable.Alignment) -> Alignment {
        switch alignment {
        case .leading: return .topLeading
        case .center: return .top
        case .trailing: return .topTrailing
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

#Preview("Markdown table cell wrapping") {
    ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            MarkdownTableBlockView(
                table: .init(
                    headers: ["300-character cell", "Status"],
                    alignments: [.leading, .center],
                    rows: [[String(repeating: "This complete sentence must wrap inside its table cell. ", count: 6), "Readable"]]
                )
            )
            MarkdownTableBlockView(
                table: .init(
                    headers: ["80-character token", "Result"],
                    alignments: [.leading, .trailing],
                    rows: [[String(repeating: "abcdefghij", count: 8), "1"]]
                )
            )
            MarkdownTableBlockView(
                table: .init(
                    headers: ["One", "Two", "Three", "Four", "Five", "Six"],
                    alignments: Array(repeating: .leading, count: 6),
                    rows: [["Wide", "tables", "remain", "horizontally", "scrollable", "here"]]
                )
            )
            MarkdownTableBlockView(
                table: .init(
                    headers: ["Key", "Value"],
                    alignments: [.leading, .trailing],
                    rows: [["Narrow table", "42"]]
                )
            )
        }
        .padding()
    }
}

struct MarkdownBlockquoteView: View {
    @Environment(\.hermesTheme) private var theme

    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .circular)
                .fill(theme.midground.opacity(0.72))
                .frame(width: 3)
            SelectableProseText(
                attributed: RenderCache.prose(text, linkColor: theme.midground),
                color: theme.mutedFg,
                uiColor: UIColor(theme.mutedFg),
                lineSpacing: 3.5
            )
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(theme.muted.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .circular))
        .accessibilityLabel("Quote: \(text)")
    }
}

struct MarkdownAlertView: View {
    @Environment(\.hermesTheme) private var theme

    let alert: MessageBubble.MarkdownAlert

    var body: some View {
        let accent = alert.kind.accentColor

        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(alert.kind.label)
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
            } icon: {
                Image(systemName: alert.kind.systemImage)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(accent)
            .accessibilityHidden(true)

            if !alert.body.isEmpty {
                SelectableProseText(
                    attributed: RenderCache.prose(alert.body, linkColor: theme.midground),
                    color: theme.fg,
                    uiColor: UIColor(theme.fg),
                    lineSpacing: 3.5
                )
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(accent.opacity(0.35), lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(accent)
                .frame(width: 4)
                .padding(.vertical, 8)
        }
        .accessibilityLabel("\(alert.kind.label): \(alert.body)")
    }
}

struct MarkdownTaskListView: View {
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
                    SelectableProseText(
                        attributed: RenderCache.prose(item.text, linkColor: theme.midground),
                        color: theme.fg,
                        uiColor: UIColor(theme.fg),
                        strikethrough: item.checked
                    )
                }
                .padding(.leading, CGFloat(item.level) * 18)
                .accessibilityLabel("\(item.checked ? "Completed" : "Incomplete") task: \(item.text)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MarkdownListBlockView: View {
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
                    SelectableProseText(
                        attributed: RenderCache.prose(item.text, linkColor: theme.midground),
                        color: theme.fg,
                        uiColor: UIColor(theme.fg),
                        lineSpacing: 3.5
                    )
                }
                .padding(.leading, CGFloat(item.level) * 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Block-level assistant-prose markdown image (STR-695). Renders a tappable
/// thumbnail — remote `https://` via `AsyncImage` (with a real retry
/// affordance on failure), `data:` inline via the shared
/// `AttachmentBlobCache.decodeDataURL` — that opens the shipped
/// `ZoomableImageView` lightbox on tap (pinch/zoom/pan/retry chrome already
/// exists there). Sizing is size-class + measured-geometry aware, never
/// `UIScreen.main`, so it stays correct in iPad split-view and multi-scene.
struct MarkdownImageBlockView: View {
    let alt: String
    let source: String

    @Environment(\.hermesTheme) private var theme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var presentZoom = false
    @State private var availableWidth: CGFloat = 0
    /// STR-695: refresh token for the remote `AsyncImage`. Bumped by the
    /// failure affordance's "Tap to retry" button so SwiftUI tears down and
    /// recreates the AsyncImage (re-fetching the URL) instead of pinning the
    /// failed phase. The contract requires placeholder/failure/retry; without
    /// this the failed thumbnail is a dead end.
    @State private var retryToken: UUID = UUID()

    private var remoteURL: URL? {
        guard source.hasPrefix("http://") || source.hasPrefix("https://") else { return nil }
        return URL(string: source)
    }
    private var isDataURL: Bool { source.hasPrefix("data:") }
    private var isCompact: Bool { horizontalSizeClass == .compact }

    /// Inline image max width (STR-695). Compact: a thumbnail that fits the
    /// bubble column — at most ~82% of the measured width and never wider than
    /// 300pt. Regular (iPad full-width): a larger inline preview capped at
    /// 440pt so multi-line alt/caption stays readable and the image never
    /// stretches across a wide column. Sizing is driven entirely by the view's
    /// own geometry + size class — never `UIScreen.main` (which reports the
    /// wrong scene in iPad split-view / multi-scene).
    private var inlineMaxWidth: CGFloat {
        guard availableWidth > 0 else { return isCompact ? 260 : 400 }
        if isCompact {
            return min(availableWidth * 0.82, 300)
        }
        return min(availableWidth * 0.66, 440)
    }

    /// Inline image max height. Compact: 340pt (thumbnail). Regular: 460pt.
    private var inlineMaxHeight: CGFloat {
        isCompact ? 340 : 460
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            thumbnail
            if !alt.isEmpty {
                Text(alt)
                    .font(.caption)
                    .foregroundStyle(theme.mutedFg)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            if abs(width - availableWidth) > 0.5 {
                availableWidth = width
            }
        }
        .fullScreenCover(isPresented: $presentZoom) {
            ZoomableImageView(
                title: alt.isEmpty ? "Image" : alt,
                remoteURL: remoteURL,
                dataURL: isDataURL ? source : nil
            )
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if isDataURL {
            if let image = ZoomableImageView.decodeDataURL(source) {
                zoomButton { thumbnailFrame(Image(uiImage: image)) }
            } else {
                placeholder("Couldn't decode this image.")
            }
        } else if let remoteURL {
            // `.id(retryToken)` is the retry contract: bumping the token
            // recreates the AsyncImage and re-fetches. The failure branch
            // renders its own Button (NOT nested in the zoom Button) so the
            // "Tap to retry" affordance is the only action available.
            AsyncImage(url: remoteURL, transaction: Transaction(animation: .snappy(duration: 0.2))) { phase in
                switch phase {
                case .empty:
                    loading
                case .success(let image):
                    zoomButton { thumbnailFrame(image) }
                case .failure:
                    retryAffordance
                @unknown default:
                    retryAffordance
                }
            }
            .id(retryToken)
        } else {
            placeholder("Unsupported image source.")
        }
    }

    /// Zoom-on-tap affordance for a loaded image. Wrapped in its own ViewBuilder
    /// so the success path keeps the `"markdownImage"` a11y identity and the
    /// failure path can render a separate retry Button without nesting.
    @ViewBuilder
    private func zoomButton<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Button {
            presentZoom = true
        } label: {
            content()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(alt.isEmpty ? "Image" : alt)
        .accessibilityHint("Double-tap to zoom")
        .accessibilityIdentifier("markdownImage")
    }

    /// STR-695 retry affordance for remote fetch failures. Distinct from the
    /// decode-failure placeholder (which is deterministic and has no retry):
    /// remote failures are often transient (network / auth / 5xx), so the
    /// contract requires a tappable retry that re-runs the AsyncImage load.
    private var retryAffordance: some View {
        Button {
            retryToken = UUID()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "arrow.clockwise.circle")
                    .font(.title3)
                Text("Couldn't load this image.")
                    .font(.caption)
                Text("Tap to retry")
                    .font(.caption2)
                    .foregroundStyle(theme.accent)
            }
            .foregroundStyle(theme.mutedFg)
            .frame(maxWidth: inlineMaxWidth, minHeight: 120)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.bg.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Couldn't load this image. Double-tap to retry.")
        .accessibilityHint("Reloads the image from the network.")
        .accessibilityIdentifier("markdownImageRetry")
    }

    private func thumbnailFrame(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFit()
            .frame(maxWidth: inlineMaxWidth, maxHeight: inlineMaxHeight, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(theme.mutedFg.opacity(0.18), lineWidth: 1)
            )
    }

    private var loading: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(theme.bg.opacity(0.5))
            .frame(maxWidth: inlineMaxWidth, minHeight: 160)
            .overlay {
                VStack(spacing: 6) {
                    ProgressView()
                    Text("Loading image…")
                        .font(.caption2)
                        .foregroundStyle(theme.mutedFg)
                }
            }
    }

    private func placeholder(_ message: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.title3)
            Text(message)
                .font(.caption)
        }
        .foregroundStyle(theme.mutedFg)
        .frame(maxWidth: inlineMaxWidth, minHeight: 120)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.bg.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        .accessibilityIdentifier("sentImageThumbnail")
        .task(id: attachment.name) { await load() }
    }

    private var thumbnailSize: CGSize {
        // STR-695: fixed cap, no `UIScreen.main` read — the sent-image echo
        // already lives inside a user bubble whose width is bounded by
        // `maxBubbleWidth`, so a hard 220pt cap is correct in every size class
        // and split-view configuration without referencing the screen.
        let width: CGFloat = 220
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

        phase = .loading
        do {
            let data = try await rest.attachmentData(name: attachment.name)
            guard let image = UIImage(data: data) else {
                phase = .failed("Attachment is not a decodable image")
                return
            }
            phase = .loaded(image)
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // Persisted transcript hints contain only the opaque upload name, not its
    // content version. Safely bypass the disk blob cache for this legacy shape;
    // a size/zero fallback could serve stale bytes after replacement.
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
    /// `onUndoLastTurn` is latest-assistant-only, so its availability travels as
    /// `showsUndoLastTurnAction`; the other action closures are intentionally
    /// excluded (not `Sendable`; their nil-ness is stable per call site).
    ///
    /// A11y note: `bubbleAccessibilityLabel` is derived from `message.role` and
    /// `message.text`, both of which are already compared via `message ==` above —
    /// so the combined element's label is implicitly covered by the existing `==`.
    /// No changes to the short-circuit logic are needed.
    nonisolated static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        lhs.message == rhs.message
            && lhs.menuActionsEnabled == rhs.menuActionsEnabled
            && lhs.assistantTurnActionsEnabled == rhs.assistantTurnActionsEnabled
            && lhs.showsUndoLastTurnAction == rhs.showsUndoLastTurnAction
            && lhs.liveTurnStartedAt == rhs.liveTurnStartedAt
            && lhs.liveTurnActive == rhs.liveTurnActive
            && lhs.appearance == rhs.appearance
            // Delivery state drives the send-failed badge (C1); a transition
            // (in-transit → failed → delivered) must re-render past the A1
            // short-circuit.
            && lhs.delivery == rhs.delivery
            // Wave 25: a dock task-box show/hide flips whether this bubble's
            // inline todo card(s) are suppressed; it must re-render past A1.
            && lhs.suppressTodoCards == rhs.suppressTodoCards
    }
}

// MARK: - Streaming cursor (reusable themed component)

/// The single breathing cursor glyph for the streaming tail — the ChatGPT-style
/// "I'm working" signal in the transcript (approved design §8). Extracted from
/// `MessageBubble` (round-2 ROOT D: lifted off the prose `Text` so the pulse never
/// re-composites the prose block) into ONE reusable component for the
/// tail-of-prose call site (the merged working line's leading glyph is
/// `BreathingCursorGlyph`, sharing the same `CursorBreathe` curve — QA-3 S3), so
/// the caret can be restyled in a single place. Reads the theme from the
/// environment (`\.hermesTheme`) and takes `isStreaming` as its only parameter.
///
/// QA-3 S1: the pulse is now STATELESS — a `TimelineView` drives the opacity off
/// the wall clock through the pure `CursorBreathe` curve (visual behavior
/// unchanged: ▌ U+258C in `theme.midground`, 1.0 → 0.25 soft breathe, 1.2 s
/// period = the ratified easeInOut-0.6-autoreverses shape). The prior
/// `@State` + `onAppear` + `withAnimation(.repeatForever)` pattern stranded the
/// cursor STATIC whenever the row remounted mid-stream (the streaming bubble is
/// re-derived on every `applyRelayItems` pass; a view-identity change or an
/// animation-nil transaction resets `@State` without re-firing `onAppear`) —
/// the motionless bare bar the owner photographed (IMG_2577/2585/2587). A
/// time-driven pulse has no state to strand: any remount keeps breathing at the
/// correct phase. Settled reads a steady full-opacity glyph.
struct StreamingCursor: View {
    /// Whether the owning turn is still streaming. Drives the pulse animation; a
    /// settled cursor reads steady full opacity.
    let isStreaming: Bool
    /// Tail-of-prose carets render with a leading space (the glyph sits right
    /// after the last word); line-leading uses (the merged working line) pass
    /// `false` so the glyph leads the row flush.
    var leadingSpace: Bool = true

    @Environment(\.hermesTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// QA-3 integration: the breathe curve lives in ONE place (`CursorBreathe`,
    /// WorkingSectionView.swift) — these members forward to it so the
    /// renderjury-lane unit pins (`WorkingSectionModelTests`) and the
    /// working-lane curve pins (`RenderConformanceTests.testCursorBreathe_*`)
    /// test the SAME single function.
    nonisolated static let breathePeriodSeconds: Double = CursorBreathe.period
    nonisolated static let minOpacity: Double = CursorBreathe.minOpacity
    nonisolated static func breatheOpacity(
        at date: Date,
        streaming: Bool,
        reduceMotion: Bool
    ) -> Double {
        CursorBreathe.opacity(at: date, streaming: streaming, reduceMotion: reduceMotion)
    }

    var body: some View {
        // One clock for the glyph: 20 fps is imperceptibly smooth for a soft
        // opacity breathe and re-composites only this tiny Text — the pulse
        // never touches the (large) prose block (round-2 ROOT D preserved).
        TimelineView(.animation(minimumInterval: 1.0 / 20.0,
                                paused: !isStreaming || reduceMotion)) { context in
            Text(leadingSpace ? " ▌" : "▌")
                .foregroundColor(theme.midground)
                .opacity(CursorBreathe.opacity(at: context.date,
                                               streaming: isStreaming,
                                               reduceMotion: reduceMotion))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Native text-selection surface (user-bubble "Select Text")

/// A `UITextView`-backed selectable text surface for the user bubble's "Select
/// Text" flow (approved design §6).
///
/// SwiftUI `Text` cannot be told to *begin* native selection programmatically, and
/// a whole-bubble `.contextMenu` long-press steals the press-hold gesture from
/// `.textSelection(.enabled)` prose. The user bubble needs a context menu (Edit /
/// Branch / Restore / Delete), so it resolves the conflict by making selection an
/// explicit, deliberate action: long-press → context menu → "Select Text" → this
/// view mounts, becomes first responder and selects all, so the native drag
/// handles + system edit menu appear immediately and the user narrows from there.
///
/// (Agent turns need none of this: they carry no context menu, so their prose is
/// natively selectable via `.textSelection` and long-press starts selection
/// directly — approved design §7.)
struct SelectableTextView: UIViewRepresentable {
    /// The plain string to make selectable.
    let text: String
    /// Face + size — system body for the user bubble — so the selectable text
    /// visually matches what it replaces.
    let font: UIFont
    /// Foreground color (converted from the SwiftUI theme token by the caller).
    let textColor: UIColor

    func makeUIView(context: Context) -> UITextView {
        let view = SelfSizingTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.dataDetectorTypes = []
        view.font = font
        view.textColor = textColor
        view.text = text
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text { uiView.text = text }
        uiView.font = font
        uiView.textColor = textColor
        // Enter selection exactly once per mount: select the whole body and show
        // the handles + edit menu, then let the user narrow it by dragging.
        guard !context.coordinator.didBeginSelection else { return }
        context.coordinator.didBeginSelection = true
        DispatchQueue.main.async {
            guard uiView.window != nil else { return }
            uiView.becomeFirstResponder()
            uiView.selectAll(nil)
        }
    }

    /// Self-size to the proposed width so the view lays out inline exactly like the
    /// `Text` it replaces (multi-line height computed for the column width). Never
    /// reads `UIScreen.main` (STR-695) — the fallback is a finite default.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fit.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        /// Guards the one-shot select-all so a re-render (theme / Dynamic Type) does
        /// not yank the selection back to "all" after the user narrowed it.
        var didBeginSelection = false
    }

    /// Builds a UIFont for the given text style, optionally in the serif design.
    static func font(textStyle: UIFont.TextStyle, serif: Bool) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: textStyle)
        guard serif, let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }
}

/// A `UITextView` that reports its content size so SwiftUI's `sizeThatFits` path
/// lays it out at the correct height with scrolling disabled.
final class SelfSizingTextView: UITextView {
    override var intrinsicContentSize: CGSize {
        let width = bounds.width > 0 ? bounds.width : UIView.layoutFittingCompressedSize.width
        let fit = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: UIView.noIntrinsicMetric, height: ceil(fit.height))
    }
}

// MARK: - Prose-run selection island (file viewer + standalone block views)

/// One contiguous prose run (a paragraph / list-item / blockquote / alert body)
/// that supports GENUINE native text selection, used by the standalone GFM
/// block views (`MarkdownBlockquoteView` / `MarkdownAlertView` /
/// `MarkdownTaskListView` / `MarkdownListBlockView`) that `FileMarkdownBodyView`
/// renders in the file viewer.
///
/// NOTE (QA-1 B11 / A6): assistant CHAT prose no longer uses this per-run
/// island — the islands bounded selection to a single paragraph (owner QA
/// IMG_2519: whole-paragraph select-all + "Done" button + no cross-paragraph
/// extension). Chat prose now folds into one ``ProseSelectionContainer`` per
/// contiguous run, giving word-level long-press selection across paragraphs.
/// This island stays for the standalone block views, where bounding selection
/// to the block is acceptable.
///
/// Long-press swaps the run for a first-responding ``SelectableTextView``
/// (a `UITextView`, `isSelectable`, `becomeFirstResponder`, `selectAll`) so the
/// real handles + system edit menu appear immediately; the reader narrows from
/// there. A trailing "Done" exits. The min-duration `LongPressGesture` is
/// attached with `.gesture` (default priority), so a drag still belongs to the
/// enclosing `ScrollView` — the press only fires on a stationary hold and never
/// blocks scrolling.
struct SelectableProseText: View {
    /// The styled markdown render shown in normal (non-selecting) mode.
    let attributed: AttributedString
    /// SwiftUI face for the normal render.
    var font: Font = .system(.body, design: .serif)
    /// UIKit text style + design used to build the selection `UITextView`'s font,
    /// so the selectable text matches the prose it replaces.
    var uiTextStyle: UIFont.TextStyle = .body
    var serif: Bool = true
    /// Default foreground for the normal render (link runs keep their own color).
    var color: Color
    /// Foreground for the selection `UITextView` (plain text has no link runs).
    var uiColor: UIColor
    var lineSpacing: CGFloat = 0
    var strikethrough: Bool = false

    @Environment(\.hermesTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selecting = false

    /// The plain, visible text handed to the selection surface — derived from the
    /// attributed characters so markdown syntax (`**`, `_`, link brackets) is
    /// already stripped and the reader selects clean prose, not raw source.
    private var plain: String { String(attributed.characters) }

    var body: some View {
        Group {
            if selecting {
                VStack(alignment: .leading, spacing: 6) {
                    SelectableTextView(
                        text: plain,
                        font: SelectableTextView.font(textStyle: uiTextStyle, serif: serif),
                        textColor: uiColor
                    )
                    Button {
                        exit()
                    } label: {
                        Text("Done")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(theme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Done selecting text")
                }
            } else {
                Text(attributed)
                    .font(font)
                    .foregroundStyle(color)
                    .strikethrough(strikethrough, color: theme.mutedFg)
                    .lineSpacing(lineSpacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .gesture(
                        LongPressGesture(minimumDuration: 0.4).onEnded { _ in enter() }
                    )
            }
        }
    }

    private func enter() {
        if reduceMotion {
            selecting = true
        } else {
            withAnimation(.easeOut(duration: 0.15)) { selecting = true }
        }
    }

    private func exit() {
        if reduceMotion {
            selecting = false
        } else {
            withAnimation(.easeOut(duration: 0.15)) { selecting = false }
        }
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
