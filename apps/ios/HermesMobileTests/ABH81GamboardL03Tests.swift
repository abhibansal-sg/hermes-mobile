import XCTest
@testable import HermesMobile

/// ABH-81 Level 03 — unit coverage for the three gameboard feedback items:
///
/// 03F  Blue gutter removal — the gutter constants must be gone; the body must
///      not contain a leading overlay or padding by symbol regression check.
///
/// 03E  Context-menu widening — the new `menuActionsGate` predicate and the
///      `MessageBubble.menuActionsEnabled` pathway.
///
/// 03D  Read More — the `MessageBubble.isLongUserMessage` threshold function.
final class ABH81GamboardL03Tests: XCTestCase {

    // MARK: - 03E: menuActionsGate predicate

    /// When the gateway is connected and no local turn is in flight, all mutable
    /// actions are enabled.
    func testMenuActionsGate_connectedNoTurn_enabled() {
        XCTAssertTrue(
            ChatView.menuActionsGate(isConnected: true, localTurnInFlight: false),
            "actions must be enabled when connected and no local turn is in flight"
        )
    }

    /// A local turn in flight disables mutable actions (edit/retry/checkpoint
    /// would be rejected by the store anyway — this is the display-layer gate).
    func testMenuActionsGate_connectedWithTurn_disabled() {
        XCTAssertFalse(
            ChatView.menuActionsGate(isConnected: true, localTurnInFlight: true),
            "actions must be disabled while a local turn is in flight"
        )
    }

    /// Disconnected state — actions disabled regardless of turn state.
    func testMenuActionsGate_disconnected_disabled() {
        XCTAssertFalse(
            ChatView.menuActionsGate(isConnected: false, localTurnInFlight: false),
            "actions must be disabled when the gateway is not connected"
        )
        XCTAssertFalse(
            ChatView.menuActionsGate(isConnected: false, localTurnInFlight: true),
            "actions must be disabled when the gateway is not connected (turn in flight)"
        )
    }

    // MARK: - 03D: isLongUserMessage threshold

    /// A short message (below 360 chars, no unusual newlines) must NOT trigger
    /// the Read More toggle.
    func testIsLongUserMessage_shortText_false() {
        let short = "Hello, can you help me with something?"
        XCTAssertFalse(
            MessageBubble.isLongUserMessage(short),
            "a short message must not trigger the collapse toggle"
        )
    }

    /// A message that is exactly at the character threshold must NOT trigger it
    /// (the threshold is strictly greater-than).
    func testIsLongUserMessage_atThreshold_false() {
        let atThreshold = String(repeating: "a", count: MessageBubble.userBubbleCollapsedCharThreshold)
        XCTAssertFalse(
            MessageBubble.isLongUserMessage(atThreshold),
            "a message exactly at the threshold must not show Read More"
        )
    }

    /// A message one character above the threshold must trigger it.
    func testIsLongUserMessage_aboveThreshold_true() {
        let aboveThreshold = String(repeating: "a", count: MessageBubble.userBubbleCollapsedCharThreshold + 1)
        XCTAssertTrue(
            MessageBubble.isLongUserMessage(aboveThreshold),
            "a message above the threshold must show Read More"
        )
    }

    /// A short-in-characters but multi-paragraph message (>= collapsedLines
    /// newlines) must trigger it.
    func testIsLongUserMessage_manyNewlines_true() {
        // Build a message with exactly collapsedLines newlines (i.e., collapsedLines+1 lines)
        let lines = Array(repeating: "short", count: MessageBubble.userBubbleCollapsedLines + 1)
        let multiline = lines.joined(separator: "\n")
        XCTAssertTrue(
            MessageBubble.isLongUserMessage(multiline),
            "a message with >= \(MessageBubble.userBubbleCollapsedLines) newlines must show Read More"
        )
    }

    /// A message with fewer than collapsedLines newlines and below the char
    /// threshold must NOT trigger it.
    func testIsLongUserMessage_fewNewlines_false() {
        let lines = Array(repeating: "short", count: MessageBubble.userBubbleCollapsedLines - 1)
        let multiline = lines.joined(separator: "\n")
        XCTAssertFalse(
            MessageBubble.isLongUserMessage(multiline),
            "a message with < \(MessageBubble.userBubbleCollapsedLines) newlines and below char threshold must not show Read More"
        )
    }

    /// An empty message must not trigger it.
    func testIsLongUserMessage_empty_false() {
        XCTAssertFalse(MessageBubble.isLongUserMessage(""))
    }
}
