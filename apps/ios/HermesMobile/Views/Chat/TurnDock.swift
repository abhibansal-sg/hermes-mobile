import SwiftUI

/// Which single interactive surface the Turn Dock shows right now.
///
/// The dock is the one home for the transcript's interactive elements, docked
/// directly above the frozen composer (approved mockup: `transcript-full.html`).
/// It shows exactly ONE surface at a time, by priority:
///
///   approval  >  clarify  >  tasks  >  queued
///
/// Resolution is a pure function so ``ChatView`` can reuse it to decide whether
/// the inline transcript ``TodoCardView`` must be suppressed (only while the
/// dock is actually showing the task box for that same list — never otherwise).
enum TurnDockContent: Equatable {
    case approval
    case clarify
    case tasks
    case queued
    case none

    static func resolve(
        hasApproval: Bool,
        hasClarification: Bool,
        hasTasks: Bool,
        hasQueued: Bool
    ) -> TurnDockContent {
        if hasApproval { return .approval }
        if hasClarification { return .clarify }
        if hasTasks { return .tasks }
        if hasQueued { return .queued }
        return .none
    }
}

// MARK: - Turn dock container

/// The container mounted in ``ChatView``'s bottom stack, attached directly above
/// the composer. Hosts the one active dock surface and animates transitions with
/// the standard spring (honoring Reduce Motion). The approval and clarify cards
/// are the exact same views used elsewhere — moved here so the dock is their
/// single home.
struct TurnDock: View {
    let chatStore: ChatStore
    let queueStore: QueueStore
    /// Applied at the queued-messages sheet root so the sheet inherits the theme
    /// (SwiftUI sheets do not inherit `\.hermesTheme` from the presenter).
    let themeStore: ThemeStore

    @Environment(\.hermesTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showQueuedSheet = false

    /// The dock's active surface, derived from the same pure resolver ChatView
    /// uses for inline-card suppression — so the two can never disagree.
    ///
    /// QA-2 R12/R13: `hasTasks` reads ``ChatStore.dockShowsTaskBox`` (turn-
    /// lifecycle-driven + session-scoped), NOT the raw `latestTodoList`. So the
    /// dock surface tracks the owning turn: visible only while that turn is
    /// live, cleared at turn end (even with missed frames, via the local-turn
    /// watchdog), never resurrected in a session that doesn't own the list.
    private var content: TurnDockContent {
        TurnDockContent.resolve(
            hasApproval: chatStore.pendingApproval != nil,
            hasClarification: chatStore.pendingClarification != nil,
            hasTasks: chatStore.dockShowsTaskBox,
            hasQueued: TurnDock.hasQueued(queueStore)
        )
    }

    /// Whether the calm "Queued — sends when reconnected" strip is warranted:
    /// session-scoped queued sends exist AND the (frozen) composer is not already
    /// surfacing its own backlog chip. When the composer's chip is up
    /// (stuck/failed/offline backlog) it owns that surface, so the dock strip
    /// stays hidden and the two never double-render.
    static func hasQueued(_ queueStore: QueueStore) -> Bool {
        !queueStore.activeItems.isEmpty && !queueStore.hasBacklog
    }

    var body: some View {
        Group {
            switch content {
            case .approval:
                if let approval = chatStore.pendingApproval {
                    ApprovalCard(approval: approval, chatStore: chatStore)
                        .transition(dockTransition)
                }
            case .clarify:
                if let clarification = chatStore.pendingClarification {
                    ClarifyBanner(clarification: clarification, chatStore: chatStore)
                        .transition(dockTransition)
                }
            case .tasks:
                // QA-2 R12 redesign: a NATIVE CAPSULE pill, width-to-fit and
                // CENTERED — never the old full-width floating box. When both
                // a task list AND queued backlog are live, the task capsule and
                // the queued capsule sit SIDE-BY-SIDE in one centered row (the
                // owner's "task centered next to pending" requirement). Each
                // capsule matches the composer's pending-pill height/visual
                // language (C1/C2). Tapping the task capsule toggles the
                // native checklist sheet below; tapping the queued capsule
                // opens the queued-messages sheet.
                if let todos = chatStore.latestTodoList {
                    DockTaskBox(
                        todos: todos,
                        showsQueued: TurnDock.hasQueued(queueStore),
                        queuedCount: queueStore.pendingCount,
                        onTapQueued: { showQueuedSheet = true }
                    )
                    .transition(dockTransition)
                }
            case .queued:
                DockQueuedStrip(count: queueStore.pendingCount) {
                    showQueuedSheet = true
                }
                .transition(dockTransition)
            case .none:
                EmptyView()
            }
        }
        .animation(dockAnimation, value: content)
        .sheet(isPresented: $showQueuedSheet) {
            QueuedMessagesSheet(queueStore: queueStore)
                .hermesThemed(themeStore)
        }
    }

    private var dockTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .move(edge: .bottom).combined(with: .opacity)
    }

