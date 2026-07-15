import WidgetKit
import SwiftUI

// MARK: - Deep links

/// Deep links into the host app via the `hermesapp://` scheme. Centralised so
/// both widgets stay consistent with the URL scheme registered on the app
/// target (see CONTRACT-WAVE1C.md / project.yml CFBundleURLTypes).
enum HermesWidgetLink {
    static let scheme = "hermesapp"

    /// Opens the app to start a brand-new session.
    static var newSession: URL { URL(string: "\(scheme)://new-session")! }

    /// Opens the app at the default root route.
    static var open: URL { URL(string: "\(scheme)://")! }

    /// Opens the app directly to the pending approvals inbox.
    static var review: URL { URL(string: "\(scheme)://review")! }
}

// MARK: - Timeline entry

/// One timeline entry for the status widget. Wraps the app-group snapshot so
/// the widget renders the last value the app wrote, with graceful placeholders.
struct StatusEntry: TimelineEntry {
    var date: Date
    var snapshot: SharedStore.WidgetSnapshot?

    /// A representative entry for previews / placeholders.
    static let placeholder = StatusEntry(
        date: Date(),
        snapshot: SharedStore.WidgetSnapshot(
            serverScope: "preview", serverRevision: "42", connectionState: .connected,
            openSessionCount: 2, activeTurnCount: 1, pendingAttentionCount: 1,
            tokensToday: 18_400,
            costToday: 0.42, fetchedAt: Date(), writtenAt: Date(), isStale: false
        )
    )
}

// MARK: - Provider

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
        } else {
            completion(StatusEntry(date: Date(), snapshot: SharedStore.readSnapshot()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let now = Date()
        let entry = StatusEntry(date: now, snapshot: SharedStore.readSnapshot())
        // The app calls WidgetCenter.reloadAllTimelines() on state changes; the
        // 15-minute refresh is just a safety net so staleness stays bounded.
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: now) ?? now.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Widget

struct StatusWidget: Widget {
    let kind = "ai.hermes.app.widget.status"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StatusProvider()) { entry in
            StatusWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Hermes Status")
        .description("Connection, active sessions, and pending approvals.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Views

struct StatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StatusEntry

    private var snapshot: SharedStore.WidgetSnapshot? { entry.snapshot }
    private var current: Bool { snapshot?.isEffectivelyStale(at: entry.date) == false }
    private var openSessions: Int { snapshot?.openSessionCount ?? 0 }
    private var activeTurns: Int { snapshot?.activeTurnCount ?? 0 }
    private var pendingAttention: Int { snapshot?.pendingAttentionCount ?? 0 }

    var body: some View {
        switch family {
        case .systemMedium:
            mediumBody
        default:
            smallBody
        }
    }

    private var smallBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Spacer(minLength: 0)
            metric(
                value: "\(openSessions) / \(activeTurns)",
                label: "open / active",
                accessibilityLabel: countsAccessibilityLabel
            )
            if pendingAttention > 0 {
                approvalLine
            } else {
                staleLine
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(pendingAttention > 0 ? HermesWidgetLink.review : HermesWidgetLink.newSession)
    }

    private var mediumBody: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                header
                Spacer(minLength: 0)
                staleLine
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 12) {
                metric(
                    value: "\(openSessions)",
                    label: openSessions == 1 ? "open session" : "open sessions",
                    accessibilityLabel: "\(openSessions) open sessions"
                )
                metric(value: "\(activeTurns)", label: activeTurns == 1 ? "active turn" : "active turns", accessibilityLabel: "\(activeTurns) active turns")
                Link(destination: pendingAttention > 0 ? HermesWidgetLink.review : HermesWidgetLink.open) {
                    if pendingAttention > 0 {
                        approvalLine
                    } else {
                        Label("Up to date", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(HermesWidgetLink.newSession)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .foregroundStyle(.tint)
            Text("Hermes")
                .font(.headline)
            Spacer(minLength: 0)
            Circle()
                .fill(current ? Color.green : Color.secondary)
                .frame(width: 9, height: 9)
                .accessibilityLabel(current ? "Connected" : "Cached or offline")
        }
    }

    private var countsAccessibilityLabel: String {
        guard snapshot != nil else { return "Session counts unavailable" }
        return "\(openSessions) open sessions, \(activeTurns) active turns"
    }

    private func metric(value: String, label: String, accessibilityLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(.title, design: .rounded).weight(.semibold))
                .contentTransition(.numericText())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var approvalLine: some View {
        Label("\(pendingAttention) attention", systemImage: "exclamationmark.triangle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
            .lineLimit(1)
            .accessibilityLabel(
                pendingAttention == 1 ? "1 pending attention item" : "\(pendingAttention) pending attention items"
            )
    }

    private var staleLine: some View {
        Group {
            if let fetchedAt = snapshot?.fetchedAt {
                HStack(spacing: 3) {
                    Text(current ? "Updated" : "Cached · Last updated")
                    Text(fetchedAt, style: .relative)
                }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("No data yet")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

#Preview("Status — small", as: .systemSmall) {
    StatusWidget()
} timeline: {
    StatusEntry.placeholder
    StatusEntry(date: Date(), snapshot: nil)
}

#Preview("Status — medium", as: .systemMedium) {
    StatusWidget()
} timeline: {
    StatusEntry.placeholder
}
