import Foundation

/// Pure, SwiftUI-free helpers that identify files eligible for the viewer's
/// rendered-markdown mode (STR-659 arm A / STR-699).
///
/// Kept isolated from `FileViewerView` so the path heuristic is unit-testable
/// without instantiating SwiftUI views. The actual Source / Rendered / Diff
/// mode model lives in `FileViewerMode`.
enum FileViewerMarkdown {
    /// True for `.md` / `.markdown` paths (case-insensitive extension). Matches
    /// the desktop file viewer's markdown auto-detection so the same files gain
    /// a rendered mode on both surfaces.
    static func isMarkdownPath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }
}
