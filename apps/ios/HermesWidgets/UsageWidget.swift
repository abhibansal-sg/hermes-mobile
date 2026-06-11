import WidgetKit
import SwiftUI

// MARK: - Timeline entry

/// Timeline entry for the usage widget: today's token + cost totals from the
/// shared app-group snapshot.
struct UsageEntry: TimelineEntry {
    var date: Date
    var snapshot: SharedStore.WidgetSnapshot?

    static let placeholder = UsageEntry(
        date: Date(),
        snapshot: SharedStore.WidgetSnapshot(
            connected: true,
            activeSessions: 1,
            pendingApprovals: 0,
            tokensToday: 18_400,
            costTodayUSD: 0.42,
            updatedAt: Date()
        )
    )
}

// MARK: - Provider

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
        } else {
            completion(UsageEntry(date: Date(), snapshot: SharedStore.readSnapshot()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let now = Date()
        let entry = UsageEntry(date: now, snapshot: SharedStore.readSnapshot())
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: now) ?? now.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Widget

struct UsageWidget: Widget {
    let kind = "ai.hermes.app.widget.usage"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Hermes Usage")
        .description("Today's token usage and estimated cost.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - View

struct UsageWidgetView: View {
    let entry: UsageEntry

    private var snapshot: SharedStore.WidgetSnapshot? { entry.snapshot }

    private var tokensText: String {
        guard let tokens = snapshot?.tokensToday else { return "—" }
        return Self.tokenFormatter.string(from: NSNumber(value: tokens)) ?? "\(tokens)"
    }

    private var costText: String {
        guard let cost = snapshot?.costTodayUSD else { return "—" }
        return Self.costFormatter.string(from: NSNumber(value: cost)) ?? String(format: "$%.2f", cost)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.fill")
                    .foregroundStyle(.tint)
                Text("Today")
                    .font(.headline)
                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 0) {
                Text(tokensText)
                    .font(.system(.title, design: .rounded).weight(.semibold))
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("tokens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                Text(costText)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                Text("est.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(HermesWidgetLink.open)
    }

    private static let tokenFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    private static let costFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = 2
        return f
    }()
}

#Preview("Usage — small", as: .systemSmall) {
    UsageWidget()
} timeline: {
    UsageEntry.placeholder
    UsageEntry(date: Date(), snapshot: nil)
}
