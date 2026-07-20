import SwiftUI

/// A self-contained approval request card rendered inline in the transcript
/// (ABH-83). Reuses the exact visual content and button semantics of the
/// former floating `ApprovalBanner` so the UI is consistent whether the card
/// is shown inline (normal path) or in any future floating context.
///
/// Displays the approval title, optional description, optional target command,
/// and three response buttons:
///  - Deny  → respondApproval(approve: false, all: false)
///  - Approve → respondApproval(approve: true,  all: false)
///  - Approve all for this turn → respondApproval(approve: true, all: true)
struct ApprovalCard: View {
    /// The pending approval to present.
    let approval: PendingApproval
    /// The chat store that owns the approval response RPC.
    let chatStore: ChatStore

    @Environment(\.hermesTheme) private var theme

    /// True while a response RPC is in flight — disables the buttons so a second
    /// tap can't double-fire (or read as a dead no-op) before the card dismisses.
    /// ABH review P1.
    @State private var isResponding = false

    /// Cap the description scroll so a long approval body never grows the card
    /// past the safe area (R10 parity with the clarify card). ~4 lines at
    /// callout; the rest scrolls inside the card.
    private let descriptionMaxHeight: CGFloat = 108

    var body: some View {
        let request = approval.request
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "lock.shield")
                    .font(.subheadline)
                    .foregroundStyle(theme.midground)
                    .accessibilityHidden(true)
                Text(request.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.fg)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            if let description = request.descriptionText, !description.isEmpty {
                ScrollView {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(theme.fg)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: descriptionMaxHeight)
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
                    respond(approve: false, all: false)
                } label: {
                    Text("Deny").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(theme.destructive)
                .disabled(isResponding)
                .accessibilityHint("Denies this tool request")

                Button {
                    respond(approve: true, all: false)
                } label: {
                    Text("Approve").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.midground)
                .disabled(isResponding)
                .accessibilityHint("Approves this tool request")
            }

            Button {
                respond(approve: true, all: true)
            } label: {
                Text("Approve all for this turn")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.mutedFg)
            .frame(maxWidth: .infinity, alignment: .center)
            .disabled(isResponding)
            .accessibilityLabel("Approve all for this turn")
            .accessibilityHint("Approves every pending tool call in this turn")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .gateCardSurface(theme: theme, cornerRadius: 18)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(theme.border.opacity(0.6), lineWidth: 0.5)
        )
        // R9 parity: dismiss the composer keyboard on appear so the approval
        // card + keyboard + composer never stack (same contract as ClarifyBanner).
        .onAppear { KeyboardDismissal.resign() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tool approval request: \(request.title)")
    }

    private func respond(approve: Bool, all: Bool) {
        isResponding = true
        Task {
            await chatStore.respondApproval(approve: approve, all: all)
            isResponding = false  // re-enable if the card is still up (e.g. RPC failed)
        }
    }
}
