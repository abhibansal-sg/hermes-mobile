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

    /// Quick-capture entry point (text optional).
    static func capture(text: String? = nil) -> URL {
        guard let text, !text.isEmpty,
              let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return URL(string: "\(scheme)://capture")!
        }
        return URL(string: "\(scheme)://capture?text=\(encoded)")!
    }
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
            connected: true,
            activeSessions: 2,
            pendingApprovals: 1,
            tokensToday: 18_400,
            costTodayUSD: 0.42,
            updatedAt: Date()
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
    private var connected: Bool { snapshot?.connected ?? false }
    private var activeSessions: Int { snapshot?.activeSessions ?? 0 }
    private var pendingApprovals: Int { snapshot?.pendingApprovals ?? 0 }

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
                value: "\(activeSessions)",
                label: activeSessions == 1 ? "session" : "sessions",
                accessibilityLabel: activeSessionsAccessibilityLabel
            )
            if pendingApprovals > 0 {
                approvalLine
            } else {
                staleLine
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(pendingApprovals > 0 ? HermesWidgetLink.review : HermesWidgetLink.newSession)
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
                    value: "\(activeSessions)",
                    label: activeSessions == 1 ? "active session" : "active sessions",
                    accessibilityLabel: activeSessionsAccessibilityLabel
                )
                Link(destination: pendingApprovals > 0 ? HermesWidgetLink.review : HermesWidgetLink.open) {
                    if pendingApprovals > 0 {
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
                .fill(connected ? Color.green : Color.secondary)
                .frame(width: 9, height: 9)
                .accessibilityLabel(connected ? "Connected" : "Offline")
        }
    }

    private var activeSessionsAccessibilityLabel: String {
        guard snapshot != nil else { return "Active sessions unavailable" }
        return activeSessions == 1 ? "1 active session" : "\(activeSessions) active sessions"
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
        Label("\(pendingApprovals) pending", systemImage: "exclamationmark.triangle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
            .lineLimit(1)
            .accessibilityLabel(
                pendingApprovals == 1 ? "1 pending approval" : "\(pendingApprovals) pending approvals"
            )
    }

    private var staleLine: some View {
        Group {
            if let updatedAt = snapshot?.updatedAt {
                Text(updatedAt, style: .relative)
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
