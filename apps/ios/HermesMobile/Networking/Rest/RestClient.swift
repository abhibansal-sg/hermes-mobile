import Foundation

/// Errors surfaced by ``RestClient``.
enum RestError: Error, LocalizedError, Sendable {
    /// The server returned a non-2xx status. `body` is the (possibly truncated) response text.
    case badStatus(Int, body: String)
    /// A transport-level failure (URLSession error, bad URL).
    case network(String)
    /// The response body could not be decoded into the expected shape.
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "Server returned HTTP \(code)"
                : "Server returned HTTP \(code): \(trimmed)"
        case .network(let message):
            return "Network error: \(message)"
        case .decoding(let message):
            return "Could not decode response: \(message)"
        }
    }
}

/// Which REST path family the gateway serves for the MOBILE endpoint group
/// (upload / devices / approvals / fs / push). The ABH-88 de-patch moved these
/// from legacy top-level routes to the hermes-mobile plugin mount; the app
/// probes which family the server speaks (``ServerCapabilities/pluginMount``)
/// and pins the result per server. Core endpoints (`/api/sessions`,
/// `/api/status`, the WS protocol, …) never moved and are unaffected.
enum APIPathStyle: String, Sendable, Codable {
    /// Legacy top-level paths (`/api/upload`, `/api/devices`, …) —
    /// pre-de-patch gateways (e.g. the live dashboard until its redeploy).
    case legacy
    /// Plugin mount (`/api/plugins/hermes-mobile/…`) — de-patched gateways.
    case plugin

    /// The other family — used by the self-healing 404 retries on background
    /// flows (push/Live-Activity registration, notification-action respond).
    var alternate: APIPathStyle { self == .plugin ? .legacy : .plugin }

    /// The path prefix the MOBILE endpoint group hangs off in this family.
    var mobileAPIPrefix: String {
        switch self {
        case .legacy: return "/api"
        case .plugin: return "/api/plugins/hermes-mobile"
        }
    }
}

/// Stateless HTTP client for the hermes gateway's REST surface.
///
/// Every request overrides the `Host` header to `127.0.0.1` (the server validates
/// Host against its loopback bind; Tailscale Serve preserves the public hostname
/// otherwise) and carries the `X-Hermes-Session-Token` auth header. All requests
/// use a 15-second timeout and throw ``RestError`` on failure.
///
/// The core endpoint groups live in `extension RestClient` files
/// (`RestClient+Sessions.swift`, `RestClient+Control.swift`, `RestClient+Audio.swift`).
/// They share the request plumbing below — `makeRequest`/`get`/`perform` and the
/// `decode`/`decodeJSONValue` helpers are `internal` (not `private`) precisely so
/// those same-module extensions reuse one implementation instead of cloning it.
struct RestClient: Sendable {
    let baseURL: URL
    let token: String
    let session: URLSession
    /// Path family for the MOBILE endpoint group (see ``APIPathStyle``).
    /// Defaults to `.legacy` so an un-migrated construction site keeps today's
    /// behavior; ``ConnectionStore`` passes the probed style.
    let pathStyle: APIPathStyle

    /// - Parameters:
    ///   - baseURL: The gateway base, e.g. `https://host[:port]`.
    ///   - token: The session token sent as `X-Hermes-Session-Token`.
    ///   - pathStyle: Path family for the mobile endpoint group.
    init(baseURL: URL, token: String, pathStyle: APIPathStyle = .legacy) {
        self.baseURL = baseURL
        self.token = token
        self.pathStyle = pathStyle
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.timeout
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    /// Testing-only initialiser: accepts a pre-built ``URLSession`` so tests
    /// can inject a stub transport (``URLProtocol`` subclass) without hitting
    /// a live server. Not intended for production use.
    init(
        baseURL: URL,
        token: String,
        session: URLSession,
        pathStyle: APIPathStyle = .legacy
    ) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
        self.pathStyle = pathStyle
    }

