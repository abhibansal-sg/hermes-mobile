import Foundation

/// Pure, UI-free logic for the composer's `@`-file mention affordance
/// (Module F4A-A1). Kept separate from ``MentionPicker`` so the trigger
/// detection and token insertion are unit-testable without a view.
///
/// CHOSEN REPRESENTATION (per the F4A contract / integration-gate item 5): a
/// selected file lands in the composer as an inline plain-text token
/// `@file:<path>` directly in the message buffer — NOT a separate attributed
/// chip model. The composer's existing single `@State text` is preserved; the
/// mention flow only edits that string. This keeps the wire contract trivial
/// (the agent reads `@file:` tokens at send) and the buffer assertion the gate
/// makes ("a `@file:<path>` token lands in the composer buffer") literal.
enum MentionCompletion {

    /// An active `@`-mention being typed: the range of the trigger word in the
    /// buffer (from the `@` to the cursor) and the query text after the `@`.
    struct ActiveMention: Equatable {
        /// The character range covering `@` … cursor, in the full text. Replaced
        /// wholesale when a candidate is chosen.
        let range: Range<String.Index>
        /// The text after the `@` (what we send to `complete.path` as the query,
        /// prefixed with `@` on the wire).
        let query: String
    }

    /// Characters that terminate an `@`-mention word. A mention runs from the
    /// `@` up to (but not including) the first whitespace/newline — paths with
    /// `/`, `.`, `-`, `_` are part of the word.
    private static let terminators = CharacterSet.whitespacesAndNewlines

    /// Detect an in-progress `@`-mention ending at the cursor.
    ///
    /// The cursor is modeled as the END of `text` (the composer appends and the
    /// picker fires off `onChange(of: text)`, so the live edit is always at the
    /// tail). We scan backward from the end to the most recent `@` that begins a
    /// mention word; if any terminator (space/newline) intervenes, there is no
    /// active mention. The `@` must be at the start of the buffer or preceded by
    /// whitespace (so an email `a@b` does not trigger).
    static func activeMention(in text: String) -> ActiveMention? {
        guard !text.isEmpty else { return nil }
        // Walk back from the end collecting the trailing non-terminator run.
        var index = text.endIndex
        while index > text.startIndex {
            let prior = text.index(before: index)
            let char = text[prior]
            if char == "@" {
                // Found the `@`. Validate the char before it is a boundary.
                if prior == text.startIndex {
                    return mention(text: text, atSign: prior)
                }
                let before = text[text.index(before: prior)]
                if before.unicodeScalars.allSatisfy(terminators.contains) {
                    return mention(text: text, atSign: prior)
                }
                // `@` glued to a non-boundary (e.g. an email) — not a mention.
                return nil
            }
            if char.unicodeScalars.contains(where: terminators.contains) {
                // Hit whitespace before any `@` — no active mention.
                return nil
            }
            index = prior
        }
        return nil
    }

    private static func mention(text: String, atSign: String.Index) -> ActiveMention {
        let queryStart = text.index(after: atSign)
        let query = String(text[queryStart..<text.endIndex])
        return ActiveMention(range: atSign..<text.endIndex, query: query)
    }

    /// The `word` argument to send to the `complete.path` RPC for a given query.
    /// The contract: for an @-file picker send `word = "@" + query` (the server
    /// expands `@file:`/`@folder:` context tokens).
    static func completionWord(for query: String) -> String {
        "@" + query
    }

    /// Replace the active mention's range with the chosen file token. The token
    /// is `@file:<path>` followed by a trailing space so the user keeps typing
    /// after it. Returns the new full buffer text.
    ///
    /// `path` is the `text` field of the chosen ``PathCompletionItem`` — the
    /// server already strips any `@file:` prefix internally, but we defensively
    /// strip a leading `@file:`/`@folder:`/`@` so a double prefix can't occur.
    static func insert(
        path: String,
        replacing mention: ActiveMention,
        in text: String
    ) -> String {
        let token = "@file:" + normalizedPath(path) + " "
        var result = text
        result.replaceSubrange(mention.range, with: token)
        return result
    }

    /// Append a `@file:<path>` token to the end of the composer buffer — used by
    /// the file VIEWER / browser "@" button, where there is no in-progress typed
    /// mention to replace (unlike ``insert(path:replacing:in:)``). A separating
    /// space is added only when the buffer is non-empty and does not already end
    /// in whitespace, and a trailing space lets the user keep typing after the
    /// token. Same one-deep `@file:` normalization as ``insert``.
    static func appendMention(path: String, to text: String) -> String {
        let token = "@file:" + normalizedPath(path) + " "
        if text.isEmpty {
            return token
        }
        let needsSeparator = !(text.hasSuffix(" ") || text.hasSuffix("\n"))
        return text + (needsSeparator ? " " : "") + token
    }

    /// Strip a leading `@file:` / `@folder:` / bare `@` from a completion `text`
    /// so the inserted token is exactly one `@file:` prefix deep.
    static func normalizedPath(_ raw: String) -> String {
        var value = raw
        for prefix in ["@file:", "@folder:", "@"] {
            if value.hasPrefix(prefix) {
                value = String(value.dropFirst(prefix.count))
                break
            }
        }
        return value
    }
}
