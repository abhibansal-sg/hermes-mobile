import AppIntents

/// Registers the App Shortcuts that surface Hermes intents to Siri and the
/// Shortcuts app with zero user setup.
///
/// Phrases MUST include `\(.applicationName)` (Apple requirement) — the system
/// substitutes the app's display name ("Hermes"). Keep the count at or under the
/// system limit (10) and lead each intent with its most natural phrase.
struct HermesShortcuts: AppShortcutsProvider {
    /// Tinted color of the shortcut tiles in the Shortcuts app.
    static let shortcutTileColor: ShortcutTileColor = .navy

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskHermesIntent(),
            // A `String` parameter cannot be embedded in an App Shortcut phrase
            // (only AppEntity/AppEnum types may be) — the prompt is collected via
            // the intent's `requestValueDialog` when the shortcut runs instead.
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) a question",
                "Send a prompt to \(.applicationName)",
            ],
            shortTitle: "Ask Hermes",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: NewSessionIntent(),
            phrases: [
                "New \(.applicationName) session",
                "Start a new \(.applicationName) session",
            ],
            shortTitle: "New Session",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: OpenSessionsIntent(),
            phrases: [
                "Open \(.applicationName) sessions",
                "Show my \(.applicationName) sessions",
            ],
            shortTitle: "Open Sessions",
            systemImageName: "list.bullet"
        )
    }
}
