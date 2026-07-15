import SwiftUI

// MARK: - STR-338 webhook subscription management panel
//
// Desktop parity with `web/src/pages/WebhooksPage.tsx`: the webhook receiver
// is its own gateway "platform" (separate from the chat channels) — a named,
// HMAC-signed subscription fires the agent (or delivers a payload directly)
// on an inbound HTTP event. `/api/webhooks*` are STOCK gateway routes (same
// posture as `/api/logs`), so — like ``SystemLogsView`` — this panel is
// reachable whenever `connectionStore.rest` exists, independent of the
// plugin-mount probe that gates the Provider/toolset panels.
//
// Scoped OUT of this iOS pass (see STR-338 spec): the desktop's automatic
// gateway-restart POLLING loop (`watchRestartOutcome` in WebhooksPage.tsx).
// This panel surfaces "enable" + an informational restart message only; the
// user re-taps Refresh once the gateway is back to confirm the receiver is
// live.

/// The panel pushed from Settings → Webhooks. Owns the list load + the
/// enable/create/toggle/delete actions; ``WebhooksStore`` is the view-model
/// (mirrors ``SystemLogsStore``'s idle/loading/loaded/error phase pattern).
struct WebhooksPanelView: View {
    let rest: RestClient

    @Environment(\.hermesTheme) private var theme
    // `@StateObject` (not `@State`) so the store's `@Published` phase/pending
    // updates from async fetches actually invalidate the view — the store is a
    // Combine `ObservableObject` (mirrors `GatewayStatusView`'s `actionRunner`).
    @StateObject private var store: WebhooksStore

    @State private var showCreateSheet = false
    @State private var pendingDelete: WebhookRoute?
    @State private var showDeleteConfirm = false
    @State private var toast: String?

    /// Enable-flow UI state. Kept on the view (not the store) — it is
    /// transient per-visit messaging about the LAST enable attempt, not
    /// server-fetched state that a refresh should reconcile.
    @State private var enabling = false
    @State private var restartNeeded = false
    @State private var restartNote: String?

    init(rest: RestClient) {
        self.rest = rest
        _store = StateObject(wrappedValue: WebhooksStore(rest: rest))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            List {
                switch store.phase {
                case .idle, .loading:
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Loading webhooks\u{2026}")
                                .foregroundStyle(theme.mutedFg)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowBackground(theme.card)
                    }

                case .error(let message):
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(theme.statusError)
                                Text(message)
                                    .foregroundStyle(theme.fg)
                            }
                            Button {
                                store.refresh()
                            } label: {
                                Label("Retry", systemImage: "arrow.clockwise")
                                    .font(.system(size: 15, weight: .medium))
                            }
                            .accessibilityIdentifier("webhooksRetryButton")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowBackground(theme.card)
                    } footer: {
                        Text("The gateway may be unreachable, or this build may predate the webhook routes.")
                            .font(.footnote)
                    }

