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
    private static let liveWindowHeight: CGFloat = 172
    private static let liveWindowBottomID = "thinking-live-window-bottom"
    private static let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// The accumulated reasoning text for the turn.
    let thinking: String
    /// Whether the owning turn is still streaming. Drives the auto-open default
    /// until the user takes manual control. Defaults to `false` so existing call
    /// sites / previews render the calm collapsed state unchanged.
    var streaming: Bool = false
    /// The owning turn's existing start timestamp from ``ChatStore.turnStartedAt``.
    /// Used only for the live elapsed label; settled labels use the duration
    /// stamped onto the message at completion before the store clears that start.
    var liveTurnStartedAt: Date?
    /// Settled duration captured by ``ChatStore`` from the same turn start.
    var settledDuration: TimeInterval?

    @Environment(\.hermesTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    @State private var pulse = false
    @State private var now = Date()
    @State private var liveScrollTarget: String? = Self.liveWindowBottomID

    /// Auto behavior: open while streaming, collapsed once settled.
    private var autoExpanded: Bool { streaming }

    /// The animation to apply to the settle transition — `nil` (no animation) until
    /// the view has appeared once, so the seed-path first paint lands final.
    private var settleAnimation: Animation? {
        hasAppeared ? .snappy(duration: 0.2) : nil
    }

    /// Binding the DisclosureGroup drives: reads the user's choice when set, else
    /// the streaming default. A write only latches `userExpanded` when it CROSSES
    /// the current default (a deliberate tap) — an echo write equal to the default
    /// (which SwiftUI emits while animating a binding-driven group, notably on the
    /// streaming→settled transition) clears the override instead, so a settled
    /// section always auto-collapses rather than getting pinned open.
    private var isExpanded: Binding<Bool> {
        Binding(
            get: { ThinkingDisplay.expansionResolved(userOverride: userExpanded, streaming: autoExpanded) },
            set: { userExpanded = ThinkingDisplay.expansionOverride(forWrite: $0, streaming: autoExpanded) }
        )
    }

    private var cleanedThinking: String {
        ThinkingDisplay.cleanedText(thinking)
    }

    private var activeStepText: String {
        ThinkingDisplay.activeStepText(from: cleanedThinking)
    }

    private var liveElapsedText: String {
        ThinkingDisplay.elapsedText(startedAt: liveTurnStartedAt, now: now)
    }

    var body: some View {
        DisclosureGroup(isExpanded: isExpanded) {
            thinkingBody
        } label: {
            thinkingLabel
        }
        .tint(theme.mutedFg)
        .onReceive(Self.tick) { now = $0 }
        .onAppear {
            hasAppeared = true
            liveScrollTarget = Self.liveWindowBottomID
            guard streaming, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .onChange(of: streaming) { _, isStreaming in
            liveScrollTarget = Self.liveWindowBottomID
            if isStreaming, !reduceMotion {
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            } else {
                pulse = false
            }
        }
    }

    @ViewBuilder
    private var thinkingLabel: some View {
        if streaming {
            HStack(spacing: 8) {
                Text(activeStepText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 12)
                Text(liveElapsedText)
                    .monospacedDigit()
                    .fontDesign(.monospaced)
                    .foregroundStyle(theme.midground.opacity(0.55))
            }
            .font(.caption)
            .italic()
            .foregroundStyle(theme.mutedFg)
            .opacity(reduceMotion ? 1.0 : (pulse ? 1.0 : 0.55))
            .brightness(reduceMotion ? 0 : (pulse ? 0.06 : 0))
            .accessibilityHint("Double-tap to expand chain of thought")
        } else {
            Text(ThinkingDisplay.settledLabel(duration: settledDuration))
                .font(.caption)
                .italic()
                .monospacedDigit()
                .foregroundStyle(theme.mutedFg)
                .accessibilityHint("Double-tap to expand chain of thought")
        }
    }

    @ViewBuilder
    private var thinkingBody: some View {
        if streaming {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        bodyText
                        Color.clear
                            .frame(height: 1)
                            .id(Self.liveWindowBottomID)
                    }
                    .scrollTargetLayout()
                }
                .scrollPosition(id: $liveScrollTarget, anchor: .bottom)
                .frame(height: Self.liveWindowHeight)
                .mask(alignment: .top) {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.16),
                            .init(color: .black, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .accessibilityIdentifier("thinkingLiveWindow")
                .onAppear {
                    liveScrollTarget = Self.liveWindowBottomID
                    proxy.scrollTo(Self.liveWindowBottomID, anchor: .bottom)
                }
                .onChange(of: cleanedThinking) { _, _ in
                    liveScrollTarget = Self.liveWindowBottomID
                    proxy.scrollTo(Self.liveWindowBottomID, anchor: .bottom)
                }
            }
        } else {
            ScrollView {
                bodyText
            }
            .frame(maxHeight: 240)
        }
    }

    private var bodyText: some View {
        Text(cleanedThinking)
            .font(.caption)
            .italic()
            .foregroundStyle(theme.mutedFg)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }
}