    /// The standard spring used across the chat chrome; nil under Reduce Motion so
    /// surfaces swap instantly.
    private var dockAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85)
    }
}

// MARK: - Task box

/// QA-2 R12 — the dock's task surface, rebuilt to the owner's redesign:
///
///  • Collapsed = a NATIVE CAPSULE pill (checklist glyph + "X of Y"), width-to-
///    fit and CENTERED above the composer. It matches the composer's pending
///    pill height/visual language (same `Capsule`, same padding, same caption
///    font) so the two read as one chrome family — never the old full-width
///    floating box that "hovered" over the transcript (C1/C2).
///  • When a queued backlog is ALSO live, the queued capsule sits BESIDE the
///    task capsule in the same centered row ("task centered next to pending").
///  • NO progress bar, NO coloured rule. The "X of Y" count carries progress.
///  • Expanded = a compact NATIVE checklist (system material, hairline border,
///    per-row status glyphs) that drops down below the centered capsule row.
///
/// The expanded rows reuse ``TodoChecklistRow`` — the exact status-glyph styling
/// the transcript's ``TodoCardView`` uses — so the dock and the transcript
/// render a todo item identically (pending/in_progress/done/cancelled affordances,
/// not the radio single-select the old sheet used).
struct DockTaskBox: View {
    let todos: TodoList
    /// Whether the queued backlog pill should sit beside the task capsule.
    let showsQueued: Bool
    /// The pending-count the queued capsule shows (when `showsQueued`).
    let queuedCount: Int
    /// Tap handler for the queued capsule (opens the queued-messages sheet).
    let onTapQueued: () -> Void

