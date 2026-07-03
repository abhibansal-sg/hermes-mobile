import Foundation

// MARK: - F4A-A1 file-browser REST surface
//
// The two NEW session-cwd file endpoints (`GET /api/fs/list`, `GET /api/fs/read`)
// plus their zero-side-effect capability probe. Kept on `RestClient` so they
// inherit the loopback `Host` override, the `X-Hermes-Session-Token` auth header,
// the ephemeral session, and the 15s timeout (no cloned plumbing).
//
// `fsList`/`fsRead` go through `perform(_:)` for the happy path, but FIRST
// classify the contract's meaningful non-2xx codes (403 sandbox escape, 404 not
// a dir/file, 413 over the read cap) into typed `FSReadError`/`RestError` so the
// viewer can show "Too large to preview" instead of a generic HTTP error. The
// probe (`probeFsEndpoint`) never throws — it mirrors `probeUploadEndpoint`,
// classifying the status of a deliberately-malformed request into the same
// `UploadProbeResult` tri-state the `ServerCapabilities` `fs` field consumes.
extension RestClient {

    // MARK: - Capability probe (eager, side-effect-free)

    /// Side-effect-free probe of `GET /api/fs/list`: request it with NO
    /// `session_id`. The patched gateway returns `400 {"error":"session_id
    /// required"}` (route exists ⇒ available); a stock gateway has no such route
    /// and returns `404`/`405` (unavailable). No file is read. Never throws —
    /// failures map to `.inconclusive`. Shapes its result as the SAME
    /// ``UploadProbeResult`` the upload probe uses, so ``ServerCapabilities`` can
    /// fold both with one switch.
    func probeFsEndpoint() async -> UploadProbeResult {
        let request = makeRequest(path: "\(mobileAPIPrefix)/fs/list", method: "GET")
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .inconclusive }
            switch http.statusCode {
            case 400: return .available
            case 404, 405: return .unavailable
            default: return .inconclusive
            }
        } catch {
            return .inconclusive
        }
    }

    // MARK: - List a directory under the session cwd

    /// `GET /api/fs/list?session_id=…[&path=…]` — list a directory under the
    /// session's sandboxed cwd. `path` is relative to the cwd root (omit / pass
    /// empty for the root itself). Throws ``FSReadError/pathEscapesRoot`` on a
    /// `403`, ``FSReadError/notAFile`` on a `404` (the path is a file or is
    /// missing — `"not a directory"`), and the underlying ``RestError`` otherwise.
    func fsList(sessionId: String, path: String? = nil) async throws -> FSListResult {
        let request = makeRequest(
            path: "\(mobileAPIPrefix)/fs/list?" + Self.fsQuery(sessionId: sessionId, path: path),
            method: "GET"
        )
        do {
            let data = try await perform(request)
            return try decode(
                FSListResult.self,
                from: data,
                context: "fs.list",
                strategy: .useDefaultKeys
            )
        } catch let error as RestError {
            throw Self.mapFSError(error)
        }
    }

    // MARK: - Read a file under the session cwd

    /// `GET /api/fs/read?session_id=…&path=…` — read a file's contents under the
    /// session's sandboxed cwd. Returns text for a UTF-8 file (`truncated` flagged
    /// if cut to the server's read cap) and `content == nil` /
    /// `encoding == .binary` for a binary file. Throws
    /// ``FSReadError/tooLarge(size:)`` on a `413` (over the 1 MB hard cap),
    /// ``FSReadError/pathEscapesRoot`` on a `403`, ``FSReadError/notAFile`` on a
    /// `404`, and ``FSReadError/other`` for any other failure.
    func fsRead(sessionId: String, path: String) async throws -> FSReadResult {
        let request = makeRequest(
            path: "\(mobileAPIPrefix)/fs/read?" + Self.fsQuery(sessionId: sessionId, path: path),
            method: "GET"
        )
        do {
            let data = try await perform(request)
            return try decode(
                FSReadResult.self,
                from: data,
                context: "fs.read",
                strategy: .useDefaultKeys
            )
        } catch let error as RestError {
            throw Self.mapFSError(error)
        }
    }

    // MARK: - Read an image file as a data URL

    /// `GET /api/fs/read?session_id=…&path=…&format=data_url` — request an image
    /// file as a `data:<mime>;base64,…` URL so the viewer can render it inline.
    /// This is the patched-gateway path that mirrors the desktop's
    /// `window.hermesDesktop.readFileDataUrl(filePath)` (see `LocalFilePreview`).
    ///
    /// Falls back gracefully: if the server does not support the `format` param
    /// it returns the normal `FSReadResult` shape; the viewer checks `dataURL !=
    /// nil` before trying to render as an image, so a stock gateway that ignores
    /// the param and returns `encoding: "binary"` just shows the binary fallback.
    ///
    /// Same error mapping as ``fsRead``.
    func fsReadAsDataURL(sessionId: String, path: String) async throws -> FSReadResult {
        let baseQuery = Self.fsQuery(sessionId: sessionId, path: path)
        let request = makeRequest(
            path: "\(mobileAPIPrefix)/fs/read?" + baseQuery + "&format=data_url",
            method: "GET"
        )
        do {
            let data = try await perform(request)
            return try decode(
                FSReadResult.self,
                from: data,
                context: "fs.read.image",
                strategy: .useDefaultKeys
            )
        } catch let error as RestError {
            throw Self.mapFSError(error)
        }
    }

    // MARK: - Helpers

    /// Build the `session_id`/`path` query string, percent-encoding both so a
    /// path with spaces or `/` survives. `path` is omitted entirely when nil/empty
    /// (the list root); `read` always passes a non-empty path.
    static func fsQuery(sessionId: String, path: String?) -> String {
        var items = [URLQueryItem(name: "session_id", value: sessionId)]
        if let path, !path.isEmpty {
            items.append(URLQueryItem(name: "path", value: path))
        }
        var components = URLComponents()
        components.queryItems = items
        // `percentEncodedQuery` from `queryItems` encodes spaces but leaves "/"
        // and "+"; the gateway reads `path` as a literal relative path so encode
        // those too to avoid a `+`→space or a path-split surprise.
        return (components.percentEncodedQuery ?? "")
            .replacingOccurrences(of: "+", with: "%2B")
    }

    /// Map a thrown ``RestError/badStatus`` into the file-specific
    /// ``FSReadError`` cases the UI renders specially; pass anything else through
    /// as ``FSReadError/other`` carrying the original message.
    static func mapFSError(_ error: RestError) -> FSReadError {
        switch error {
        case .badStatus(let code, let body):
            switch code {
            case 413:
                return .tooLarge(size: Self.parseSizeField(from: body))
            case 403:
                return .pathEscapesRoot
            case 404:
                // R1-fix finding 2: the server returns `{"error":"unknown
                // session"}` for a stale/unknown sid (no dashboard-cwd fallback),
                // vs `{"error":"not a directory"}`/`"not a file"` for a real path
                // miss. Distinguish so the browser shows "No Active Session"
                // rather than a misleading file-not-found.
                return Self.is404UnknownSession(body) ? .noActiveSession : .notAFile
            default:
                return .other(error.errorDescription ?? "HTTP \(code)")
            }
        case .network, .decoding:
            return .other(error.errorDescription ?? "Request failed")
        }
    }

    /// True when a `404` body is the unknown-session marker
    /// (`{"error":"unknown session"}`) rather than a path miss. Tolerant: any
    /// parse failure falls back to the path-miss interpretation.
    private static func is404UnknownSession(_ body: String) -> Bool {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return (object["error"] as? String) == "unknown session"
    }

    /// Pull the `"size"` int out of a `413` body (`{"error":"file too
    /// large","size":N}`) for the "Too large (N)" detail; tolerant of absence.
    private static func parseSizeField(from body: String) -> Int? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let size = object["size"] as? Int { return size }
        if let size = object["size"] as? Double { return Int(size) }
        return nil
    }
}

