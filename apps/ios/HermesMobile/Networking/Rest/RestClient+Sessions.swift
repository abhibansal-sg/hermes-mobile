import Foundation

// Session-management REST endpoints (search / rename / archive / export).
//
// These are true ``RestClient`` extension members: they reuse the shared
// `makeRequest`/`get`/`perform`/`decode` plumbing from `RestClient.swift` (loopback
// `Host: 127.0.0.1` override, `X-Hermes-Session-Token` auth, 15s timeout, and
// ``RestError`` mapping) rather than duplicating it. ``SessionStore`` calls them
// through the active connection's ``RestClient`` (`ConnectionStore.rest`).
//
// ``SessionSearchResult`` declares explicit snake_case `CodingKeys`, so its decode
// passes `strategy: .useDefaultKeys` to skip the global snake-case conversion that
// would otherwise double-transform the keys.

// MARK: - Search result

/// One row from `GET /api/sessions/search` (`results[]`).
///
/// The server groups FTS5 matches by session and returns the best snippet per
/// session, so each `id` is unique. `snippet` may carry SQLite `<b>…</b>` match
/// markers, which ``plainSnippet`` strips for display.
struct SessionSearchResult: Decodable, Identifiable, Sendable, Equatable {
    /// `session_id` — also the stable identity for `ForEach`.
    let id: String
    let snippet: String?
    let role: String?
    let source: String?
    let model: String?
    /// Session start time (epoch seconds), when the server includes it.
    let sessionStarted: Double?

    private enum CodingKeys: String, CodingKey {
        case id = "session_id"
        case snippet, role, source, model
        case sessionStarted = "session_started"
    }

    /// Snippet with FTS5 `<b>…</b>` highlight markers removed and newlines
    /// collapsed — safe to drop straight into a `Text`.
    var plainSnippet: String {
        guard let snippet, !snippet.isEmpty else { return "" }
        return snippet
            .replacingOccurrences(of: "<b>", with: "")
            .replacingOccurrences(of: "</b>", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `true` when the raw snippet reads as structured content (JSON object/array
    /// or a code-ish line) rather than prose. The drawer renders structured
    /// snippets monospaced and prose snippets in the normal face (R1: "monospace
    /// ONLY for structured content").
    var snippetIsStructured: Bool {
        let s = plainSnippet
        guard !s.isEmpty else { return false }
        let opensObject = s.hasPrefix("{") || s.hasPrefix("[")
        // Heuristic: a JSON-ish body has both a quoted key and a colon.
        let looksKeyed = s.contains("\":") || s.contains("\": ")
        return opensObject && looksKeyed
    }

    /// A display-ready excerpt for the drawer row. Prose snippets are stripped of
    /// JSON noise (braces, quotes, key prefixes) so the matched text reads as a
    /// plain sentence (R1); structured snippets are returned verbatim (rendered
    /// monospaced by the row). Always single-line and trimmed.
    var displaySnippet: String {
        let plain = plainSnippet
        guard !plain.isEmpty else { return "" }
        guard !snippetIsStructured else { return plain }
        return Self.stripJSONNoise(from: plain)
    }

    /// Strip JSON structural noise from a prose excerpt: leading/trailing braces
    /// and brackets, a leading `"key":` prefix, wrapping double quotes, escaped
    /// quotes, and collapsed whitespace. Conservative — only touches obvious
    /// JSON scaffolding so genuine prose is untouched.
    static func stripJSONNoise(from text: String) -> String {
        var s = text
        // Drop a leading `"some_key":` (optionally with surrounding braces).
        if let range = s.range(
            of: #"^[\{\[\s]*"[A-Za-z0-9_\-\.]+"\s*:\s*"#,
            options: .regularExpression
        ) {
            s.removeSubrange(range)
        }
        // Trim residual outer structural characters and quotes.
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "{}[]\"' \t"))
        // Unescape the common JSON escapes that survive into a value excerpt.
        s = s
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\t", with: " ")
            .replacingOccurrences(of: "\\/", with: "/")
        // Collapse any run of whitespace introduced by the above.
        s = s.replacingOccurrences(
            of: #"\s{2,}"#, with: " ", options: .regularExpression
        )
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var startedDate: Date? {
        guard let sessionStarted else { return nil }
        return Date(timeIntervalSince1970: sessionStarted)
    }

    /// A run of snippet text and whether it is the matched (to-be-emphasised)
    /// term. The drawer row turns these into an `AttributedString`, keeping all
    /// SwiftUI styling (`theme.midground`, `.footnote`) in the view layer so this
    /// networking model stays Foundation-only.
    struct SnippetSegment: Equatable, Sendable {
        let text: String
        let isMatch: Bool
    }

    /// Split the display excerpt into plain / matched segments for the drawer row
    /// (R1: "the matched query term bolded").
    ///
    /// Preference order:
    ///  1. FTS5 `<b>…</b>` markers in the raw snippet — the server already knows
    ///     the exact matched span, so we honour it (and strip JSON noise around
    ///     it for prose snippets).
    ///  2. A case-insensitive match of `query` against the cleaned excerpt, when
    ///     the server omitted markers.
    ///  3. A single plain segment (no emphasis).
    func snippetSegments(query: String) -> [SnippetSegment] {
        // Path 1: honour server FTS markers when present.
        if let snippet, snippet.contains("<b>") {
            let marked = Self.cleanedMarkedSnippet(
                from: snippet, structured: snippetIsStructured
            )
            return Self.segments(fromMarked: marked)
        }
        // Path 2/3: clean excerpt, optionally splitting on the query term.
        let excerpt = displaySnippet
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !excerpt.isEmpty, !trimmedQuery.isEmpty,
              let range = excerpt.range(of: trimmedQuery, options: .caseInsensitive) else {
            return excerpt.isEmpty ? [] : [SnippetSegment(text: excerpt, isMatch: false)]
        }
        var segments: [SnippetSegment] = []
        let before = String(excerpt[excerpt.startIndex..<range.lowerBound])
        if !before.isEmpty { segments.append(SnippetSegment(text: before, isMatch: false)) }
        segments.append(SnippetSegment(text: String(excerpt[range]), isMatch: true))
        let after = String(excerpt[range.upperBound...])
        if !after.isEmpty { segments.append(SnippetSegment(text: after, isMatch: false)) }
        return segments
    }

    /// Normalize a raw FTS-marked snippet for display: collapse newlines and,
    /// for prose, strip the JSON scaffolding while keeping the `<b>…</b>` markers
    /// intact so the caller can still locate the matched span.
    private static func cleanedMarkedSnippet(
        from raw: String, structured: Bool
    ) -> String {
        let normalized = raw.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !structured else { return normalized }
        // Reuse the prose JSON-stripper; the angle-bracket markers are not in its
        // strip set, so they survive.
        var cleaned = normalized
        if let range = cleaned.range(
            of: #"^[\{\[\s]*"[A-Za-z0-9_\-\.]+"\s*:\s*"#,
            options: .regularExpression
        ) {
            cleaned.removeSubrange(range)
        }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "{}[] \t"))
        return cleaned
    }

