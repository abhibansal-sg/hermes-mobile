import SwiftUI

/// A dependency-free, regex-driven syntax highlighter that turns a code string
/// into a monospaced `AttributedString` with semantic colouring.
///
/// Design goals:
/// - **No third-party deps.** Pure `NSRegularExpression` + Foundation.
/// - **Fast.** One compiled regex set per language, built lazily and cached
///   for the process lifetime. Highlighting a block is a handful of regex
///   passes, not a tokeniser.
/// - **Readable in light and dark.** Colours come from `UIColor`-backed
///   `Color`s chosen to keep contrast in both appearances.
///
/// The highlighter is intentionally approximate: it favours speed and "good
/// enough" colouring over a true grammar. Later rules win where ranges
/// overlap, so the rule order per language matters (comments and strings are
/// applied last so they override keyword/number colouring inside them).
enum SyntaxHighlighter {

    // MARK: - Public API

    /// Highlight `code` for `language` (case-insensitive; aliases resolved).
    /// Unknown or `nil` languages fall back to plain monospaced text.
    ///
    /// `baseColor` is the un-highlighted text colour (punctuation, identifiers,
    /// and everything not matched by a rule). It is routed from `theme.fg` so the
    /// code base tone tracks the active theme; the semantic role colours
    /// (keyword/string/number/type/comment) stay system-semantic this round.
    /// Defaults to the system label colour for non-themed callers.
    static func highlight(_ code: String, language: String?, baseColor: Color = Theme.plain) -> AttributedString {
        var attributed = AttributedString(code)
        attributed.font = .system(.body, design: .monospaced)
        attributed.foregroundColor = baseColor

        guard
            let language,
            let resolved = Language(alias: language),
            let rules = ruleCache.rules(for: resolved)
        else {
            return attributed
        }

        let ns = code as NSString
        let full = NSRange(location: 0, length: ns.length)

        for rule in rules {
            rule.regex.enumerateMatches(in: code, options: [], range: full) { match, _, _ in
                guard let match else { return }
                let range = rule.captureGroup.map { match.range(at: $0) } ?? match.range
                guard range.location != NSNotFound, range.length > 0 else { return }
                guard let stringRange = Range(range, in: attributed) else { return }
                attributed[stringRange].foregroundColor = rule.color
            }
        }

        return attributed
    }

    /// Whether a language token maps to a supported highlighter (used by the UI
    /// to decide if a language badge is "known").
    static func isSupported(_ language: String?) -> Bool {
        guard let language else { return false }
        return Language(alias: language) != nil
    }

    // MARK: - Theme

