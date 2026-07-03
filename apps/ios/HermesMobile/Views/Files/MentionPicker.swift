import SwiftUI

/// The composer's `@`-file completion list (Module F4A-A1). Mounted ABOVE the
/// composer card while an `@`-mention is being typed; it queries the
/// `complete.path` RPC (debounced) for the active query and renders the
/// candidates. Selecting a row hands the chosen path back to the composer, which
/// inserts a `@file:<path>` token (see ``MentionCompletion``).
///
/// FULL NATIVE (UI-I): a system `List` of rows in a bounded card; identity via
/// `theme`/`tint`. The trigger + insertion live in the composer; this view only
/// fetches and presents.
///
/// States rendered (audit finding — `fetchError` is distinct from empty "No matches"):
///   - **loading** (spinner) — first fetch in progress with no prior results.
///   - **results** (list of rows) — at least one candidate returned.
///   - **empty** ("No matches" / "Type to search files") — fetch succeeded, zero rows.
///   - **error** ("Search unavailable" + error hint) — the RPC threw; distinct
///     from empty so the user knows it is a transient failure not a real zero-hit.
///
/// Gating: the composer only mounts this when `capabilities.fs != .unavailable`
/// AND the `@`-mention pref is on — a stock server never reaches it.
struct MentionPicker: View {
    /// The live gateway client for the `complete.path` RPC.
    let client: HermesGatewayClient
    /// The active runtime session id (threaded so the server resolves the
    /// session's cwd for completions).
    let sessionId: String?
    /// The current mention query (text after the `@`). Re-queries on change.
    let query: String
    /// Called with the chosen completion item's path when a row is tapped.
    let onSelect: (PathCompletionItem) -> Void

    @Environment(\.hermesTheme) private var theme

    @State private var items: [PathCompletionItem] = []
    @State private var isLoading = false
    /// Non-nil when the most recent fetch threw a network/RPC error.
    @State private var fetchError: String? = nil
    /// Monotonic token so a slow earlier query can't overwrite a newer result.
    @State private var queryToken = 0

    /// Cap the visible rows so the picker never eats the whole screen; the RPC
    /// already caps at 30.
    private static let maxRows = 6

    var body: some View {
        Group {
            if isLoading && items.isEmpty && fetchError == nil {
                loadingRow
            } else if let errorMessage = fetchError {
                errorRow(errorMessage)
            } else if items.isEmpty {
                emptyRow
            } else {
                list
            }
        }
        .background(theme.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(theme.border, lineWidth: 1)
        )
        .accessibilityIdentifier("mentionPicker")
        .task(id: query) { await fetch() }
    }

    // MARK: - States

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text("Searching files…")
                .font(.footnote)
                .foregroundStyle(theme.mutedFg)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("mentionPickerLoading")
    }

    private var emptyRow: some View {
        Text(query.isEmpty ? "Type to search files" : "No matches")
            .font(.footnote)
            .foregroundStyle(theme.mutedFg)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("mentionPickerEmpty")
    }

    /// Distinct error state — shown when the RPC throws, so the user sees
    /// "Search unavailable" rather than "No matches" (audit finding).
    private func errorRow(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(theme.mutedFg)
            VStack(alignment: .leading, spacing: 2) {
                Text("Search unavailable")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(theme.mutedFg)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(theme.mutedFg)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("mentionPickerError")
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(items.prefix(Self.maxRows).enumerated()), id: \.element.id) { index, item in
                    Button {
                        onSelect(item)
                    } label: {
                        row(item)
                    }
                    .buttonStyle(.plain)
                    if index < min(items.count, Self.maxRows) - 1 {
                        Divider().overlay(theme.border)
                    }
                }
            }
        }
        // Bound the height so the keyboard stays visible: ~44pt per row.
        .frame(maxHeight: CGFloat(min(items.count, Self.maxRows)) * 46)
    }

    private func row(_ item: PathCompletionItem) -> some View {
        let contextKind = contextHintKind(item)
        return HStack(spacing: 10) {
            Image(systemName: iconName(for: item, contextKind: contextKind))
                .foregroundStyle(contextKind == nil ? (item.isDirectory ? theme.midground : theme.mutedFg) : theme.midground)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                    .font(.body)
                    .foregroundStyle(theme.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if contextKind != nil, let meta = item.meta, !meta.isEmpty {
                    Text(meta)
                        .font(.caption2)
                        .foregroundStyle(theme.mutedFg)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 14)
        .padding(.vertical, contextKind == nil ? 11 : 9)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: item, contextKind: contextKind))
    }

    private static let contextHintTexts: Set<String> = [
        "@diff", "@staged", "@file:", "@folder:", "@url:", "@git:"
    ]

    private func contextHintKind(_ item: PathCompletionItem) -> String? {
        guard query.isEmpty, Self.contextHintTexts.contains(item.text) else { return nil }
        switch item.text {
        case "@diff": return "Diff"
        case "@staged": return "Staged diff"
        case "@file:": return "File reference"
        case "@folder:": return "Folder reference"
        case "@url:": return "URL reference"
        case "@git:": return "Git reference"
        default: return nil
        }
    }

    private func iconName(for item: PathCompletionItem, contextKind: String?) -> String {
        guard contextKind != nil else {
            return item.isDirectory ? "folder.fill" : "doc"
        }
        switch item.text {
        case "@diff", "@staged": return "arrow.triangle.branch"
        case "@file:": return "doc.text"
        case "@folder:": return "folder.fill"
        case "@url:": return "link"
        case "@git:": return "point.3.connected.trianglepath.dotted"
        default: return "at"
        }
    }

    private func accessibilityLabel(for item: PathCompletionItem, contextKind: String?) -> String {
        if let contextKind {
            return "\(contextKind): \(item.label)"
        }
        return (item.isDirectory ? "Folder: " : "File: ") + item.label
    }

    // MARK: - Fetch

    private func fetch() async {
        queryToken &+= 1
        let token = queryToken
        isLoading = true
        fetchError = nil
        // Light debounce so each keystroke doesn't fire an RPC.
        try? await Task.sleep(for: .milliseconds(180))
        guard token == queryToken else { return }

        var params: [String: JSONValue] = [
            "word": .string(MentionCompletion.completionWord(for: query))
        ]
        if let sessionId, !sessionId.isEmpty {
            params["session_id"] = .string(sessionId)
        }

        do {
            let raw = try await client.requestRaw("complete.path", params: .object(params))
            guard token == queryToken else { return }
            items = Self.parse(raw)
            fetchError = nil
            isLoading = false
        } catch {
            guard token == queryToken else { return }
            // Surface the error in the picker rather than silently showing
            // "No matches" (audit finding: distinct fetchError state).
            items = []
            fetchError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            isLoading = false
        }
    }

    /// Decode the `complete.path` result (`{items:[{text, display, meta}]}`),
    /// dropping any entry without a `text`.
    static func parse(_ raw: JSONValue) -> [PathCompletionItem] {
        guard let rows = raw["items"]?.arrayValue else { return [] }
        return rows.compactMap { $0.decoded(as: PathCompletionItem.self) }
            .filter { !$0.text.isEmpty }
    }
}