    /// Split a (cleaned) FTS-marked snippet into plain / matched segments by
    /// pairing `<b>…</b>` markers.
    private static func segments(fromMarked marked: String) -> [SnippetSegment] {
        var result: [SnippetSegment] = []
        var remainder = Substring(marked)
        func appendPlain(_ s: String) {
            guard !s.isEmpty else { return }
            result.append(SnippetSegment(text: s, isMatch: false))
        }
        while let open = remainder.range(of: "<b>") {
            appendPlain(String(remainder[remainder.startIndex..<open.lowerBound]))
            remainder = remainder[open.upperBound...]
            guard let close = remainder.range(of: "</b>") else {
                appendPlain(String(remainder))
                return result
            }
            let matched = String(remainder[remainder.startIndex..<close.lowerBound])
            if !matched.isEmpty { result.append(SnippetSegment(text: matched, isMatch: true)) }
            remainder = remainder[close.upperBound...]
        }
        appendPlain(String(remainder))
        return result
    }

    /// Build a minimal ``SessionSummary`` so a tapped search result can be opened
    /// through the normal `SessionStore.open(_:)` path without a second fetch.
    /// The snippet becomes the preview; title/count fill in on the next refresh.
    var asSessionSummary: SessionSummary {
        SessionSummary(
            id: id,
            title: nil,
            preview: plainSnippet.isEmpty ? nil : plainSnippet,
            startedAt: sessionStarted,
            messageCount: nil,
            source: source,
            lastActive: nil,
            cwd: nil
        )
    }
}

// MARK: - Endpoints

