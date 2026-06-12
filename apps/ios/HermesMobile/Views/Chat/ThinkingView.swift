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

    /// ARCH37 STEP 5 — SUPPRESS THE COLLAPSE ANIMATION ON THE SEED PATH. The
    /// `.animation(value: streaming)` below eases the height change when a turn
    /// settles (`streaming` true -> false). On a SEED OPEN the row is built already-
    /// settled (`streaming == false` from the first render), so a pure seed never
    /// animates — but a row that is seeded WHILE a foreign mirror is mid-settle, or
    /// re-created on the per-session remount (Step 1), could animate a height delta
    /// AFTER first paint (a post-paint contentSize change the open must not see).
    /// This latch suppresses the animation until the view has appeared once: the
    /// FIRST render (the seed paint) is never animated, so the collapsed height is
    /// final at first paint; only a live `streaming` transition AFTER appearance
    /// animates (the watch-it-settle UX during an in-view turn).
    @State private var hasAppeared = false

    /// Auto behavior: open while streaming, collapsed once settled.
    private var autoExpanded: Bool { streaming }

    /// The animation to apply to the settle transition — `nil` (no animation) until
    /// the view has appeared once, so the seed-path first paint lands final.
    private var settleAnimation: Animation? {
        hasAppeared ? .snappy(duration: 0.2) : nil
    }

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
                .animation(settleAnimation, value: streaming)
                .accessibilityHint("Double-tap to expand chain of thought")
        }
        .tint(theme.mutedFg)
        // When the turn settles, animate the auto-collapse so an untouched
        // accordion eases shut rather than snapping. A user who has taken manual
        // control (`userExpanded != nil`) is unaffected — their state is sticky.
        // ARCH37 Step 5: `settleAnimation` is nil until the view has appeared, so
        // the SEED-PATH first paint lands at its final (collapsed) height with no
        // animated height delta — only a live in-view settle animates.
        .animation(settleAnimation, value: streaming)
        .onAppear { hasAppeared = true }
    }
}
