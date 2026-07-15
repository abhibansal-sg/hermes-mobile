import Foundation

/// A request handed from an App Intent (or Siri shortcut) to the running app.
///
/// App Intents run in a *separate* execution context from the SwiftUI app and
/// must stay lightweight — they do not open their own gateway connection. Instead
/// each intent records what the user asked for in `UserDefaults` and then brings
/// the app to the foreground. The app drains the pending request on the next
/// `scenePhase == .active` transition (see ``PendingIntentRouter``).
///
/// The encoding is intentionally a tiny, stable JSON blob (not `Codable` of a
/// richer type) so the App Intents extension and the app agree on a shape that
/// can never fail to decode across versions: a `kind` discriminator plus an
/// optional `prompt`.
enum PendingIntent: Equatable, Sendable {
    /// Open the app to a brand-new session with `prompt` prefilled and sent.
    case ask(prompt: String)
    /// Open the app to the session list (no session activated).
    case openSessions
    /// Open the app and immediately create a new, empty session.
    case newSession

    // MARK: - UserDefaults contract

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

    /// Park this request in `defaults`, overwriting any earlier pending request.
    ///
    /// "Last write wins": if the user fires two shortcuts back to back before the
    /// app foregrounds, only the most recent is honored — which matches the user's
    /// intent (they re-asked) and keeps the drain a single step.
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
}
