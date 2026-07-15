import SwiftUI

// MARK: - Diff model (STR-659/STR-701)

/// One rendered row of a parsed unified diff.
struct DiffLine: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case added
        case removed
        case context
        /// A visual break between hunks. Carries no text — the noisy raw
        /// `@@ -a,b +c,d @@` syntax is stripped; the surrounding old/new line
        /// numbers on the lines around it keep the numbering understandable.
        case hunkBreak
    }

    let id: Int
    let kind: Kind
    let oldLineNumber: Int?
    let newLineNumber: Int?
    let text: String
}

/// Parses a unified diff (as returned by `git diff` / `git diff --no-color`)
/// into displayable ``DiffLine``s, dropping the noisy file-header preamble
/// (`diff --git`, `index`, `---`, `+++`, mode/rename metadata) that a git diff
/// carries but which reads as clutter in a single-file viewer that already
/// shows the file name in the navigation title.
enum DiffParser {
    private static let hunkHeaderPrefix = "@@"

    static func parse(_ raw: String) -> [DiffLine] {
        var result: [DiffLine] = []
        var oldLine = 0
        var newLine = 0
        var sawHunk = false
        var nextID = 0

        func appendLine(_ kind: DiffLine.Kind, old: Int?, new: Int?, text: String) {
            result.append(DiffLine(id: nextID, kind: kind, oldLineNumber: old, newLineNumber: new, text: text))
            nextID += 1
        }

        for rawLine in raw.components(separatedBy: "\n") {
            if rawLine.hasPrefix(hunkHeaderPrefix) {
                if let hunk = parseHunkHeader(rawLine) {
                    if sawHunk {
                        appendLine(.hunkBreak, old: nil, new: nil, text: "")
                    }
                    oldLine = hunk.oldStart
                    newLine = hunk.newStart
                    sawHunk = true
                }
                continue
            }
            guard sawHunk else {
                // Preamble before the first hunk (diff --git / index / ---/+++
                // / mode changes / binary-file notices) — noise, drop it.
                continue
            }
            if isFileHeaderNoise(rawLine) { continue }

            if rawLine.hasPrefix("+") {
                appendLine(.added, old: nil, new: newLine, text: String(rawLine.dropFirst()))
                newLine += 1
            } else if rawLine.hasPrefix("-") {
                appendLine(.removed, old: oldLine, new: nil, text: String(rawLine.dropFirst()))
                oldLine += 1
            } else if rawLine.hasPrefix("\\") {
                // "\ No newline at end of file" — informational, not a real line.
                continue
            } else {
                let text = rawLine.hasPrefix(" ") ? String(rawLine.dropFirst()) : rawLine
                appendLine(.context, old: oldLine, new: newLine, text: text)
                oldLine += 1
                newLine += 1
            }
        }
        return result
    }

    private struct HunkHeader { let oldStart: Int; let newStart: Int }

    /// Parses `@@ -oldStart,oldCount +newStart,newCount @@ optional-context`.
    /// The count fields are optional in the unified format (implied `1`), and
    /// only the START of each range is needed to seed the running counters.
    private static func parseHunkHeader(_ line: String) -> HunkHeader? {
        // Isolate the two "@@ ... @@" markers' payload: "-a,b +c,d".
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3,
              parts[0] == "@@",
              let oldStart = startValue(from: parts[1], prefix: "-"),
              let newStart = startValue(from: parts[2], prefix: "+")
        else { return nil }
        return HunkHeader(oldStart: oldStart, newStart: newStart)
    }

    private static func startValue(from token: Substring, prefix: Character) -> Int? {
        guard token.first == prefix else { return nil }
        let body = token.dropFirst()
        let startText = body.split(separator: ",", maxSplits: 1).first ?? body
        return Int(startText)
    }

    /// Lines that belong to the file-header block a `diff --git` hunk MAY
    /// repeat before subsequent hunks in a multi-hunk hunk-header-only diff
    /// (rare, but tolerate it defensively): `---`/`+++` file markers.
    private static func isFileHeaderNoise(_ line: String) -> Bool {
        line.hasPrefix("--- ") || line.hasPrefix("+++ ")
    }
}

// MARK: - View

/// Renders a parsed unified diff as colored, line-numbered rows — added lines
/// tinted with `theme.statusOK`, removed with `theme.destructive`, context
/// neutral. Mirrors the monospaced, horizontally-scrollable idiom of
/// ``FileViewerView``'s source mode.
struct FileDiffView: View {
    let diffText: String

    @Environment(\.hermesTheme) private var theme

    private var lines: [DiffLine] { DiffParser.parse(diffText) }

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    row(line)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.bg)
        .accessibilityIdentifier("fileViewerDiff")
    }

    @ViewBuilder
    private func row(_ line: DiffLine) -> some View {
        switch line.kind {
        case .hunkBreak:
            Divider()
                .overlay(theme.border)
                .padding(.vertical, 6)
        case .added, .removed, .context:
            HStack(alignment: .top, spacing: 0) {
                lineNumber(line.oldLineNumber)
                lineNumber(line.newLineNumber)
                Text(marker(for: line.kind) + line.text)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(textColor(for: line.kind))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
            }
            .padding(.vertical, 1)
            .background(background(for: line.kind))
        }
    }

    private func lineNumber(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(theme.mutedFg)
            .frame(width: 34, alignment: .trailing)
    }

    private func marker(for kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: return "+ "
        case .removed: return "- "
        case .context: return "  "
        case .hunkBreak: return ""
        }
    }

    private func textColor(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: return theme.statusOK
        case .removed: return theme.destructive
        case .context: return theme.fg
        case .hunkBreak: return theme.mutedFg
        }
    }

    private func background(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: return theme.statusOK.opacity(0.12)
        case .removed: return theme.destructive.opacity(0.12)
        case .context, .hunkBreak: return .clear
        }
    }
}