    /// A copy of this client speaking the given path family (same session).
    func withPathStyle(_ style: APIPathStyle) -> RestClient {
        RestClient(baseURL: baseURL, token: token, session: session, pathStyle: style)
    }

    /// Prefix for the MOBILE endpoint group under this client's path family.
    var mobileAPIPrefix: String { pathStyle.mobileAPIPrefix }

    private static let timeout: TimeInterval = 15

    // MARK: - Endpoints

    /// `GET /api/status` — server health and capability snapshot.
    func status() async throws -> ServerStatus {
        let data = try await get(path: "/api/status")
        return try decode(ServerStatus.self, from: data, context: "status")
    }

    /// `GET /api/sessions` — session list ordered by most recent activity.
    ///
    /// Unlike the WS `session.list` RPC (creation order), `order=recent` is
    /// compression-chain aware and bubbles an old session back to the top
    /// when it gets new activity — matching the desktop sidebar.
    func sessions(limit: Int = 100) async throws -> [SessionSummary] {
        let data = try await get(
            path: "/api/sessions?limit=\(limit)&order=recent&archived=exclude"
        )
        struct Wrapper: Decodable { let sessions: [SessionSummary] }
        return try decode(Wrapper.self, from: data, context: "sessions").sessions
    }

    /// `GET /api/sessions` — session list with the server-reported total count.
    ///
    /// The wire response is `{"sessions":[…], "total": N, "limit": N, "offset": N}`.
    /// Older gateways omit the pagination envelope and return only `{"sessions":[…]}`;
    /// in that case `total` is `nil` (the caller preserves the previously-known total).
    ///
    /// ABH-86 item 3: decoding the `total` field so the drawer's count affordance works.
    /// UX1: `minMessages=1` filters scaffold/empty sessions server-side (desktop parity:
    /// `listAllProfileSessions(limit, 1)` in desktop-controller.tsx:265).
    /// Pagination uses GROW-THE-LIMIT semantics (desktop-controller.tsx:290): pass
    /// `limit = loaded + PAGE_SIZE, offset=0` on every call — the window expands rather
    /// than walking with a fixed-limit+offset. The `offset` parameter is kept for the
    /// production-path default (offset=0) so older call sites compile unchanged.
    /// `excludeSource` / `source` filter by session origin (ABH drawer
    /// bifurcation): the human-chat Recents passes `excludeSource: ["cron"]` so
    /// automation runs never enter the list (or its cache); the automation-runs
    /// feed passes `source: "cron"`. The server splits `exclude_sources` on commas.
    func sessionsWithTotal(
        limit: Int = 100,
        offset: Int = 0,
        minMessages: Int = 1,
        excludeSource: [String] = [],
        source: String? = nil
    ) async throws -> (sessions: [SessionSummary], total: Int?) {
        var parts = [
            "limit=\(limit)",
            "order=recent",
            "archived=exclude",
        ]
        if minMessages > 0 { parts.append("min_messages=\(minMessages)") }
        if offset > 0       { parts.append("offset=\(offset)") }
        if !excludeSource.isEmpty {
            // Gateway FastAPI param is `exclude_sources` (PLURAL) — see
            // web_server.py /api/sessions. iOS historically sent the singular
            // `exclude_source`, which FastAPI silently dropped, so cron runs were
            // never server-filtered and dominated the first page (only the
            // client-side `visibleSessions` filter hid them — wasting the loaded
            // window on cron and making a freshly-active desktop session far less
            // likely to be in it). Backward-safe: a stock gateway ignores an
            // unknown param, and the client-side filter remains the guarantee.
            parts.append("exclude_sources=\(excludeSource.joined(separator: ","))")
        }
        if let source, !source.isEmpty {
            parts.append("source=\(source)")
        }
        let path = "/api/sessions?" + parts.joined(separator: "&")
        let data = try await get(path: path)
        struct Wrapper: Decodable {
            let sessions: [SessionSummary]
            let total: Int?
        }
        let wrapper = try decode(Wrapper.self, from: data, context: "sessionsWithTotal")
        return (wrapper.sessions, wrapper.total)
    }

