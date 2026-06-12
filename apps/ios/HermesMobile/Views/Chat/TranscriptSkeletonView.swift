import SwiftUI

/// Theme-consistent transcript placeholder shown on a CACHE-MISS session open
/// (WhatsApp bar — "never white"). The transcript area used to be a bare
/// `ProgressView` over a white void for the 2.5–4s network fetch; this renders a
/// few alternating user/assistant skeleton bubbles instead, so an open that has
/// no cached content reads as "content arriving" rather than a blank screen.
///
/// Design language matches the drawer's `sessionSkeletonRows`: STATIC muted bars
/// (`theme.mutedFg` at low opacity), no shimmer animation — deterministic by
/// construction (no timers, no animation that could regress the smoothness work).
/// A cache HIT never reaches this view: the cached transcript is painted as the
/// first frame, so this is exclusively the cold/uncached-open interim.
struct TranscriptSkeletonView: View {
    let theme: HermesTheme

    /// Staggered (alignment, line-widths) tuples shaped like a real exchange:
    /// short user turns on the trailing edge, longer assistant paragraphs on the
    /// leading edge. Fixed so the skeleton is deterministic.
    private static let bubbles: [(isUser: Bool, lines: [CGFloat])] = [
        (true, [180]),
        (false, [240, 220, 140]),
        (true, [120]),
        (false, [230, 250, 200, 90]),
    ]

    var body: some View {
        VStack(spacing: 18) {
            ForEach(Array(Self.bubbles.enumerated()), id: \.offset) { _, bubble in
                bubbleRow(isUser: bubble.isUser, lines: bubble.lines)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func bubbleRow(isUser: Bool, lines: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 7) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, w in
                    RoundedRectangle(cornerRadius: 5)
                        // User bars sit a touch stronger (they read as a filled
                        // bubble); assistant bars are lighter (inline text).
                        .fill(theme.mutedFg.opacity(isUser ? 0.16 : 0.12))
                        .frame(width: w, height: 12)
                }
            }
            .padding(isUser ? 12 : 0)
            .background(
                Group {
                    if isUser {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(theme.userBubble.opacity(0.35))
                    }
                }
            )
            if !isUser { Spacer(minLength: 40) }
        }
    }
}
