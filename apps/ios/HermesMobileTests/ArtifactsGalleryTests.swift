import XCTest
@testable import HermesMobile

/// Unit tests for Task #14: artifacts gallery iOS grid + ABH-180 load-more.
///
/// All requests are intercepted via ``ArtifactStubProtocol`` (existing tests) or
/// the ``ArtifactsGalleryModel/fetchPage`` seam (pagination tests) — no live server.
/// Covers the required criteria:
///   1. ``testArtifactPageDecodes``           — envelope fields parse correctly.
///   2. ``testFilterTypeBuildsURL``           — `type=` param matches the filter.
///   3. ``testFallbackOn404``                 — 404 → throws `RestError.badStatus(404,_)`.
///   4. ``testOnlyFallBackOn404``             — 500 propagates, is not swallowed.
///   5. ``testBlobCacheKeyNilOnNoSize``       — link artifacts (no size) yield `nil` key.
///   6. ``testBlobCacheKeyNilOnEmptyServer``  — empty serverId yields `nil` key.
///   7. ``testDisplayNameFallback``           — last URL path component used when no filename.
///   8. ``testTotalIsGrandCount``             — `total` from envelope preserved (not page size).
///   9. ``testSharedMessageIdAllArtifactsUnique`` — M1: two artifacts sharing one message_id
///      have distinct composite ids (ForEach must not drop either).
///  10. ``testLoadMoreAppendsPageTwoWithOffset`` — ABH-180: load-more fetches offset=50 and
///      appends new artifacts; `hasMore` reflects remaining count vs total.
///  11. ``testLoadMoreStopsWhenTotalReached``    — ABH-180: `loadMore` no-ops once
///      `artifacts.count >= galleryTotal`.
///  12. ``testFilterChangeResetsOffsetAndResults`` — ABH-180: `load()` clears prior results
///      and resets offset and generation.
///  13. ``testNoDuplicateArtifactIdsAcrossPages`` — ABH-180: an artifact id appearing in
///      both message-pages is appended only once.
@MainActor
final class ArtifactsGalleryTests: XCTestCase {

    // MARK: - Helpers

    private let baseURL = URL(string: "http://127.0.0.1:9123")!
    private let token   = "test-token"

