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
    private var content: TurnDockContent {
        TurnDockContent.resolve(
            hasApproval: chatStore.pendingApproval != nil,
            hasClarification: chatStore.pendingClarification != nil,
            hasTasks: chatStore.latestTodoList != nil,
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
                if let todos = chatStore.latestTodoList {
                    DockTaskBox(todos: todos)
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

/// A SLIM ONE-LINE PILL (checklist glyph + "X of Y" + current in-progress task
/// title) that expands IN PLACE to the full checklist. Owner QA redesign:
///
///  • Collapsed = a single-line pill in the same visual language as the queued
///    strip — NOT a tall lighter floating card. Its fill is `theme.muted`, a
///    subtle wash on the transcript surface, so it reads as part of the transcript
///    rather than a lighter box hovering over it.
///  • NO progress bar. The old full-width `theme.midground` progress rule under
///    the header read as a "mystery blue line"; the "X of Y" count carries the
///    same information without a coloured rule.
///  • Expanded = a compact, theme-matched checklist with tight row spacing.
///
/// The expanded rows reuse ``TodoChecklistRow`` — the exact styling the
/// transcript's ``TodoCardView`` uses — so the dock and the transcript render a
/// todo item identically.
struct DockTaskBox: View {
    let todos: TodoList

    @Environment(\.hermesTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isExpanded = false

    private var doneCount: Int {
        todos.items.filter { $0.status == .completed }.count
    }
    private var total: Int { todos.items.count }
    /// The task the agent is actively working, if any — shown in the collapsed
    /// pill. Falls back to the first not-yet-done item so the pill always names
    /// *something* actionable.
    private var currentTitle: String? {
        todos.items.first { $0.status == .inProgress }?.content
            ?? todos.items.first { $0.status == .pending || $0.status == .other }?.content
    }

    var body: some View {
        VStack(spacing: 0) {
            pill
            if isExpanded { list }
        }
        // Subtle transcript-matched wash (owner QA: "not a lighter box"), hairline
        // border. Corner radius + horizontal metrics mirror the queued strip so the
        // two dock surfaces share one visual language.
        .background(theme.muted, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(theme.border.opacity(0.6), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    private var pill: some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "checklist")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(theme.midground)
                Text("\(doneCount) of \(total)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.fg)
                    .monospacedDigit()
                    .layoutPriority(1)
                if let currentTitle {
                    Text(currentTitle)
                        .font(.footnote)
                        .foregroundStyle(theme.mutedFg)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 0)
                }
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.mutedFg)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Tasks, \(doneCount) of \(total) done")
        .accessibilityValue(currentTitle.map { "Current: \($0)" } ?? "")
        .accessibilityHint(isExpanded ? "Collapse task list" : "Expand task list")
        .accessibilityAddTraits(.isButton)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Hairline divider between the pill and the expanded list, matched to the
            // subtle wash — replaces the old coloured progress rule.
            Rectangle()
                .fill(theme.border.opacity(0.6))
                .frame(height: 1)
                .padding(.bottom, 2)
                .accessibilityHidden(true)
            ForEach(todos.items) { item in
                TodoChecklistRow(item: item)
            }
        }
        .padding(.horizontal, 13)
        .padding(.top, 8)
        .padding(.bottom, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
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