extension RestClient {
    /// `GET /api/sessions/search?q=&limit=&scope=` — FTS5 search over message
    /// content.
    ///
    /// Returns one result per matching session (best snippet). Queries shorter
    /// than two characters are answered locally with an empty array, matching the
    /// debounced UI contract and avoiding a pointless round-trip.
    ///
    /// `scope` narrows by message role (a stock server before this param ignores
    /// it and returns the `all` behavior, so it degrades safely):
    /// `all` (every role + session-id matches), `messages` (user + assistant
    /// prose), `code` (tool output / structured results).
    func searchSessions(
        query: String, limit: Int = 20, scope: String = "all"
    ) async throws -> [SessionSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "scope", value: scope),
        ]
        let encodedQuery = components.percentEncodedQuery ?? ""
        let path = encodedQuery.isEmpty
            ? "/api/sessions/search"
            : "/api/sessions/search?\(encodedQuery)"
        let data = try await get(path: path)

        struct Wrapper: Decodable { let results: [SessionSearchResult] }
        // SessionSearchResult declares explicit snake_case CodingKeys — skip the
        // global snake-case conversion (it would double-convert).
        return try decode(
            Wrapper.self, from: data, context: "search", strategy: .useDefaultKeys
        ).results
    }

    /// `PATCH /api/sessions/{id}` with `{ "title": ... }` — rename a session.
    ///
    /// An empty string clears the title server-side. Returns the title the server
    /// actually stored (it may differ, e.g. trimmed), so the caller can update the
    /// row with the authoritative value.
    @discardableResult
    func renameSession(id: String, title: String) async throws -> String {
        let body: JSONValue = .object(["title": .string(title)])
        let data = try await patchSession(id: id, body: body)
        struct Wrapper: Decodable { let title: String? }
        return (try decode(
            Wrapper.self, from: data, context: "rename", strategy: .useDefaultKeys
        ).title) ?? title
    }

    /// `GET /api/sessions?archived=only&limit=` — the archived-only session list.
    ///
    /// Mirrors the regular `sessions(limit:)` call but passes `archived=only` so
    /// the server returns exclusively archived rows. Ordered by most recent
    /// activity (`order=recent`) matching the live list. Called by
    /// ``SessionStore/loadArchived(limit:)`` for the Archived Chats surface
    /// (ABH-80 item 5).
    func archivedSessions(limit: Int = 100) async throws -> [SessionSummary] {
        let data = try await get(
            path: "/api/sessions?limit=\(limit)&order=recent&archived=only"
        )
        struct Wrapper: Decodable { let sessions: [SessionSummary] }
        return try decode(Wrapper.self, from: data, context: "archivedSessions").sessions
    }

    /// `PATCH /api/sessions/{id}` with `{ "archived": ... }` — archive or restore.
    ///
    /// Archiving soft-hides the session; the default list query
    /// (`archived=exclude`) drops it on the next refresh, so callers also remove
    /// it from the in-memory list immediately for instant feedback.
    func setSessionArchived(id: String, archived: Bool) async throws {
        let body: JSONValue = .object(["archived": .bool(archived)])
        _ = try await patchSession(id: id, body: body)
    }

    /// `GET /api/sessions/{id}/export` → JSON `{ ...session, messages: [...] }`,
    /// rendered to a Markdown transcript suitable for `ShareLink`.
    ///
    /// The server returns structured JSON (not Markdown), so the transcript is
    /// assembled client-side here — reusing ``StoredMessage`` for the same
    /// string/blocks content flattening the chat view uses.
    func exportSessionMarkdown(id: String) async throws -> String {
        let encodedId = id.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? id
        let data = try await get(path: "/api/sessions/\(encodedId)/export")
        let root = try decodeJSONValue(from: data, context: "export")
        return Self.renderExportMarkdown(from: root)
    }

    /// `PATCH /api/sessions/{id}` with a JSON body — shared by rename/archive.
    private func patchSession(id: String, body: JSONValue) async throws -> Data {
        let encodedId = id.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? id
        var request = makeRequest(path: "/api/sessions/\(encodedId)", method: "PATCH")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encodeBody(body, context: "patch")
        return try await perform(request)
    }

    // MARK: - Markdown rendering

    /// Format an export payload into a human-readable Markdown transcript.
    static func renderExportMarkdown(from root: JSONValue) -> String {
        var lines: [String] = []

        let title = root["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("# \(title.flatMap { $0.isEmpty ? nil : $0 } ?? "Hermes session")")
        lines.append("")

        var meta: [String] = []
        if let source = root["source"]?.stringValue, !source.isEmpty {
            meta.append("Source: \(source)")
        }
        if let model = root["model"]?.stringValue, !model.isEmpty {
            meta.append("Model: \(model)")
        }
        if let started = (root["started_at"] ?? root["session_started"])?.doubleValue {
            let date = Date(timeIntervalSince1970: started)
            meta.append("Started: \(Self.exportDateFormatter.string(from: date))")
        }
        if !meta.isEmpty {
            lines.append("_\(meta.joined(separator: " · "))_")
            lines.append("")
        }

        let parsed = (root["messages"]?.arrayValue ?? []).compactMap(StoredMessage.init(json:))
        if parsed.isEmpty {
            lines.append("_No messages._")
        } else {
            for message in parsed {
                lines.append("## \(Self.roleHeading(message.role))")
                let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append(text.isEmpty ? "_(empty)_" : text)
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func roleHeading(_ role: String) -> String {
        switch role.lowercased() {
        case "user": return "User"
        case "assistant": return "Assistant"
        case "system": return "System"
        case "tool": return "Tool"
        default: return role.capitalized
        }
    }

    private static let exportDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