                case .loaded(let result):
                    loadedSections(result)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.bg)

            if let toast {
                Text(toast)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(theme.bg)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(theme.fg.opacity(0.9), in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle("Webhooks")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(store.phase.isLoading)
                .accessibilityLabel("Refresh webhooks")
                .accessibilityIdentifier("webhooksRefreshButton")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreateSheet = true
                } label: {
                    Label("New subscription", systemImage: "plus")
                }
                .disabled(!(store.phase.loadedResult?.enabled ?? false) || enabling)
                .accessibilityIdentifier("webhookCreateButton")
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            WebhookCreateSheet(rest: rest) {
                store.refresh()
                showToast("Created \u{2713}")
            }
        }
        .confirmationDialog(
            "Delete \u{201C}\(pendingDelete?.name ?? "subscription")\u{201D}?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let route = pendingDelete else { return }
                Task {
                    await store.delete(route)
                    showToast("Deleted \u{201C}\(route.name)\u{201D}")
                }
            }
            .accessibilityIdentifier("webhookDeleteConfirmButton")
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This will permanently remove this webhook subscription.")
        }
        .alert("Action failed", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.actionError ?? "")
        }
        .task { await store.loadIfNeeded() }
    }

    // MARK: - Loaded content

    @ViewBuilder
    private func loadedSections(_ result: WebhooksListResult) -> some View {
        if !result.enabled {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Webhook receiver disabled", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.subheadline.weight(.semibold))
                    Text("Webhooks are their own gateway platform. Enable them here to accept incoming HTTP events; chat channels are only needed when a subscription delivers to Telegram, Discord, Slack, or another channel.")
                        .font(.footnote)
                        .foregroundStyle(theme.mutedFg)
                    Button {
                        Task { await handleEnable() }
                    } label: {
                        if enabling {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Enabling\u{2026}")
                            }
                        } else {
                            Label("Enable webhooks", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                    }
                    .disabled(enabling)
                    .accessibilityIdentifier("webhookEnableButton")
                }
                .padding(.vertical, 4)
                .listRowBackground(theme.card)
            }
        }

        if restartNeeded, let restartNote {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(theme.statusWarn)
                    Text(restartNote)
                        .font(.footnote)
                        .foregroundStyle(theme.fg)
                }
                .listRowBackground(theme.card)
            } footer: {
                Text("Tap Refresh once the gateway is back up to confirm the receiver is live.")
                    .font(.footnote)
            }
        }

        Section {
            if result.subscriptions.isEmpty {
                ContentUnavailableView {
                    Label("No subscriptions", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("Tap \u{201C}New subscription\u{201D} to create your first webhook.")
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(result.subscriptions) { route in
                    WebhookRowView(
                        route: route,
                        isPending: store.pendingNames.contains(route.name),
                        onToggle: {
                            Task {
                                await store.toggle(route)
                                showToast(route.enabled ? "Disabled \u{201C}\(route.name)\u{201D}" : "Enabled \u{201C}\(route.name)\u{201D}")
                            }
                        },
                        onDelete: {
                            pendingDelete = route
                            showDeleteConfirm = true
                        }
                    )
                    .listRowBackground(theme.card)
                }
            }
        } header: {
            Text("Subscriptions (\(result.subscriptions.count))")
        } footer: {
            Text("Subscription changes hot-reload once the webhook receiver is running. Disabled subscriptions reject incoming events.")
                .font(.footnote)
        }
    }

    // MARK: - Actions

    private var errorBinding: Binding<Bool> {
        Binding(get: { store.actionError != nil }, set: { if !$0 { store.actionError = nil } })
    }

    private func showToast(_ message: String) {
        withAnimation(.spring(response: 0.3)) { toast = message }
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation(.spring(response: 0.3)) { toast = nil }
        }
    }

    private func handleEnable() async {
        enabling = true
        restartNeeded = false
        restartNote = nil
        defer { enabling = false }
        guard let result = await store.enableWebhooks() else { return }
        if result.restartStarted == false {
            let detail = result.restartError.map { ": \($0)" } ?? "."
            restartNeeded = true
            restartNote = "Webhooks are enabled, but the gateway restart failed\(detail) Restart it manually to bring the receiver online."
        } else if result.needsRestart {
            restartNeeded = true
            restartNote = "Webhooks are enabled, but the gateway still needs a restart before the receiver can come online."
        }
    }
}

// MARK: - Store (view-model)

/// The view-model for ``WebhooksPanelView``. Owns the fetch phase and the
/// per-row mutation state, and drives every call through ``RestClient``'s
/// webhook methods. Mirrors ``SystemLogsStore``'s idle/loading/loaded/error
/// phase pattern.
@MainActor
final class WebhooksStore: ObservableObject {

    enum Phase: Equatable {
        case idle
        case loading
        case loaded(WebhooksListResult)
        case error(String)

        var isLoading: Bool {
            if case .loading = self { return true }
            return false
        }

        var loadedResult: WebhooksListResult? {
            if case .loaded(let result) = self { return result }
            return nil
        }
    }

    @Published private(set) var phase: Phase = .idle
    /// Subscription names with an in-flight toggle/delete, for per-row spinners.
    @Published private(set) var pendingNames: Set<String> = []
    @Published var actionError: String?

    private let rest: RestClient

    init(rest: RestClient) {
        self.rest = rest
    }

    /// Load on first appearance only (idle → loading). Subsequent updates go
    /// through ``refresh()``.
    func loadIfNeeded() async {
        guard case .idle = phase else { return }
        await fetch()
    }

    /// Re-fetch the list — called on the explicit Refresh/Retry buttons and
    /// after a successful enable/create.
    func refresh() {
        Task { await fetch() }
    }

