import Foundation

/// A request handed from an App Intent (or Siri shortcut) to the running app.
///
/// App Intents run in a separate process and never open a gateway connection.
/// Invocations enqueue independent rows in ``WorkRepository`` before
/// foregrounding the app.
enum PendingIntent: Equatable, Sendable {
    /// Open the app to a brand-new session with `prompt` prefilled and sent.
    case ask(prompt: String)
    /// Open the app to the session list (no session activated).
    case openSessions
    /// Open the app and immediately create a new, empty session.
    case newSession

    var workKind: WorkIntentKind {
        switch self {
        case .ask: .askHermes
        case .openSessions: .openSessions
        case .newSession: .newSession
        }
    }

    var promptText: String? {
        if case .ask(let prompt) = self { return prompt }
        return nil
    }

    /// Durable handoff used by the App Intents process. Every invocation gets a
    /// separate stable job/client id; no networking occurs in the extension.
    @discardableResult
    func enqueue(
        in repository: WorkRepository,
        scope: WorkScope? = nil,
        now: Date = Date()
    ) async throws -> WorkJob {
        try await repository.enqueueAppIntent(
            kind: workKind,
            text: promptText,
            scope: scope,
            now: now
        )
    }

}

struct GatewayCleanupTombstone: Codable, Equatable, Sendable {
    let server: String
    let deviceId: String?
    var remoteRetryNeeded = false
    /// Set when a re-pair to `server` under a NEW device supersedes the forget:
    /// the local cache-suppression is void (cached content for the re-paired
    /// server always paints at cold-open), and only the best-effort remote
    /// revoke of the OLD `deviceId` remains owed. Absent from tombstones written
    /// by older builds — decoded as `false` via ``init(from:)`` below.
    var supersededByRepair = false
}

extension GatewayCleanupTombstone {
    private enum CodingKeys: String, CodingKey {
        case server, deviceId, remoteRetryNeeded, supersededByRepair
    }

    // Tolerant decode so a tombstone persisted by an older build (which has no
    // `supersededByRepair` / `remoteRetryNeeded` key) still decodes instead of
    // being silently dropped — a dropped tombstone would forfeit the owed remote
    // revoke. Keeping this in an extension preserves the synthesized memberwise
    // initializer and the synthesized `Encodable`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        server = try container.decode(String.self, forKey: .server)
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId)
        remoteRetryNeeded = try container.decodeIfPresent(Bool.self, forKey: .remoteRetryNeeded) ?? false
        supersededByRepair = try container.decodeIfPresent(Bool.self, forKey: .supersededByRepair) ?? false
    }
}