    /// `GET /api/sessions/{id}/messages` — stored transcript for a session.
    ///
    /// The response is either `{"messages": [...]}` or a bare `[...]` array;
    /// both shapes are handled. Entries that fail ``StoredMessage`` parsing
    /// are dropped.
    func messages(sessionId: String) async throws -> [StoredMessage] {
        let encodedId = sessionId.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? sessionId
        let data = try await get(path: "/api/sessions/\(encodedId)/messages")

        let root = try decodeJSONValue(from: data, context: "messages")

        let array: [JSONValue]
        if let bare = root.arrayValue {
            array = bare
        } else if let wrapped = root["messages"]?.arrayValue {
            array = wrapped
        } else {
            throw RestError.decoding("messages: expected array or {messages:[…]}")
        }
        return array.compactMap(StoredMessage.init(json:))
    }

    /// Response of the plugin-mount incremental transcript fetch
    /// (``messagesDelta``). `isDelta` true → `messages` is only the tail beyond the
    /// client's cursor; false → `messages` is the full transcript (the server
    /// detected a prefix reshape and forced a re-sync). `prefixCount`/`maxId` are
    /// the new cursor the client persists.
    struct TranscriptDelta: Sendable {
        let isDelta: Bool
        let prefixCount: Int
        let maxId: Int
        let messages: [StoredMessage]
    }

    /// `GET <plugin>/sessions/{id}/messages?after_id&prefix_count` — incremental
    /// transcript fetch (Phase 3). Only the hermes-mobile PLUGIN mount serves this,
    /// so it is a no-op (returns nil) unless this client speaks `.plugin`; the
    /// caller then falls back to the full ``messages(sessionId:)``. Any failure
    /// (404 on an older plugin build, transport, decode) also returns nil → full
    /// fetch. The wire rows mirror the stock endpoint, so ``StoredMessage`` parses
    /// both identically.
    func messagesDelta(
        sessionId: String,
        afterId: Int,
        prefixCount: Int
    ) async -> TranscriptDelta? {
        guard pathStyle == .plugin else { return nil }
        let encodedId = sessionId.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? sessionId
        let path = "\(mobileAPIPrefix)/sessions/\(encodedId)/messages"
            + "?after_id=\(afterId)&prefix_count=\(prefixCount)"
        do {
            let data = try await get(path: path)
            let root = try decodeJSONValue(from: data, context: "messagesDelta")
            guard let isDelta = root["is_delta"]?.boolValue,
                  let array = root["messages"]?.arrayValue else { return nil }
            return TranscriptDelta(
                isDelta: isDelta,
                prefixCount: root["prefix_count"]?.intValue ?? -1,
                maxId: root["max_id"]?.intValue ?? 0,
                messages: array.compactMap(StoredMessage.init(json:))
            )
        } catch {
            return nil  // legacy/older plugin (404), transport, or decode → full fetch
        }
    }

    /// Outcome of the zero-side-effect ``probeUploadEndpoint()`` capability check.
    enum UploadProbeResult: Sendable, Equatable {
        /// `400` — the endpoint exists and rejected the missing multipart field.
        case available
        /// `404`/`405` — the endpoint isn't routed on this (stock) gateway.
        case unavailable
        /// Any other status or a transport error — can't decide from this probe.
        case inconclusive
    }

