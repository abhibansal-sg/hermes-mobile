import SwiftUI

/// The Archived Chats surface (ABH-80 item 5), reached from the "Archived
/// Chats" row in ``SettingsView``. Shows the list of archived sessions fetched
/// via ``SessionStore/loadArchived(limit:)`` (backed by
/// ``RestClient/archivedSessions(limit:)``).
///
/// Each row shows the session title + a relative date. Rows carry a trailing
/// "Unarchive" button (and a matching swipe action) that calls
/// ``SessionStore/unarchive(_:)`` — the existing PATCH `{ archived: false }`
/// restore path — and removes the row immediately (the main session list
/// refreshes in the background). Tapping a row opens the session via the
/// normal ``SessionStore/open(_:)`` path; the view is pushed inside
/// ``SettingsView``'s own `NavigationStack`, so the system back-chevron handles
/// dismissal.
///
/// Empty state: ``ContentUnavailableView`` ("No archived chats",
/// `archivebox` glyph) — the iOS 17+ system component, matching the
/// established pattern in the codebase.
struct ArchivedSessionsView: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(\.hermesTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    /// Invoked after opening a session so the host can dismiss surrounding
    /// navigation chrome too. From the drawer this closes the drawer — without
    /// it, tapping an archived chat dismissed only this sheet and left the
    /// drawer covering the chat (build-29 QA). Defaults to a no-op for any
    /// non-drawer host.
    var onNavigate: () -> Void = {}

    /// PSF-10: track whether the initial load is still in flight so we show
    /// a spinner rather than the empty-state while waiting for the first fetch.
    @State private var isLoading = false

    var body: some View {
        List {
            if isLoading && sessions.archivedSessions.isEmpty {
                // Loading placeholder — a single clear row keeps the insetGrouped
                // chrome minimal while the overlay spinner is visible.
                Color.clear
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .frame(height: 0)
            } else if sessions.archivedSessions.isEmpty {
                // System ContentUnavailableView inside a List renders as a
                // full-height placeholder row on iOS 17+. Accessible and
                // scheme-adaptive without custom drawing.
                // PSF-11: improved copy — tells the user how to archive rather
                // than the generic "will appear here".
                ContentUnavailableView(
                    "No Archived Chats",
                    systemImage: "archivebox",
                    description: Text("Archive a chat from the session list and it will appear here.")
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                // PSF-06: wrap rows in a Section so the insetGrouped list renders
                // proper section chrome and the theme.card fill reads correctly.
                Section {
                    ForEach(sessions.archivedSessions) { summary in
                        archivedRow(summary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.bg)
        .navigationTitle("Archived Chats")
        .navigationBarTitleDisplayMode(.inline)
        // PSF-10: loading overlay — shown during the initial fetch so the user
        // sees a spinner rather than the empty/ContentUnavailableView flashing in
        // for a moment before the list arrives.
        .overlay {
            if isLoading && sessions.archivedSessions.isEmpty {
                ProgressView()
            }
        }
        // PSF-10: pull-to-refresh mirrors DevicesView / ApprovalAuditView pattern.
        .refreshable { await reload() }
        .task {
            // Re-fetch on every appear so the list is fresh each time the
            // view is pushed (avoids showing a stale cache from a prior push).
            await reload()
        }
    }

    // MARK: - Load

    private func reload() async {
        isLoading = true
        await sessions.loadArchived()
        isLoading = false
    }

    // MARK: - Row

    /// One archived-session row: title on the leading side, relative date
    /// trailing, with an "Unarchive" swipe-action and a mirroring trailing
    /// button so the affordance is discoverable without long-press muscle memory.
    @ViewBuilder
    private func archivedRow(_ summary: SessionSummary) -> some View {
        HStack(spacing: 0) {
            // Tapping opens the session and pops back to the drawer.
            Button {
                sessions.open(summary)
                dismiss()
                onNavigate()
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary.displayHumanTitle)
                        .font(.body.weight(.medium))
                        .foregroundStyle(theme.fg)
                        .lineLimit(1)
                    if let date = summary.displayDate {
                        Text(date, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(theme.mutedFg)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            // Trailing unarchive button — primary discoverable affordance,
            // mirrored by the swipe action below.
            Button {
                Task { await sessions.unarchive(summary) }
            } label: {
                Text("Unarchive")
                    .font(.footnote.weight(.medium))
                    // `theme.midground` (the brand accent, contrast-safe for
                    // labels) — `theme.accent` is a background FILL on several
                    // themes and rendered near-invisible here (release audit).
                    .foregroundStyle(theme.midground)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(theme.accent.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Unarchive \(summary.displayHumanTitle)")
        }
        .padding(.vertical, 4)
        .listRowBackground(theme.card)
        // Swipe-from-trailing to unarchive — the natural gesture for this action
        // and consistent with archive being available on a row context menu in
        // the drawer. No per-row horizontal pan competes with the drawer because
        // this list is pushed inside SettingsView, not embedded in the drawer.
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                Task { await sessions.unarchive(summary) }
            } label: {
                Label("Unarchive", systemImage: "archivebox")
            }
            .tint(theme.accent)
        }
    }
}