    /// Build a ``RestClient`` that routes through ``ArtifactStubProtocol`` with
    /// `.plugin` path style so the guard inside `artifacts()` passes.
    private func pluginClient() -> RestClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ArtifactStubProtocol.self]
        return RestClient(
            baseURL: baseURL,
            token: token,
            session: URLSession(configuration: config),
            pathStyle: .plugin
        )
    }

    override func setUp() {
        ArtifactStubProtocol.responses    = []
        ArtifactStubProtocol.capturedURLs = []
    }

    // MARK: - 1. Decode

    /// A full envelope with all optional fields present must parse into an
    /// ``ArtifactPage`` with one ``Artifact`` carrying all fields.
    func testArtifactPageDecodes() async throws {
        let json = """
        {
          "type": "images",
          "results": [
            {
              "session_id": "sess-abc",
              "session_title": "My Session",
              "message_id": 42,
              "kind": "image",
              "url_or_path": "https://example.com/photo.png",
              "filename": "photo.png",
              "mime": "image/png",
              "size": 98765,
              "snippet": null,
              "timestamp": 1700000000.0
            }
          ],
          "total": 1,
          "offset": 0
        }
        """
        ArtifactStubProtocol.responses = [(json.data(using: .utf8)!, 200)]
        let client = pluginClient()

        let page = try await client.artifacts(type: "images")

        XCTAssertEqual(page.type, "images")
        XCTAssertEqual(page.total, 1)
        XCTAssertEqual(page.offset, 0)
        XCTAssertEqual(page.results.count, 1)

        let art = page.results[0]
        XCTAssertEqual(art.messageId, 42)
        // Composite id must encode message_id + url_or_path so multiple artifacts
        // from the same message have distinct ForEach identities.
        XCTAssertEqual(art.id, "42:https://example.com/photo.png")
        XCTAssertEqual(art.sessionId, "sess-abc")
        XCTAssertEqual(art.sessionTitle, "My Session")
        XCTAssertEqual(art.kind, "image")
        XCTAssertEqual(art.urlOrPath, "https://example.com/photo.png")
        XCTAssertEqual(art.filename, "photo.png")
        XCTAssertEqual(art.mimeType, "image/png")
        XCTAssertEqual(art.size, 98765)
        XCTAssertNil(art.snippet)
        let ts = try XCTUnwrap(art.timestamp, "timestamp must be present")
        XCTAssertEqual(ts, 1700000000.0, accuracy: 0.001)
    }

    // MARK: - 2. URL building

    /// The `type=` query parameter must match the `ArtifactFilter.rawValue` passed
    /// to `artifacts(type:)`. The path must use the plugin prefix.
    func testFilterTypeBuildsURL() async throws {
        let json = """
        {"type":"files","results":[],"total":0,"offset":0}
        """
        ArtifactStubProtocol.responses = [(json.data(using: .utf8)!, 200)]
        let client = pluginClient()

        _ = try await client.artifacts(type: "files", limit: 50)

        guard let captured = ArtifactStubProtocol.capturedURLs.first else {
            return XCTFail("No URL captured")
        }
        XCTAssertTrue(
            captured.path.contains("/api/plugins/hermes-mobile/artifacts"),
            "URL must use the plugin prefix; got \(captured.path)"
        )
        let components = URLComponents(url: captured, resolvingAgainstBaseURL: false)
        let typeParam = components?.queryItems?.first(where: { $0.name == "type" })?.value
        XCTAssertEqual(typeParam, "files", "type= param must match the filter rawValue")
        let limitParam = components?.queryItems?.first(where: { $0.name == "limit" })?.value
        XCTAssertEqual(limitParam, "50")
    }

    // MARK: - 3. 404 fallback

    /// A 404 response from the gateway must throw `RestError.badStatus(404, _)` so
    /// callers (``ArtifactsGalleryView``) can degrade to `ContentUnavailableView`
    /// instead of an error state.
    func testFallbackOn404() async throws {
        ArtifactStubProtocol.responses = [(Data(), 404)]
        let client = pluginClient()

        do {
            _ = try await client.artifacts()
            XCTFail("Expected RestError.badStatus(404,_) — call should throw")
        } catch RestError.badStatus(404, _) {
            // Expected: callers distinguish 404 from other errors.
        } catch {
            XCTFail("Expected RestError.badStatus(404,_), got \(error)")
        }
    }

    // MARK: - 4. 500 surfaces

    /// A 500 response must throw and NOT be silently swallowed. Only 404 is the
    /// gateway-absent signal; real server errors propagate.
    func testOnlyFallBackOn404() async throws {
        let errJSON = """
        {"error": "internal server error"}
        """
        ArtifactStubProtocol.responses = [(errJSON.data(using: .utf8)!, 500)]
        let client = pluginClient()

        do {
            _ = try await client.artifacts()
            XCTFail("A 500 from the server must throw, not return silently")
        } catch RestError.badStatus(500, _) {
            // Expected: genuine server errors propagate.
        } catch {
            XCTFail("Expected RestError.badStatus(500,_), got \(error)")
        }
    }

    // MARK: - 5. Blob cache key nil when no size

    /// A link artifact (no `size`) must return `nil` from `blobCacheKey` — links
    /// have no byte count so they cannot be cached or looked up by size.
    func testBlobCacheKeyNilOnNoSize() {
        // Build an Artifact via JSON round-trip to exercise the real CodingKeys.
        let json = """
        {
          "session_id": "s1", "message_id": 1, "kind": "link",
          "url_or_path": "https://example.com", "session_title": null,
          "filename": null, "mime": null, "size": null,
          "snippet": null, "timestamp": null
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        let art = try! decoder.decode(Artifact.self, from: json)

        let key = art.blobCacheKey(serverId: "https://my-server.example", profileId: "default")
        XCTAssertNil(key, "Link artifacts with no size must produce a nil cache key")
    }

    // MARK: - 6. Blob cache key nil on empty serverId

    /// An empty `serverId` (not yet connected, or URL not yet set) must return
    /// `nil` from `blobCacheKey` — an empty server id is not a valid cache scope.
    func testBlobCacheKeyNilOnEmptyServer() {
        let json = """
        {
          "session_id": "s2", "message_id": 2, "kind": "image",
          "url_or_path": "https://example.com/img.png", "session_title": null,
          "filename": null, "mime": "image/png", "size": 1024,
          "snippet": null, "timestamp": null
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        let art = try! decoder.decode(Artifact.self, from: json)

        let key = art.blobCacheKey(serverId: "   ", profileId: "default")
        XCTAssertNil(key, "Whitespace-only serverId must produce a nil cache key")
    }

    // MARK: - 7. Display name fallback

    /// When `filename` is absent the last path component of `url_or_path` must
    /// be used as the display name.
    func testDisplayNameFallback() {
        let json = """
        {
          "session_id": "s3", "message_id": 3, "kind": "file",
          "url_or_path": "/home/user/workspace/report.pdf", "session_title": null,
          "filename": null, "mime": null, "size": 512,
          "snippet": null, "timestamp": null
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        let art = try! decoder.decode(Artifact.self, from: json)

        XCTAssertEqual(art.displayName, "report.pdf",
                       "displayName must fall back to the last path component")
    }

    // MARK: - 8. total is grand count

    /// `ArtifactPage.total` is the server's full matched count BEFORE pagination;
    /// it must NOT be confused with the per-page result count. Verify the field
    /// decodes correctly even when `results` is empty.
    func testTotalIsGrandCount() async throws {
        let json = """
        {"type":"all","results":[],"total":1234,"offset":50}
        """
        ArtifactStubProtocol.responses = [(json.data(using: .utf8)!, 200)]
        let client = pluginClient()

        let page = try await client.artifacts(offset: 50)

        XCTAssertEqual(page.total, 1234,
                       "total must reflect the grand matched count, not the page length")
        XCTAssertEqual(page.offset, 50)
        XCTAssertTrue(page.results.isEmpty)
    }

    // MARK: - 9. M1: shared message_id → distinct composite ids

    /// Two artifacts from the same message (same `message_id`, different
    /// `url_or_path`) must have distinct `Artifact.id` values so SwiftUI's
    /// `ForEach` does not drop either.
    ///
    /// This is the regression test for M1: the server can emit multiple artifacts
    /// per message_id (e.g. an image part AND a link extracted from the same
    /// message body in a `type=all` response). A message_id-only `id` would cause
    /// SwiftUI to render only one cell and silently discard the rest.
    func testSharedMessageIdAllArtifactsUnique() async throws {
        let json = """
        {
          "type": "all",
          "results": [
            {
              "session_id": "sess-1", "message_id": 99, "kind": "image",
              "url_or_path": "https://example.com/photo.png",
              "session_title": null, "filename": null, "mime": "image/png",
              "size": 1024, "snippet": null, "timestamp": null
            },
            {
              "session_id": "sess-1", "message_id": 99, "kind": "link",
              "url_or_path": "https://example.com/page",
              "session_title": null, "filename": null, "mime": null,
              "size": null, "snippet": "see here", "timestamp": null
            }
          ],
          "total": 2,
          "offset": 0
        }
        """
        ArtifactStubProtocol.responses = [(json.data(using: .utf8)!, 200)]
        let client = pluginClient()

        let page = try await client.artifacts()

        XCTAssertEqual(page.results.count, 2, "Both artifacts must be in the response")
        let ids = page.results.map(\.id)
        XCTAssertEqual(Set(ids).count, 2,
                       "Two artifacts sharing message_id 99 must have DISTINCT composite ids")
        XCTAssertEqual(ids[0], "99:https://example.com/photo.png")
        XCTAssertEqual(ids[1], "99:https://example.com/page")
        // messageId is preserved for navigation
        XCTAssertEqual(page.results[0].messageId, 99)
        XCTAssertEqual(page.results[1].messageId, 99)
    }

    // MARK: - 10. ABH-180: load-more appends page 2 with correct offset

    /// ``ArtifactsGalleryModel/load(type:api:)`` populates page 1;
    /// ``ArtifactsGalleryModel/loadMore(type:api:)`` must fetch with `offset=50`
    /// and append new artifacts. `hasMore` must reflect remaining count vs total.
    func testLoadMoreAppendsPageTwoWithOffset() async {
        let limit = ArtifactsGalleryModel.pageLimit   // 50
        var capturedOffsets: [Int] = []

        let model = ArtifactsGalleryModel()
        model.fetchPage = { type, offset in
            capturedOffsets.append(offset)
            // Page 1 (offset 0): 50 items, total = 80 → has-more after page 1.
            // Page 2 (offset 50): 30 items, total = 80 → done after page 2.
            let count = offset == 0 ? limit : 30
            let results = (offset..<offset + count).map { i in
                Artifact.stub(messageId: i, urlOrPath: "https://example.com/a\(i)")
            }
            return ArtifactPage(type: type, results: results, total: 80, offset: offset)
        }

        let dummyClient = RestClient(baseURL: URL(string: "http://127.0.0.1:9123")!,
                                     token: "t")

        // Page 1.
        await model.load(type: "all", api: dummyClient)
        XCTAssertEqual(model.artifacts.count, limit, "Page 1 must have \(limit) artifacts")
        XCTAssertTrue(model.hasMore, "hasMore must be true when artifacts.count < galleryTotal")
        XCTAssertEqual(capturedOffsets, [0], "Page-1 must use offset=0")
        XCTAssertEqual(model.galleryOffset, limit, "galleryOffset must advance to pageLimit")

        // Load-more.
        await model.loadMore(type: "all", api: dummyClient)
        XCTAssertEqual(capturedOffsets.count, 2, "loadMore must fire one more fetch")
        XCTAssertEqual(capturedOffsets[1], limit,
                       "Page-2 fetch must use offset=\(limit)")
        XCTAssertEqual(model.artifacts.count, 80, "Both pages must be combined")
        XCTAssertFalse(model.hasMore,
                       "hasMore must be false when artifacts.count == galleryTotal")
    }

    // MARK: - 11. ABH-180: loadMore no-ops when total reached

    /// Once `artifacts.count >= galleryTotal`, ``loadMore(type:api:)`` must be a
    /// no-op — no additional fetch must fire.
    func testLoadMoreStopsWhenTotalReached() async {
        let limit = ArtifactsGalleryModel.pageLimit
        var fetchCount = 0

        let model = ArtifactsGalleryModel()
        model.fetchPage = { type, offset in
            fetchCount += 1
            // Single page (30 items), total = 30 → no more pages.
            let results = (0..<30).map { i in
                Artifact.stub(messageId: i, urlOrPath: "https://example.com/b\(i)")
            }
            return ArtifactPage(type: type, results: results, total: 30, offset: 0)
        }

        let dummyClient = RestClient(baseURL: URL(string: "http://127.0.0.1:9123")!,
                                     token: "t")

        await model.load(type: "all", api: dummyClient)
        XCTAssertEqual(model.artifacts.count, 30)
        XCTAssertFalse(model.hasMore, "hasMore must be false: 30 artifacts == total 30")
        XCTAssertEqual(fetchCount, 1)

        // loadMore must no-op.
        await model.loadMore(type: "all", api: dummyClient)
        XCTAssertEqual(fetchCount, 1,
                       "loadMore must not fire when hasMore is false")
        XCTAssertEqual(model.artifacts.count, 30,
                       "Artifact count must not change after no-op loadMore")
        _ = limit  // suppress unused warning
    }

    // MARK: - 12. ABH-180: filter change resets offset and results

    /// A second call to ``load(type:api:)`` (filter change) must clear prior
    /// results, reset ``galleryOffset`` to 0, and bump the generation counter
    /// so any in-flight load-more is discarded.
    func testFilterChangeResetsOffsetAndResults() async {
        var lastType = "all"

        let model = ArtifactsGalleryModel()
        model.fetchPage = { type, _ in
            lastType = type
            let results = [
                Artifact.stub(messageId: 1, urlOrPath: "https://example.com/\(type)/1")
            ]
            return ArtifactPage(type: type, results: results, total: 1, offset: 0)
        }

        let dummyClient = RestClient(baseURL: URL(string: "http://127.0.0.1:9123")!,
                                     token: "t")
        let firstGeneration = model.generation

        // Initial load (all).
        await model.load(type: "all", api: dummyClient)
        XCTAssertEqual(model.artifacts.count, 1)
        XCTAssertTrue(model.artifacts[0].urlOrPath.contains("/all/"))

        // Filter change → load images.
        await model.load(type: "images", api: dummyClient)
        XCTAssertFalse(model.artifacts.contains(where: { $0.urlOrPath.contains("/all/") }),
                       "Old filter results must not survive a filter change")
        XCTAssertEqual(model.artifacts.count, 1,
                       "New filter must produce fresh results")
        XCTAssertTrue(model.artifacts[0].urlOrPath.contains("/images/"),
                      "Results must be from the new filter type")
        XCTAssertEqual(model.galleryOffset, ArtifactsGalleryModel.pageLimit,
                       "galleryOffset must be reset and then advanced by pageLimit")
        XCTAssertGreaterThan(model.generation, firstGeneration,
                             "generation must increment on each load() call")
        XCTAssertEqual(lastType, "images", "Fetch must use the new filter type")
    }

    // MARK: - 13. ABH-180: no duplicate artifact ids across pages

    /// An artifact composite id appearing in both page 1 and page 2 must appear
    /// only once in the accumulated ``ArtifactsGalleryModel/artifacts`` list.
    func testNoDuplicateArtifactIdsAcrossPages() async {
        let limit = ArtifactsGalleryModel.pageLimit
        var callCount = 0

        let model = ArtifactsGalleryModel()
        model.fetchPage = { type, offset in
            callCount += 1
            if offset == 0 {
                // Page 1: unique items + one "shared" artifact.
                var results = (0..<limit - 1).map { i in
                    Artifact.stub(messageId: i, urlOrPath: "https://example.com/unique/\(i)")
                }
                results.append(Artifact.stub(messageId: 999, urlOrPath: "https://shared.example/art"))
                return ArtifactPage(type: type, results: results, total: 100, offset: 0)
            } else {
                // Page 2: shared artifact re-appears + new items.
                var results = [
                    Artifact.stub(messageId: 999, urlOrPath: "https://shared.example/art")
                ]
                results.append(contentsOf: (100..<100 + limit - 1).map { i in
                    Artifact.stub(messageId: i, urlOrPath: "https://example.com/new/\(i)")
                })
                return ArtifactPage(type: type, results: results, total: 100, offset: offset)
            }
        }

        let dummyClient = RestClient(baseURL: URL(string: "http://127.0.0.1:9123")!,
                                     token: "t")

        await model.load(type: "all", api: dummyClient)
        await model.loadMore(type: "all", api: dummyClient)

        XCTAssertEqual(callCount, 2, "Both pages must be fetched")

        let sharedId = "999:https://shared.example/art"
        let duplicates = model.artifacts.filter { $0.id == sharedId }
        XCTAssertEqual(duplicates.count, 1,
                       "Shared artifact must appear exactly once across both pages")

        let allIds = model.artifacts.map(\.id)
        XCTAssertEqual(allIds.count, Set(allIds).count,
                       "All artifact ids must be unique across both pages")
    }
}

// MARK: - Artifact test helper

private extension Artifact {
    /// Minimal stub for pagination tests — avoids JSON round-trip boilerplate.
    static func stub(messageId: Int, urlOrPath: String) -> Artifact {
        let json = """
        {
          "session_id": "sess-\(messageId)", "message_id": \(messageId),
          "kind": "link", "url_or_path": "\(urlOrPath)",
          "session_title": null, "filename": null, "mime": null,
          "size": null, "snippet": null, "timestamp": null
        }
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(Artifact.self, from: json)
    }
}

// MARK: - ArtifactStubProtocol

/// A FIFO ``URLProtocol`` stub for ``ArtifactsGalleryTests``.
///
/// Enqueue `(Data, Int)` pairs in ``responses`` before the test; each request
/// dequeues one entry in order. Captured request URLs land in ``capturedURLs``
/// for assertion. When the queue is empty the stub responds 404.
final class ArtifactStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [(Data, Int)]   = []
    nonisolated(unsafe) static var capturedURLs: [URL]        = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url {
            ArtifactStubProtocol.capturedURLs.append(url)
        }
        let (body, status) = ArtifactStubProtocol.responses.isEmpty
            ? (Data(), 404)
            : ArtifactStubProtocol.responses.removeFirst()
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
