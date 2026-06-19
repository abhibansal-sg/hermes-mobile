import XCTest
@testable import HermesMobile

/// Unit tests for ABH-179: offset pagination for `/api/sessions/search`.
///
/// ## Success criteria
///
/// (a) **Page 1 populates results** — `searchQueryChanged()` writes results and
///     sets `searchHasMore=true` (stock path, full page).
/// (b) **loadMore appends page 2 with correct offset** — a second `loadMoreSearchResults()`
///     call appends the new rows (deduped) and the seam receives `offset=N`.
/// (c) **Short page stops further requests** — after a page < `searchPageLimit`
///     rows, `searchHasMore = false`; a subsequent `loadMoreSearchResults()` no-ops.
/// (d) **New query resets offset + results** — `searchQueryChanged()` resets
///     `searchOffset`, `searchHasMore`, and `searchResults` before the new page lands.
/// (e) **Stale page after query change is ignored** — a load-more page that
///     arrives after the generation counter advanced is discarded.
///
/// **Plugin-path no-spin**: `loadMoreSearchResults()` on the plugin path must force
/// `searchHasMore = false` so the DrawerView sentinel never fires again.
///
/// All tests drive the REAL `searchQueryChanged()` / `loadMoreSearchResults()` Task-based
/// methods via the `#if DEBUG searchFetch` seam. No state is manually assigned to
/// reproduce what the method would have done — the method runs end-to-end.
///
/// Direct `fetchSearch(query:offset:api:)` calls cover only the offset URL-encoding
/// contract (independent of the task machinery).
///
/// Reuses ``SearchStubProtocol`` from ``PluginSearchTests`` (same test target).
@MainActor
final class SearchPaginationTests: XCTestCase {

    private let baseURL = URL(string: "http://127.0.0.1:9123")!
    private let token   = "test-token"