// MARK: - ABH-368 system log viewer

/// Errors surfaced by ``RestClient/systemLogs``. The gateway's `GET /api/logs`
/// returns `400 {"detail":"Unknown log file: foo"}` for an unrecognized `file`
/// param — that is mapped to ``unknownFile`` so the viewer shows "Unknown log
/// file" rather than a generic HTTP error.
enum SystemLogError: Error, LocalizedError, Sendable {
    /// `400` — the `file` key is not in the server's `LOG_FILES`.
    case unknownFile(detail: String)
    /// Any other failure (network, decoding, unexpected status).
    case other(String)

    var errorDescription: String? {
        switch self {
        case .unknownFile(let detail):
            return detail.isEmpty ? "Unknown log file." : detail
        case .other(let message):
            return message
        }
    }
}

extension RestClient {

    // MARK: - System logs tail

    /// `GET /api/logs?file=…&level=…&search=…` — fetch a filtered tail of a
    /// system log file. The server reads up to N lines from the end of the file
    /// (100 by default, capped at 500; 2000 when a search term narrows the
    /// window), applies the `level` (minimum-level) and `search` (case-
    /// insensitive substring) filters server-side, and returns
    /// `{file, lines:[…]}`.
    ///
    /// An unknown `file` key yields a `400` → ``SystemLogError/unknownFile``.
    /// A file that exists but has no content (e.g. `desktop.log` on a headless
    /// server) yields a successful `200` with an empty `lines` array — the
    /// viewer treats that as an honest "no lines" state, NOT an error.
    ///
    /// - Parameters:
    ///   - file: The log file key (e.g. "agent", "errors", "gateway"). The
    ///     valid set comes from the server's `LOG_FILES` — the viewer reads it
    ///     defensively and never hardcodes a list the gateway might not have.
    ///   - level: An optional minimum severity (DEBUG/INFO/WARNING/ERROR).
    ///     `.all` omits the param entirely (the server treats absent as no
    ///     filter).
    ///   - search: An optional case-insensitive substring. Omitted when empty.
    ///   - lineCount: The max lines to return (server caps at 500; 2000 with
    ///     search). Defaults to 200 — enough for a phone tail without flooding.
    /// - Returns: The decoded `{file, lines}` payload.
    func systemLogs(
        file: String,
        level: SystemLogLevel = .all,
        search: String = "",
        lineCount: Int = 200
    ) async throws -> SystemLogResult {
        let query = Self.logsQuery(
            file: file,
            level: level,
            search: search,
            lineCount: lineCount
        )
        // /api/logs is a STOCK gateway route (not a plugin-mount route), so it
        // hangs off /api directly regardless of pathStyle. The existing
        // makeRequest joins the path under baseURL, and the Host override +
        // bearer auth headers are applied uniformly.
        let request = makeRequest(path: "/api/logs?\(query)", method: "GET")
        do {
            let data = try await perform(request)
            return try decode(
                SystemLogResult.self,
                from: data,
                context: "systemLogs",
                strategy: .useDefaultKeys
            )
        } catch let error as RestError {
            throw Self.mapLogsError(error)
        }
    }

