import XCTest
@testable import HermesMobile

/// Unit tests for ABH-179: offset pagination for `/api/sessions/search` (stock)
/// and `/api/plugins/hermes-mobile/sessions/search` (plugin).
///
/// ## Success criteria
///
/// (a) **Page 1 populates results** — `searchQueryChanged()` writes results and
///     sets `searchHasMore=true` when the raw page was full.
/// (b) **loadMore appends page 2 with correct offset** — `loadMoreSearchResults()`
///     receives `offset=searchPageLimit` and appends new rows without duplicates.
/// (c) **Short raw page stops further requests** — `rawPageFull=false` → `searchHasMore=false`;
///     a subsequent `loadMoreSearchResults()` no-ops.
/// (d) **New query resets offset + results** — `searchQueryChanged()` clears prior
///     results, resets offset and generation.
/// (e) **Stale page after query change is discarded** — generation guard in the
///     real Task discards a load-more page that arrives after the query changed.
///
/// ## Plugin-path pagination (NEW — ABH-179 live-path)
///
/// (f) **Plugin load-more sends offset and appends new sessions** — seam returns
///     `rawPageFull=true` on page 1; `loadMoreSearchResults()` fires with `offset=limit`
///     and appends sessions from page 2.
/// (g) **Cross-page session dedup** — a session_id appearing in both message-pages
///     is NOT duplicated in `searchResults`.
/// (h) **has-more keys on rawPageFull, not collapsed count** — a full raw page that
///     collapses to zero new sessions still keeps `searchHasMore=true`; a short raw
///     page stops pagination even when the collapsed count is non-zero.
/// (i) **Offset cap respected** — once `searchOffset >= searchOffsetCap`, load-more
///     no-ops even when `searchHasMore` is still true on the prior page.
///
/// All tests drive REAL `searchQueryChanged()` / `loadMoreSearchResults()` via the
/// `#if DEBUG searchFetch` seam — no manual state replication.
///
/// URL-encoding contract tests use `fetchSearch()` directly via `SearchStubProtocol`.
///
/// Reuses ``SearchStubProtocol`` from ``PluginSearchTests`` (same test target).
@MainActor
final class SearchPaginationTests: XCTestCase {

    private let baseURL = URL(string: "http://127.0.0.1:9123")!
    private let token   = "test-token"

