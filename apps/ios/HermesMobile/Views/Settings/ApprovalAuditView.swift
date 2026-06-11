import SwiftUI

/// Read-only approval-audit log (W3A-A), pushed from the Devices section. Lists
/// the append-only audit records from `GET /api/approvals/audit`,
/// most-recent-first, with per-record device attribution (which device — or the
/// shared token — resolved each approval). FULL NATIVE: a system `List` of
/// `Section`/`LabeledContent`/`Label` rows; identity via tint only.
///
/// SECRETS HYGIENE: a record carries only the 8-char `token_prefix` + the stable
/// `device_id` — NEVER a full token. This view renders those verbatim and never
/// logs them.
struct ApprovalAuditView: View {
    /// The REST client for the active connection (built from the same URL+token
    /// as the rest of the app — device token or shared token, both accepted).
    let rest: RestClient

    @Environment(\.hermesTheme) private var theme

    @State private var entries: [ApprovalAuditEntry] = []
    @State private var isLoading = true
    @State private var loadError: String?
    /// Whether the currently loaded batch is a truncated window rather than the
    /// full log. `true` when the server returned exactly `pageLimit` records.
    @State private var hasMore = false
    /// Whether a "load more" fetch is in flight.
    @State private var isLoadingMore = false

    /// The initial page size. A small window keeps the first load fast.
    private static let pageLimit = 50
    /// Maximum entries to request on "load more".
    private static let maxLimit = 500

    var body: some View {
        List {
            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(theme.mutedFg)
                        .listRowBackground(theme.card)
                }
            } else if entries.isEmpty && !isLoading {
                Section {
                    Label("No approvals recorded yet.", systemImage: "checklist")
                        .foregroundStyle(theme.mutedFg)
                        .listRowBackground(theme.card)
                }
            } else {
                Section {
                    ForEach(entries) { entry in
                        auditRow(entry)
                            .listRowBackground(theme.card)
                    }
                } footer: {
                    if hasMore {
                        // Explicit "Load more" footer — no auto-pagination.
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Showing the \(entries.count) most recent approvals.")
                                .font(.footnote)
                                .foregroundStyle(theme.mutedFg)
                            Button {
                                Task { await loadMore() }
                            } label: {
                                if isLoadingMore {
                                    Label("Loading…", systemImage: "arrow.clockwise")
                                        .font(.footnote.weight(.medium))
                                } else {
                                    Label("Load more", systemImage: "arrow.down.circle")
                                        .font(.footnote.weight(.medium))
                                }
                            }
                            .disabled(isLoadingMore)
                            .accessibilityIdentifier("auditLoadMore")
                        }
                        .padding(.top, 4)
                    } else if !entries.isEmpty {
                        Text("Each entry records which device resolved an approval. Tokens are never shown in full.")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.bg)
        .navigationTitle("Approval Audit")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading && entries.isEmpty && loadError == nil {
                ProgressView()
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: - Row

    @ViewBuilder
    private func auditRow(_ entry: ApprovalAuditEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Self.choiceLabel(entry.choice))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Self.isDeny(entry.choice) ? theme.destructive : theme.fg)
                if entry.resolveAll {
                    Text("· all")
                        .font(.footnote)
                        .foregroundStyle(theme.mutedFg)
                }
                Spacer(minLength: 8)
                Text(Self.relativeDate(entry.ts))
                    .font(.footnote)
                    .foregroundStyle(theme.mutedFg)
            }
            if let preview = entry.commandPreview, !preview.isEmpty {
                Text(preview)
                    .font(.footnote)
                    .foregroundStyle(theme.mutedFg)
                    .lineLimit(2)
            }
            Text(Self.attribution(entry))
                .font(.caption)
                .foregroundStyle(theme.mutedFg)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel({
            let choice = Self.choiceLabel(entry.choice)
            let all = entry.resolveAll ? ", all" : ""
            let tool = entry.commandPreview.map { ", \($0)" } ?? ""
            let date = Self.relativeDate(entry.ts)
            let attribution = Self.attribution(entry)
            return "\(choice)\(all)\(tool), \(date), \(attribution)"
        }())
    }

    // MARK: - Load

    private func load() async {
        isLoading = true
        loadError = nil
        hasMore = false
        do {
            let fetched = try await rest.approvalAudit(limit: Self.pageLimit)
            entries = fetched
            // If the server returned exactly the page limit, there may be more.
            hasMore = fetched.count >= Self.pageLimit
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? "Couldn't load the audit log."
        }
        isLoading = false
    }

    /// Load up to ``maxLimit`` records, replacing the current page.
    private func loadMore() async {
        guard hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let fetched = try await rest.approvalAudit(limit: Self.maxLimit)
            entries = fetched
            hasMore = fetched.count >= Self.maxLimit
        } catch {
            // Surface the error inline; leave existing entries visible.
            loadError = (error as? LocalizedError)?.errorDescription ?? "Couldn't load more entries."
        }
    }

    // MARK: - Pure presentation helpers (unit-tested)

    /// Human label for a resolve `choice` wire value.
    static func choiceLabel(_ choice: String) -> String {
        switch choice {
        case "once": return "Approved once"
        case "session": return "Approved for session"
        case "always": return "Always approved"
        case "deny": return "Denied"
        default: return choice.isEmpty ? "Resolved" : choice.capitalized
        }
    }

    static func isDeny(_ choice: String) -> Bool { choice == "deny" }

    /// Attribution line: which device (or the shared token / internal child)
    /// resolved the approval, with the 8-char token prefix when a token did.
    /// NEVER includes a full token.
    static func attribution(_ entry: ApprovalAuditEntry) -> String {
        let who: String
        switch entry.credential {
        case "device":
            let name = (entry.deviceName?.isEmpty == false) ? entry.deviceName! : "Device"
            who = name
        case "shared":
            who = "Shared token"
        case "internal":
            who = "Agent (internal)"
        case "cookie":
            who = "Web session"
        default:
            who = entry.credential.isEmpty ? "Unknown" : entry.credential.capitalized
        }
        if let prefix = entry.tokenPrefix, !prefix.isEmpty {
            return "\(who) · \(prefix)…"
        }
        return who
    }

    /// Relative date for an epoch-seconds timestamp ("3m ago"). A zero/absent
    /// timestamp shows an em dash.
    static func relativeDate(_ ts: Double) -> String {
        guard ts > 0 else { return "—" }
        let date = Date(timeIntervalSince1970: ts)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
