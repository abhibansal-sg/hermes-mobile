import XCTest
@testable import HermesMobile

/// A11y judgment PR — unit tests for `MessageBubble.bubbleAccessibilityLabel` and
/// the A1 Equatable short-circuit that must not be affected by the a11y change.
///
/// ## What this covers
///
/// 1. **Label construction** — `bubbleAccessibilityLabel(role:text:)` is a pure
///    `nonisolated static` function extracted to be callable from any context.
///    Five cases: user, assistant, system, tool, empty text.
///
/// 2. **Equatable short-circuit integrity** — The `nonisolated ==` on
///    `MessageBubble` compares `message`, `menuActionsEnabled`, and `appearance`.
///    The a11y label is derived from `message.role` + `message.text`, both covered
///    by `message ==`. This test confirms the A1 invariants still hold post-a11y:
///    - A settled bubble compared with itself returns `true` (short-circuit fires).
///    - A streaming→settled change returns `false` (re-render applies .combine).
///    - A text change returns `false` (label would differ).
///    - A `menuActionsEnabled` change returns `false`.
///
/// The `MessageBubble` init is `@MainActor`-isolated (it's a View) — so the
/// Equatable tests run inside a `MainActor.run` block.
@MainActor
final class MessageBubbleA11yTests: XCTestCase {

    // MARK: - 1. bubbleAccessibilityLabel construction

    func testUserLabelPrefix() {
        let label = MessageBubble.bubbleAccessibilityLabel(role: .user, text: "Hello there")
        XCTAssertEqual(label, "You said: Hello there",
                       "user bubble label must start with 'You said: '")
    }

    func testAssistantLabelPrefix() {
        let label = MessageBubble.bubbleAccessibilityLabel(role: .assistant, text: "Sure, I can help.")
        XCTAssertEqual(label, "Assistant said: Sure, I can help.",
                       "assistant bubble label must start with 'Assistant said: '")
    }

    func testSystemLabelPrefix() {
        let label = MessageBubble.bubbleAccessibilityLabel(role: .system, text: "Session started")
        XCTAssertEqual(label, "System: Session started",
                       "system bubble label must start with 'System: '")
    }

    func testToolLabelPrefix() {
        let label = MessageBubble.bubbleAccessibilityLabel(role: .tool, text: "exit 0")
        XCTAssertEqual(label, "Tool: exit 0",
                       "tool bubble label must start with 'Tool: '")
    }

    func testLabelWithEmptyText() {
        // An empty text part (streaming start) must not produce a nil/crash label.
        let label = MessageBubble.bubbleAccessibilityLabel(role: .assistant, text: "")
        XCTAssertEqual(label, "Assistant said: ",
                       "empty text must produce a valid (empty-body) label without crashing")
    }

    // MARK: - Sent-image attachment rendering inputs

    func testSentImageAttachmentsExtractsOpaqueUploadNameAndCleansText() {
        let raw = """
        Please look at this.

        [Image attached at: /Users/abhi/.hermes/uploads/abcdef0123456789abcdef0123456789.jpg]
        """

        let result = MessageBubble.sentImageAttachments(in: raw)

        XCTAssertEqual(result.displayText, "Please look at this.")
        XCTAssertEqual(result.attachments.map(\.name), ["abcdef0123456789abcdef0123456789.jpg"])
        XCTAssertEqual(result.attachments.first?.filename, "abcdef0123456789abcdef0123456789.jpg")
    }

    func testSentImageAttachmentsIgnoresUnsafeOrUnsupportedReferences() {
        let raw = """
        Caption survives.
        [Image attached at: ../secret.png]
        [Image attached at: /tmp/not-image.txt]
        """

        let result = MessageBubble.sentImageAttachments(in: raw)

        XCTAssertEqual(result.displayText, raw)
        XCTAssertTrue(result.attachments.isEmpty)
    }

    // MARK: - 2. Equatable short-circuit integrity

    /// A settled bubble compared with itself must return `true` — SwiftUI skips
    /// `body` evaluation entirely for equal bubbles (A1 guarantee). The a11y
    /// `.combine` modifier is inside `body`, so it is never re-evaluated either.
    func testEquatableShortCircuitFires_settledBubble() {
        let msg = ChatMessage(
            role: .assistant,
            text: "Here is the answer.",
            isStreaming: false
        )
        let appearance = BubbleAppearance(themeID: "dark", colorScheme: .dark, typeSize: .large)
        let bubble = MessageBubble(message: msg, menuActionsEnabled: true, appearance: appearance)
        XCTAssertEqual(bubble, bubble,
                       "a settled MessageBubble must be equal to itself (A1 short-circuit)")
    }

    /// Streaming→settled transition: `isStreaming` is part of `ChatMessage`, which
    /// is compared by `message ==`. Changing `isStreaming` must flip `==` to `false`
    /// so SwiftUI re-evaluates `body` and the `.combine` modifier is applied on the
    /// newly-settled bubble.
    func testEquatableReturnsFalse_streamingStateChange() {
        let settled = ChatMessage(role: .assistant, text: "Done.", isStreaming: false)
        let streaming = ChatMessage(
            id: settled.id,
            role: settled.role,
            parts: settled.parts,
            isStreaming: true,       // only this differs
            timestamp: settled.timestamp
        )
        let appearance = BubbleAppearance()
        let settledBubble   = MessageBubble(message: settled,   menuActionsEnabled: true, appearance: appearance)
        let streamingBubble = MessageBubble(message: streaming, menuActionsEnabled: true, appearance: appearance)
        XCTAssertNotEqual(settledBubble, streamingBubble,
                          "streaming vs settled bubble must not be equal — body must re-evaluate")
    }

    /// A text change in `message` must break equality — the a11y label is derived
    /// from `message.text`, covered by `message ==`.
    func testEquatableReturnsFalse_textChange() {
        let msg1 = ChatMessage(role: .assistant, text: "First response.", isStreaming: false)
        let msg2 = ChatMessage(role: .assistant, text: "Updated response.", isStreaming: false)
        let appearance = BubbleAppearance()
        let bubble1 = MessageBubble(message: msg1, menuActionsEnabled: true, appearance: appearance)
        let bubble2 = MessageBubble(message: msg2, menuActionsEnabled: true, appearance: appearance)
        XCTAssertNotEqual(bubble1, bubble2,
                          "bubbles with different text must not be equal (a11y label would differ too)")
    }

    /// A bubble whose ONLY difference is `menuActionsEnabled` must break equality
    /// (unrelated to a11y but confirms the `==` covers all three inputs).
    func testEquatableReturnsFalse_menuActionsChanged() {
        let msg = ChatMessage(role: .user, text: "What time is it?", isStreaming: false)
        let appearance = BubbleAppearance()
        let enabled  = MessageBubble(message: msg, menuActionsEnabled: true,  appearance: appearance)
        let disabled = MessageBubble(message: msg, menuActionsEnabled: false, appearance: appearance)
        XCTAssertNotEqual(enabled, disabled,
                          "menuActionsEnabled change must break equality")
    }
}
