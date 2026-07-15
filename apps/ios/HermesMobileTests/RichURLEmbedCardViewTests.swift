import XCTest
@testable import HermesMobile

final class RichURLEmbedCardViewTests: XCTestCase {
    private func descriptor(
        provider: RichURLEmbedProvider = .youtube,
        maxWidth: Double,
        aspectRatio: Double?,
        fixedHeight: Double?
    ) -> RichURLEmbedDescriptor {
        RichURLEmbedDescriptor(
            provider: provider,
            sourceURL: URL(string: "https://example.com")!,
            embedURL: URL(string: "https://example.com/embed")!,
            label: "Example",
            maxWidth: maxWidth,
            aspectRatio: aspectRatio,
            fixedHeight: fixedHeight,
            id: "example:1"
        )
    }

    func testWidthCapsAtMaxWidthWhenColumnIsWider() {
        let embed = descriptor(maxWidth: 640, aspectRatio: 16 / 9, fixedHeight: nil)

        XCTAssertEqual(RichURLEmbedLayout.width(for: embed, availableWidth: 1000), 640)
    }

    func testWidthShrinksToNarrowerColumn() {
        let embed = descriptor(maxWidth: 640, aspectRatio: 16 / 9, fixedHeight: nil)

        XCTAssertEqual(RichURLEmbedLayout.width(for: embed, availableWidth: 320), 320)
    }

    func testWidthNeverGoesNegative() {
        let embed = descriptor(maxWidth: 640, aspectRatio: 16 / 9, fixedHeight: nil)

        XCTAssertEqual(RichURLEmbedLayout.width(for: embed, availableWidth: -50), 0)
    }

    func testHeightSolvesAspectRatioAgainstRenderedWidth() {
        let embed = descriptor(maxWidth: 640, aspectRatio: 16 / 9, fixedHeight: nil)

        XCTAssertEqual(RichURLEmbedLayout.height(for: embed, width: 640), 640 / (16.0 / 9.0), accuracy: 0.001)
        // A narrower column recomputes height, not just clamps it.
        XCTAssertEqual(RichURLEmbedLayout.height(for: embed, width: 320), 320 / (16.0 / 9.0), accuracy: 0.001)
    }

    func testHeightUsesMapsAspectRatio() {
        let embed = descriptor(provider: .googleMaps, maxWidth: 640, aspectRatio: 16 / 10, fixedHeight: nil)

        XCTAssertEqual(RichURLEmbedLayout.height(for: embed, width: 640), 640 / (16.0 / 10.0), accuracy: 0.001)
    }

    func testHeightPrefersFixedHeightOverAspectRatio() {
        let embed = descriptor(provider: .spotify, maxWidth: 480, aspectRatio: nil, fixedHeight: 152)

        XCTAssertEqual(RichURLEmbedLayout.height(for: embed, width: 480), 152)
        // Fixed height does not scale with width — that is the point of "fixed".
        XCTAssertEqual(RichURLEmbedLayout.height(for: embed, width: 200), 152)
    }

    func testHeightFallsBackWhenNeitherFixedHeightNorAspectRatioIsSet() {
        let embed = descriptor(maxWidth: 640, aspectRatio: nil, fixedHeight: nil)

        XCTAssertEqual(
            RichURLEmbedLayout.height(for: embed, width: 640),
            640 / RichURLEmbedLayout.fallbackAspectRatio,
            accuracy: 0.001
        )
    }

    func testOpenLabelIncludesProviderLabel() {
        let youtube = descriptor(provider: .youtube, maxWidth: 640, aspectRatio: 16 / 9, fixedHeight: nil)
        let spotify = descriptor(provider: .spotify, maxWidth: 480, aspectRatio: nil, fixedHeight: 152)

        XCTAssertEqual(RichURLEmbedLayout.openLabel(for: youtube), "Open Example")
        XCTAssertEqual(RichURLEmbedLayout.openLabel(for: spotify), "Open Example")
    }
}
