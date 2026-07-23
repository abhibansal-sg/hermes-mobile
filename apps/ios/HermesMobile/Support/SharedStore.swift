import Foundation

/// Conventions for data shared between the app and its extensions through
/// the `group.ai.hermes.app` app group: widget snapshots and the share-sheet
/// inbox. Extensions and app compile this same file into their targets.
enum SharedStore {
    static let appGroupID = "group.ai.hermes.app"
    static let inboxDidChangeNotification = Notification.Name("SharedStore.inboxDidChange")

    #if DEBUG
    nonisolated(unsafe) static var testDefaults: UserDefaults?
    nonisolated(unsafe) static var testSnapshotURL: URL?
    #endif

    static var defaults: UserDefaults? {
        #if DEBUG
        if let testDefaults { return testDefaults }
        #endif
        return UserDefaults(suiteName: appGroupID)
    }

    static var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        )
    }

    // MARK: - Widget snapshot

    /// Snapshot the app writes and widgets read. Keep flat + Codable-stable.
    struct WidgetSnapshot: Codable, Sendable, Equatable {
        static let currentSchemaVersion = 2
        static let freshnessInterval: TimeInterval = 15 * 60

        enum ConnectionState: String, Codable, Sendable {
            case connected, connecting, offline
        }

        var schemaVersion: Int = currentSchemaVersion
        var serverScope: String?
        var serverRevision: String?
        var connectionState: ConnectionState
        var openSessionCount: Int?
        var activeTurnCount: Int?
        var pendingAttentionCount: Int?
        var tokensToday: Int?
        var costToday: Double?
        var fetchedAt: Date?
        var writtenAt: Date
        var isStale: Bool

        var isRevisionCommitted: Bool {
            guard let revision = serverRevision else { return false }
            return !revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        func isEffectivelyStale(at now: Date = Date()) -> Bool {
            guard !isStale, connectionState == .connected, isRevisionCommitted,
                  let fetchedAt else { return true }
            return now.timeIntervalSince(fetchedAt) > Self.freshnessInterval
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case serverScope = "server_scope"
            case serverRevision = "server_revision"
            case connectionState = "connection_state"
            case openSessionCount = "open_session_count"
            case activeTurnCount = "active_turn_count"
            case pendingAttentionCount = "pending_attention_count"
            case tokensToday = "tokens_today"
            case costToday = "cost_today"
            case fetchedAt = "fetched_at"
            case writtenAt = "written_at"
            case isStale = "is_stale"
        }
    }

    static let snapshotKey = "hermes.widgetSnapshot"
    static let snapshotFilename = "widget-snapshot-v2.json"

    static var snapshotURL: URL? {
        #if DEBUG
        if let testSnapshotURL { return testSnapshotURL }
        #endif
        return containerURL?.appendingPathComponent(snapshotFilename, isDirectory: false)
    }

    static func readSnapshot() -> WidgetSnapshot? {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    static func clearSnapshot() {
        defaults?.removeObject(forKey: snapshotKey)
        if let url = snapshotURL { try? FileManager.default.removeItem(at: url) }
    }

    static func notifyInboxDidChange() {
        NotificationCenter.default.post(name: inboxDidChangeNotification, object: nil)
    }
}
