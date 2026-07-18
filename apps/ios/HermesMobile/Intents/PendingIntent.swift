import Foundation

/// A request handed from an App Intent (or Siri shortcut) to the running app.
///
/// App Intents run in a separate process and never open a gateway connection.
/// Current invocations enqueue independent rows in ``WorkRepository`` before
/// foregrounding the app. The property-list encoding below is retained only as
/// a one-release migration bridge for requests written by the previous version.
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

    // MARK: - Legacy UserDefaults contract

    private static let kindKey = "kind"
    private static let promptKey = "prompt"

    private static let kindAsk = "ask"
    private static let kindOpenSessions = "openSessions"
    private static let kindNewSession = "newSession"

    /// The dictionary persisted to `UserDefaults`. Plain property-list types only
    /// (`String`), so it round-trips through `UserDefaults` and an App Group with
    /// no transformer.
    var storageValue: [String: String] {
        switch self {
        case .ask(let prompt):
            return [Self.kindKey: Self.kindAsk, Self.promptKey: prompt]
        case .openSessions:
            return [Self.kindKey: Self.kindOpenSessions]
        case .newSession:
            return [Self.kindKey: Self.kindNewSession]
        }
    }

    /// Reconstruct a request from the persisted dictionary, or `nil` if the blob
    /// is absent/malformed. An `ask` with an empty prompt is treated as malformed
    /// (there is nothing to send) and yields `nil`.
    init?(storageValue: [String: String]) {
        guard let kind = storageValue[Self.kindKey] else { return nil }
        switch kind {
        case Self.kindAsk:
            let prompt = (storageValue[Self.promptKey] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { return nil }
            self = .ask(prompt: prompt)
        case Self.kindOpenSessions:
            self = .openSessions
        case Self.kindNewSession:
            self = .newSession
        default:
            return nil
        }
    }

    // MARK: - Persistence

    /// Park a request in the previous version's single-slot handoff.
    ///
    /// New App Intent code must use ``enqueue(in:scope:now:)``. This overwrite-only
    /// API remains solely for retrying/migrating requests created by the old app.
    func park(in defaults: UserDefaults = .standard) {
        defaults.set(storageValue, forKey: DefaultsKeys.pendingIntentPrompt)
    }

    /// Read and clear the parked request atomically (best-effort: `UserDefaults`
    /// has no transaction, but the app drains on the main actor so there is no
    /// concurrent reader). Returns `nil` when nothing is pending.
    static func takePending(from defaults: UserDefaults = .standard) -> PendingIntent? {
        guard let raw = defaults.dictionary(forKey: DefaultsKeys.pendingIntentPrompt) as? [String: String] else {
            // A stale value of the wrong type should not wedge the slot.
            if defaults.object(forKey: DefaultsKeys.pendingIntentPrompt) != nil {
                defaults.removeObject(forKey: DefaultsKeys.pendingIntentPrompt)
            }
            return nil
        }
        defaults.removeObject(forKey: DefaultsKeys.pendingIntentPrompt)
        return PendingIntent(storageValue: raw)
    }


    static func clearPending(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: DefaultsKeys.pendingIntentPrompt)
    }

    static func flushPendingStorage(from defaults: UserDefaults = .standard) {
        _ = defaults.synchronize()
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
