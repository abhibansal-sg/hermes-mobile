import AppIntents
import Foundation

// MARK: - Ask Hermes

/// "Ask Hermes …" — the headline intent. Takes a free-text `prompt`, parks an
/// ``PendingIntent/ask(prompt:)`` request, and opens the app, which creates a
/// fresh session and submits the prompt.
///
/// `openAppWhenRun` brings the app to the foreground; the actual session
/// creation + send happens app-side in ``PendingIntentRouter`` on the next
/// active scene phase, so the intent never opens its own gateway connection.
struct AskHermesIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Hermes"
    static let description = IntentDescription(
        "Start a new Hermes session with a question and send it.",
        categoryName: "Sessions"
    )

    /// Foreground the app so the parked prompt is drained and the user sees the
    /// streaming reply.
    static let openAppWhenRun = true

    @Parameter(
        title: "Prompt",
        description: "What you want to ask Hermes.",
        requestValueDialog: "What should I ask Hermes?"
    )
    var prompt: String

    /// Written summary shown in the Shortcuts editor.
    static var parameterSummary: some ParameterSummary {
        Summary("Ask Hermes \(\.$prompt)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppIntentError.emptyPrompt
        }
        PendingIntent.ask(prompt: trimmed).park()
        return .result()
    }
}

// MARK: - Open Sessions

/// "Open Hermes sessions" — foregrounds the app and shows the session list.
struct OpenSessionsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Hermes Sessions"
    static let description = IntentDescription(
        "Open Hermes to your list of sessions.",
        categoryName: "Sessions"
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingIntent.openSessions.park()
        return .result()
    }
}

// MARK: - New Session

/// "New Hermes session" — foregrounds the app and opens a fresh LOCAL draft chat
/// ready for input, exactly like the in-app "New chat" / desktop Cmd+N. No server
/// session is created up front: the draft materializes on the first prompt, so
/// running this intent and never typing leaves NO orphaned empty session behind
/// (User decision 3 — local-draft parity). Because a draft needs no gateway, the
/// intent works even while disconnected.
struct NewSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "New Hermes Session"
    static let description = IntentDescription(
        "Start a new, empty Hermes session.",
        categoryName: "Sessions"
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingIntent.newSession.park()
        return .result()
    }
}

// MARK: - Errors

/// Surfaced to Shortcuts/Siri when an intent cannot proceed.
enum AppIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case emptyPrompt

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .emptyPrompt:
            return "Please provide something to ask Hermes."
        }
    }
}
