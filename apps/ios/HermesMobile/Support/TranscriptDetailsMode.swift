import Foundation

/// Global transcript detail level (STR-2 / ABH-421 / STR-241). Persisted via
/// `DefaultsKeys.transcriptDetailsMode`. Purely a rendering DEFAULT: it seeds
/// each disclosure's initial collapsed/expanded state wherever one already
/// exists (`ThinkingView`, `ToolActivityRow`) — it never forces a state a user
/// has explicitly toggled. `.normal` preserves today's behavior exactly.
enum TranscriptDetailsMode: String, CaseIterable, Sendable {
    case minimal
    case normal
    case verbose
}

/// The four transcript sections whose visibility can be toggled independently
/// of `TranscriptDetailsMode`. Disabling a section hides its transcript UI but
/// never deletes underlying data (`ChatMessage.parts` stays intact).
enum TranscriptSection: String, CaseIterable, Sendable {
    case thinking
    case tools
    case subagents
    case activity
}

/// Pure mapping from `TranscriptDetailsMode` to a section's default expansion
/// state. Kept free of SwiftUI/UserDefaults so it is trivially unit-testable.
enum TranscriptRenderPolicy {
    /// Whether a `ThinkingView` accordion should default to expanded (absent
    /// any user toggle or live-streaming auto-open, both of which still win).
    static func thinkingDefaultExpanded(mode: TranscriptDetailsMode) -> Bool {
        mode == .verbose
    }

    /// Whether a `ToolActivityRow` should default to expanded (absent any
    /// user toggle).
    static func toolDefaultExpanded(mode: TranscriptDetailsMode) -> Bool {
        mode == .verbose
    }
}