    private func stockClient() -> RestClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SearchStubProtocol.self]
        return RestClient(
            baseURL: baseURL, token: token,
            session: URLSession(configuration: config),
            pathStyle: .legacy
        )
    }

    private func pluginClient() -> RestClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SearchStubProtocol.self]
        return RestClient(
            baseURL: baseURL, token: token,
            session: URLSession(configuration: config),
            pathStyle: .plugin
        )
    }

    private let pageLimit = SessionStore.searchPageLimit   // 20

    /// 300ms debounce + one Task round-trip.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(600))
    }

    override func setUp() {
        SearchStubProtocol.responses    = []
        SearchStubProtocol.capturedURLs = []
    }

    // MARK: - Helpers

    private func makeRows(_ count: Int, startIndex: Int = 0) -> [SessionSearchResult] {
        (startIndex..<startIndex + count).map { i in
            SessionSearchResult(id: "s\(i)", snippet: "hit \(i)", role: nil,
                                source: nil, model: nil, sessionStarted: nil)
        }
    }

    private func stockEnvelope(count: Int, startIndex: Int = 0) -> Data {
        let rows = (startIndex..<startIndex + count).map { i in
            #"{"session_id":"s\#(i)","snippet":"hit \#(i)","role":"user","session_started":0}"#
        }.joined(separator: ",")
        return #"{"results":[\#(rows)]}"#.data(using: .utf8)!
    }

    // MARK: - (a) Page 1 populates results

    /// `searchQueryChanged()` on a full page must populate `searchResults` and set
    /// `searchHasMore = true`.
    func testPageOnePopulatesResults() async {
        let store = SessionStore()
        store.searchQuery = "hello"
        store.searchFetch = { [pageLimit] _, _ in
            // rawPageFull = true: raw page is full → more may exist.
            (self.makeRows(pageLimit), true)
        }
        store.searchQueryChanged()
        await settle()

        XCTAssertEqual(store.searchResults.count, pageLimit,
                       "A full page must populate searchResults with searchPageLimit rows")
        XCTAssertTrue(store.searchHasMore,
                      "rawPageFull=true must set searchHasMore = true")
        XCTAssertEqual(store.searchOffset, pageLimit,
                       "searchOffset must advance to pageLimit after a full first page")
    }

    // MARK: - (b) loadMore appends page 2 with correct offset

    /// `loadMoreSearchResults()` must pass `offset=pageLimit` to the seam and append
    /// the returned rows without duplicates.
    func testLoadMoreAppendsPageTwoWithOffset() async {
        var capturedOffsets: [Int] = []
        let store = SessionStore()
        store.searchQuery = "hello"
        store.searchFetch = { [pageLimit] _, offset in
            capturedOffsets.append(offset)
            // Always a full raw page → more may exist.
            return (self.makeRows(pageLimit, startIndex: offset), true)
        }

        // Page 1.
        store.searchQueryChanged()
        await settle()
        XCTAssertEqual(store.searchResults.count, pageLimit, "Page 1 must populate results")
        XCTAssertTrue(store.searchHasMore, "Full raw page 1 must set searchHasMore")
        XCTAssertEqual(capturedOffsets, [0], "Page-1 fetch must use offset=0")

        // Page 2 via load-more.
        store.loadMoreSearchResults()
        await settle()

        XCTAssertEqual(capturedOffsets.count, 2, "loadMore must trigger exactly one more fetch")
        XCTAssertEqual(capturedOffsets[1], pageLimit,
                       "Page-2 fetch must use offset=pageLimit (\(pageLimit))")
        XCTAssertEqual(store.searchResults.count, 2 * pageLimit,
                       "Two full pages must yield 2 × searchPageLimit results")
        XCTAssertEqual(store.searchResults.last?.id, "s\(2 * pageLimit - 1)",
                       "Last row of page 2 must be appended at the end")
    }

    // MARK: - (c) Short raw page stops further requests

    /// After a short raw page (`rawPageFull=false`), `searchHasMore` must be false
    /// and `loadMoreSearchResults` must not fire again.
    func testShortPageTerminatesPagination() async {
        var fetchCount = 0
        let store = SessionStore()
        store.searchQuery = "few"
        store.searchFetch = { _, _ in
            fetchCount += 1
            // rawPageFull = false: short page, no more.
            return (self.makeRows(3), false)
        }
        store.searchQueryChanged()
        await settle()

        XCTAssertFalse(store.searchHasMore,
                       "rawPageFull=false must set searchHasMore = false")
        XCTAssertEqual(fetchCount, 1, "Only the initial fetch must have fired")

        store.loadMoreSearchResults()
        await settle()

        XCTAssertEqual(fetchCount, 1,
                       "loadMoreSearchResults must no-op when searchHasMore = false")
    }

    // MARK: - (d) New query resets offset, results, and generation

    /// A second `searchQueryChanged()` must replace prior results and reset pagination
    /// state.
    func testNewQueryResetsState() async {
        var currentQuery = "first"
        let store = SessionStore()
        store.searchQuery = currentQuery
        store.searchFetch = { [pageLimit] q, _ in
            (self.makeRows(pageLimit).map { r in
                SessionSearchResult(id: "\(q)-\(r.id)", snippet: r.snippet,
                                    role: nil, source: nil, model: nil, sessionStarted: nil)
            }, true)   // rawPageFull = true
        }
        store.searchQueryChanged()
        await settle()

        XCTAssertTrue(store.searchResults.first?.id.hasPrefix("first") == true,
                      "First query must produce first-prefixed results")
        XCTAssertTrue(store.searchHasMore)
        let firstGeneration = store.searchGeneration

        currentQuery = "second"
        store.searchQuery = "second"
        store.searchQueryChanged()
        await settle()

        XCTAssertFalse(store.searchResults.contains(where: { $0.id.hasPrefix("first") }),
                       "Old query results must not survive a new query")
        XCTAssertTrue(store.searchResults.first?.id.hasPrefix("second") == true,
                      "New query results must be present after a query change")
        XCTAssertGreaterThan(store.searchGeneration, firstGeneration,
                             "searchGeneration must increment on each new query")
        XCTAssertEqual(store.searchOffset, pageLimit,
                       "searchOffset must reflect the new page after reset + advance")
    }

    // MARK: - (e) Stale load-more page is discarded

    /// A load-more page arriving after a query change must be discarded via the
    /// generation guard in the real Task — not by manual state replication.
    func testStaleLoadMorePageIsIgnored() async {
        let store = SessionStore()
        store.searchQuery = "qq"
        var blockLoadMore = false

        store.searchFetch = { [pageLimit] _, offset in
            if offset > 0 && blockLoadMore {
                // Slow page — lets a new query land first.
                try? await Task.sleep(for: .milliseconds(300))
                return (self.makeRows(pageLimit, startIndex: offset), true)
            }
            return (self.makeRows(pageLimit, startIndex: offset), true)
        }
        store.searchQueryChanged()
        await settle()

        XCTAssertEqual(store.searchResults.count, pageLimit)
        XCTAssertTrue(store.searchHasMore)

        blockLoadMore = true
        store.loadMoreSearchResults()
        // Immediately issue a new query — bumps generation before load-more page lands.
        store.searchQuery = "new-query"
        store.searchQueryChanged()
        await settle()

        XCTAssertFalse(store.searchResults.contains(where: { $0.id == "s\(pageLimit)" }),
                       "Stale load-more rows must be discarded after a query change")
        XCTAssertLessThanOrEqual(store.searchResults.count, pageLimit,
                                  "Stale page must not be appended")
    }

    // MARK: - (f) Plugin load-more sends offset and appends new sessions

    /// On the plugin path, `loadMoreSearchResults()` must send `offset=pageLimit`
    /// and append new sessions from the subsequent message-page.
    func testPluginLoadMoreSendsOffsetAndAppends() async {
        var capturedOffsets: [Int] = []
        let store = SessionStore()
        store.searchQuery = "qq"
        store.searchFetch = { [pageLimit] _, offset in
            capturedOffsets.append(offset)
            // Plugin path: rawPageFull=true for all full pages.
            return (self.makeRows(pageLimit, startIndex: offset), true)
        }

        // Page 1.
        store.searchQueryChanged()
        await settle()
        XCTAssertEqual(store.searchResults.count, pageLimit,
                       "Plugin page 1 must populate searchResults")
        XCTAssertTrue(store.searchHasMore,
                      "Plugin rawPageFull=true must allow load-more")
        XCTAssertEqual(capturedOffsets, [0])

        // Load-more: must send offset=pageLimit and append.
        store.loadMoreSearchResults()
        await settle()

        XCTAssertEqual(capturedOffsets.count, 2,
                       "load-more must fire exactly one additional fetch")
        XCTAssertEqual(capturedOffsets[1], pageLimit,
                       "Plugin load-more fetch must use offset=pageLimit (\(pageLimit))")
        XCTAssertEqual(store.searchResults.count, 2 * pageLimit,
                       "Plugin pages 1+2 must be appended")
    }

    // MARK: - (g) Cross-page session dedup

    /// A session_id appearing in two consecutive message-pages must appear only once
    /// in `searchResults` (the first occurrence's snippet wins).
    func testPluginCrossPageSessionDedup() async {
        let store = SessionStore()
        store.searchQuery = "qq"
        var callCount = 0

        store.searchFetch = { [pageLimit] _, offset in
            callCount += 1
            if offset == 0 {
                // Page 1: sessions s0..s(limit-2) + "shared-session".
                var rows = self.makeRows(pageLimit - 1)
                rows.append(SessionSearchResult(
                    id: "shared-session", snippet: "first occurrence",
                    role: nil, source: nil, model: nil, sessionStarted: nil
                ))
                return (rows, true)   // full raw page
            } else {
                // Page 2: "shared-session" + some new sessions.
                var rows = [SessionSearchResult(
                    id: "shared-session", snippet: "duplicate — must be dropped",
                    role: nil, source: nil, model: nil, sessionStarted: nil
                )]
                rows.append(contentsOf: self.makeRows(pageLimit - 1, startIndex: 100))
                return (rows, false)   // short raw page → stops pagination
            }
        }

        store.searchQueryChanged()
        await settle()
        store.loadMoreSearchResults()
        await settle()

        XCTAssertEqual(callCount, 2, "Both pages must be fetched")

        // shared-session must appear exactly once.
        let sharedCount = store.searchResults.filter { $0.id == "shared-session" }.count
        XCTAssertEqual(sharedCount, 1,
                       "shared-session must not be duplicated across pages")

        // When it does appear, the first-occurrence snippet must win.
        let sharedRow = store.searchResults.first { $0.id == "shared-session" }
        XCTAssertEqual(sharedRow?.snippet, "first occurrence",
                       "First occurrence's snippet must win on cross-page dedup")

        // Total unique sessions = (pageLimit-1) from page1 + 1 shared + (pageLimit-1) from page2.
        XCTAssertEqual(store.searchResults.count, 2 * pageLimit - 1,
                       "Total must equal unique sessions across both pages")
    }

    // MARK: - (h) has-more keys on rawPageFull, not collapsed count

    /// A full raw page (rawPageFull=true) that collapses to zero NEW sessions must
    /// still keep `searchHasMore=true` (more raw messages may exist).
    /// A short raw page (rawPageFull=false) must stop pagination even with results.
    func testHasMoreKeysOnRawPageFullNotCollapsedCount() async {
        let store = SessionStore()
        store.searchQuery = "qq"
        var callCount = 0

        store.searchFetch = { [pageLimit] _, offset in
            callCount += 1
            if offset == 0 {
                // Full raw page → rawPageFull = true.
                return (self.makeRows(pageLimit), true)
            } else {
                // Second call: full raw page but ALL sessions are already in results
                // (same ids as page 1 — simulates heavy collapse where no new sessions
                // emerge but the raw page was still full).
                return (self.makeRows(pageLimit), true)
            }
        }

        // After page 1 (rawPageFull=true), searchHasMore must be true.
        store.searchQueryChanged()
        await settle()
        XCTAssertTrue(store.searchHasMore,
                      "Full raw page must set searchHasMore=true regardless of collapsed count")

        // After load-more with same ids (deduped → zero new sessions appended),
        // searchHasMore still depends only on rawPageFull.
        store.loadMoreSearchResults()
        await settle()

        // Results stay at pageLimit (deduped, nothing new added from page 2).
        XCTAssertEqual(store.searchResults.count, pageLimit,
                       "Deduped load-more must not append duplicates")
        // But has-more is still true because raw page was full.
        XCTAssertTrue(store.searchHasMore,
                      "rawPageFull=true on load-more must keep searchHasMore=true")
        XCTAssertEqual(callCount, 2, "Both fetches must have fired")

        // Now a short raw page stops it.
        store.searchFetch = { _, _ in
            callCount += 1
            return (self.makeRows(3), false)   // rawPageFull = false
        }
        store.loadMoreSearchResults()
        await settle()

        XCTAssertFalse(store.searchHasMore,
                       "rawPageFull=false must set searchHasMore=false")
        XCTAssertEqual(callCount, 3, "Third fetch must have fired")
    }

    // MARK: - (i) Offset cap respected

    /// Once `searchOffset >= searchOffsetCap`, `loadMoreSearchResults()` must be a
    /// no-op even when the prior page was full.
    func testOffsetCapPreventsLoadMore() async {
        let store = SessionStore()
        store.searchQuery = "qq"
        var fetchCount = 0

        store.searchFetch = { [pageLimit] _, _ in
            fetchCount += 1
            return (self.makeRows(pageLimit), true)   // always full
        }
        store.searchQueryChanged()
        await settle()

        XCTAssertTrue(store.searchHasMore)
        XCTAssertEqual(fetchCount, 1)

        // Manually advance offset to the cap.
        store.searchOffset = SessionStore.searchOffsetCap

        // loadMoreSearchResults guard checks `searchOffset < searchOffsetCap`.
        store.loadMoreSearchResults()
        await settle()

        XCTAssertEqual(fetchCount, 1,
                       "loadMoreSearchResults must no-op when searchOffset >= searchOffsetCap")
    }

    // MARK: - Offset URL-encoding (via direct fetchSearch / searchSessionsPlugin)

    /// Offset=0 must NOT appear in the plugin URL (server default).
    func testPluginOffsetAbsentForFirstPage() async throws {
        let pluginJSON = #"{"results":[],"count":0,"offset":0}"#
        SearchStubProtocol.responses = [(pluginJSON.data(using: .utf8)!, 200)]
        let client = pluginClient()
        let store  = SessionStore()
        store.searchScope = .all

        _ = try await client.searchSessionsPlugin(query: "hello", offset: 0)

        guard let url = SearchStubProtocol.capturedURLs.first else {
            XCTFail("No URL captured"); return
        }
        XCTAssertFalse((url.query ?? "").contains("offset="),
                       "Plugin first-page request must not include offset= param, got: \(url.query ?? "")")
    }

    /// Offset>0 must appear in the plugin URL.
    func testPluginOffsetPresentForSubsequentPages() async throws {
        let pluginJSON = #"{"results":[],"count":0,"offset":20}"#
        SearchStubProtocol.responses = [(pluginJSON.data(using: .utf8)!, 200)]
        let client = pluginClient()
        let store  = SessionStore()
        store.searchScope = .all

        _ = try await client.searchSessionsPlugin(query: "hello", offset: 20)

        guard let url = SearchStubProtocol.capturedURLs.first else {
            XCTFail("No URL captured"); return
        }
        XCTAssertTrue((url.query ?? "").contains("offset=20"),
                      "Plugin load-more request must carry offset=20 in URL, got: \(url.query ?? "")")
    }

    /// Offset=0 must NOT appear in the stock URL.
    func testStockOffsetAbsentForFirstPage() async throws {
        SearchStubProtocol.responses = [(stockEnvelope(count: pageLimit), 200)]
        let client = stockClient()
        let store  = SessionStore()
        store.searchScope = .all

        _ = try await store.fetchSearch(query: "hello", offset: 0, api: client)

        guard let url = SearchStubProtocol.capturedURLs.first else {
            XCTFail("No URL captured"); return
        }
        XCTAssertFalse((url.query ?? "").contains("offset="),
                       "Stock first-page request must not include offset= param, got: \(url.query ?? "")")
    }

    /// Offset>0 must appear in the stock URL.
    func testStockOffsetPresentForSubsequentPages() async throws {
        SearchStubProtocol.responses = [(stockEnvelope(count: pageLimit), 200)]
        let client = stockClient()
        let store  = SessionStore()
        store.searchScope = .all

        _ = try await store.fetchSearch(query: "hello", offset: 20, api: client)

        guard let url = SearchStubProtocol.capturedURLs.first else {
            XCTFail("No URL captured"); return
        }
        XCTAssertTrue((url.query ?? "").contains("offset=20"),
                      "Stock load-more request must carry offset=20 in URL, got: \(url.query ?? "")")
    }
}
