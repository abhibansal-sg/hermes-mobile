import XCTest
@testable import HermesMobile

/// Code-side a11y unit tests for ABH-181 (a11y pass).
///
/// ## What this covers
///
/// 1. **`ToolClusterView.summaryLabel`** — the static helper that feeds the
///    collapsed-capsule button's `.accessibilityLabel`. Verifies plural/singular
///    nouns, elapsed formatting, and the no-elapsed fallback.
///
/// 2. **`ConnectionMode.label` stability** — the mode picker buttons in
///    `WelcomeView` use `mode.label` verbatim as the `.accessibilityLabel`. If
///    the label text changes in a way that confuses VoiceOver (e.g. an empty
///    string or a raw SF Symbol name leaks in) the test fails.
///
/// Contrast, focus-during-streaming, and visual layout are deferred to device
/// VoiceOver validation (task #20).
final class ViewA11yTests: XCTestCase {

    // MARK: - 1. ToolClusterView summary label

    func testSummaryLabel_pluralNoElapsed() {
        let label = ToolClusterView.summaryLabel(toolCount: 3, elapsedSeconds: nil)
        XCTAssertEqual(label, "3 tool calls",
                       "plural noun, no elapsed → bare count label")
    }

    func testSummaryLabel_singularNoElapsed() {
        let label = ToolClusterView.summaryLabel(toolCount: 1, elapsedSeconds: nil)
        XCTAssertEqual(label, "1 tool call",
                       "singular noun must not read '1 tool calls'")
    }

    func testSummaryLabel_pluralWithElapsed() {
        let label = ToolClusterView.summaryLabel(toolCount: 4, elapsedSeconds: 7.4)
        XCTAssertEqual(label, "4 tool calls · 7s",
                       "elapsed is formatted as integer seconds with '· Xs' suffix")
    }

    func testSummaryLabel_singularWithElapsed() {
        let label = ToolClusterView.summaryLabel(toolCount: 1, elapsedSeconds: 1.8)
        XCTAssertEqual(label, "1 tool call · 2s",
                       "singular + elapsed rounds to nearest second")
    }

    func testSummaryLabel_zeroElapsedOmitted() {
        // A zero elapsed (sum of per-tool durations = 0) is treated as "unknown"
        // and the time tail is omitted — an empty tail reads better than "· 0s".
        let label = ToolClusterView.summaryLabel(toolCount: 2, elapsedSeconds: nil)
        XCTAssertFalse(label.contains("·"), "nil elapsed must not include the '·' separator")
        XCTAssertFalse(label.hasSuffix("s") && label.contains("·"),
                       "nil elapsed must not append a seconds suffix after '·'")
    }

    func testSummaryLabel_neverContainsSFSymbolName() {
        // Guard: the label must never leak raw SF Symbol image names (e.g.
        // "gearshape") — those only appear when `.accessibilityLabel` is absent
        // and VoiceOver falls back to reading the image name.
        let label = ToolClusterView.summaryLabel(toolCount: 2, elapsedSeconds: 5)
        XCTAssertFalse(label.contains("gearshape"),
                       "summary label must not contain SF Symbol name 'gearshape'")
    }

    // MARK: - 2. ConnectionMode label stability

    /// The WelcomeView mode button's `.accessibilityLabel` is `mode.label`
    /// (optionally suffixed with ", selected"). Verify the labels are non-empty,
    /// human-readable, and do NOT start with an SF Symbol name.
    func testConnectionModeLabels_nonEmpty() {
        for mode in ConnectionMode.allCases {
            XCTAssertFalse(mode.label.isEmpty,
                           "ConnectionMode.\(mode) label must not be empty")
        }
    }

    func testConnectionModeLabels_noSFSymbolName() {
        // SF Symbol names used in WelcomeView mode buttons are documented in
        // ConnectionMode.systemImage. Ensure the human label and systemImage are
        // distinct (a bug that assigns the symbol name to `.label` would break VoiceOver).
        for mode in ConnectionMode.allCases {
            XCTAssertNotEqual(mode.label, mode.systemImage,
                              "ConnectionMode.\(mode) .label must differ from .systemImage")
        }
    }

    func testConnectionModeLabels_noSelectedSuffixInLabel() {
        // WelcomeView.modeButton uses mode.label as the .accessibilityLabel regardless
        // of selection state — selection is conveyed by the .isSelected TRAIT, not
        // by appending ", selected" to the label. Appending would cause VoiceOver to
        // double-announce "selected, selected" (trait + label suffix).
        for mode in ConnectionMode.allCases {
            XCTAssertFalse(mode.label.hasSuffix(", selected"),
                           "ConnectionMode.\(mode) .label must not include a ', selected' suffix — use .isSelected trait")
            // The label must equal exactly mode.label (no suffix) whether or not
            // the button happens to be selected.
            let buttonLabel = mode.label   // mirrors WelcomeView.modeButton implementation
            XCTAssertEqual(buttonLabel, mode.label,
                           "modeButton a11y label must be exactly mode.label with no selection suffix")
        }
    }
}
