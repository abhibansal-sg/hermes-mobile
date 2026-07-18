import XCTest
@testable import HermesMobile

/// Wave-2 render-lane coverage (docs/RELAY-PHONE-PROTOCOL.md §2). Pins the
/// render-only `ChatItem` body projections, the image-source classification, and
/// the pure formatting helpers the per-type item views (`Views/Chat/Items/`) draw
/// from. Deterministic: constructs `ChatItem`s directly, no I/O, no view tree.
final class ChatItemRendererTests: XCTestCase {

    private func item(
        _ type: ChatItemType,
        rawType: String? = nil,
        status: ChatItemStatus = .completed,
        summary: String? = nil,
        body: JSONValue = .null
    ) -> ChatItem {
        ChatItem(itemID: "i", type: type, rawType: rawType, status: status, ord: 0, summary: summary, body: body)
    }

    // MARK: - Tool projections (§2 toolCall body)

    func testToolArgsResultDurationProjections() {
        let tool = item(.toolCall, body: [
            "name": "read_file",
            "args": ["path": "parser.swift"],
            "result": "…220 lines…",
            "duration_s": 0.42,
        ])
        XCTAssertEqual(tool.toolName, "read_file")
        XCTAssertEqual(tool.argsSummary, "{path: parser.swift}")
        XCTAssertEqual(tool.resultPreview, "…220 lines…")
        XCTAssertEqual(tool.durationSeconds, 0.42)
    }

    func testToolResultFallsBackToOutputAndCompactsStructured() {
        let tool = item(.toolCall, body: ["output": ["hits": 3]])
        XCTAssertEqual(tool.resultPreview, "{hits: 3}")
    }

    func testEmptyToolBodyYieldsEmptyProjections() {
        let tool = item(.toolCall, rawType: "quantum_flux", body: .null)
        XCTAssertEqual(tool.argsSummary, "")
        XCTAssertEqual(tool.resultPreview, "")
        XCTAssertNil(tool.durationSeconds)
        // Forward-compat: unknown tool keeps its real name for the generic card.
        XCTAssertEqual(tool.toolName, "quantum_flux")
    }

    // MARK: - Image projections + source classification (§2 image body)

    func testImageReferencePrecedence() {
        // host_image wins over the generic keys, matching the tool-path precedence.
        let img = item(.image, body: [
            "host_image": "https://h/img.png",
            "image": "https://i/other.png",
            "url": "https://u/last.png",
        ])
        XCTAssertEqual(img.imageReference, "https://h/img.png")

        // Falls through to url/source/path when the primary keys are absent.
        let pathImg = item(.image, body: ["path": "~/.hermes/uploads/x.png"])
        XCTAssertEqual(pathImg.imageReference, "~/.hermes/uploads/x.png")

        XCTAssertNil(item(.image, body: .null).imageReference)
    }

    func testImageAltPrecedence() {
        XCTAssertEqual(item(.image, summary: "s", body: ["alt": "a"]).imageAlt, "a")
        XCTAssertEqual(item(.image, summary: "s", body: ["caption": "c"]).imageAlt, "c")
        XCTAssertEqual(item(.image, summary: "s", body: .null).imageAlt, "s")
    }

    func testImageSourceClassification() {
        XCTAssertEqual(ItemImageSource(reference: "https://x/y.png"),
                       .remote(URL(string: "https://x/y.png")!))
        XCTAssertEqual(ItemImageSource(reference: "http://x/y.png"),
                       .remote(URL(string: "http://x/y.png")!))
        XCTAssertEqual(ItemImageSource(reference: "data:image/png;base64,AAAA"),
                       .dataURL("data:image/png;base64,AAAA"))
        XCTAssertEqual(ItemImageSource(reference: "~/.hermes/uploads/x.png"),
                       .opaque("~/.hermes/uploads/x.png"))
        // Whitespace is trimmed before classifying.
        XCTAssertEqual(ItemImageSource(reference: "  https://x/y.png  "),
                       .remote(URL(string: "https://x/y.png")!))
    }

    // MARK: - Browser projections (§2 browser body)

    func testBrowserProjections() {
        let br = item(.browser, body: [
            "name": "browser_snapshot",
            "url": "https://example.com",
            "screenshot": "https://example.com/shot.png",
        ])
        XCTAssertEqual(br.browserURL, "https://example.com")
        XCTAssertEqual(br.browserScreenshot, "https://example.com/shot.png")

        let navOnly = item(.browser, body: ["page_url": "https://docs.example.com"])
        XCTAssertEqual(navOnly.browserURL, "https://docs.example.com")
        XCTAssertNil(navOnly.browserScreenshot)
    }

    // MARK: - FileChange diff reuse (§2 fileChange body)

    func testFileChangeDiffStats() {
        let fc = item(.fileChange, body: [
            "path": "parser.swift",
            "inline_diff": "@@ -1,2 +1,3 @@\n context\n-old\n+new\n+added",
        ])
        let diff = try! XCTUnwrap(fc.inlineDiff)
        let stats = DiffRendering.stats(for: diff)
        XCTAssertEqual(stats.added, 2)
        XCTAssertEqual(stats.removed, 1)
    }

    // MARK: - Error text projection (§2 error body)

    func testErrorTextBody() {
        let err = item(.error, status: .failed, summary: "Build failed",
                       body: ["text": "2 errors in parser.swift"])
        XCTAssertEqual(err.textBody, "2 errors in parser.swift")
        // With no body text, textBody falls back to the summary.
        let bare = item(.error, status: .failed, summary: "Connection refused", body: .null)
        XCTAssertEqual(bare.textBody, "Connection refused")
    }

    // MARK: - Duration formatting

    func testDurationFormat() {
        XCTAssertEqual(ChatItemFormat.duration(0.42), "0.4s")
        XCTAssertEqual(ChatItemFormat.duration(12), "12s")
        XCTAssertEqual(ChatItemFormat.duration(1.0), "1s")
        XCTAssertNil(ChatItemFormat.duration(nil))
        XCTAssertNil(ChatItemFormat.duration(-1))
    }

    // MARK: - Usage line (parity with the legacy footer)

    func testUsageLineFormat() {
        let usage = item(.usage, body: [
            "usage": ["input": 1200, "output": 340, "total": 1540,
                      "cost_usd": 0.012, "context_used": 1540],
        ]).usageStats
        let stats = try! XCTUnwrap(usage)
        XCTAssertEqual(UsageFooterView.usageLine(stats), "1540 tokens · $0.0120 · ctx 1.5K")
    }

    func testUsageLineCombinesTokensWhenTotalMissing() {
        let stats = try! XCTUnwrap(item(.usage, body: ["usage": ["input": 800, "output": 200]]).usageStats)
        XCTAssertEqual(UsageFooterView.usageLine(stats), "1000 tokens")
    }

    func testUsageLineEmptyWhenNothingToShow() {
        let stats = try! XCTUnwrap(item(.usage, body: ["usage": [:]]).usageStats)
        XCTAssertNil(UsageFooterView.usageLine(stats))
    }

    // MARK: - Status word

    func testStatusWord() {
        XCTAssertEqual(item(.toolCall, status: .inProgress).statusWord, "running")
        XCTAssertEqual(item(.toolCall, status: .completed).statusWord, "done")
        XCTAssertEqual(item(.toolCall, status: .failed).statusWord, "failed")
    }
}
