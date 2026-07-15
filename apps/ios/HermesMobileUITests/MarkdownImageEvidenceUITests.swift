import XCTest

/// STR-695 / STR-1399 acceptance evidence for inline markdown-image rendering.
///
/// Drives the shipped feature deterministically, WITHOUT a live gateway, via the
/// DEBUG `HERMES_UITEST_SEED=mdimage` seam. That seed paints one assistant message
/// whose prose interleaves two markdown images — a real remote `https` png (the
/// `AsyncImage` remote branch) and a tiny inline `data:` png (the deterministic
/// `decodeDataURL` branch) — so paragraph → image → paragraph ordering is
/// exercised and at least one inline image (`markdownImage`) is always present
/// offline.
///
/// The flow under test:
///   inline render (`markdownImage`) → tap → lightbox (`zoomableImageView`)
///   → Close (`zoomableImageCloseButton`) → dismiss returns to the inline render.
///
/// It is written to pass on BOTH a compact (iPhone) and a regular (iPad/split)
/// size class: the assertions are device-agnostic — no hardcoded geometry, no
/// compact-only assumptions — so the same test produces the iPhone + iPad
/// recordings the acceptance gate requires. Unlike the live-gateway tests it does
/// NOT skip offline: the seed forces `.connected`, so ChatView renders with no
/// credentials.
final class MarkdownImageEvidenceUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testInlineMarkdownImageRenderTapZoomDismiss() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // Clear any saved gateway config so no live connect is attempted; the
        // `mdimage` seed forces `.connected` and paints ChatView deterministically.
        app.launchArguments += ["-hermes.serverURL", ""]
        app.launchArguments += ["-hermes.connectionMode", ""]
        app.launchEnvironment["HERMES_UITEST_SEED"] = "mdimage"

        // Defensive: the deterministic seed path does NOT request notification
        // permission (only approval/clarify/secret turns do), but a leftover system
        // alert from a prior install must never intercept the evidence run. The
        // monitor fires on the next interaction with the app.
        let alertMonitor = addUIInterruptionMonitor(withDescription: "System permission alert") { alert in
            for label in ["Allow", "Allow While Using App", "OK", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        defer { removeUIInterruptionMonitor(alertMonitor) }

        app.launch()

        // 1. Inline render — the markdown image paints inside the seeded assistant
        //    prose. Target the data-URL ("inline pixel") image specifically, not
        //    `.firstMatch` on the bare `markdownImage` identifier: the remote `https`
        //    image (label "remote camera") only gains that identifier once its
        //    `AsyncImage` transitions `.empty` -> `.success` (MessageBubble.swift's
        //    `loading` placeholder carries no `markdownImage` id), which can happen
        //    mid-test as the network fetch completes. `.firstMatch` re-resolves
        //    lazily at tap-time, so it can land on that freshly-appeared element
        //    while it's still mid-`.snappy` transition and not yet hittable —
        //    exactly the "Failed to not hittable" seen on this test (STR-1399 root
        //    cause). The data-URL image decodes synchronously offline and is the one
        //    the test is documented to rely on ("always present offline"), so query
        //    it by its alt-text label instead. Query across any element type: the
        //    `markdownImage` a11y id sits on a plain SwiftUI Button wrapping the
        //    thumbnail, which UIKit may surface as a button or an image.
        let markdownImage = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label == %@", "markdownImage", "inline pixel"))
            .firstMatch
        XCTAssertTrue(
            markdownImage.waitForExistence(timeout: 30),
            "Inline markdownImage (inline pixel) did not render in the seeded assistant prose"
        )
        // Nudge the interruption monitor in case a stray system alert is up.
        app.tap()
        XCTAssertTrue(markdownImage.waitForExistence(timeout: 5),
                      "markdownImage vanished after clearing any system alert")

        // 2. Tap the inline image → the ZoomableImageView lightbox presents.
        markdownImage.tap()
        let zoomable = app.descendants(matching: .any)["zoomableImageView"].firstMatch
        XCTAssertTrue(
            zoomable.waitForExistence(timeout: 10),
            "Tapping the inline image did not present ZoomableImageView (lightbox)"
        )

        // 3. Close → the lightbox dismisses and the inline image returns.
        let close = app.buttons["zoomableImageCloseButton"]
        XCTAssertTrue(close.waitForExistence(timeout: 5),
                      "Close button (zoomableImageCloseButton) missing in the lightbox")
        close.tap()

        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: zoomable)
        XCTAssertEqual(
            XCTWaiter().wait(for: [dismissed], timeout: 10), .completed,
            "ZoomableImageView did not dismiss after tapping Close"
        )
        XCTAssertTrue(
            markdownImage.waitForExistence(timeout: 10),
            "Inline markdownImage did not return after dismissing the lightbox"
        )
    }
}
