import SwiftUI

/// A `usage` item (docs/RELAY-PHONE-PROTOCOL.md §2) — the turn footer carrying
/// `message.complete.usage`. Rendered as one quiet caption line (tokens · cost ·
/// context), matching the legacy `.usage` footer, with an optional context-window
/// meter when the relay stamped the last prompt's occupancy.
///
/// In the render mapping a `usage` item whose stats decode projects onto the
/// legacy `.usage` part; this view is the render-lane renderer for that data and
/// the fallback when a `usage` item arrives without decodable stats.
struct UsageFooterView: ChatItemContentView {
    let item: ChatItem

    @Environment(\.hermesTheme) private var theme

    init(item: ChatItem) {
        self.item = item
    }

    private var stats: UsageStats? { item.usageStats }

    var body: some View {
        if let stats, let line = Self.usageLine(stats), !line.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(line)
                    .font(.caption2)
                    .foregroundStyle(theme.mutedFg)
                if let percent = stats.contextPercent {
                    contextMeter(percent: percent)
                }
            }
            .padding(.top, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Usage: \(line)")
            .accessibilityIdentifier("usageFooter")
        }
    }

    /// A thin context-window occupancy bar: fills `percent`% of its width with the
    /// brand accent over a muted track. Purely informational; hidden by the
    /// caller when the server sent no occupancy.
    private func contextMeter(percent: Int) -> some View {
        let clamped = min(max(percent, 0), 100)
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.muted)
                Capsule()
                    .fill(theme.midground)
                    .frame(width: proxy.size.width * CGFloat(clamped) / 100)
            }
        }
        .frame(height: 3)
        .frame(maxWidth: 200)
        .accessibilityHidden(true)
    }

    /// "N tokens · $C · ctx K" — the same compact line the legacy footer shows.
    /// `nonisolated static` so tests pin the format without a view. Returns nil
    /// when there is nothing worth showing.
    nonisolated static func usageLine(_ usage: UsageStats) -> String? {
        var parts: [String] = []
        if let total = usage.total ?? combinedTokens(usage) {
            parts.append("\(total) tokens")
        }
        if let cost = usage.costUsd {
            parts.append(String(format: "$%.4f", cost))
        }
        if let ctx = usage.contextUsed {
            parts.append("ctx \(UsageStats.formatK(ctx))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private nonisolated static func combinedTokens(_ usage: UsageStats) -> Int? {
        guard usage.input != nil || usage.output != nil else { return nil }
        return (usage.input ?? 0) + (usage.output ?? 0)
    }
}

#if DEBUG
#Preview("Usage footer") {
    VStack(alignment: .leading, spacing: 12) {
        UsageFooterView(item: ChatItem(
            itemID: "u1", type: .usage, status: .completed, ord: 0,
            body: ["usage": ["input": 1200, "output": 340, "total": 1540,
                             "cost_usd": 0.012, "context_used": 1540,
                             "context_max": 128000, "context_percent": 12]]
        ))
        UsageFooterView(item: ChatItem(
            itemID: "u2", type: .usage, status: .completed, ord: 1,
            body: ["usage": ["input": 800, "output": 200]]
        ))
    }
    .padding()
}
#endif
