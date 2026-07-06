import XCTest
@testable import HermesMobile

/// Focused tests for STR-2 / ABH-421 / STR-241 (transcript `details_mode` +
/// per-section visibility controls).
///
/// Covered:
/// - ``DefaultsKeys/transcriptDetailsModeValue(_:)`` defaults to `.normal` when
///   the key is absent, and decodes persisted minimal/normal/verbose values.
/// - ``DefaultsKeys/transcriptSectionEnabled(_:_:)`` defaults ON per section
///   and honors an explicit `false`.
/// - ``TranscriptRenderPolicy`` correctly maps each `TranscriptDetailsMode` to
///   thinking/tool default expansion.
@MainActor
final class TranscriptDetailsModeTests: XCTestCase {

    // MARK: - DefaultsKeys.transcriptDetailsModeValue

    func testTranscriptDetailsModeDefaultsToNormalWhenKeyAbsent() {
        let defaults = UserDefaults(suiteName: "TranscriptDetailsModeTests.mode1")!
        defaults.removePersistentDomain(forName: "TranscriptDetailsModeTests.mode1")
        XCTAssertEqual(
            DefaultsKeys.transcriptDetailsModeValue(defaults),
            .normal,
            "A missing details_mode key must decode to .normal, preserving today's behavior exactly"
        )
    }

    func testTranscriptDetailsModeDecodesPersistedMinimal() {
        let defaults = UserDefaults(suiteName: "TranscriptDetailsModeTests.mode2")!
        defaults.removePersistentDomain(forName: "TranscriptDetailsModeTests.mode2")
        defaults.set(TranscriptDetailsMode.minimal.rawValue, forKey: DefaultsKeys.transcriptDetailsMode)
        XCTAssertEqual(DefaultsKeys.transcriptDetailsModeValue(defaults), .minimal)
    }

    func testTranscriptDetailsModeDecodesPersistedVerbose() {
        let defaults = UserDefaults(suiteName: "TranscriptDetailsModeTests.mode3")!
        defaults.removePersistentDomain(forName: "TranscriptDetailsModeTests.mode3")
        defaults.set(TranscriptDetailsMode.verbose.rawValue, forKey: DefaultsKeys.transcriptDetailsMode)
        XCTAssertEqual(DefaultsKeys.transcriptDetailsModeValue(defaults), .verbose)
    }

    func testTranscriptDetailsModeFallsBackToNormalOnUnrecognisedValue() {
        let defaults = UserDefaults(suiteName: "TranscriptDetailsModeTests.mode4")!
        defaults.removePersistentDomain(forName: "TranscriptDetailsModeTests.mode4")
        defaults.set("not-a-real-mode", forKey: DefaultsKeys.transcriptDetailsMode)
        XCTAssertEqual(DefaultsKeys.transcriptDetailsModeValue(defaults), .normal)
    }

    // MARK: - DefaultsKeys.transcriptSectionEnabled

    func testTranscriptSectionsDefaultOnWhenKeysAbsent() {
        let defaults = UserDefaults(suiteName: "TranscriptDetailsModeTests.sections1")!
        defaults.removePersistentDomain(forName: "TranscriptDetailsModeTests.sections1")
        for section in TranscriptSection.allCases {
            XCTAssertTrue(
                DefaultsKeys.transcriptSectionEnabled(section, defaults),
                "\(section) must default ON when its key is absent (existing installs see every section unchanged)"
            )
        }
    }

    func testTranscriptSectionExplicitFalseIsHonored() {
        let defaults = UserDefaults(suiteName: "TranscriptDetailsModeTests.sections2")!
        defaults.removePersistentDomain(forName: "TranscriptDetailsModeTests.sections2")
        defaults.set(false, forKey: DefaultsKeys.transcriptSectionKey(.thinking))
        XCTAssertFalse(DefaultsKeys.transcriptSectionEnabled(.thinking, defaults))
        // Untouched sections remain ON.
        XCTAssertTrue(DefaultsKeys.transcriptSectionEnabled(.tools, defaults))
        XCTAssertTrue(DefaultsKeys.transcriptSectionEnabled(.subagents, defaults))
        XCTAssertTrue(DefaultsKeys.transcriptSectionEnabled(.activity, defaults))
    }

    func testTranscriptSectionExplicitTrueIsHonored() {
        let defaults = UserDefaults(suiteName: "TranscriptDetailsModeTests.sections3")!
        defaults.removePersistentDomain(forName: "TranscriptDetailsModeTests.sections3")
        defaults.set(true, forKey: DefaultsKeys.transcriptSectionKey(.activity))
        XCTAssertTrue(DefaultsKeys.transcriptSectionEnabled(.activity, defaults))
    }

    func testTranscriptSectionKeyIsStablePerSection() {
        // Each section must map to a distinct persisted key, else toggling one
        // section would silently clobber another's stored preference.
        let keys = Set(TranscriptSection.allCases.map { DefaultsKeys.transcriptSectionKey($0) })
        XCTAssertEqual(keys.count, TranscriptSection.allCases.count)
    }

    // MARK: - TranscriptRenderPolicy

    func testThinkingDefaultExpandedOnlyInVerbose() {
        XCTAssertFalse(TranscriptRenderPolicy.thinkingDefaultExpanded(mode: .minimal))
        XCTAssertFalse(TranscriptRenderPolicy.thinkingDefaultExpanded(mode: .normal))
        XCTAssertTrue(TranscriptRenderPolicy.thinkingDefaultExpanded(mode: .verbose))
    }

    func testToolDefaultExpandedOnlyInVerbose() {
        XCTAssertFalse(TranscriptRenderPolicy.toolDefaultExpanded(mode: .minimal))
        XCTAssertFalse(TranscriptRenderPolicy.toolDefaultExpanded(mode: .normal))
        XCTAssertTrue(TranscriptRenderPolicy.toolDefaultExpanded(mode: .verbose))
    }

    // MARK: - ThinkingView.autoExpanded (via the render-policy composition)

    /// `ThinkingView.autoExpanded` is `streaming || thinkingDefaultExpanded(mode:)`
    /// — pinned here as a plain boolean-logic regression since the private
    /// property itself isn't directly testable from outside the view.
    func testThinkingAutoExpandedComposition() {
        func autoExpanded(streaming: Bool, mode: TranscriptDetailsMode) -> Bool {
            streaming || TranscriptRenderPolicy.thinkingDefaultExpanded(mode: mode)
        }
        XCTAssertTrue(autoExpanded(streaming: true, mode: .normal), "Streaming must still auto-open regardless of mode")
        XCTAssertFalse(autoExpanded(streaming: false, mode: .normal), "Normal mode preserves today's collapsed default")
        XCTAssertFalse(autoExpanded(streaming: false, mode: .minimal))
        XCTAssertTrue(autoExpanded(streaming: false, mode: .verbose), "Verbose mode defaults thinking open even when settled")
    }
}
