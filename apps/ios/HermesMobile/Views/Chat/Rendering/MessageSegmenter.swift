import Foundation

/// Splits assistant markdown into an ordered list of prose / code / math
/// segments so the bubble can render prose as inline markdown, fenced code in a
/// syntax-aware card, and LaTeX math with a native math view.
///
/// The split is driven by triple-backtick fences (```). An opening fence may
/// carry an info string (the language hint, e.g. ```` ```swift ````); the
/// remainder of the line after the backticks (trimmed) becomes the language.
///
/// While a turn is still streaming the closing fence may not have arrived yet.
/// In that case the unterminated tail is emitted as a `.code` segment so the
/// user sees a code block forming rather than raw backticks in prose — this
/// matches how terminals and other chat clients render streaming code.
enum MessageSegmenter {

    /// A contiguous run of prose, fenced code, or LaTeX math.
    enum Segment: Identifiable, Equatable, Sendable {
        case prose(String)
        case code(language: String?, body: String)
        case math(latex: String, display: Bool)

        /// Stable-enough identity for `ForEach`. The index prefix keeps
        /// otherwise-identical adjacent segments distinct.
        var id: String {
            switch self {
            case .prose(let text):
                return "p:\(text.hashValue)"
            case .code(let language, let body):
                return "c:\(language ?? "")|\(body.hashValue)"
            case .math(let latex, let display):
                return "m:\(display ? "d" : "i")|\(latex.hashValue)"
            }
        }
    }

    /// The fence delimiter. Fences are recognised only at the start of a line
    /// (after optional leading whitespace), matching CommonMark.
    private static let fence = "```"

    /// Segment `text` into prose and code runs.
    ///
    /// - Empty / all-prose input yields a single `.prose` segment (or none if
    ///   the input is empty) — never an empty array for non-empty prose.
    /// - Consecutive fences (an empty code block) yield a `.code` with an
    ///   empty body.
    /// - An unterminated final fence yields a `.code` whose body is the tail.
    static func segments(_ text: String) -> [Segment] {
        guard !text.isEmpty else { return [] }

        var result: [Segment] = []

        // Preserve line structure exactly (including a trailing newline) by
        // splitting on "\n" with empties kept; we re-join with "\n".
        let lines = text.components(separatedBy: "\n")

        var proseLines: [String] = []
        var codeLines: [String] = []
        var inCode = false
        var codeLanguage: String?

        func flushProse() {
            guard !proseLines.isEmpty else { return }
            let body = proseLines.joined(separator: "\n")
            // Drop a run that is purely empty lines between two code blocks so
            // we don't emit blank prose bubbles; keep meaningful whitespace.
            if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(contentsOf: proseAndMathSegments(body))
            }
            proseLines.removeAll(keepingCapacity: true)
        }

        func flushCode() {
            let body = codeLines.joined(separator: "\n")
            result.append(.code(language: codeLanguage, body: body))
            codeLines.removeAll(keepingCapacity: true)
            codeLanguage = nil
        }

        for line in lines {
            if isFenceLine(line) {
                if inCode {
                    // Closing fence.
                    flushCode()
                    inCode = false
                } else {
                    // Opening fence — flush any pending prose first.
                    flushProse()
                    inCode = true
                    codeLanguage = languageHint(from: line)
                }
            } else if inCode {
                codeLines.append(line)
            } else {
                proseLines.append(line)
            }
        }

        // Drain remainders. An open code block at EOF is the streaming tail.
        if inCode {
            flushCode()
        } else {
            flushProse()
        }