    /// Stock-path client: plugin route returns 404, falls back to stock+offset.
    private func stockClient() -> RestClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SearchStubProtocol.self]
        return RestClient(
            baseURL: baseURL, token: token,
            session: URLSession(configuration: config),
            pathStyle: .legacy
        )
    }

    /// Plugin-path client: plugin route succeeds, stock fallback never reached.
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

    /// 300ms debounce + one network round-trip.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(600))
    }

    override func setUp() {
        SearchStubProtocol.responses    = []
        SearchStubProtocol.capturedURLs = []
    }

    // MARK: - Helpers

    /// Build `count` distinct `SessionSearchResult` rows starting at `startIndex`.
    private func makeRows(_ count: Int, startIndex: Int = 0) -> [SessionSearchResult] {
        (startIndex..<startIndex + count).map { i in
            SessionSearchResult(id: "s\(i)", snippet: "hit \(i)", role: nil,
                                source: nil, model: nil, sessionStarted: nil)
        }
    }

    /// Enqueue a stock-path HTTP response body for `fetchSearch`.
    private func stockEnvelope(count: Int, startIndex: Int = 0) -> Data {
        let rows = (startIndex..<startIndex + count).map { i in
            #"{"session_id":"s\#(i)","snippet":"hit \#(i)","role":"user","session_started":0}"#
        }.joined(separator: ",")
        return #"{"results":[\#(rows)]}"#.data(using: .utf8)!
    }

    // MARK: - (a) Page 1 populates results

    /// `searchQueryChanged()` must write a full page into `searchResults` and set
    /// `searchHasMore = true` on the stock path.
    func testPageOnePopulatesResults() async {
        let store = SessionStore()
        store.searchQuery = "hello"
        store.searchFetch = { [pageLimit] _, _ in
            (self.makeRows(pageLimit), false)   // stock path, full page
        }
        store.searchQueryChanged()
        await settle()

        XCTAssertEqual(store.searchResults.count, pageLimit,
                       "A full stock page must populate searchResults with searchPageLimit rows")
        XCTAssertTrue(store.searchHasMore,
                      "A full stock page must set searchHasMore = true")
        XCTAssertEqual(store.searchOffset, pageLimit,
                       "searchOffset must advance to pageLimit after a full first page")
    }

    // MARK: - (b) loadMore appends page 2 with correct offset

    /// `loadMoreSearchResults()` must pass the current offset to the seam and append
    /// the returned rows without duplicates.
    func testLoadMoreAppendsPageTwoWithOffset() async {
        var capturedOffsets: [Int] = []
        let store = SessionStore()
        store.searchQuery = "hello"
        store.searchFetch = { [pageLimit] _, offset in
            capturedOffsets.append(offset)
            return (self.makeRows(pageLimit, startIndex: offset), false)
        }

        // Page 1.
        store.searchQueryChanged()
        await settle()
        XCTAssertEqual(store.searchResults.count, pageLimit, "Page 1 must populate results")
        XCTAssertTrue(store.searchHasMore, "Full page 1 must set searchHasMore")
        XCTAssertEqual(capturedOffsets, [0], "Page-1 fetch must use offset=0")

        // Page 2 via load-more.
        store.loadMoreSearchResults()
        await settle()

        XCTAssertEqual(capturedOffsets.count, 2, "loadMore must trigger exactly one more fetch")
        XCTAssertEqual(capturedOffsets[1], pageLimit,
                       "Page-2 fetch must use offset=\(pageLimit)")
        XCTAssertEqual(store.searchResults.count, 2 * pageLimit,
                       "Two full pages must yield 2 × searchPageLimit results")
        XCTAssertEqual(store.searchResults.last?.id, "s\(2 * pageLimit - 1)",
                       "Last row of page 2 must be appended at the end")
    }

    // MARK: - (c) Short page stops further requests

    /// After a short page, `searchHasMore` must be false and `loadMoreSearchResults`
    /// must not fire again.
    func testShortPageTerminatesPagination() async {
        var fetchCount = 0
        let store = SessionStore()
        store.searchQuery = "few"
        store.searchFetch = { _, _ in
            fetchCount += 1
            return (self.makeRows(3), false)   // always short
        }
        store.searchQueryChanged()
        await settle()

        XCTAssertFalse(store.searchHasMore,
                       "A short page must set searchHasMore = false")
        XCTAssertEqual(fetchCount, 1, "Only the initial fetch must have fired")

        // Attempt load-more — must no-op.
        store.loadMoreSearchResults()
        await settle()

        XCTAssertEqual(fetchCount, 1,
                       "loadMoreSearchResults must be a no-op when searchHasMore = false")
    }

    // MARK: - (d) New query resets offset, results, and generation

    /// A second `searchQueryChanged()` call must clear prior results, reset offset,
    /// and replace results with those from the new query.
    func testNewQueryResetsState() async {
        var currentQuery = "first"
        let store = SessionStore()
        store.searchQuery = currentQuery
        store.searchFetch = { [pageLimit] q, _ in
            (self.makeRows(pageLimit).map { r in
                SessionSearchResult(id: "\(q)-\(r.id)", snippet: r.snippet,
                                    role: nil, source: nil, model: nil, sessionStarted: nil)
            }, false)
        }
        store.searchQueryChanged()
        await settle()

        XCTAssertTrue(store.searchResults.first?.id.hasPrefix("first") == true,
                      "First query must produce first-prefixed results")
        XCTAssertTrue(store.searchHasMore)
        let firstGeneration = store.searchGeneration

        // New query.
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
                       "searchOffset must reflect the new page (reset + advance)")
    }

    // MARK: - (e) Stale load-more page is discarded

    /// A load-more page that resolves after the generation counter advances must
    /// be discarded — `searchResults` must remain unchanged.
    func testStaleLoadMorePageIsIgnored() async {
        // Phase 1: full first page.
        let store = SessionStore()
        store.searchQuery = "qq"
        var blockLoadMore = false

        store.searchFetch = { [pageLimit] _, offset in
            if offset > 0 && blockLoadMore {
                // Slow page — yields to let a query-change land first.
                try? await Task.sleep(for: .milliseconds(300))
                return (self.makeRows(pageLimit, startIndex: offset), false)
            }
            return (self.makeRows(pageLimit, startIndex: offset), false)
        }
        store.searchQueryChanged()
        await settle()

        XCTAssertEqual(store.searchResults.count, pageLimit)
        XCTAssertTrue(store.searchHasMore)

        // Start a slow load-more.
        blockLoadMore = true
        store.loadMoreSearchResults()
        // Immediately issue a new query — bumps generation before load-more page lands.
        store.searchQuery = "new-query"
        store.searchQueryChanged()
        await settle()   // let both tasks complete

        // The stale load-more page must have been discarded; only the new query rows survive.
        XCTAssertFalse(store.searchResults.contains(where: { $0.id == "s\(pageLimit)" }),
                       "Stale load-more rows (from the old query) must be discarded")
        XCTAssertLessThanOrEqual(store.searchResults.count, pageLimit,
                                  "Total results must not exceed one page (stale page dropped)")
    }

    // MARK: - Plugin path: load-more must not spin

    /// When the seam returns `servedByPlugin = true`, `searchQueryChanged()` must
    /// set `searchHasMore = false` even on a full page.
    func testPluginPathInitialFetchForcesSarchHasMoreFalse() async {
        let store = SessionStore()
        store.searchQuery = "qq"
        store.searchFetch = { [pageLimit] _, _ in
            (self.makeRows(pageLimit), true)   // plugin path, full page
        }
        store.searchQueryChanged()
        await settle()

        XCTAssertEqual(store.searchResults.count, pageLimit,
                       "Plugin path must return a full page of results")
        XCTAssertFalse(store.searchHasMore,
                       "Plugin path must force searchHasMore = false even for a full page")
    }

    /// `loadMoreSearchResults()` driven via seam with `servedByPlugin = true` must
    /// not append rows and must leave `searchHasMore = false`.
    func testPluginLoadMoreDoesNotSpin() async {
        var fetchCount = 0
        let store = SessionStore()
        store.searchQuery = "qq"
        store.searchFetch = { [pageLimit] _, _ in
            fetchCount += 1
            return (self.makeRows(pageLimit), true)   // plugin, full page every call
        }
        // Initial fetch.
        store.searchQueryChanged()
        await settle()

        XCTAssertFalse(store.searchHasMore,
                       "Plugin path initial fetch must NOT set searchHasMore = true")
        XCTAssertEqual(fetchCount, 1, "Only the initial fetch must have fired")

        // Attempt load-more — must be a no-op since searchHasMore = false.
        store.loadMoreSearchResults()
        await settle()

        XCTAssertEqual(fetchCount, 1,
                       "loadMoreSearchResults must not fire on plugin path (searchHasMore=false)")
    }

    // MARK: - Offset URL-encoding (via direct fetchSearch)

    /// Offset=0 (first page) must NOT appear in the request URL (server default).
    func testOffsetParamAbsentForFirstPage() async throws {
        SearchStubProtocol.responses = [(stockEnvelope(count: pageLimit), 200)]
        let client = stockClient()
        let store  = SessionStore()
        store.searchScope = .all

        _ = try await store.fetchSearch(query: "hello", offset: 0, api: client)

        guard let url = SearchStubProtocol.capturedURLs.first else {
            XCTFail("No URL captured"); return
        }
        XCTAssertFalse((url.query ?? "").contains("offset="),
                       "First-page request must not include offset= param, got: \(url.query ?? "")")
    }

    /// Offset>0 must appear in the request URL with the correct value.
    func testOffsetParamPresentForSubsequentPages() async throws {
        SearchStubProtocol.responses = [(stockEnvelope(count: pageLimit), 200)]
        let client = stockClient()
        let store  = SessionStore()
        store.searchScope = .all

        _ = try await store.fetchSearch(query: "hello", offset: 20, api: client)

        guard let url = SearchStubProtocol.capturedURLs.first else {
            XCTFail("No URL captured"); return
        }
        XCTAssertTrue((url.query ?? "").contains("offset=20"),
                      "Subsequent-page request must carry offset=20 in URL, got: \(url.query ?? "")")
    }
}