    /// Semantic colours. `UIColor` lets each role adapt across light/dark; the
    /// hand-tuned RGB variants keep code legible on both the card background
    /// and `textSelection` highlights.
    enum Theme {
        static let plain = Color(uiColor: .label)
        static let keyword = Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.78, green: 0.58, blue: 0.98, alpha: 1) // soft purple
                : UIColor(red: 0.52, green: 0.20, blue: 0.78, alpha: 1)
        })
        static let string = Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.99, green: 0.58, blue: 0.45, alpha: 1) // warm orange
                : UIColor(red: 0.78, green: 0.20, blue: 0.10, alpha: 1) // red
        })
        static let comment = Color(uiColor: .secondaryLabel)
        static let number = Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.45, green: 0.74, blue: 0.99, alpha: 1) // light blue
                : UIColor(red: 0.13, green: 0.36, blue: 0.78, alpha: 1)
        })
        static let type = Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.40, green: 0.82, blue: 0.74, alpha: 1) // teal
                : UIColor(red: 0.10, green: 0.50, blue: 0.45, alpha: 1)
        })
    }

    // MARK: - Languages

    /// Highlightable languages. Aliases (e.g. `ts`, `zsh`) resolve here.
    enum Language: Hashable {
        case swift, python, javascript, typescript, bash, json, yaml, go, rust, sql, html, css

        init?(alias: String) {
            switch alias.lowercased() {
            case "swift": self = .swift
            case "python", "py": self = .python
            case "javascript", "js", "jsx", "mjs", "cjs": self = .javascript
            case "typescript", "ts", "tsx": self = .typescript
            case "bash", "sh", "zsh", "shell", "console": self = .bash
            case "json", "jsonc", "json5": self = .json
            case "yaml", "yml": self = .yaml
            case "go", "golang": self = .go
            case "rust", "rs": self = .rust
            case "sql": self = .sql
            case "html", "xml", "htm": self = .html
            case "css", "scss": self = .css
            default: return nil
            }
        }
    }

    // MARK: - Rules

    /// A single highlight pass: a compiled regex, the colour to apply, and an
    /// optional capture-group index (when only part of the match should be
    /// coloured, e.g. the type name after a keyword).
    struct Rule {
        let regex: NSRegularExpression
        let color: Color
        let captureGroup: Int?

        init?(_ pattern: String, _ color: Color, group: Int? = nil, options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
            self.regex = regex
            self.color = color
            self.captureGroup = group
        }
    }

    /// Per-language compiled-rule cache, populated lazily and reused for the
    /// process lifetime. `NSCache` keeps it thread-safe without locking.
    private final class RuleCache: @unchecked Sendable {
        private let cache = NSCache<NSString, RuleBox>()

        func rules(for language: Language) -> [Rule]? {
            let key = String(describing: language) as NSString
            if let box = cache.object(forKey: key) { return box.rules }
            let built = SyntaxHighlighter.buildRules(for: language)
            cache.setObject(RuleBox(built), forKey: key)
            return built
        }
    }

    private final class RuleBox {
        let rules: [Rule]
        init(_ rules: [Rule]) { self.rules = rules }
    }

    private static let ruleCache = RuleCache()

    // MARK: - Rule construction

    /// Shared building blocks. Order is significant: numbers/keywords first,
    /// then strings, then comments — so a `//` inside a string is not recoloured
    /// as a comment, and a keyword inside a comment ends up comment-coloured.
    private static func buildRules(for language: Language) -> [Rule] {
        switch language {
        case .swift:
            return compactRules([
                numberRule(),
                keywordRule(swiftKeywords),
                typeRule(),
                doubleQuotedStringRule(),
                lineCommentRule("//"),
                blockCommentRule()
            ])
        case .python:
            return compactRules([
                numberRule(),
                keywordRule(pythonKeywords),
                pythonStringRule(),
                lineCommentRule("#")
            ])
        case .javascript, .typescript:
            let keywords = language == .typescript ? typescriptKeywords : javascriptKeywords
            return compactRules([
                numberRule(),
                keywordRule(keywords),
                typeRule(),
                jsStringRule(),
                lineCommentRule("//"),
                blockCommentRule()
            ])
        case .bash:
            return compactRules([
                keywordRule(bashKeywords),
                bashVariableRule(),
                singleQuotedStringRule(),
                doubleQuotedStringRule(),
                lineCommentRule("#")
            ])
        case .json:
            return compactRules([
                numberRule(),
                jsonKeyRule(),
                jsonLiteralRule(),
                doubleQuotedStringRule()
            ])
        case .yaml:
            return compactRules([
                numberRule(),
                yamlKeyRule(),
                yamlLiteralRule(),
                doubleQuotedStringRule(),
                singleQuotedStringRule(),
                lineCommentRule("#")
            ])
        case .go:
            return compactRules([
                numberRule(),
                keywordRule(goKeywords),
                typeRule(),
                doubleQuotedStringRule(),
                backtickStringRule(),
                lineCommentRule("//"),
                blockCommentRule()
            ])
        case .rust:
            return compactRules([
                numberRule(),
                keywordRule(rustKeywords),
                typeRule(),
                doubleQuotedStringRule(),
                lineCommentRule("//"),
                blockCommentRule()
            ])
        case .sql:
            return compactRules([
                numberRule(),
                keywordRule(sqlKeywords, options: [.caseInsensitive]),
                singleQuotedStringRule(),
                lineCommentRule("--"),
                blockCommentRule()
            ])
        case .html:
            return compactRules([
                Rule("</?[A-Za-z][A-Za-z0-9-]*", Theme.keyword),
                Rule("\\b([A-Za-z-]+)(?==)", Theme.type, group: 1),
                doubleQuotedStringRule(),
                singleQuotedStringRule(),
                Rule("<!--[\\s\\S]*?-->", Theme.comment)
            ])
        case .css:
            return compactRules([
                numberRule(),
                Rule("([.#]?[A-Za-z_][\\w-]*)(?=\\s*\\{)", Theme.type, group: 1),
                Rule("\\b([a-z-]+)(?=\\s*:)", Theme.keyword, group: 1),
                doubleQuotedStringRule(),
                singleQuotedStringRule(),
                blockCommentRule()
            ])
        }
    }

    private static func compactRules(_ rules: [Rule?]) -> [Rule] {
        rules.compactMap { $0 }
    }

    // MARK: - Generic rule factories

    private static func numberRule() -> Rule? {
        Rule("\\b0[xXbBoO][0-9A-Fa-f_]+\\b|\\b\\d[\\d_]*(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b", Theme.number)
    }

    private static func keywordRule(_ keywords: [String], options: NSRegularExpression.Options = []) -> Rule? {
        let escaped = keywords.map { NSRegularExpression.escapedPattern(for: $0) }
        let pattern = "\\b(?:\(escaped.joined(separator: "|")))\\b"
        return Rule(pattern, Theme.keyword, options: options)
    }

    /// Capitalised identifiers → treated as type names. Cheap heuristic shared
    /// by the C-family / Swift / Go / Rust grammars.
    private static func typeRule() -> Rule? {
        Rule("\\b[A-Z][A-Za-z0-9_]*\\b", Theme.type)
    }

    private static func doubleQuotedStringRule() -> Rule? {
        Rule("\"(?:[^\"\\\\\\n]|\\\\.)*\"", Theme.string)
    }

    private static func singleQuotedStringRule() -> Rule? {
        Rule("'(?:[^'\\\\\\n]|\\\\.)*'", Theme.string)
    }

    private static func backtickStringRule() -> Rule? {
        Rule("`[^`]*`", Theme.string)
    }

    /// JS/TS strings: double, single, and template literals.
    private static func jsStringRule() -> Rule? {
        Rule("\"(?:[^\"\\\\\\n]|\\\\.)*\"|'(?:[^'\\\\\\n]|\\\\.)*'|`(?:[^`\\\\]|\\\\.)*`", Theme.string)
    }

    /// Python strings incl. triple-quoted blocks.
    private static func pythonStringRule() -> Rule? {
        Rule("\"\"\"[\\s\\S]*?\"\"\"|'''[\\s\\S]*?'''|\"(?:[^\"\\\\\\n]|\\\\.)*\"|'(?:[^'\\\\\\n]|\\\\.)*'", Theme.string)
    }

    private static func lineCommentRule(_ token: String) -> Rule? {
        let escaped = NSRegularExpression.escapedPattern(for: token)
        return Rule("\(escaped).*", Theme.comment)
    }

    private static func blockCommentRule() -> Rule? {
        Rule("/\\*[\\s\\S]*?\\*/", Theme.comment)
    }

    private static func bashVariableRule() -> Rule? {
        Rule("\\$\\{?[A-Za-z_][A-Za-z0-9_]*\\}?|\\$[0-9@*#?$!-]", Theme.type)
    }

    private static func jsonKeyRule() -> Rule? {
        Rule("\"(?:[^\"\\\\\\n]|\\\\.)*\"(?=\\s*:)", Theme.type)
    }

    private static func jsonLiteralRule() -> Rule? {
        Rule("\\b(?:true|false|null)\\b", Theme.keyword)
    }

    private static func yamlKeyRule() -> Rule? {
        Rule("(?m)^\\s*-?\\s*([A-Za-z_][\\w-]*)(?=\\s*:)", Theme.type, group: 1)
    }

    private static func yamlLiteralRule() -> Rule? {
        Rule("\\b(?:true|false|null|yes|no|on|off|~)\\b", Theme.keyword, options: [.caseInsensitive])
    }

    // MARK: - Keyword tables

    private static let swiftKeywords = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import",
        "init", "inout", "internal", "let", "open", "operator", "private", "precedencegroup",
        "protocol", "public", "rethrows", "static", "struct", "subscript", "typealias", "var",
        "actor", "async", "await", "throws", "throw", "try", "break", "case", "continue", "default",
        "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return",
        "switch", "where", "while", "as", "is", "nil", "self", "Self", "super", "true", "false",
        "any", "some", "nonisolated", "isolated", "mutating", "nonmutating", "weak", "unowned",
        "lazy", "final", "override", "convenience", "required", "indirect"
    ]

    private static let pythonKeywords = [
        "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class",
        "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global",
        "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return",
        "try", "while", "with", "yield", "match", "case", "self", "cls"
    ]

    private static let javascriptKeywords = [
        "var", "let", "const", "function", "return", "if", "else", "for", "while", "do", "switch",
        "case", "default", "break", "continue", "new", "delete", "typeof", "instanceof", "void",
        "this", "super", "class", "extends", "import", "export", "from", "as", "async", "await",
        "yield", "try", "catch", "finally", "throw", "true", "false", "null", "undefined", "in", "of"
    ]

    private static let typescriptKeywords = javascriptKeywords + [
        "interface", "type", "enum", "namespace", "declare", "abstract", "implements", "public",
        "private", "protected", "readonly", "keyof", "infer", "is", "satisfies", "override"
    ]

    private static let bashKeywords = [
        "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac",
        "function", "in", "select", "return", "break", "continue", "local", "export", "readonly",
        "declare", "set", "unset", "echo", "exit", "source", "alias", "shift"
    ]

    private static let goKeywords = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
        "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range",
        "return", "select", "struct", "switch", "type", "var", "nil", "true", "false", "iota",
        "make", "new", "len", "cap", "append"
    ]

    private static let rustKeywords = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
        "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move",
        "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true",
        "type", "unsafe", "use", "where", "while", "union"
    ]

    private static let sqlKeywords = [
        "select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create",
        "table", "drop", "alter", "add", "column", "index", "view", "join", "inner", "left", "right",
        "outer", "full", "on", "group", "by", "order", "having", "limit", "offset", "distinct",
        "as", "and", "or", "not", "null", "is", "in", "like", "between", "union", "all", "exists",
        "case", "when", "then", "else", "end", "primary", "key", "foreign", "references", "default",
        "constraint", "unique", "count", "sum", "avg", "min", "max", "asc", "desc", "with", "returning"
    ]
}
