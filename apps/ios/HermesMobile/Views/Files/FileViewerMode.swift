import Foundation

/// The explicit view modes ``FileViewerView`` can render a text file in.
/// `.rendered` only applies to markdown files; `.diff` only applies when a
/// non-empty unified diff is available for the file (STR-659/STR-701).
enum FileViewerMode: String, CaseIterable, Identifiable, Sendable, Equatable {
    case source
    case rendered
    case diff

    var id: String { rawValue }

    var label: String {
        switch self {
        case .source: return "Source"
        case .rendered: return "Rendered"
        case .diff: return "Diff"
        }
    }

    var systemImage: String {
        switch self {
        case .source: return "doc.plaintext"
        case .rendered: return "doc.richtext"
        case .diff: return "arrow.left.arrow.right"
        }
    }

    /// Auto-selection order matches the desktop client: prefer the diff when
    /// the file has uncommitted changes, otherwise render markdown, otherwise
    /// fall back to raw source. `diffText` is the caller's ALREADY-normalized
    /// (trimmed, nil-if-empty) diff — pass `nil` for a clean file, a non-repo
    /// workspace, or an unavailable/failed diff endpoint; all three fall
    /// through identically (best-effort fetch, never blocks the read).
    static func autoSelect(diffText: String?, isMarkdown: Bool) -> FileViewerMode {
        if diffText != nil { return .diff }
        if isMarkdown { return .rendered }
        return .source
    }

    /// The modes selectable for a given file, in display order. `.source` is
    /// always available for text content; `.rendered` and `.diff` only appear
    /// when applicable so the picker never offers a mode with nothing to show.
    static func availableModes(diffText: String?, isMarkdown: Bool) -> [FileViewerMode] {
        var modes: [FileViewerMode] = [.source]
        if isMarkdown { modes.append(.rendered) }
        if diffText != nil { modes.append(.diff) }
        return modes
    }
}

enum FileViewerModeDetection {
    /// Markdown detection is shared with STR-699's rendered-markdown helper so
    /// the toolbar mode picker and renderer never drift.
    static func isMarkdown(path: String) -> Bool {
        FileViewerMarkdown.isMarkdownPath(path)
    }

    /// Normalize a best-effort diff fetch result: whitespace-only or empty
    /// text (a clean file) collapses to `nil` so callers have one signal for
    /// "no diff to show" regardless of why.
    static func normalizedDiffText(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return raw
    }
}