    @Environment(\.hermesTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isExpanded = false

    private var doneCount: Int {
        todos.items.filter { $0.status == .completed }.count
    }
    private var total: Int { todos.items.count }
    /// The task the agent is actively working, if any — shown in the collapsed
    /// capsule. Falls back to the first not-yet-done item so the pill always
    /// names *something* actionable; nil only when every item is terminal (the
    /// dock surface is already dismissed by then via `dockShowsTaskBox`).
    private var currentTitle: String? {
        todos.items.first { $0.status == .inProgress }?.content
            ?? todos.items.first { $0.status == .pending || $0.status == .other }?.content
    }

    var body: some View {
        VStack(spacing: 0) {
            // CENTERED capsule row. `Spacer(minLength: 0)` on both sides centers
            // the width-to-fit capsule group without forcing full-width — the
            // pill never stretches wider than its content (C2: never wider than
            // the composer). When the queued capsule is also warranted it sits
            // in the SAME centered HStack, side-by-side with the task capsule.
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                taskCapsule
                if showsQueued {
                    DockQueuedCapsule(count: queuedCount, onTap: onTapQueued)
                }
                Spacer(minLength: 0)
            }
            if isExpanded {
                expandedList
                    .padding(.top, 8)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var taskCapsule: some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.midground)
                Text("\(doneCount) of \(total)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(theme.fg)
                    .monospacedDigit()
                if let currentTitle {
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(theme.mutedFg)
                    Text(currentTitle)
                        .font(.caption)
                        .foregroundStyle(theme.mutedFg)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(theme.mutedFg)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            // Same padding language as the composer's pending pill so the two
            // share one height / visual rhythm.
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(theme.muted, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.border.opacity(0.6), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Tasks, \(doneCount) of \(total) done")
        .accessibilityValue(currentTitle.map { "Current: \($0)" } ?? "")
        .accessibilityHint(isExpanded ? "Collapse task list" : "Expand task list")
        .accessibilityAddTraits(.isButton)
    }

    /// The expanded checklist — a compact NATIVE surface (system material, 13 pt
    /// corner radius, hairline border) anchored under the centered capsule row.
    /// Per-row status glyphs come from ``TodoChecklistRow`` so a task renders
    /// identically here and in the transcript (C1).
    private var expandedList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(todos.items) { item in
                TodoChecklistRow(item: item)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 13))
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(theme.border.opacity(0.6), lineWidth: 1)
        )
    }
}

/// QA-2 R12 — the queued-backlog capsule that sits BESIDE the task capsule when
/// both are live. Same native capsule language as the task pill and the
/// composer's pending pill (C1/C2): width-to-fit, `theme.muted` fill, caption
/// font, `text.badge.plus` glyph. Tapping opens the queued-messages sheet.
struct DockQueuedCapsule: View {
    let count: Int
    let onTap: () -> Void

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        Button(action: onTap) {
            Label("\(count) pending", systemImage: "text.badge.plus")
                .font(.caption.weight(.medium))
                .foregroundStyle(theme.mutedFg)
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(theme.muted, in: Capsule())
                .overlay(Capsule().strokeBorder(theme.border.opacity(0.6), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(count) queued \(count == 1 ? "message" : "messages")")
        .accessibilityValue("Sends when reconnected")
        .accessibilityHint("Opens queued messages")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Queued strip

/// Slim dock strip for session-scoped queued sends: a breathing accent bar +
/// "Queued — sends when reconnected" + a count pill. Tapping opens the queued
/// messages sheet.
struct DockQueuedStrip: View {
    let count: Int
    let onTap: () -> Void

    @Environment(\.hermesTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var breathing = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Capsule()
                    .fill(theme.midground)
                    .frame(width: 3, height: 16)
                    .opacity(reduceMotion ? 0.9 : (breathing ? 0.35 : 1.0))
                Text("Queued — sends when reconnected")
                    .font(.footnote)
                    .foregroundStyle(theme.mutedFg)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(theme.midground)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 2)
                    .background(theme.midground.opacity(0.16), in: Capsule())
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 13))
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(theme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) queued \(count == 1 ? "message" : "messages")")
        .accessibilityValue("Sends when reconnected")
        .accessibilityHint("Opens queued messages")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Queued messages sheet

/// Lists the session-scoped queued sends with a per-item cancel (removes the row
/// from the outbox). Wired to the real ``QueueStore`` — cancel calls
/// ``QueueStore/remove(id:)``.
struct QueuedMessagesSheet: View {
    let queueStore: QueueStore

    @Environment(\.hermesTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if queueStore.activeItems.isEmpty {
                    ContentUnavailableView(
                        "No queued messages",
                        systemImage: "tray",
                        description: Text("Messages you send while offline queue here and send automatically when the connection is back.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(queueStore.activeItems) { item in
                                row(for: item)
                            }
                        } footer: {
                            Text("These send automatically, in order, the moment the connection is back. Tap ✕ to cancel one.")
                        }
                    }
                }
            }
            .background(theme.bg)
            .scrollContentBackground(.hidden)
            .navigationTitle("Queued messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(for item: QueueStore.QueuedPrompt) -> some View {
        HStack(spacing: 11) {
            Text(item.text)
                .font(.callout)
                .foregroundStyle(theme.fg)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Task { await queueStore.remove(id: item.id) }
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(theme.mutedFg)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel queued message")
        }
        .listRowBackground(theme.card)
        .accessibilityElement(children: .combine)
    }
}
