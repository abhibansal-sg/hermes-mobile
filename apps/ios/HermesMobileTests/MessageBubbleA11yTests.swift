import XCTest
import SwiftUI
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

    func testLocalSentImageEchoCarriesUploadMarkersForImmediateThumbnail() {
        let paths = [
            "/Users/abhi/.hermes/uploads/11111111111111111111111111111111.jpg",
            "/Users/abhi/.hermes/uploads/22222222222222222222222222222222.png",
        ]

        let echoed = ChatStore.localSentImageDisplayText(
            outgoing: "Please compare these.",
            uploadedImagePaths: paths
        )
        let result = MessageBubble.sentImageAttachments(in: echoed)

        XCTAssertEqual(result.displayText, "Please compare these.")
        XCTAssertEqual(result.attachments.map(\.name), [
            "11111111111111111111111111111111.jpg",
            "22222222222222222222222222222222.png",
        ])
    }

    // MARK: - ABH-360 GFM block parsing

    func testMarkdownBlocksParsesGFMTableWithAlignmentAndRows() {
        let blocks = MessageBubble.markdownBlocks("""
        Before

        | Name | Qty | Notes |
        |:-----|----:|:-----:|
        | Apples | 12 | fresh |
        | Pears | | ready |
        """)

        XCTAssertEqual(blocks.count, 2)
        guard case .table(let table) = blocks[1] else {
            return XCTFail("second block should be a native markdown table")
        }
        XCTAssertEqual(table.headers, ["Name", "Qty", "Notes"])
        XCTAssertEqual(table.alignments, [.leading, .trailing, .center])
        XCTAssertEqual(table.rows, [["Apples", "12", "fresh"], ["Pears", "", "ready"]])
    }

    func testMarkdownBlocksParsesTaskListBlockquoteAndNestedList() {
        let blocks = MessageBubble.markdownBlocks("""
        - [x] Done
          - [ ] Nested

        > quoted **markdown**
        > continues

        1. Parent
          - Child
        """)

        XCTAssertEqual(blocks.count, 3)
        guard case .taskItems(let tasks) = blocks[0] else {
            return XCTFail("first block should be a task list")
        }
        XCTAssertEqual(tasks, [
            MessageBubble.MarkdownTaskItem(checked: true, text: "Done", level: 0),
            MessageBubble.MarkdownTaskItem(checked: false, text: "Nested", level: 1),
        ])

        guard case .blockquote(let quote) = blocks[1] else {
            return XCTFail("second block should be a blockquote")
        }
        XCTAssertEqual(quote, "quoted **markdown**\ncontinues")

        guard case .listItems(let items) = blocks[2] else {
            return XCTFail("third block should be a nested list")
        }
        XCTAssertEqual(items, [
            MessageBubble.MarkdownListItem(marker: "1.", text: "Parent", level: 0),
            MessageBubble.MarkdownListItem(marker: "•", text: "Child", level: 1),
        ])
    }

    func testMarkdownBlocksParsesAllGitHubAlertMarkers() {
        let cases: [(marker: String, kind: MessageBubble.MarkdownAlertKind, label: String)] = [
            ("NOTE", .note, "Note"),
            ("TIP", .tip, "Tip"),
            ("IMPORTANT", .important, "Important"),
            ("WARNING", .warning, "Warning"),
            ("CAUTION", .caution, "Caution"),
        ]

        for testCase in cases {
            let blocks = MessageBubble.markdownBlocks("> [!\(testCase.marker)] Alert body")

            XCTAssertEqual(blocks.count, 1, testCase.marker)
            guard case .alert(let alert) = blocks[0] else {
                XCTFail("\(testCase.marker) should parse as an alert")
                continue
            }
            XCTAssertEqual(alert.kind, testCase.kind)
            XCTAssertEqual(alert.kind.label, testCase.label)
            XCTAssertEqual(alert.body, "Alert body")
            XCTAssertFalse(alert.body.contains("[!\(testCase.marker)]"))
        }
    }

    func testMarkdownBlocksParsesAlertMarkerCaseAndLeadingWhitespace() {
        let blocks = MessageBubble.markdownBlocks(">     [!warning] Watch this")

        guard case .alert(let alert) = blocks.first else {
            return XCTFail("leading whitespace and lowercase marker should parse as an alert")
        }
        XCTAssertEqual(alert.kind, .warning)
        XCTAssertEqual(alert.body, "Watch this")
    }

    func testMarkdownBlocksParsesAlertMultilineBodyAfterMarker() {
        let blocks = MessageBubble.markdownBlocks("""
        > [!TIP]
        > Use **markdown** here.
        > Keep the second line.
        """)

        guard case .alert(let alert) = blocks.first else {
            return XCTFail("blockquote alert should parse as an alert")
        }
        XCTAssertEqual(alert.kind, .tip)
        XCTAssertEqual(alert.body, "Use **markdown** here.\nKeep the second line.")
    }

    func testMarkdownBlocksLeavesUnknownAlertAndParagraphMarkersUnchanged() {
        let blocks = MessageBubble.markdownBlocks("""
        > [!INFO] Keep raw marker

        [!WARNING] Paragraph marker
        """)

        XCTAssertEqual(blocks.count, 2)
        guard case .blockquote(let quote) = blocks[0] else {
            return XCTFail("unknown marker should remain a normal blockquote")
        }
        XCTAssertEqual(quote, "[!INFO] Keep raw marker")

        guard case .paragraph(let paragraph) = blocks[1] else {
            return XCTFail("paragraph marker should remain a paragraph")
        }
        XCTAssertEqual(paragraph, "[!WARNING] Paragraph marker")
    }

    func testAccessibilityTextForMarkdownStripsValidAlertMarker() {
        let text = MessageBubble.accessibilityTextForMarkdown("""
        > [!CAUTION] Do not expose the token.
        """)

        XCTAssertEqual(text, "Caution: Do not expose the token.")
        XCTAssertFalse(text.contains("[!CAUTION]"))
    }

    func testGitHubAlertRenderingEvidenceSnapshots() throws {
        let message = ChatMessage(
            role: .assistant,
            text: """
            > [!WARNING] Rotate the token before sharing logs.
            > The raw marker should not be visible in this card.
            """,
            isStreaming: false
        )

        let directory = URL(fileURLWithPath: "/tmp/str-693-evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let environment = AppEnvironment()

        try writeSnapshot(
            MessageBubble(message: message)
                .environment(\.hermesTheme, HermesThemePresets.nousLight)
                .environment(environment.connectionStore)
                .environment(environment.sessionStore)
                .padding(20)
                .background(HermesThemePresets.nousLight.bg),
            size: CGSize(width: 393, height: 260),
            url: directory.appendingPathComponent("github-alert-iphone.png")
        )
        try writeSnapshot(
            MessageBubble(message: message)
                .environment(\.hermesTheme, HermesThemePresets.nousLight)
                .environment(environment.connectionStore)
                .environment(environment.sessionStore)
                .padding(28)
                .background(HermesThemePresets.nousLight.bg),
            size: CGSize(width: 768, height: 300),
            url: directory.appendingPathComponent("github-alert-ipad.png")
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("github-alert-iphone.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("github-alert-ipad.png").path))
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

    private func writeSnapshot<V: View>(_ view: V, size: CGSize, url: URL) throws {
        let controller = UIHostingController(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading))
        controller.view.bounds = CGRect(origin: .zero, size: size)
        controller.view.backgroundColor = .clear

        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }

        guard let data = image.pngData() else {
            return XCTFail("snapshot PNG encoding failed")
        }
        try data.write(to: url, options: .atomic)
    }
}