    /// Side-effect-free probe of the plugin mount itself (ABH-88): `GET
    /// /api/plugins/hermes-mobile/devices` — an ABSOLUTE path, independent of
    /// this client's ``pathStyle``. A de-patched gateway returns `200` with a
    /// well-formed `{"devices":[…]}` body (mirrors ``probeDevicesEndpoint``'s
    /// body check); a pre-de-patch gateway has no plugin mount and returns
    /// `404`/`405`. Drives ``ServerCapabilities/pluginMount``, which selects
    /// the path family every OTHER mobile call uses.
    func probePluginMountEndpoint() async -> UploadProbeResult {
        let request = makeRequest(
            path: "/api/plugins/hermes-mobile/devices", method: "GET"
        )
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .inconclusive }
            switch http.statusCode {
            case 200:
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   object["devices"] is [Any] {
                    return .available
                }
                return .inconclusive
            case 404, 405:
                return .unavailable
            default:
                return .inconclusive
            }
        } catch {
            return .inconclusive
        }
    }

    /// Side-effect-free probe of `POST <prefix>/upload`: send an EMPTY body and
    /// classify the status. The patched gateway rejects the absent multipart
    /// field with `400`; a stock gateway has no route and returns `404`/`405`.
    /// No file is ever created. Never throws — failures map to `.inconclusive`.
    func probeUploadEndpoint() async -> UploadProbeResult {
        let request = makeRequest(path: "\(mobileAPIPrefix)/upload", method: "POST")
        // No body, no multipart Content-Type: the server sees a request missing
        // the required `file` field and 400s without writing anything.
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

    /// `POST /api/upload` — multipart upload of a single file under field `file`.
    func upload(data: Data, filename: String, mimeType: String) async throws -> UploadResult {
        let boundary = "Boundary-\(UUID().uuidString)"
        let body = multipartBody(
            data: data,
            filename: filename,
            mimeType: mimeType,
            boundary: boundary
        )
        var request = makeRequest(path: "\(mobileAPIPrefix)/upload", method: "POST")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = body
        let responseData = try await perform(request)
        return try decode(UploadResult.self, from: responseData, context: "upload")
    }

    // MARK: - Request plumbing
    //
    // `internal` (not `private`) so the `RestClient+*` extension files reuse this
    // single implementation rather than cloning the loopback Host override, auth
    // header, timeout, status check, and error mapping.

    /// JSON key-decoding strategy a caller needs for a given response shape.
    enum KeyStrategy: Sendable {
        /// Wire keys are snake_case; let `JSONDecoder` camel-case them. Use for
        /// fixed-shape responses whose models have no explicit `CodingKeys`.
        case convertFromSnakeCase
        /// No key conversion. Use when the model declares explicit snake_case
        /// `CodingKeys` (converting would double-transform and corrupt the match).
        case useDefaultKeys
    }

    /// Build a request with the mandatory Host override + auth headers.
    func makeRequest(path: String, method: String) -> URLRequest {
        // Split any query string off before joining — appendingPathComponent
        // percent-encodes "?" and the server would see a literal-path 404.
        let parts = path.split(separator: "?", maxSplits: 1)
        let purePath = String(parts[0])
        var url = baseURL.appendingPathComponent(
            purePath.hasPrefix("/") ? String(purePath.dropFirst()) : purePath
        )
        if parts.count == 2,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.percentEncodedQuery = String(parts[1])
            url = components.url ?? url
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: Self.timeout
        )
        request.httpMethod = method
        // Loopback Host override — the gateway validates Host against its bind.
        request.setValue("127.0.0.1", forHTTPHeaderField: "Host")
        request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func get(path: String) async throws -> Data {
        try await perform(makeRequest(path: path, method: "GET"))
    }

    /// JSON-encode a ``JSONValue`` request body, mapping failures to ``RestError``.
    func encodeBody(_ body: JSONValue, context: String) throws -> Data {
        do {
            return try JSONEncoder().encode(body)
        } catch {
            throw RestError.network("\(context): encode body: \(error.localizedDescription)")
        }
    }

    /// Execute a request and validate the HTTP status, mapping failures to ``RestError``.
    func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RestError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw RestError.network("Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw RestError.badStatus(http.statusCode, body: String(body.prefix(512)))
        }
        return data
    }

    /// Decode `data` into `T`, applying the requested key strategy.
    ///
    /// Defaults to `.convertFromSnakeCase` (the common fixed-shape case:
    /// status/sessions/upload/model.info/usage). Pass `.useDefaultKeys` for models
    /// with explicit snake_case `CodingKeys` (``SessionSearchResult``,
    /// ``AudioSpeakResult``) so the wire keys aren't double-converted.
    func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        context: String,
        strategy: KeyStrategy = .convertFromSnakeCase
    ) throws -> T {
        let decoder = JSONDecoder()
        if case .convertFromSnakeCase = strategy {
            decoder.keyDecodingStrategy = .convertFromSnakeCase
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw RestError.decoding("\(context): \(error.localizedDescription)")
        }
    }

    /// Decode `data` into a raw ``JSONValue`` with NO key conversion — dynamic
    /// keys (provider slugs, model ids, personality names) must survive verbatim,
    /// which `.convertFromSnakeCase` would rewrite. Used by the control surface's
    /// `/api/model/options`, `/api/config`, `/api/cron/jobs`, `/api/skills` and by
    /// the bare-array message/export payloads.
    func decodeJSONValue(from data: Data, context: String) throws -> JSONValue {
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw RestError.decoding("\(context): \(error.localizedDescription)")
        }
    }

    /// Assemble an RFC 7578 multipart/form-data body for a single `file` part.
    private func multipartBody(
        data: Data,
        filename: String,
        mimeType: String,
        boundary: String
    ) -> Data {
        var body = Data()
        let crlf = "\r\n"
        body.append("--\(boundary)\(crlf)")
        body.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\(crlf)"
        )
        body.append("Content-Type: \(mimeType)\(crlf)\(crlf)")
        body.append(data)
        body.append(crlf)
        body.append("--\(boundary)--\(crlf)")
        return body
    }
}