    // MARK: - Helpers

    /// Build the `file`/`level`/`search`/`lines` query string, percent-encoding
    /// each value so a search term with spaces or special chars survives. `level`
    /// is omitted entirely for `.all` (the server treats absent/`ALL`/empty as no
    /// filter); `search` is omitted when blank.
    static func logsQuery(
        file: String,
        level: SystemLogLevel,
        search: String,
        lineCount: Int
    ) -> String {
        var items = [
            URLQueryItem(name: "file", value: file),
            URLQueryItem(name: "lines", value: String(lineCount)),
        ]
        if level.isLevel {
            items.append(URLQueryItem(name: "level", value: level.rawValue))
        }
        let trimmedSearch = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty {
            items.append(URLQueryItem(name: "search", value: trimmedSearch))
        }
        var components = URLComponents()
        components.queryItems = items
        return components.percentEncodedQuery ?? ""
    }

    /// Map a thrown ``RestError/badStatus`` into ``SystemLogError``: a `400`
    /// from `/api/logs` means an unknown file key (surfaced as a clear
    /// "Unknown log file" message); anything else is `.other`.
    static func mapLogsError(_ error: RestError) -> SystemLogError {
        switch error {
        case .badStatus(let code, let body):
            if code == 400 {
                // The server body is FastAPI's {"detail": "Unknown log file: foo"}
                let detail = Self.parseDetailField(from: body) ?? body
                return .unknownFile(detail: detail)
            }
            return .other(error.errorDescription ?? "HTTP \(code)")
        case .network, .decoding:
            return .other(error.errorDescription ?? "Request failed")
        }
    }

    /// Pull the `"detail"` string out of a FastAPI error body
    /// (`{"detail":"Unknown log file: foo"}`); tolerant of absence.
    private static func parseDetailField(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["detail"] as? String
    }
}
