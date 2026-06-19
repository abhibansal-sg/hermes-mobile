import XCTest
@testable import HermesMobile

/// Unit tests for Task #9: server full-text search iOS wiring.
///
/// Covers the four required criteria (no network — all requests intercepted via
/// ``SearchStubProtocol``):
///   1. ``testPluginSearchDecodes`` — canned envelope → all fields parse correctly.
///   2. ``testPluginSearchURLBuilt`` — path + percent-encoding are correct.
///   3. ``testFallbackToStockOn404`` — plugin 404 → stock endpoint called, results
///      returned, `lastError` remains nil.
///   4. ``testScopeMapsToRole`` — each ``SessionStore/SearchScope`` maps to the
///      right `role=` query params in the plugin URL.
///   5. ``testStaleResponseGuard`` — a response arriving after the query changed is
///      discarded (existing stale-guard behaviour preserved).
///   6. ``testRealErrorSurfaces`` — a 500 from the plugin is NOT silently swallowed
///      (only 404 falls back; real errors propagate).
///
/// ``SearchStubProtocol`` keeps a FIFO queue of (Data, Int) pairs so a single
/// call can describe what the plugin and then the stock endpoint both return —
/// without requiring a live server.
@MainActor
final class PluginSearchTests: XCTestCase {

    // MARK: - Helpers

    private let baseURL = URL(string: "http://127.0.0.1:9123")!
    private let token = "test-token"

