import Foundation

/// Splits assistant markdown into an ordered list of prose / code segments so
/// the bubble can render prose as inline markdown and code in a syntax-aware
/// card.
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

    /// A contiguous run of either prose or fenced code.
    enum Segment: Identifiable, Equatable, Sendable {
        case prose(String)
        case code(language: String?, body: String)

        /// Stable-enough identity for `ForEach`. The index prefix keeps
        /// otherwise-identical adjacent segments distinct.
        var id: String {
            switch self {
            case .prose(let text):
                return "p:\(text.hashValue)"
            case .code(let language, let body):
                return "c:\(language ?? "")|\(body.hashValue)"
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
                result.append(.prose(body))
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
}
