import SwiftUI

/// Flat recency feed of cron (automation) sessions, fetched via
/// `GET /api/sessions?source=cron&order=recent`. Reachable from
/// ``CronJobsView`` via a toolbar button and a "Recent runs" row at the top
/// of the jobs list. Part of the drawer bifurcation (ABH): automation runs
/// no longer appear in the human-chat Recents — they live here instead.
///
/// ## Fetch strategy
/// Fetch-on-view: a single `sessionsWithTotal(source: "cron")` per appear,
/// with pull-to-refresh. No separate cache — cron sessions are excluded from
/// `SessionStore.sessions` by the bifurcation (`excludeSource: ["cron"]`),
/// so there is nothing to alias here.
///
/// ## Open-a-run approach: `sessionStore.open(_:)` + `dismiss()`
/// Tapping a row calls `sessionStore.open(summary)` then
/// `@Environment(\.dismiss)` to collapse the Settings sheet. In SwiftUI,
/// calling `dismiss()` from a view pushed inside a `NavigationStack` that
/// was PRESENTED as a sheet dismisses the whole presentation context (the
/// sheet), not just the top stack entry — the same pattern
/// `ArchivedSessionsView` uses (opens session, calls `dismiss()`, sheet
/// closes, the newly-active chat is revealed in the app root). A read-only
/// transcript push was considered and rejected: it requires an extra
/// `rest.messages` round-trip and produces a dead-end read-only surface
/// rather than the live interactive chat — worse UX for no architectural
/// benefit.
struct AutomationRunsView: View {
    /// The live REST client — passed from ``CronJobsView``, which receives
    /// it from `SettingsView.panelView` → `connectionStore.control`
    /// (identical to how every other panel is constructed).
    let rest: RestClient

    @Environment(SessionStore.self) private var sessionStore
    @Environment(\.hermesTheme) private var theme
    /// Dismissing this view closes the entire Settings sheet (presentation
    /// context), landing the user on the active chat.
    @Environment(\.dismiss) private var dismiss

    @State private var phase: PanelPhase<[SessionSummary]> = .loading

    var body: some View {
        PanelContent(
            phase: phase,
            label: "Loading runs\u{2026}",
            retry: { Task { await load() } }
        ) { sessions in
            if sessions.isEmpty {
                ZStack {
                    theme.bg.ignoresSafeArea()
                    ContentUnavailableView {
                        Label("No automation runs yet", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("Runs will appear here after your scheduled jobs execute.")
                    }
                }
            } else {
                List {
                    ForEach(sessions) { summary in
                        AutomationRunRow(summary: summary) {
                            openRun(summary)
                        }
                        .listRowBackground(theme.card)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(theme.bg)
                .refreshable { await load() }
            }
        }
        .navigationTitle("Recent Runs")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: - Data

    private func load() async {
        if phase.value == nil { phase = .loading }
        do {
            let (sessions, _) = try await rest.sessionsWithTotal(source: "cron")
            // Defense-in-depth: keep only cron rows even against a gateway that
            // predates the `source` param (which would return all sources).
            let runs = sessions.filter { ($0.source ?? "").lowercased() == "cron" }
            phase = .loaded(runs)
        } catch {
            phase = .failed(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }

    // MARK: - Navigation

    /// Activate the tapped run and dismiss the Settings sheet so the user
    /// lands on the live transcript. `sessionStore.open(_:)` is synchronous
    /// (it fires async tasks internally) so the session switch is instant.
    private func openRun(_ summary: SessionSummary) {
        sessionStore.open(summary)
        dismiss()
    }
}

// MARK: - Row

/// One automation-run row: human title, last-message preview snippet,
/// relative time (ticked every 60 s via `TimelineView`), and a subtle
/// `clock.arrow.circlepath` glyph that marks the row as an automation run.
/// Visual rhythm mirrors ``DrawerSessionRow`` to give the user a consistent
/// mental model for "a run is a session".
private struct AutomationRunRow: View {
    let summary: SessionSummary
    let onTap: () -> Void

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.displayHumanTitle)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.fg)
                        .lineLimit(1)

                    if let preview = summary.preview, !preview.isEmpty {
                        Text(preview)
                            .font(.subheadline)
                            .foregroundStyle(theme.mutedFg)
                            .lineLimit(1)
                    }

                    // Relative time — ticks every 60 s (mirrors DrawerSessionRow
                    // ABH-86 item 4 treatment).
                    if let date = summary.displayDate {
                        TimelineView(.periodic(from: .now, by: 60)) { _ in
                            Text(date, format: .relative(presentation: .named))
                                .font(.caption2)
                                .foregroundStyle(theme.mutedFg)
                        }
                    }
                }

                Spacer(minLength: 0)

                // Subtle trailing glyph — visually anchors the row as an
                // automation run without dominating the title.
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(theme.mutedFg.opacity(0.65))
                    .accessibilityLabel("Automation")
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("automationRunRow")
        .accessibilityLabel(summary.displayHumanTitle)
        .accessibilityHint("Open this automation run")
    }
}