private extension Data {
    /// Append a UTF-8 string fragment to a multipart body.
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}

// MARK: - Delta-aware transcript fetch (Phase 3)

/// When the on-device cache holds a cursor for `sessionId` AND the gateway speaks
/// the hermes-mobile plugin mount, fetch only the messages beyond the cursor and
/// merge them onto the cached transcript — cutting the over-the-wire payload from
/// "the whole transcript on every change" to "just the new tail". In every other
/// case (no cursor, legacy gateway, a server-detected prefix reshape, or any delta
/// failure) it falls back to the full stock fetch.
///
/// It returns the FULL `[StoredMessage]` list to seed, so the delta is invisible to
/// everything downstream: the same `toChatMessages` normalize, the same in-place
/// `chat.seed` reconcile (by deterministic wire id), and the same `saveTranscript`
/// write-through all run exactly as before. The win is purely the bytes fetched —
/// no new merge path, no cache-schema migration.
///
/// Safety: the cached prefix and the server delta concatenate cleanly because the
/// cache holds COMPLETED server rows (streaming content arrives over WS, never via
/// this path) and the plugin route's generation guard forces a full re-sync
/// (`isDelta == false`) the instant the prefix is reshaped server-side.
func fetchTranscriptDeltaAware(
    rest: RestClient,
    cacheStore: CacheStore?,
    sessionId: String
) async throws -> [StoredMessage] {
    if let cacheStore,
       let cursor = try? await cacheStore.deltaCursor(for: sessionId),
       cursor.afterId > 0,
       let delta = await rest.messagesDelta(
           sessionId: sessionId,
           afterId: cursor.afterId,
           prefixCount: cursor.prefixCount
       ) {
        if delta.isDelta {
            // Tail-only payload: append onto the cached prefix and seed the union.
            // An empty tail (client already caught up) returns the cache unchanged.
            var cached: [StoredMessage] = []
            // `try?` flattens loadTranscript's `[StoredMessage]?` to a single optional.
            if let rows = try? await cacheStore.loadTranscript(sessionId) {
                cached = rows
            }
            return cached + delta.messages
        }
        // Server forced a full re-sync (prefix reshaped): use its authoritative list.
        return delta.messages
    }
    // No cursor / legacy gateway / delta unavailable → full stock fetch (unchanged).
    return try await rest.messages(sessionId: sessionId)
}
