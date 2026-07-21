import XCTest
import UIKit

/// R4 W0b — I7/I19 void-geometry, RENDER layer (amendment A1: the void
/// property is NOT observable in the item stream; it exists only in the laid-out
/// viewport). Drives the REAL app in the simulator against the isolated
/// (9130+) mock gateway + worktree relay — never the live 9119 gateway or the
/// live 8788 relay — scrolling a TALL transcript and asserting the invariant:
///
///   **Content or skeleton above the window, never void** (contract I7/I19,
///   QA-1 B4 / QA-3 S7 rule): no blank viewport band sandwiched between
///   rendered content rows, live or after any reconcile / window grow.
///
/// The current transcript is an EAGER WINDOWED VStack (SMOOTHNESS R39 replaced
/// the LazyVStack — its height-estimation voids were the original bug class);
/// the live risk moved to the WINDOW seams (the `loadEarlierMessages` grow
/// anchor, the R15 segment-drop class). This test scrolls THROUGH those seams
/// and fails honestly if any of them paints a void: the detector flags every
/// ≥30pt run of pure background with content both above AND below it in the
/// same viewport (legitimate inter-row gaps are ≤24pt and never sandwiched
/// across the whole width; the top edge-fade and the composer sit outside the
/// scanned insets).
///
/// HONESTY PROOF: `testVoidScannerDetectsSyntheticBand` feeds the detector a
/// synthetic screenshot with a known 200px void band and one with none — an
/// injected void is ALWAYS reported, a clean viewport NEVER. A geometry test
/// whose detector cannot see a void would be a vacuous green; this guard makes
/// the failure mode impossible.
///
/// Backend: `scripts/r4-void-evidence.sh` brings up the mock gateway seeded
/// with a 72-row tall session + a history-bearing streaming (longturn) session
/// and the worktree relay, exporting TEST_RUNNER_* env; the tests SKIP when
/// the env is absent (suite stays green without a backend, exactly like
/// QA1ColdOpenRelayUITests).
@MainActor
final class VoidGeometryUITests: XCTestCase {
    private let composerPlaceholder = "Message Hermes…"
    private let tallSessionRow = "sessionRow.sess-tall-0001"
    private let streamSessionRow = "sessionRow.sess-stream-0001"

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 400
    }

    // MARK: - I7/I19: tall transcript scroll — no void band, ever

    func testTallTranscriptScrollHasNoVoidBand() throws {
        let app = try launchAgainstIsolatedRelay()

        // Open the seeded 72-row tall session from the drawer.
        let drawerToggle = app.buttons["drawerToggle"]
        XCTAssertTrue(drawerToggle.waitForExistence(timeout: 20), "chat shell did not render")
        drawerToggle.tap()
        let row = app.buttons[tallSessionRow]
        XCTAssertTrue(row.waitForExistence(timeout: 45), "tall session row missing from drawer")
        row.tap()

        // The newest tail paints (row 71 is the last assistant message).
        let newest = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "tall-msg-35")
        ).firstMatch
        XCTAssertTrue(newest.waitForExistence(timeout: 20), "tall transcript tail did not paint")

        var violations: [String] = []
        var bandsPerStep: [String: Int] = [:]
        for step in 0..<7 {
            // GEOMETRY: the invariant under test.
            let shot = XCUIScreen.main.screenshot()
            let bands = Self.voidBands(in: shot.image.cgImage!)
            if !bands.isEmpty {
                let attachment = XCTAttachment(image: shot.image)
                attachment.name = "void-band-step-\(step)"
                attachment.lifetime = .keepAlways
                add(attachment)
                for band in bands {
                    violations.append("step \(step): void band rows \(band.rows) (\(band.points)pt tall)")
                }
            }
            bandsPerStep["step\(step)"] = bands.count

            // SCROLL toward older content (bottom-anchored chat: swipe down).
            app.swipeDown()
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.9))

            // I19: backward paging is never gated — grow the window via the
            // load-earlier chip whenever it appears (windowed tail exhaustion
            // + server page). A load-error chip is an honest failure.
            let loadError = app.otherElements["loadError"]
            XCTAssertFalse(loadError.exists, "step \(step): scrollback page load errored")
            let chip = app.buttons["loadEarlierMessages"]
            if chip.waitForExistence(timeout: 0.6) {
                chip.tap()
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(1.2))
            }
        }

        // Detached from the tail mid-scroll ⇒ the jump-to-bottom affordance
        // (I19/A10) must be offered.
        let pill = app.buttons["scrollToBottom"]
        XCTAssertTrue(pill.waitForExistence(timeout: 3), "no jump-to-bottom pill after scrolling up a tall transcript")

        XCTAssertTrue(
            violations.isEmpty,
            "I7/I19 VOID GEOMETRY violated — blank viewport band(s) rendered:\n"
            + violations.joined(separator: "\n")
        )
        NSLog("R4-VOID-EVIDENCE: tall transcript 7 scroll steps, \(bandsPerStep.count) sampled, 0 void bands")
    }

    // MARK: - I7/I19: mid-turn scroll-up — tail append never voids or moves the reader

    func testMidTurnScrollUpKeepsViewportWhole() throws {
        let app = try launchAgainstIsolatedRelay()

        let drawerToggle = app.buttons["drawerToggle"]
        XCTAssertTrue(drawerToggle.waitForExistence(timeout: 20), "chat shell did not render")
        drawerToggle.tap()
        let row = app.buttons[streamSessionRow]
        XCTAssertTrue(row.waitForExistence(timeout: 45), "stream session row missing from drawer")
        row.tap()
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(2.0))

        // Send: the seeded longturn streams ~48 word-deltas over ~7s.
        let composer = composerElement(app)
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "composer missing")
        composer.tap()
        composer.typeText("begin the stream")
        let send = app.buttons["Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "Send button missing")
        send.tap()

        // Wait until the stream is live (a few deltas landed).
        let streaming = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "w3")
        ).firstMatch
        XCTAssertTrue(streaming.waitForExistence(timeout: 15), "the longturn stream never started")

        // Detach the reader: scroll toward older content while the tail appends.
        app.swipeDown()
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.8))

        // I19: while the reader is detached, streaming appends at the tail
        // WITHOUT moving the reader and WITHOUT voiding the viewport. Sample
        // geometry + the topmost visible row across ~16 more deltas.
        let topAtDetach = topVisibleLabel(app)
        var violations: [String] = []
        for sample in 0..<4 {
            let shot = XCUIScreen.main.screenshot()
            let bands = Self.voidBands(in: shot.image.cgImage!)
            if !bands.isEmpty {
                let attachment = XCTAttachment(image: shot.image)
                attachment.name = "void-band-midturn-\(sample)"
                attachment.lifetime = .keepAlways
                add(attachment)
                for band in bands {
                    violations.append("mid-turn sample \(sample): void band rows \(band.rows) (\(band.points)pt)")
                }
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.8))
        }
        // Reader offset stable across the tail append (≈16 deltas at 0.15s).
        let topAfter = topVisibleLabel(app)
        if let a = topAtDetach, let b = topAfter {
            XCTAssertEqual(a, b, "I19: tail append MOVED the detached reader (top row changed)")
        }

        XCTAssertTrue(
            violations.isEmpty,
            "I7/I19 VOID GEOMETRY violated mid-turn — blank band(s) while the tail streamed:\n"
            + violations.joined(separator: "\n")
        )
        NSLog("R4-VOID-EVIDENCE: mid-turn 4 samples while streaming, 0 void bands, readerTop='\(topAfter ?? "nil")'")
    }

    // MARK: - Detector honesty proof (pure; no app, no backend)

    func testVoidScannerDetectsSyntheticBand() {
        // A viewport with a 200px void band SANDWICHED between content.
        let voided = Self.syntheticViewport(heightPx: 600, bandRows: 150...349)!
        let bands = Self.voidBands(in: voided.cgImage!)
        XCTAssertEqual(bands.count, 1, "the detector must see an injected void band")
        let band = bands[0]
        XCTAssertTrue(band.rows.overlaps(150...349), "band rows \(band.rows) miss the injected 150...349")
        XCTAssertTrue(band.points >= 30, "band points \(band.points) below the 30pt floor")

        // A clean viewport (content everywhere) reports nothing — the detector
        // never false-positives on a healthy render.
        let clean = Self.syntheticViewport(heightPx: 600, bandRows: nil)!
        XCTAssertTrue(Self.voidBands(in: clean.cgImage!).isEmpty, "clean viewport flagged as void")

        // Edge blankness (top OR bottom only — e.g. the legitimate tail space
        // below the last message) is NOT a sandwiched void.
        let topBlank = Self.syntheticViewport(heightPx: 600, bandRows: 0...120)!
        XCTAssertTrue(Self.voidBands(in: topBlank.cgImage!).isEmpty, "top-edge blank must not count (not sandwiched)")
    }

    // MARK: - Void-band detector (pure function of a screenshot)

    struct VoidBand {
        let rows: ClosedRange<Int>
        var points: Int { rows.count / 3 }  // @3x sim screenshots
    }

    /// Every maximal run of ≥`minBandPx` near-background pixel rows that has
    /// CONTENT rows both above and below it within the scanned viewport insets
    /// (the sandwich rule: a void is blank space the user scrolls BETWEEN
    /// content — never the legitimate tail space at a transcript end, the
    /// header inset, or the edge-fade gradient zone).
    static func voidBands(
        in image: CGImage,
        emptyFraction: Double = 0.92,
        tolerance: Int = 28,
        minBandPx: Int = 90,
        topInsetFraction: Double = 0.10,
        bottomInsetFraction: Double = 0.12
    ) -> [VoidBand] {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return [] }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Background reference: the top-left corner pixel (theme-independent —
        // works in light and dark; the theme fills the canvas edge-to-edge).
        let bgR = Int(pixels[0]), bgG = Int(pixels[1]), bgB = Int(pixels[2])

        func isEmptyRow(_ y: Int) -> Bool {
            let base = y * w * 4
            var bgCount = 0
            for x in 0..<w {
                let i = base + x * 4
                if abs(Int(pixels[i]) - bgR) <= tolerance
                    && abs(Int(pixels[i + 1]) - bgG) <= tolerance
                    && abs(Int(pixels[i + 2]) - bgB) <= tolerance {
                    bgCount += 1
                }
            }
            return Double(bgCount) / Double(w) >= emptyFraction
        }

        // CGImage row 0 is the TOP of the screen — scan between the header and
        // composer insets (the edge-fade gradients live in the insets).
        let top = Int(Double(h) * topInsetFraction)
        let bottom = h - Int(Double(h) * bottomInsetFraction)
        let empty = (top..<bottom).map { isEmptyRow($0) }

        // Sandwich rule: a run counts only with a content row above AND below.
        var bands: [VoidBand] = []
        var runStart: Int?
        for (i, e) in empty.enumerated() {
            let y = top + i
            if e {
                if runStart == nil { runStart = y }
            } else if let s = runStart {
                if y - s >= minBandPx && s > top {
                    bands.append(VoidBand(rows: s...(y - 1)))
                }
                runStart = nil
            }
        }
        // A run reaching the bottom inset has no content below ⇒ tail space,
        // not a sandwiched void — deliberately not emitted.
        return bands
    }

    // MARK: - Helpers

    private func launchAgainstIsolatedRelay() throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
              let relayURL = env["HERMES_RELAY_URL"],
              !url.isEmpty, !token.isEmpty, !relayURL.isEmpty else {
            throw XCTSkip(
                "HERMES_URL/HERMES_TOKEN/HERMES_RELAY_URL not provided — start the isolated backend via scripts/r4-void-evidence.sh"
            )
        }
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_URL"] = url
        app.launchEnvironment["HERMES_TOKEN"] = token
        app.launchEnvironment["HERMES_TRANSPORT"] = "relay"
        app.launchEnvironment["HERMES_RELAY_URL"] = relayURL
        app.launchEnvironment["HERMES_UITEST_SIZE_CLASS"] = "compact"
        app.launchArguments += ["--uitest-mute-audio", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        addSystemAlertMonitor()
        app.launch()
        return app
    }

    private func composerElement(_ app: XCUIApplication) -> XCUIElement {
        let field = app.textFields[composerPlaceholder]
        return field.exists ? field : app.textViews[composerPlaceholder]
    }

    /// The label of the topmost visible transcript text (reader-offset proxy).
    private func topVisibleLabel(_ app: XCUIApplication) -> String? {
        let window = app.windows.firstMatch.frame
        // Inside the transcript band: below the header, above the composer.
        let bandTop = window.minY + window.height * 0.14
        let bandBottom = window.minY + window.height * 0.80
        return app.staticTexts.allElementsBoundByIndex
            .filter {
                $0.frame.minY >= bandTop && $0.frame.maxY <= bandBottom
                    && $0.frame.height > 4 && !$0.label.isEmpty
            }
            .min { $0.frame.minY < $1.frame.minY }?
            .label
    }

    private func addSystemAlertMonitor() {
        addUIInterruptionMonitor(withDescription: "Dismiss simulator system alerts") { alert in
            for title in ["Allow", "Cancel", "Don’t Allow", "Don't Allow", "OK"] {
                let button = alert.buttons[title]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }
    }

    /// A synthetic screenshot: light canvas with dark "content" marks on every
    /// row EXCEPT an optional void band — the detector's injected-fault proof.
    private static func syntheticViewport(heightPx: Int, bandRows: ClosedRange<Int>?) -> UIImage? {
        let widthPx = 300
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: widthPx, height: heightPx), format: format)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: widthPx, height: heightPx))
            UIColor.black.setFill()
            for y in 0..<heightPx {
                if let band = bandRows, band.contains(y) { continue }  // void: pure background
                for x in stride(from: 0, to: widthPx, by: 4) {
                    ctx.fill(CGRect(x: x, y: y, width: 2, height: 1))
                }
            }
        }
    }
}
