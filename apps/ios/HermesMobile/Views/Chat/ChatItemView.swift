import SwiftUI

// Wave-2 render-lane seam (docs/RELAY-PHONE-PROTOCOL.md §2/§7). MessageBubble
// routes every `.item` ChatMessagePart here. This is the SKELETON the render
// lane fleshes out: it renders a correct, if minimal, card for each special
// item type today so the mock harness previews and the app compiles. The render
// lane replaces the per-type bodies with the full special renders (generic tool
// card, diff view, inline image, browser snapshot, error banner) WITHOUT
// changing this dispatch surface.

/// The render-dispatch seam the render lane implements: given a fully-resolved
/// `ChatItem`, produce its SwiftUI view. Keeping this a protocol lets the render
/// lane swap in a richer renderer (or a test double) without touching
/// `MessageBubble`.
protocol ChatItemRendering {
    associatedtype Content: View
    @MainActor @ViewBuilder func view(for item: ChatItem) -> Content
}

/// Default renderer used by `ChatItemView`. The render lane extends/replaces the
/// per-type branches; the switch is the contract, the bodies are placeholders.
struct DefaultChatItemRenderer: ChatItemRendering {
    @MainActor
    func view(for item: ChatItem) -> some View {
        ChatItemView(item: item)
    }
}

/// Skeleton view for a Wave-2 item-backed part. Dispatches on `item.type`.
struct ChatItemView: View {
    @Environment(\.hermesTheme) private var theme
    let item: ChatItem

    var body: some View {
        switch item.type {
        case .toolCall, .fileChange, .image, .browser:
            genericCard
        case .error:
            errorCard
        // Text-shaped kinds never reach here — `ChatItem.renderPart` projects
        // `agentMessage`/`reasoning`/`usage`/`userMessage` onto legacy parts.
        // Rendered defensively as the generic card if one ever does.
        case .agentMessage, .reasoning, .usage, .userMessage:
            genericCard
        }
    }

    // MARK: - Placeholder renders (render lane replaces these)

    /// Collapsed generic tool card: name + status + one-line summary (§2). Covers
    /// ALL current + future tools by construction — the forward-compat backbone.
    private var genericCard: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: statusSymbol)
                .font(.caption)
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.toolName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.cardFg)
                if let summary = item.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(theme.mutedFg)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.toolName), \(item.status.rawValue)")
    }

    /// Error item — never hidden in a collapse (§2).
    private var errorCard: some View {
        Label {
            Text(item.summary ?? item.textBody)
                .font(.caption)
                .foregroundStyle(theme.statusError)
        } icon: {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(theme.statusError)
        }
        .padding(8)
        .background(theme.statusError.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var statusSymbol: String {
        switch item.status {
        case .inProgress: return "circle.dashed"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .inProgress: return theme.mutedFg
        case .completed: return theme.statusOK
        case .failed: return theme.statusError
        }
    }
}
