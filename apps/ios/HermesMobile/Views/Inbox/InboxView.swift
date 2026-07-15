import SwiftUI

/// A list of pending agent prompts (approvals + clarifications) accumulated
/// across **all** sessions by `InboxStore`. Each row is resolved inline:
/// approvals get Deny / Approve / Approve-all, clarifications get choice chips
/// plus a free-text answer. Empty state when nothing is pending.
///
/// Session titles are resolved against `SessionStore` when its list is loaded,
/// falling back to a shortened id otherwise. Answering an item targets the
/// item's own session, so a prompt broadcast from another client resolves on
/// the correct runtime.
struct InboxView: View {
    @Environment(InboxStore.self) private var inbox
    @Environment(SessionStore.self) private var sessions
    // Resolved from the store rather than `\.hermesTheme`: this view is presented
    // inside a sheet whose NavigationStack root (and thus its `.hermesThemed`)
    // lives upstream, and SwiftUI does not reliably carry custom EnvironmentValues
    // across a sheet boundary — but the `@Observable` store does propagate.
    @Environment(ThemeStore.self) private var themeStore

    var body: some View {
        let theme = themeStore.current
        Group {
            if inbox.pendingItems.isEmpty {
                emptyState(theme)
            } else {
                List {
                    ForEach(inbox.pendingItems) { item in
                        InboxItemRow(item: item, inbox: inbox, sessionTitle: sessionTitle(for: item), theme: theme)
                            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                            .listRowSeparator(.hidden)
                            .listRowBackground(theme.bg)
                            // R1 #94: a stuck-pending row (failed respond
                            // re-arms forever against a dead runtime) needs an
                            // exit that isn't answering it — wire the store's
                            // previously-dead `dismiss(_:)`.
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    inbox.dismiss(item)
                                } label: {
                                    Label("Dismiss", systemImage: "xmark")
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(theme.bg)
            }
        }
        .navigationTitle("Inbox")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // P2x: standardize the sheet title to `.headline.semibold` in `fg` via a
        // principal item so it reads as the anchor rather than being matched by the
        // inline system title. Mirrors the Batch-C ChatView principal-title pattern.
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Inbox")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(theme.fg)
                    .lineLimit(1)
            }
            // R1 #94: `.expired` items accumulate in the store forever with no
            // tidy-up affordance — wire the previously-dead `clearExpired()`.
            if inbox.items.contains(where: { $0.state == .expired }) {
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        inbox.clearExpired()
                    } label: {
                        Label("Clear Expired", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func emptyState(_ theme: HermesTheme) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.largeTitle.weight(.regular))
                .foregroundStyle(theme.mutedFg)
                .accessibilityHidden(true)
            // I1: tone the empty headline down to `.headline` weight in `mutedFg`
            // so it no longer out-shouts the sheet title.
            Text("No pending requests")
                .font(.headline)
                .foregroundStyle(theme.mutedFg)
            Text("Approvals and questions from the agent appear here.")
                .font(.subheadline)
                .foregroundStyle(theme.mutedFg)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .background(theme.bg)
    }

    /// Resolve a human title for the item's session: the loaded session row's
    /// `displayTitle` when known (matched on stored id, then runtime id),
    /// otherwise a shortened id.
    private func sessionTitle(for item: InboxStore.Item) -> String {
        let candidates = [item.storedSessionId, item.sessionId].compactMap { $0 }
        for id in candidates {
            if let match = sessions.sessions.first(where: { $0.id == id }) {
                return match.displayTitle
            }
        }
        let id = item.storedSessionId ?? item.sessionId
        return "Session " + String(id.prefix(8))
    }
}

/// One inbox row: a material card with a session label, the prompt, and the
/// appropriate inline response controls for its kind.
private struct InboxItemRow: View {
    let item: InboxStore.Item
    let inbox: InboxStore
    let sessionTitle: String
    let theme: HermesTheme

    @State private var freeText = ""
    /// True while a respond RPC is in flight — gates re-entry and disables the
    /// action buttons so a double-tap can't double-respond (release audit P1).
    @State private var isResponding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            switch item.payload {
            case .approval(let request):
                approvalBody(request)
            case .clarify(let request):
                clarifyBody(request)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // I1/G2: card styling on the solid `card` fill (not `.regularMaterial`,
        // which renders as grey frosted glass over any dark theme) with the
        // neutral `border` token rather than a tinted brand stroke.
        .background(theme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(theme.border, lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: item.kind == .approval ? "lock.shield" : "questionmark.bubble")
                .foregroundStyle(theme.midground)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.cardFg)
                    .fixedSize(horizontal: false, vertical: true)
                Text(sessionTitle)
                    .font(.caption)
                    .foregroundStyle(theme.mutedFg)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Approval

    @ViewBuilder
    private func approvalBody(_ request: ApprovalRequestPayload) -> some View {
        if let description = request.descriptionText, !description.isEmpty {
            Text(description)
                .font(.callout)
                .foregroundStyle(theme.cardFg)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let target = request.target, !target.isEmpty {
            Text(target)
                .font(.caption.monospaced())
                .foregroundStyle(theme.mutedFg)
                .lineLimit(2)
                .truncationMode(.middle)
        }

        HStack(spacing: 10) {
            Button(role: .destructive) {
                respondApproval(approve: false, all: false)
            } label: {
                Text("Deny").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(theme.destructive)
            .accessibilityHint("Denies this request for the agent")

            Button {
                respondApproval(approve: true, all: false)
            } label: {
                Text("Approve").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.midground)
            .accessibilityHint("Approves this request for the agent")
        }
        .disabled(isResponding)

        Button {
            respondApproval(approve: true, all: true)
        } label: {
            Text("Approve all for this turn")
                .font(.caption)
        }
        .buttonStyle(.plain)
        .disabled(isResponding)
        .foregroundStyle(theme.mutedFg)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityHint("Approves all pending requests for this turn")
    }

    // MARK: - Clarify

    @ViewBuilder
    private func clarifyBody(_ request: ClarifyRequestPayload) -> some View {
        if !request.choices.isEmpty {
            ChoiceFlowLayout(spacing: 8) {
                ForEach(request.choices, id: \.self) { choice in
                    Button {
                        respondClarification(choice)
                    } label: {
                        Text(choice)
                            .font(.callout)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                    }
                    .buttonStyle(.bordered)
                    .tint(theme.midground)
                }
            }
        }

        HStack(spacing: 8) {
            TextField("Type an answer…", text: $freeText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .onSubmit(submitFreeText)

            Button {
                submitFreeText()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSubmitFreeText ? theme.midground : theme.mutedFg)
            .disabled(!canSubmitFreeText)
            .accessibilityLabel("Submit answer")
        }
    }

    private var canSubmitFreeText: Bool {
        !freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitFreeText() {
        let trimmed = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        respondClarification(trimmed)
    }

    // MARK: - Actions

    // In-flight guard (release audit P1): a rapid double-tap previously fired
    // two concurrent responds — the second hit 4009 and re-armed the item as a
    // phantom pending card. Mirrors ApprovalCard's isResponding pattern; the
    // row's buttons disable via `.disabled(isResponding)` at the call sites.

    private func respondApproval(approve: Bool, all: Bool) {
        guard !isResponding else { return }
        isResponding = true
        Task {
            await inbox.respondApproval(item, approve: approve, all: all)
            isResponding = false
        }
    }

    private func respondClarification(_ answer: String) {
        guard !isResponding else { return }
        isResponding = true
        freeText = ""
        Task {
            await inbox.respondClarification(item, answer: answer)
            isResponding = false
        }
    }
}
