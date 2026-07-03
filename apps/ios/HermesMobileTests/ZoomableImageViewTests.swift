import CoreGraphics
import XCTest
@testable import HermesMobile

final class ZoomableImageViewTests: XCTestCase {

    func testClampedScaleStaysInsideViewerBounds() {
        XCTAssertEqual(ZoomableImageMetrics.clampedScale(0.25), 1.0)
        XCTAssertEqual(ZoomableImageMetrics.clampedScale(3.5), 3.5)
        XCTAssertEqual(ZoomableImageMetrics.clampedScale(12.0), 6.0)
    }

    func testFittedSizePreservesAspectRatioInsideBounds() {
        let wide = ZoomableImageMetrics.fittedSize(
            imageSize: CGSize(width: 400, height: 200),
            in: CGSize(width: 300, height: 300)
        )
        XCTAssertEqual(wide.width, 300, accuracy: 0.001)
        XCTAssertEqual(wide.height, 150, accuracy: 0.001)

        let tall = ZoomableImageMetrics.fittedSize(
            imageSize: CGSize(width: 200, height: 400),
            in: CGSize(width: 300, height: 300)
        )
        XCTAssertEqual(tall.width, 150, accuracy: 0.001)
        XCTAssertEqual(tall.height, 300, accuracy: 0.001)
    }

    func testMaximumOffsetUsesFittedImageSizeAndScale() {
        let maxOffset = ZoomableImageMetrics.maximumOffset(
            imageSize: CGSize(width: 400, height: 200),
            boundsSize: CGSize(width: 300, height: 300),
            scale: 2
        )

        XCTAssertEqual(maxOffset.width, 150, accuracy: 0.001)
        XCTAssertEqual(maxOffset.height, 0, accuracy: 0.001)
    }

    func testClampedOffsetRejectsPanningPastVisibleEdges() {
        let clamped = ZoomableImageMetrics.clampedOffset(
            CGSize(width: 999, height: -999),
            imageSize: CGSize(width: 400, height: 200),
            boundsSize: CGSize(width: 300, height: 300),
            scale: 3
        )

        XCTAssertEqual(clamped.width, 300, accuracy: 0.001)
        XCTAssertEqual(clamped.height, -75, accuracy: 0.001)
    }

    func testDoubleTapZoomTogglesFromMinimumToReadableZoomAndBack() {
        XCTAssertEqual(
            ZoomableImageMetrics.doubleTapScale(after: ZoomableImageMetrics.minimumScale),
            ZoomableImageMetrics.doubleTapScale,
            accuracy: 0.001
        )

        XCTAssertEqual(
            ZoomableImageMetrics.doubleTapScale(after: ZoomableImageMetrics.doubleTapScale),
            ZoomableImageMetrics.minimumScale,
            accuracy: 0.001
        )
    }

    func testDoubleTapToggleTreatsNearMinimumAsZoomIn() {
        XCTAssertEqual(
            ZoomableImageMetrics.doubleTapScale(after: ZoomableImageMetrics.minimumScale + 0.0001),
            ZoomableImageMetrics.doubleTapScale,
            accuracy: 0.001
        )
    }

    func testDismissGestureOnlyFiresForVerticalSwipeAtRest() {
        XCTAssertTrue(ZoomableImageMetrics.shouldDismissAtRest(
            scale: ZoomableImageMetrics.minimumScale,
            translation: CGSize(width: 42, height: 140)
        ))

        XCTAssertFalse(ZoomableImageMetrics.shouldDismissAtRest(
            scale: ZoomableImageMetrics.minimumScale,
            translation: CGSize(width: 130, height: 140)
        ))
        XCTAssertFalse(ZoomableImageMetrics.shouldDismissAtRest(
            scale: ZoomableImageMetrics.minimumScale,
            translation: CGSize(width: 42, height: 110)
        ))
        XCTAssertFalse(ZoomableImageMetrics.shouldDismissAtRest(
            scale: ZoomableImageMetrics.doubleTapScale,
            translation: CGSize(width: 42, height: 180)
        ))
    }

    func testInvalidGeometryProducesZeroFitAndNoOffset() {
        let fitted = ZoomableImageMetrics.fittedSize(
            imageSize: .zero,
            in: CGSize(width: 300, height: 300)
        )
        XCTAssertEqual(fitted, .zero)

        let clamped = ZoomableImageMetrics.clampedOffset(
            CGSize(width: 50, height: 50),
            imageSize: .zero,
            boundsSize: CGSize(width: 300, height: 300),
            scale: 4
        )
        XCTAssertEqual(clamped, .zero)
    }
}
