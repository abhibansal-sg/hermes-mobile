import Foundation

enum ThinkingDisplay {
    private static let statusPrefixPattern =
        #"(?i)^(?:\S{1,16}\s+)?(?:processing|thinking|reasoning|analyzing|pondering|contemplating|musing|cogitating|ruminating|deliberating|mulling|reflecting|computing|synthesizing|formulating|brainstorming)(?:\.{3}|…)\s*"#

    private static let placeholderPattern =
        #"(?i)^(?:current\s+rewritten\s+thinking|next\s+thinking\s+to\s+process|rewritten\s+thinking|thinking\s+to\s+process)\.?\s*$"#

    private static let statusPrefixRegex = try? NSRegularExpression(pattern: statusPrefixPattern)
    private static let placeholderRegex = try? NSRegularExpression(pattern: placeholderPattern)

    static func cleanedText(_ text: String) -> String {
        let cleanedLines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { stripStatusPrefix(String($0)) }

        let cleaned = cleanedLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !matchesPlaceholder(cleaned) else { return "" }
        return cleaned
    }

    static func activeStepText(from cleanedText: String) -> String {
        cleanedText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last(where: { !$0.isEmpty })
            ?? "Thinking…"
    }

    static func elapsedText(startedAt: Date?, now: Date) -> String {
        guard let startedAt else { return "0s" }
        let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
        return durationText(seconds: seconds)
    }

    static func settledLabel(duration: TimeInterval?) -> String {
        guard let duration else { return "Thinking" }
        return "Thought for \(durationText(seconds: max(0, Int(duration))))"
    }

    private static func durationText(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    private static func stripStatusPrefix(_ line: String) -> String {
        guard let statusPrefixRegex else { return line }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return statusPrefixRegex
            .stringByReplacingMatches(in: line, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func matchesPlaceholder(_ text: String) -> Bool {
        guard let placeholderRegex else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return placeholderRegex.firstMatch(in: text, range: range) != nil
    }
}
