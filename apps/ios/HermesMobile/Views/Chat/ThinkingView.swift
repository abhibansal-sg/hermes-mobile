import SwiftUI

/// Disclosure of an assistant turn's private reasoning, rendered IN WIRE
/// POSITION (the order `MessageBubble` lays out `message.parts`) — never pinned
/// to the top (ABH-87 Batch D / contract §3.3, desktop `ReasoningAccordionGroup`).
///
/// AUTO-OPEN / AUTO-COLLAPSE: while the turn is `streaming` the accordion opens
/// itself so the user watches the chain of thought live; when the turn settles
/// it collapses back to the quiet "Thinking…" label so a long reasoning block
/// never dominates a finished transcript. The FIRST explicit user toggle wins —
/// once the reader has opened or closed it by hand, the streaming-driven default
/// stops overriding their choice (desktop thread.tsx:344-351). The body is
/// scrollable and capped so even an open block stays bounded.
///
/// Rendered only when `thinking` is non-empty.
struct ThinkingView: View {
    /// The accumulated reasoning text for the turn.
    let thinking: String
    /// Whether the owning turn is still streaming. Drives the auto-open default
    /// until the user takes manual control. Defaults to `false` so existing call
    /// sites / previews render the calm collapsed state unchanged.
    var streaming: Bool = false

    @Environment(\.hermesTheme) private var theme

    /// The effective expansion state. `nil` means "no explicit user choice yet,
    /// follow the streaming-driven default"; a non-nil value is the user's own
    /// toggle, which from then on wins over the default (desktop first-toggle-wins).
    @State private var userExpanded: Bool?

    /// Auto behavior: open while streaming, collapsed once settled.
    private var autoExpanded: Bool { streaming }

    /// Binding the DisclosureGroup drives: reads the user's choice when set, else
    /// the streaming default; a write is always an explicit user toggle, so it
    /// latches `userExpanded` and the default no longer applies.
    private var isExpanded: Binding<Bool> {
        Binding(
            get: { userExpanded ?? autoExpanded },
            set: { userExpanded = $0 }
        )
    }

    var body: some View {
        DisclosureGroup(isExpanded: isExpanded) {
            ScrollView {
                Text(thinking)
                    .font(.caption)
                    .italic()
                    .foregroundStyle(theme.mutedFg)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            .frame(maxHeight: 240)
        } label: {
            // VC-07: label is "Thinking" (settled) / "Thinking…" (streaming).
            // CC-08: animate the label transition so "Thinking…" eases to
            // "Thinking" when the turn settles rather than cutting.
            Label(streaming ? "Thinking…" : "Thinking", systemImage: "brain")
                .font(.caption)
                .italic()
                .foregroundStyle(theme.mutedFg)
                .animation(.snappy(duration: 0.2), value: streaming)
                .accessibilityHint("Double-tap to expand chain of thought")
        }
        .tint(theme.mutedFg)
        // When the turn settles, animate the auto-collapse so an untouched
        // accordion eases shut rather than snapping. A user who has taken manual
        // control (`userExpanded != nil`) is unaffected — their state is sticky.
        .animation(.snappy(duration: 0.2), value: streaming)
    }
}
