import SwiftUI

/// A compact banner pinned above the composer that alerts the user to a pending
/// approval / clarification in a session OTHER than the one currently open
/// (ABH-83). The OPEN session's prompt is shown inline in the transcript via
/// ``ApprovalCard`` (approvals) / ``ClarifyBanner`` (clarifications); this banner
/// covers the cross-session case so a blocking prompt elsewhere is never silently
/// stranded behind the open chat.
///
/// Behaviour:
/// - **Approvals** can be answered in place — `InboxStore.respondApproval` routes
///   the response to the prompt's OWN runtime (not the active session), so it is
///   safe to act without switching. Tapping the prompt (or "Review") still jumps
///   to that session for full context / Approve-all.
/// - **Clarifications** need their full input UI (choices + free text), so the
///   banner only offers "Answer", which jumps to the session.
/// - Additional pending cross-session items beyond the first surface a
///   "+N more" pill that opens the full Inbox.
///
/// Presentational only: the owner (``ChatView``) resolves the session title,
/// the overflow count, and supplies the action closures.
struct CrossSessionBanner: View {
    let item: InboxStore.Item
    /// Human title of the session the prompt belongs to (resolved by the owner).
    let sessionTitle: String
    /// Count of OTHER pending cross-session items beyond `item` (drives "+N more").
    let extraCount: Int
    /// Jump to the prompt's session for full context.
    let onReview: () -> Void
    /// Approve the prompt in place (routed to its own runtime).
    let onApprove: () -> Void
    /// Deny the prompt in place (routed to its own runtime).
    let onDeny: () -> Void
    /// Open the full Inbox (used by the "+N more" pill).
    let onOpenInbox: () -> Void

    @Environment(\.hermesTheme) private var theme

    /// One-shot guard: the respond closures fire network RPCs owned by the
    /// parent; tapping Deny then Approve within one RTT previously sent BOTH
    /// (ABH-90 ledger parity with ApprovalCard). A fresh banner instance (new
    /// item) naturally resets this.
    @State private var didRespond = false

    private var isApproval: Bool { item.kind == .approval }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header — which session this prompt belongs to + overflow pill.
            HStack(spacing: 6) {
                Image(systemName: isApproval ? "lock.shield" : "questionmark.bubble")
                    .foregroundStyle(theme.midground)
                    .accessibilityHidden(true)
                Text(isApproval ? "Approval in \(sessionTitle)" : "Question in \(sessionTitle)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.mutedFg)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if extraCount > 0 {
                    Button(action: onOpenInbox) {
                        Text("+\(extraCount) more")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(theme.midground.opacity(0.15), in: Capsule())
                            .foregroundStyle(theme.midground)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(extraCount) more pending in inbox")
                }
            }

            // Prompt title + optional supporting line. Tappable → review in context.
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.fg)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(theme.mutedFg)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onReview)
            // The tappable prompt region must be VoiceOver-activatable (an
            // onTapGesture alone is not exposed). ABH review P1.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens the session to respond")
            .accessibilityAction(.default, onReview)

            // Actions.
            HStack(spacing: 8) {
                if isApproval {
                    Button(role: .destructive) {
                        guard !didRespond else { return }
                        didRespond = true
                        onDeny()
                    } label: {
                        Text("Deny").font(.callout)
                    }
                    .buttonStyle(.bordered)
                    .disabled(didRespond)
                    .accessibilityLabel("Deny approval")

                    Button {
                        guard !didRespond else { return }
                        didRespond = true
                        onApprove()
                    } label: {
                        Text("Approve").font(.callout)
                    }
                    .disabled(didRespond)
                    .buttonStyle(.borderedProminent)
                    .tint(theme.midground)
                    .accessibilityLabel("Approve request")
                }
                Spacer(minLength: 0)
                Button(action: onReview) {
                    HStack(spacing: 3) {
                        Text(isApproval ? "Review" : "Answer")
                            .font(.callout.weight(.semibold))
                        Image(systemName: "arrow.right")
                            .font(.caption.weight(.bold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.midground)
                .accessibilityHint("Opens the session to respond with full context")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(theme.border, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }
}
