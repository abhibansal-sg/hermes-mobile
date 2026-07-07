import Foundation

/// Pure, SwiftUI-free helpers that drive the file viewer's rendered-markdown
/// reading mode (STR-659 arm A / STR-699).
///
/// Kept isolated from `FileViewerView` so the mode-selection contract is
/// unit-testable without instantiating SwiftUI Views, and so the same rules
/// can be reused by any future caller (e.g. a file-list badge) without
/// duplicating the markdown-path heuristic.
enum FileViewerMarkdown {
    /// The two reading modes offered for a markdown file. The toggle is only
    /// surfaced when `defaultViewMode` returns non-`nil` (i.e. the file is
    /// markdown).
    enum ViewMode: String, Equatable, Sendable, CaseIterable {
        case rendered
        case source
    }

    /// True for `.md` / `.markdown` paths (case-insensitive extension). Matches
    /// the desktop file viewer's markdown auto-detection so the same files gain
    /// a rendered mode on both surfaces.
    static func isMarkdownPath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    /// The default reading mode for a file, or `nil` when the file is not
    /// markdown (no rendered/source toggle is offered and the existing
    /// monospaced source path is used unchanged).
    ///
    /// Per STR-659 arm A: a markdown file opens **rendered** when no git diff is
    /// available. When a diff IS available the diff arm owns presentation, so
    /// the mode falls back to `.source` here — the explicit user toggle still
    /// lets the reader reach rendered. Non-markdown files return `nil`.
    static func defaultViewMode(isMarkdown: Bool, isDiffAvailable: Bool) -> ViewMode? {
        guard isMarkdown else { return nil }
        return isDiffAvailable ? .source : .rendered
    }
}