    private func fetch() async {
        phase = .loading
        do {
            let result = try await rest.listWebhooks()
            phase = .loaded(result)
        } catch {
            phase = .error((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Enable the webhook platform. Refreshes the list on success (whether or
    /// not the gateway's self-restart succeeded — the `enabled` flag was
    /// persisted either way) so the banner state reflects reality. Returns the
    /// raw result so the view can decide what restart messaging to show.
    func enableWebhooks() async -> WebhookEnableResult? {
        do {
            let result = try await rest.enableWebhooks()
            await fetch()
            return result
        } catch {
            actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    /// Toggle one subscription's enabled state and splice the confirmed value
    /// back into the loaded list — no full reload needed.
    func toggle(_ route: WebhookRoute) async {
        guard !pendingNames.contains(route.name) else { return }
        pendingNames.insert(route.name)
        defer { pendingNames.remove(route.name) }
        do {
            let confirmed = try await rest.setWebhookEnabled(name: route.name, enabled: !route.enabled)
            if case .loaded(var result) = phase,
               let index = result.subscriptions.firstIndex(where: { $0.name == route.name }) {
                result.subscriptions[index] = result.subscriptions[index].copy(enabled: confirmed)
                phase = .loaded(result)
            }
        } catch {
            actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Delete one subscription and remove it from the loaded list.
    func delete(_ route: WebhookRoute) async {
        guard !pendingNames.contains(route.name) else { return }
        pendingNames.insert(route.name)
        defer { pendingNames.remove(route.name) }
        do {
            _ = try await rest.deleteWebhook(name: route.name)
            if case .loaded(var result) = phase {
                result.subscriptions.removeAll { $0.name == route.name }
                phase = .loaded(result)
            }
        } catch {
            actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Row

/// One subscription row: name + deliver/deliver-only/disabled badges,
/// description, event chips, the URL with a copy button, and per-row
/// enable/disable + delete actions.
private struct WebhookRowView: View {
    let route: WebhookRoute
    let isPending: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void

    @Environment(\.hermesTheme) private var theme
    @State private var urlCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(route.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                badge(route.deliver, tint: theme.accent)
                if route.deliverOnly {
                    badge("deliver only", tint: theme.mutedFg)
                }
                if !route.enabled {
                    badge("disabled", tint: theme.statusWarn)
                }
            }
            .opacity(route.enabled ? 1 : 0.6)

            if !route.description.isEmpty {
                Text(route.description)
                    .font(.footnote)
                    .foregroundStyle(theme.mutedFg)
            }

            if route.events.isEmpty {
                badge("(all events)", tint: theme.mutedFg)
            } else {
                // Wrap-friendly event chip row.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(route.events, id: \.self) { event in
                        badge(event, tint: theme.mutedFg)
                    }
                }
            }

            HStack(spacing: 8) {
                Text(route.url)
                    .font(.footnote.monospaced())
                    .foregroundStyle(theme.mutedFg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    UIPasteboard.general.string = route.url
                    urlCopied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        urlCopied = false
                    }
                } label: {
                    Image(systemName: urlCopied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(theme.mutedFg)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy webhook URL")
                .accessibilityIdentifier("webhookCopyURLButton_\(route.name)")
            }

            HStack(spacing: 16) {
                Button {
                    onToggle()
                } label: {
                    if isPending {
                        ProgressView()
                    } else {
                        Text(route.enabled ? "Disable" : "Enable")
                    }
                }
                .font(.footnote.weight(.medium))
                .disabled(isPending)
                .accessibilityIdentifier("webhookRowToggle_\(route.name)")

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(theme.destructive)
                }
                .disabled(isPending)
                .accessibilityLabel("Delete \(route.name)")
                .accessibilityIdentifier("webhookRowDelete_\(route.name)")

                Spacer()
            }
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("webhookRow_\(route.name)")
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

// MARK: - Create sheet

/// The delivery target the server accepts for `deliver` — mirrors the
/// dashboard's `<Select>` options exactly (`WebhooksPage.tsx`).
private enum WebhookDeliverTarget: String, CaseIterable, Identifiable {
    case log, telegram, discord, slack, email
    case githubComment = "github_comment"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .log: return "Log"
        case .telegram: return "Telegram"
        case .discord: return "Discord"
        case .slack: return "Slack"
        case .email: return "Email"
        case .githubComment: return "GitHub comment"
        }
    }
}

/// Modal sheet: the create form, then (on success) the one-time secret
/// reveal. Client-side name validation is a friendly hint only — the server
/// (`^[a-z0-9][a-z0-9_-]*$` after lowercase+hyphenate) is authoritative.
private struct WebhookCreateSheet: View {
    let rest: RestClient
    /// Invoked once, after the user dismisses the created-secret screen —
    /// the caller refreshes the list at that point.
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.hermesTheme) private var theme

    @State private var name = ""
    @State private var description = ""
    @State private var eventsText = ""
    @State private var deliver: WebhookDeliverTarget = .log
    @State private var deliverOnly = false
    @State private var prompt = ""

    @State private var creating = false
    @State private var createError: String?
    @State private var created: (route: WebhookRoute, secret: String)?
    @State private var secretCopied = false
    @State private var urlCopied = false

    var body: some View {
        NavigationStack {
            Group {
                if let created {
                    createdView(created)
                } else {
                    formView
                }
            }
            .navigationTitle("New subscription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if created == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
    }

    // MARK: Form

    private var formView: some View {
        Form {
            Section {
                TextField("e.g. github-push", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("webhookNameField")
                if let hint = nameHint {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(theme.statusWarn)
                }
            } header: {
                Text("Name")
            } footer: {
                Text("Lowercase alphanumeric with hyphens/underscores. Spaces become hyphens.")
            }

            Section("Description") {
                TextField("What this webhook does (optional)", text: $description)
                    .accessibilityIdentifier("webhookDescriptionField")
            }

            Section {
                TextField("comma-separated, leave empty for all", text: $eventsText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("webhookEventsField")
            } header: {
                Text("Events")
            }

            Section("Deliver to") {
                Picker("Deliver to", selection: $deliver) {
                    ForEach(WebhookDeliverTarget.allCases) { target in
                        Text(target.label).tag(target)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("webhookDeliverPicker")

                Toggle("Deliver only", isOn: $deliverOnly)
                    .accessibilityIdentifier("webhookDeliverOnlyToggle")
                Text("Skip the agent, deliver payload directly.")
                    .font(.footnote)
                    .foregroundStyle(theme.mutedFg)
            }

            Section {
                TextEditor(text: $prompt)
                    .frame(minHeight: 80)
                    .accessibilityIdentifier("webhookPromptField")
            } header: {
                Text("Prompt")
            } footer: {
                Text("Instructions for the agent when this webhook fires (optional).")
            }

            if let createError {
                Section {
                    Text(createError)
                        .foregroundStyle(theme.statusError)
                }
            }

            Section {
                Button {
                    Task { await create() }
                } label: {
                    if creating {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Creating\u{2026}")
                        }
                    } else {
                        Text("Create")
                    }
                }
                .disabled(creating || trimmedName.isEmpty)
                .accessibilityIdentifier("webhookCreateSubmitButton")
            }
        }
    }

    /// A client-side friendly hint (never blocking) mirroring the server's
    /// `^[a-z0-9][a-z0-9_-]*$` check after its own lowercase+hyphenate
    /// normalization. The server remains authoritative — this is UX only.
    private var nameHint: String? {
        guard !trimmedName.isEmpty else { return nil }
        let normalized = trimmedName.lowercased().replacingOccurrences(of: " ", with: "-")
        guard let regex = try? NSRegularExpression(pattern: "^[a-z0-9][a-z0-9_-]*$") else { return nil }
        let range = NSRange(normalized.startIndex..., in: normalized)
        if regex.firstMatch(in: normalized, range: range) == nil {
            return "Will be sent as \u{201C}\(normalized)\u{201D} \u{2014} use lowercase letters, numbers, hyphens, or underscores."
        }
        return nil
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func create() async {
        creating = true
        createError = nil
        defer { creating = false }
        let events = eventsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        do {
            let result = try await rest.createWebhook(
                name: trimmedName,
                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                events: events,
                prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                deliver: deliver.rawValue,
                deliverOnly: deliverOnly
            )
            created = result
        } catch {
            createError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Created (one-time secret reveal)

    private func createdView(_ created: (route: WebhookRoute, secret: String)) -> some View {
        Form {
            Section {
                Text("Subscription created. Copy the secret now \u{2014} it is only shown once.")
                    .font(.subheadline)
                    .foregroundStyle(theme.mutedFg)
            }

            Section("Webhook URL") {
                HStack(spacing: 8) {
                    Text(created.route.url)
                        .font(.footnote.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = created.route.url
                        urlCopied = true
                    } label: {
                        Image(systemName: urlCopied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityLabel("Copy webhook URL")
                    .accessibilityIdentifier("webhookCopyCreatedURLButton")
                }
            }

            Section {
                HStack(spacing: 8) {
                    Text(created.secret)
                        .font(.footnote.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = created.secret
                        secretCopied = true
                    } label: {
                        Image(systemName: secretCopied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityLabel("Copy secret")
                    .accessibilityIdentifier("webhookCopySecretButton")
                }
            } header: {
                Text("Secret (shown once)")
            } footer: {
                Text("This secret will never be shown again. Store it now if this subscription verifies incoming signatures.")
                    .foregroundStyle(theme.statusWarn)
            }

            Section {
                Button("Done") {
                    onDone()
                    dismiss()
                }
                .accessibilityIdentifier("webhookCreateDoneButton")
            }
        }
    }
}