        return result
    }

    // MARK: - Fence recognition

    /// True when `line`, ignoring leading whitespace, begins with a fence.
    private static func isFenceLine(_ line: String) -> Bool {
        let trimmed = trimLeadingWhitespace(line)
        return trimmed.hasPrefix(fence)
    }

    /// The info string after an opening fence, normalised to a lowercase
    /// language token, or `nil` when none is present. Only the first token is
    /// used (CommonMark allows trailing info; we ignore it).
    private static func languageHint(from line: String) -> String? {
        let trimmed = trimLeadingWhitespace(line)
        let afterFence = String(trimmed.dropFirst(fence.count))
        let token = afterFence
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ", maxSplits: 1)
            .first
            .map(String.init)?
            .lowercased()
        guard let token, !token.isEmpty else { return nil }
        return token
    }

    private static func trimLeadingWhitespace(_ line: String) -> Substring {
        var index = line.startIndex
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            index = line.index(after: index)
        }
        return line[index...]
    }

    // MARK: - Math recognition

    private struct MathMatch {
        let start: String.Index
        let contentStart: String.Index
        let contentEnd: String.Index
        let end: String.Index
        let display: Bool
    }

    /// Split a prose run further around clear LaTeX math delimiters. This pass is
    /// intentionally conservative for single-dollar math so normal currency prose
    /// remains untouched and streaming tails with unclosed delimiters stay prose.
    private static func proseAndMathSegments(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var cursor = text.startIndex
        var proseStart = cursor

        while cursor < text.endIndex {
            guard let match = mathMatch(in: text, from: cursor) else {
                cursor = text.index(after: cursor)
                continue
            }

            if proseStart < match.start {
                segments.append(.prose(String(text[proseStart..<match.start])))
            }

            let latex = String(text[match.contentStart..<match.contentEnd])
            segments.append(.math(latex: latex, display: match.display))
            cursor = match.end
            proseStart = cursor
        }

        if proseStart < text.endIndex {
            segments.append(.prose(String(text[proseStart..<text.endIndex])))
        }

        return segments
    }

    private static func mathMatch(in text: String, from start: String.Index) -> MathMatch? {
        guard !isEscaped(start, in: text) else { return nil }

        if text[start] == "\\" {
            let next = text.index(after: start)
            guard next < text.endIndex else { return nil }
            if text[next] == "(" {
                return pairedDelimiterMatch(in: text, start: start, openingLength: 2, closing: "\\)", display: false)
            }
            if text[next] == "[" {
                return pairedDelimiterMatch(in: text, start: start, openingLength: 2, closing: "\\]", display: true)
            }
            return nil
        }

        guard text[start] == "$" else { return nil }
        let afterDollar = text.index(after: start)

        if afterDollar < text.endIndex, text[afterDollar] == "$" {
            return dollarDisplayMatch(in: text, start: start)
        }

        return dollarInlineMatch(in: text, start: start)
    }

    private static func pairedDelimiterMatch(
        in text: String,
        start: String.Index,
        openingLength: Int,
        closing: String,
        display: Bool
    ) -> MathMatch? {
        let contentStart = text.index(start, offsetBy: openingLength)
        guard let closeStart = findUnescaped(closing, in: text, from: contentStart) else {
            return nil
        }
        let content = text[contentStart..<closeStart]
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return MathMatch(
            start: start,
            contentStart: contentStart,
            contentEnd: closeStart,
            end: text.index(closeStart, offsetBy: closing.count),
            display: display
        )
    }

    private static func dollarDisplayMatch(in text: String, start: String.Index) -> MathMatch? {
        let contentStart = text.index(start, offsetBy: 2)
        guard contentStart < text.endIndex,
              !text[contentStart].isWhitespace,
              let closeStart = findUnescaped("$$", in: text, from: contentStart)
        else { return nil }

        let content = text[contentStart..<closeStart]
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !containsUnescapedDollar(content)
        else { return nil }

        return MathMatch(
            start: start,
            contentStart: contentStart,
            contentEnd: closeStart,
            end: text.index(closeStart, offsetBy: 2),
            display: true
        )
    }

    private static func dollarInlineMatch(in text: String, start: String.Index) -> MathMatch? {
        let contentStart = text.index(after: start)
        guard contentStart < text.endIndex,
              !text[contentStart].isWhitespace,
              !text[contentStart].isNumber
        else { return nil }

        var cursor = contentStart
        while cursor < text.endIndex {
            if text[cursor] == "$", !isEscaped(cursor, in: text) {
                let content = text[contentStart..<cursor]
                guard isValidInlineDollarContent(content, in: text, closingAt: cursor) else {
                    return nil
                }
                return MathMatch(
                    start: start,
                    contentStart: contentStart,
                    contentEnd: cursor,
                    end: text.index(after: cursor),
                    display: false
                )
            }
            cursor = text.index(after: cursor)
        }

        return nil
    }

    private static func isValidInlineDollarContent(
        _ content: Substring,
        in text: String,
        closingAt close: String.Index
    ) -> Bool {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !content.contains(where: { $0.isNewline }),
              content.last?.isWhitespace != true,
              !containsUnescapedDollar(content)
        else { return false }

        let afterClose = text.index(after: close)
        if afterClose < text.endIndex, text[afterClose].isNumber {
            return false
        }

        return true
    }

    private static func findUnescaped(
        _ needle: String,
        in text: String,
        from start: String.Index
    ) -> String.Index? {
        var cursor = start
        while cursor < text.endIndex {
            if text[cursor...].hasPrefix(needle), !isEscaped(cursor, in: text) {
                return cursor
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    private static func containsUnescapedDollar(_ content: Substring) -> Bool {
        var cursor = content.startIndex
        while cursor < content.endIndex {
            if content[cursor] == "$", !isEscaped(cursor, in: content) {
                return true
            }
            cursor = content.index(after: cursor)
        }
        return false
    }

    private static func isEscaped(_ index: String.Index, in text: String) -> Bool {
        guard index > text.startIndex else { return false }
        var slashCount = 0
        var cursor = text.index(before: index)
        while true {
            if text[cursor] == "\\" {
                slashCount += 1
            } else {
                break
            }
            if cursor == text.startIndex { break }
            cursor = text.index(before: cursor)
        }
        return slashCount % 2 == 1
    }

    private static func isEscaped(_ index: Substring.Index, in text: Substring) -> Bool {
        guard index > text.startIndex else { return false }
        var slashCount = 0
        var cursor = text.index(before: index)
        while true {
            if text[cursor] == "\\" {
                slashCount += 1
            } else {
                break
            }
            if cursor == text.startIndex { break }
            cursor = text.index(before: cursor)
        }
        return slashCount % 2 == 1
    }
}
