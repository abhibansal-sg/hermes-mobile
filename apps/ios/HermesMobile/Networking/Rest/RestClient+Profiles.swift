import Foundation

// MARK: - F4b multi-profile REST surface (feature-detected, DORMANT by default)
//
// The multi-profile endpoints (`GET /api/profiles`, `GET /api/profiles/sessions`,
// and the optional `profile` scope on per-session GET/PATCH/DELETE) arrive only at
// the upstream rebase — they are ABSENT from today's live 9119 backend. This
// extension codes against the pinned upstream shapes (see CONTRACT-F4B.md
// §Interface); every caller in `SessionStore` gates on
// `capabilities.profiles == .available`, so on a stock / pre-multi-profile gateway
// none of this is reached and the app is byte-for-byte its pre-F4b self.
//
// Kept on `RestClient` (mirroring `RestClient+FS.swift`) so these inherit the
// loopback `Host` override, the `X-Hermes-Session-Token` auth header, the
// ephemeral session, and the 15s timeout via the shared `makeRequest`/`get`/
// `perform`/`decode` plumbing — no cloned HTTP code.
extension RestClient {

    // MARK: - Capability probe (eager, side-effect-free)

    /// Side-effect-free probe of `GET /api/profiles/sessions` — the cross-profile
    /// AGGREGATE rail, which is the route GENUINELY NEW at the upstream rebase.
    ///
    /// IMPORTANT (dormancy correctness): a bare `GET /api/profiles` is NOT a valid
    /// multi-profile probe on our codebase — that route already exists on the
    /// working HEAD (`web_server.py:6354`, the desktop profiles-management page,
    /// landed at `4523965de`) and returns `200 {"profiles":[…]}` on today's server.
    /// Probing it would classify our LIVE 9119 / this-branch backend as
    /// `.available` and break dormancy. The route that is actually absent until the
    /// rebase is `GET /api/profiles/sessions` (`get_profiles_sessions`,
    /// origin/main `web_server.py:1636`), so THAT is the existence probe.
    ///
    /// All its query params are optional (`limit=20`, `offset=0`, `order=recent`,
    /// `archived=exclude`, `profile=all`), so a bare GET on a SUPPORTING server
    /// returns `200` with the aggregate wrapper (route exists ⇒ available); a
    /// pre-multi-profile server has no such route and returns `404`/`405`
    /// (unavailable). The probe is a READ — no session/profile is created or
    /// mutated. Never throws — failures map to `.inconclusive`. Shapes its result
    /// as the SAME ``UploadProbeResult`` the upload/fs probes use so
    /// ``ServerCapabilities`` folds all three with one switch.
    ///
    /// Refinement over a bare status check: a `200` must ALSO carry a `sessions`
    /// array to count as `.available`; a `200` lacking one is `.inconclusive`
    /// (defensive against a same-path collision).
    func probeProfilesEndpoint() async -> UploadProbeResult {
        let request = makeRequest(path: "/api/profiles/sessions", method: "GET")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .inconclusive }
            switch http.statusCode {
            case 200:
                // Confirm the body really is the aggregate wrapper before trusting
                // the route. `JSONSerialization` (not a typed decode) so a missing
                // optional field can't downgrade a genuine `200` to inconclusive.
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   object["sessions"] is [Any] {
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

    // MARK: - Profile list (the switcher's data)

    /// `GET /api/profiles` → decode `{"profiles":[…]}` into the minimal
    /// ``ProfileSummary`` rows the switcher needs. Decoded via
    /// `.convertFromSnakeCase` (`is_default` → `isDefault`); every other key the
    /// server emits is ignored. Always returns ≥ 1 row (the default) on a
    /// supporting server.
    func profiles() async throws -> [ProfileSummary] {
        let data = try await get(path: "/api/profiles")
        struct Wrapper: Decodable { let profiles: [ProfileSummary] }
        return try decode(Wrapper.self, from: data, context: "profiles").profiles
    }

    // MARK: - Cross-profile aggregate rail

    /// `GET /api/profiles/sessions?profile=…&limit=…&offset=…&order=…&archived=…`
    /// → the cross-profile aggregate rail wrapper. `profile="all"` aggregates
    /// across every profile; a specific name resolves that one. Called ONLY when
    /// `profiles == .available` AND the active scope is "All profiles"; the
    /// single-profile / default scope keeps using the existing `GET /api/sessions`
    /// (so the dormant path is byte-for-byte the shipped fetch).
    ///
    /// The server is STRICT on a bad/unknown profile name (`400`/`404`); those map
    /// to ``RestError/badStatus`` for the caller to surface inline.
    func profileSessions(
        profile: String = "all",
        limit: Int = 100,
        offset: Int = 0,
        order: String = "recent",
        archived: String = "exclude",
        excludeSource: [String] = [],
        source: String? = nil
    ) async throws -> ProfilesSessionsResult {
        var components = URLComponents()
        var items = [
            URLQueryItem(name: "profile", value: profile),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "order", value: order),
            URLQueryItem(name: "archived", value: archived),
        ]
        // Drawer bifurcation: Recents (aggregate rail) excludes automation runs;
        // an automation-runs feed would pass source: "cron".
        if !excludeSource.isEmpty {
            // PLURAL `exclude_sources` — the gateway's actual param name (see
            // RestClient.sessionsWithTotal). The singular form is silently dropped.
            items.append(URLQueryItem(name: "exclude_sources", value: excludeSource.joined(separator: ",")))
        }
        if let source, !source.isEmpty {
            items.append(URLQueryItem(name: "source", value: source))
        }
        components.queryItems = items
        let query = components.percentEncodedQuery ?? ""
        let path = query.isEmpty
            ? "/api/profiles/sessions"
            : "/api/profiles/sessions?\(query)"
        let data = try await get(path: path)
        return try decode(
            ProfilesSessionsResult.self,
            from: data,
            context: "profiles.sessions"
        )
    }

    // MARK: - Per-session profile threading (REST; STRICT unknown-profile)
    //
    // Used by SessionStore ONLY when a specific non-default profile scope is
    // active AND multi-profile is available. The REST path is STRICT on an unknown
    // profile: `400` on an invalid name (ValueError) and `404 "Profile '<name>'
    // does not exist."` when the profile doesn't exist (`_cron_profile_home`,
    // web_server.py:5445-5457). Both surface as ``RestError/badStatus`` carrying
    // the server message, which the caller maps to a native inline error.
    //
    // `profile` is passed as a QUERY param on GET/DELETE and in the JSON BODY on
    // PATCH (the `SessionRename` model, web_server.py:5273-5278). A `nil`/empty
    // `profile` falls back to the plain (profile-less) request, so the default /
    // all scope keeps the byte-for-byte shipped behavior.

    /// `GET /api/sessions/{id}/messages[?profile=…]` — stored transcript scoped to
    /// a profile when one is active. With `profile == nil`/empty this is the plain
    /// (shipped) request.
    func messages(sessionId: String, profile: String?) async throws -> [StoredMessage] {
        guard let profile, !profile.isEmpty else {
            return try await messages(sessionId: sessionId)
        }
        let encodedId = sessionId.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? sessionId
        let path = "/api/sessions/\(encodedId)/messages?" + Self.profileQuery(profile)
        let data = try await get(path: path)

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

    /// `DELETE /api/sessions/{id}[?profile=…]` — delete a session in the given
    /// profile scope. With `profile == nil`/empty this is the plain (shipped)
    /// request path; this method is the profile-aware variant used by the switcher.
    func deleteSession(id: String, profile: String?) async throws {
        let encodedId = id.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? id
        var path = "/api/sessions/\(encodedId)"
        if let profile, !profile.isEmpty {
            path += "?" + Self.profileQuery(profile)
        }
        _ = try await perform(makeRequest(path: path, method: "DELETE"))
    }

    /// `PATCH /api/sessions/{id}` with `{ "title": …, "profile": … }` — rename a
    /// session in the given profile scope. The `profile` is carried in the BODY
    /// (the `SessionRename` model), NOT the query. With `profile == nil`/empty this
    /// delegates to the plain (shipped) ``renameSession(id:title:)``.
    @discardableResult
    func renameSession(id: String, title: String, profile: String?) async throws -> String {
        guard let profile, !profile.isEmpty else {
            return try await renameSession(id: id, title: title)
        }
        let encodedId = id.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? id
        let body: JSONValue = .object([
            "title": .string(title),
            "profile": .string(profile),
        ])
        var request = makeRequest(path: "/api/sessions/\(encodedId)", method: "PATCH")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encodeBody(body, context: "patch")
        let data = try await perform(request)
        struct Wrapper: Decodable { let title: String? }
        return (try decode(
            Wrapper.self, from: data, context: "rename", strategy: .useDefaultKeys
        ).title) ?? title
    }

    // MARK: - Helpers

    /// Build a single `profile=…` query fragment, percent-encoding the name so a
    /// value with spaces/`/` survives.
    static func profileQuery(_ profile: String) -> String {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "profile", value: profile)]
        return (components.percentEncodedQuery ?? "")
            .replacingOccurrences(of: "+", with: "%2B")
    }
}
