import SwiftUI

extension Date {
    /// Relative label for drawer/session timestamps, with sub-minute granularity
    /// suppressed: anything under a minute reads "now" (the rows tick every 60s,
    /// so it then advances to "1 minute ago", "2 minutes ago", …). Showing live
    /// seconds would need a 1 Hz per-row re-render for no real value, and a 60s
    /// tick would otherwise leave the seconds frozen/stale. (User QA.)
    var sessionRelativeLabel: String {
        if abs(timeIntervalSinceNow) < 60 { return "a moment ago" }
        return formatted(.relative(presentation: .named))
    }
}

// MARK: - Drawer source glyph

/// Drawer-local source presentation: a single SF Symbol per originating client,
/// no label and no capsule (the contract: GLYPH only, `mutedFg`). The drawer is
/// deliberately quieter than a labelled badge.
///
/// Mapping (contract B1): paperplane = telegram, terminal = cli/tui,
/// clock.arrow.circlepath = cron, desktopcomputer = desktop. Anything else
/// falls back to a neutral bubble.
enum DrawerSourceGlyph {
    /// Resolve a wire `source` string to its SF Symbol name.
    static func systemImage(for source: String?) -> String {
        switch source?.lowercased() {
        case "telegram": return "paperplane"
        case "cli", "tui": return "terminal"
        case "cron": return "clock.arrow.circlepath"
        case "desktop": return "desktopcomputer"
        default: return "bubble.left"
        }
    }

    /// Accessibility label for the glyph.
    static func label(for source: String?) -> String {
        switch source?.lowercased() {
        case "telegram": return "Telegram"
        case "cli": return "CLI"
        case "tui": return "TUI"
        case "cron": return "Automation"
        case "desktop": return "Desktop"
        case let other?: return other.capitalized
        case nil: return "Agent"
        }
    }
}

// MARK: - Drawer session row

/// One session row in the drawer list. Hierarchy per the contract:
/// title (15 semibold, `fg`), preview (13, `mutedFg`, **1 line**), relative
/// time (11, `mutedFg`) and a source GLYPH (no message count, no capsule).
///
/// A live-pulse dot (theme `midground`) appears when ``isLive`` is `true` —
/// fed by `SessionStore.isLive(_:)` (a broadcast event for this stored session
/// arrived <10s ago; B3 owns the registry, B1 consumes it).
struct DrawerSessionRow: View {
    @Environment(\.hermesTheme) private var theme

    let summary: SessionSummary
    var isPinned: Bool = false
    var isSelected: Bool = false
    /// Whether a broadcast event for this session landed in the last ~10s.
    var isLive: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Leading: live pulse OR pin marker OR nothing — kept in a fixed-
            // width gutter so titles align whether or not a marker is present.
            // DC-04: animate the transition so pin/live marker changes fade in/out.
            leadingMarker
                .frame(width: 8)
                .animation(.easeInOut(duration: 0.25), value: isLive)
                .animation(.easeInOut(duration: 0.2), value: isPinned)

            VStack(alignment: .leading, spacing: 3) {
                Text(summary.displayHumanTitle)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.fg)
                    .lineLimit(1)

                if let preview = summary.preview, !preview.isEmpty {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(theme.mutedFg)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    if let date = summary.displayDate {
                        // ABH-86 item 4: tick the relative-time label every 60s so
                        // "2m ago" advances to "3m ago" without a new message frame.
                        // TimelineView(.periodic) updates only this subtree; the rest
                        // of the row is unaffected. The context.date is unused — the
                        // Text format closure re-evaluates at each tick automatically
                        // because it closes over the stable `date` value.
                        TimelineView(.periodic(from: .now, by: 60)) { _ in
                            Text(date.sessionRelativeLabel)
                                .font(.caption2)
                                .foregroundStyle(theme.mutedFg)
                        }
                    }
                    Image(systemName: DrawerSourceGlyph.systemImage(for: summary.source))
                        .font(.caption2)
                        .foregroundStyle(theme.mutedFg)
                        .accessibilityLabel(DrawerSourceGlyph.label(for: summary.source))
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(isSelected ? theme.accent.opacity(0.18) : Color.clear)
                // DC-05: animate the selection fill so tapping a row shows a
                // smooth accent fill transition rather than a hard cut. The spring
                // duration (0.25 s) matches the drawer's open/close spring.
                .animation(.spring(response: 0.25, dampingFraction: 0.85), value: isSelected)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        // ABH-85: expose the date + preview as a VoiceOver value so blind users
        // hear "2m ago — last reply text" without needing to navigate into the row.
        .accessibilityValue(accessibilityRowValue)
    }

    /// Builds the VoiceOver value string: relative date + preview snippet.
    /// Both parts are optional; if neither is available the string is empty
    /// and VoiceOver omits the value announcement entirely.
    private var accessibilityRowValue: String {
        var parts: [String] = []
        if let date = summary.displayDate {
            // Same "now"-under-a-minute label the visible row shows (read once at
            // focus time; the TimelineView path handles the periodic refresh).
            parts.append(date.sessionRelativeLabel)
        }
        if let preview = summary.preview, !preview.isEmpty {
            parts.append(preview)
        }
        return parts.joined(separator: " — ")
    }

    @ViewBuilder
    private var leadingMarker: some View {
        if isLive {
            LivePulseDot(color: theme.midground)
                .accessibilityLabel("Live")
                // DC-04: live-pulse dot uses an identity transition so it fades
                // in on appear and out on removal — a .scale+.opacity combination
                // so the dot blooms/pops into/out of existence rather than a hard
                // cut that draws the eye.
                .transition(
                    .asymmetric(
                        insertion: .scale(scale: 0.4).combined(with: .opacity),
                        removal:   .scale(scale: 0.4).combined(with: .opacity)
                    )
                )
        } else if isPinned {
            Image(systemName: "pin.fill")
                .font(.caption2)
                .foregroundStyle(theme.midground)
                .accessibilityLabel("Pinned")
                .transition(.scale(scale: 0.5).combined(with: .opacity))
        } else {
            Color.clear.frame(width: 8, height: 8)
        }
    }
}

// MARK: - Live pulse dot

/// A small dot that gently pulses to signal recent live activity on a stored
/// session. Theme `midground` per the contract. Animation is local and
/// purely decorative (respects Reduce Motion by collapsing to a static dot).
private struct LivePulseDot: View {
    let color: Color

    @State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .scaleEffect(reduceMotion ? 1 : (pulsing ? 1.0 : 0.6))
            .opacity(reduceMotion ? 1 : (pulsing ? 1.0 : 0.45))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
    }
}