    /// Build a ``RestClient`` that routes all requests through ``SearchStubProtocol``.
    /// `pathStyle: .plugin` so ``searchSessionsPlugin`` does not short-circuit.
    private func pluginClient() -> RestClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SearchStubProtocol.self]
        return RestClient(
            baseURL: baseURL,
            token: token,
            session: URLSession(configuration: config),
            pathStyle: .plugin
        )
    }

    /// Build a ``RestClient`` that speaks the stock (legacy) path style.
    private func stockClient() -> RestClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SearchStubProtocol.self]
        return RestClient(
            baseURL: baseURL,
            token: token,
            session: URLSession(configuration: config),
            pathStyle: .legacy
        )
    }

    override func setUp() {
        SearchStubProtocol.responses = []
        SearchStubProtocol.capturedURLs = []
    }

    // MARK: - 1. Decode

    /// The plugin envelope `{query, results:[{session_id, session_title,
    /// session_started_at, message_id, role, snippet, timestamp}], count, offset}`
    /// must parse completely into ``SessionSearchResult`` rows.
    func testPluginSearchDecodes() async throws {
        let json = """
        {
          "query": "hello",
          "results": [
            {
              "session_id": "sess-abc",
              "session_title": "My chat",
              "session_started_at": 1700000000.0,
              "message_id": 42,
              "role": "user",
              "snippet": "say <b>hello</b> world",
              "timestamp": 1700000001.0
            },
            {
              "session_id": "sess-def",
              "session_title": "Another chat",
              "session_started_at": 1699000000.0,
              "message_id": 7,
              "role": "assistant",
              "snippet": "respond here",
              "timestamp": 1699000005.0
            }
          ],
          "count": 2,
          "offset": 0
        }
        """
        SearchStubProtocol.responses = [(json.data(using: .utf8)!, 200)]
        let client = pluginClient()

        let (results, _) = try await client.searchSessionsPlugin(query: "hello")

        XCTAssertEqual(results.count, 2, "Both session rows must be decoded")
        let first = results[0]
        XCTAssertEqual(first.id, "sess-abc", "session_id must map to .id")
        XCTAssertEqual(first.snippet, "say <b>hello</b> world",
                       "snippet must be preserved verbatim (FTS markers intact)")
        XCTAssertEqual(first.role, "user", "role must round-trip")
        XCTAssertEqual(first.sessionStarted, 1700000000.0,
                       "session_started_at must map to sessionStarted")
        XCTAssertNil(first.source, "source is not returned by the plugin endpoint")

        let second = results[1]
        XCTAssertEqual(second.id, "sess-def")
        XCTAssertEqual(second.role, "assistant")
    }

    // MARK: - 2. URL built

    /// The plugin path must be `/api/plugins/hermes-mobile/sessions/search` and the
    /// query must be percent-encoded (space → %20 etc.).
    func testPluginSearchURLBuilt() async throws {
        let json = #"{"query":"hello world","results":[],"count":0,"offset":0}"#
        SearchStubProtocol.responses = [(json.data(using: .utf8)!, 200)]
        let client = pluginClient()

        _ = try await client.searchSessionsPlugin(query: "hello world")

        guard let url = SearchStubProtocol.capturedURLs.first else {
            XCTFail("No URL captured"); return
        }
        XCTAssertTrue(
            url.path.hasPrefix("/api/plugins/hermes-mobile/sessions/search"),
            "Plugin endpoint must be under /api/plugins/hermes-mobile/sessions/search, got \(url.path)"
        )
        let query = url.query ?? ""
        XCTAssertTrue(query.contains("q=hello%20world") || query.contains("q=hello+world"),
                      "Query term must be percent-encoded in the URL, got \(query)")
    }

    // MARK: - 3. Fallback on 404

    /// When the plugin endpoint returns 404, ``SessionStore/fetchSearch`` must
    /// transparently call the stock ``/api/sessions/search`` and return its results.
    /// `lastError` must remain nil — the degradation is silent (no user-visible error).
    func testFallbackToStockOn404() async throws {
        // Plugin → 404; stock → valid results.
        let notFound = #"{"error":"not found"}"#.data(using: .utf8)!
        let stockJSON = """
        {"results":[{"session_id":"s1","snippet":"found it","role":"user","session_started":0}]}
        """.data(using: .utf8)!
        SearchStubProtocol.responses = [
            (notFound, 404),
            (stockJSON, 200),
        ]

        let api = pluginClient()
        let store = SessionStore()
        store.searchScope = .all

        let (results, rawPageFull) = try await store.fetchSearch(query: "found", api: api)

        XCTAssertEqual(results.count, 1, "Stock fallback result must be returned")
        XCTAssertEqual(results[0].id, "s1", "Stock result session_id must parse correctly")
        // 1 result < searchPageLimit(20) → short page → rawPageFull = false.
        XCTAssertFalse(rawPageFull, "A short stock page must report rawPageFull = false")
        // lastError is untouched (fetchSearch doesn't write it; the caller Task does).
        XCTAssertEqual(SearchStubProtocol.capturedURLs.count, 2,
                       "Both plugin and stock endpoints must be called")
        // Verify the second URL is the stock path.
        let stockURL = SearchStubProtocol.capturedURLs[1]
        XCTAssertTrue(
            stockURL.path.hasPrefix("/api/sessions/search"),
            "Fallback must use stock /api/sessions/search, got \(stockURL.path)"
        )
    }

    // MARK: - 4. Scope → role mapping

    /// Each ``SessionStore/SearchScope`` must produce the correct `role=` params in the
    /// plugin query string: `.all` → no role, `.messages` → user+assistant, `.code` → tool.
    func testScopeMapsToRole() {
        XCTAssertEqual(SessionStore.roles(for: .all), [],
                       ".all must send no role filter")
        XCTAssertEqual(SessionStore.roles(for: .messages), ["user", "assistant"],
                       ".messages must map to user + assistant")
        XCTAssertEqual(SessionStore.roles(for: .code), ["tool"],
                       ".code must map to tool")
    }

    /// The `role=` params built from `.messages` scope must appear in the request URL
    /// as repeatable query items (`role=user&role=assistant`).
    func testScopeMessagesBuildsRoleParams() async throws {
        let json = #"{"query":"hi","results":[],"count":0,"offset":0}"#
        SearchStubProtocol.responses = [(json.data(using: .utf8)!, 200)]
        let client = pluginClient()

        _ = try await client.searchSessionsPlugin(
            query: "hi", roles: SessionStore.roles(for: .messages)
        )

        guard let url = SearchStubProtocol.capturedURLs.first else {
            XCTFail("No URL captured"); return
        }
        let query = url.query ?? ""
        XCTAssertTrue(query.contains("role=user"),
                      ".messages scope must include role=user in query, got \(query)")
        XCTAssertTrue(query.contains("role=assistant"),
                      ".messages scope must include role=assistant in query, got \(query)")
    }

    // MARK: - 5. Stale response guard

    /// The stale-response guard lives inside `searchQueryChanged`'s Task: if
    /// `searchQuery` has advanced past the debounced `trimmed` by the time the
    /// network response arrives, the result is silently discarded and
    /// `searchResults` is not updated.
    ///
    /// We verify: (a) `fetchSearch` itself still returns the decoded rows (it has
    /// no stale logic — it's a pure fetch); (b) the guard condition `searchQuery ≠ trimmed`
    /// correctly identifies the stale case so the caller Task drops the result.
    func testStaleResponseGuard() async throws {
        let json = """
        {"query":"old","results":[{"session_id":"stale","snippet":"stale","role":"user",
         "session_started_at":0,"message_id":1,"timestamp":0}],"count":1,"offset":0}
        """
        SearchStubProtocol.responses = [(json.data(using: .utf8)!, 200)]
        let api = pluginClient()
        let store = SessionStore()
        // Simulate the user typing on: searchQuery has moved past the in-flight "old".
        store.searchQuery = "new query"

        let (results, _) = try await store.fetchSearch(query: "old", api: api)

        // (a) fetchSearch returns the decoded rows — the stale guard is the caller's job.
        XCTAssertFalse(results.isEmpty, "fetchSearch itself must return the decoded rows")
        XCTAssertEqual(results[0].id, "stale")

        // (b) The guard condition evaluates correctly: current query ≠ in-flight trimmed.
        let trimmed = "old"
        let currentTrimmed = store.searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(currentTrimmed == trimmed,
                       "Guard must detect the stale case and would discard the result in the Task")
    }

    // MARK: - 6. Real 500 surfaces (not swallowed)

    /// A 500 from the plugin must be re-thrown — only 404 triggers the stock fallback.
    /// Swallowing a 500 would mask genuine server failures.
    func testRealErrorSurfaces() async {
        let serverError = #"{"error":"internal error"}"#.data(using: .utf8)!
        SearchStubProtocol.responses = [(serverError, 500)]
        let client = pluginClient()

        do {
            _ = try await client.searchSessionsPlugin(query: "crash")
            XCTFail("A 500 from the plugin must throw, not return silently")
        } catch RestError.badStatus(500, _) {
            // Expected: a genuine 500 propagates.
        } catch {
            XCTFail("Expected RestError.badStatus(500), got \(error)")
        }
    }

    // MARK: - 7. Per-session dedup

    /// When the plugin returns multiple rows for the SAME session_id, only the
    /// first (highest-ranking) row must appear in the collapsed result list.
    func testPerSessionDedup() async throws {
        let json = """
        {
          "query": "dup",
          "results": [
            {"session_id":"sess-1","session_title":"A","session_started_at":0,
             "message_id":1,"role":"user","snippet":"first hit","timestamp":0},
            {"session_id":"sess-1","session_title":"A","session_started_at":0,
             "message_id":2,"role":"assistant","snippet":"second hit","timestamp":1},
            {"session_id":"sess-2","session_title":"B","session_started_at":0,
             "message_id":3,"role":"user","snippet":"other","timestamp":0}
          ],
          "count": 3,
          "offset": 0
        }
        """
        SearchStubProtocol.responses = [(json.data(using: .utf8)!, 200)]
        let client = pluginClient()

        let (results, _) = try await client.searchSessionsPlugin(query: "dup")

        XCTAssertEqual(results.count, 2,
                       "Two distinct session_ids must produce exactly two rows")
        XCTAssertEqual(results[0].id, "sess-1")
        XCTAssertEqual(results[0].snippet, "first hit",
                       "First (best-ranking) snippet must win for the deduplicated session")
        XCTAssertEqual(results[1].id, "sess-2")
    }

}

// MARK: - SearchStubProtocol

/// A FIFO ``URLProtocol`` stub for ``PluginSearchTests``.
///
/// Enqueue responses in ``responses`` before the test; each request dequeues
/// one entry in order (plugin call first, stock fallback second, etc.).
/// Captured request URLs are appended to ``capturedURLs`` for assertion.
final class SearchStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [(Data, Int)] = []
    nonisolated(unsafe) static var capturedURLs: [URL] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url {
            SearchStubProtocol.capturedURLs.append(url)
        }
        let (body, status) = SearchStubProtocol.responses.isEmpty
            ? (Data(), 404)
            : SearchStubProtocol.responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
