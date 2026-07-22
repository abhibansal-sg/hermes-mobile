import XCTest
import SwiftUI
import UIKit
@testable import HermesMobile

/// QA-1 B11 / A6 — word-granularity native selection across agent prose.
///
/// The build-114 owner QA (IMG_2519) hit the per-paragraph selection ISLAND
/// (`SelectableProseText`): long-press swapped the run for a first-responding
/// `UITextView` that auto-selected the ENTIRE paragraph and offered a "Done"
/// exit — no word granularity, no cross-paragraph extension. The ratified fix
/// folds each contiguous prose run of an assistant message into ONE
/// `UITextView`-backed ``ProseSelectionContainer`` (word-level long-press
/// selection with native handles; cards stay non-selectable islands; no
/// Copy|Share pill, no "Done").
///
/// ## Regression contract
///
/// The two hierarchy tests (`…MountsSingleSelectableContainer…`,
/// `…SelectionExtendsAcrossParagraphs…`) use ONLY the pre-existing
/// `MessageBubble(message:)` API, so they compile on `qa1/base` and FAIL at
/// runtime there (no `UITextView` is mounted on the settled bubble in the
/// island architecture — prose was SwiftUI `Text` until a long-press swap) and
/// PASS after the restructure. The remaining tests pin the new flattener /
/// bridge / container contracts.
@MainActor
final class ProseSelectionTests: XCTestCase {

    // MARK: - Runtime hierarchy contract (fail-before / pass-after)

    /// A settled assistant message of TWO paragraphs must mount exactly ONE
    /// selectable `UITextView` whose text spans BOTH paragraphs — the single
    /// container per contiguous prose run. Non-editable (no keyboard), no
    /// select-all on mount (selection starts empty; the system long-press
    /// begins word selection at the touch point).
    ///
    /// FAILS on qa1/base: the island architecture mounts ZERO UITextViews on
    /// the settled bubble (each paragraph is a SwiftUI `Text` until the
    /// long-press swap), so `textViews.count == 1` cannot hold.
    func testAssistantProseMountsSingleSelectableContainerSpanningParagraphs() {
        let message = ChatMessage(
            role: .assistant,
            text: """
            Alpha is the first paragraph of the answer.

            Beta starts the second paragraph here.
            """,
            isStreaming: false
        )
        let textViews = hostedTextViews(bubble(message))

        XCTAssertEqual(textViews.count, 1,
            "a contiguous prose run must render as exactly ONE selectable container (paragraphs are not islands)")
        guard let textView = textViews.first else { return }

        let string = textView.attributedText.string
        XCTAssertTrue(string.contains("Alpha is the first paragraph"),
                      "the container must carry the first paragraph")
        XCTAssertTrue(string.contains("Beta starts the second paragraph"),
                      "the container must carry the second paragraph — selection must be able to reach it")

        XCTAssertTrue(textView.isSelectable, "the prose container must be selectable")
        XCTAssertFalse(textView.isEditable, "the prose container must not be editable")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 0),
                       "no select-all on mount — the reader starts from a word-level long-press, not a whole-block selection")
    }

    /// The single container must allow a selection that SPANS the paragraph
    /// boundary (paragraphs are not selection walls — B11). Drives a real
    /// `selectedRange` across the "\n\n" boundary on the mounted container.
    ///
    /// FAILS on qa1/base: no container is mounted (zero UITextViews), so no
    /// cross-paragraph selection surface exists.
    func testSelectionExtendsAcrossParagraphsInSingleContainer() {
        let message = ChatMessage(
            role: .assistant,
            text: """
            Alpha is the first paragraph of the answer.

            Beta starts the second paragraph here.
            """,
            isStreaming: false
        )
        let textViews = hostedTextViews(bubble(message))
        guard let textView = textViews.first else {
            return XCTFail("no selectable prose container mounted — the island architecture cannot extend selection across paragraphs")
        }

        let nsText = textView.attributedText.string as NSString
        let tailAnchor = nsText.range(of: "first paragraph").location
        let headAnchor = nsText.range(of: "Beta starts").location
        XCTAssertNotEqual(tailAnchor, NSNotFound)
        XCTAssertNotEqual(headAnchor, NSNotFound)

        // Select from mid-paragraph-1 across the boundary into paragraph 2
        // (the programmatic drive stands in for the user's long-press —
        // mark the interaction so the QA-2 B11 mount gate stands down).
        (textView as? ProseTextView)?.noteInteractionForTesting()
        let end = headAnchor + ("Beta starts" as NSString).length
        textView.selectedRange = NSRange(location: tailAnchor, length: end - tailAnchor)

        let selected = nsText.substring(with: textView.selectedRange)
        XCTAssertTrue(selected.contains("first paragraph of the answer."),
                      "selection must include the paragraph-1 tail")
        XCTAssertTrue(selected.contains("Beta starts"),
                      "the same selection must cross into paragraph 2 — the boundary is not a wall")
    }

    /// A6 / N5: no "Done" affordance and no Copy|Share pill on agent prose —
    /// exit is the standard tap-away dismissal and Copy lives on the system
    /// edit menu of the live selection. Walks the hosted tree's accessibility
    /// labels (SwiftUI controls surface there, not as UIViews).
    func testAssistantProseCarriesNoDoneAffordance() {
        let message = ChatMessage(
            role: .assistant,
            text: """
            One paragraph.

            Two paragraph.
            """,
            isStreaming: false
        )
        let root = hostedRoot(bubble(message))
        var labels: [String] = []
        collectAccessibilityLabels(root, depth: 0, into: &labels)
        XCTAssertFalse(labels.contains("Done selecting text"),
                       "agent prose must not show a 'Done' selection-exit button (B11 / A6)")
    }

    /// Cards split the prose flow: a fenced code block between two paragraphs
    /// yields TWO selectable containers (one per side), each carrying only its
    /// own paragraph — the code card stays a non-selectable island (A6: cards
    /// not selectable).
    ///
    /// FAILS on qa1/base: zero UITextViews mounted.
    func testCodeCardSplitsProseIntoSeparateContainers() {
        let message = ChatMessage(
            role: .assistant,
            text: """
            Before the code.

            ```swift
            let answer = 42
            ```

            After the code.
            """,
            isStreaming: false
        )
        let textViews = hostedTextViews(bubble(message))

        XCTAssertEqual(textViews.count, 2,
            "a card between two prose runs yields one selectable container per side")
        let strings = textViews.map { $0.attributedText.string }
        XCTAssertTrue(strings.contains { $0.contains("Before the code.") && !$0.contains("After the code.") },
                      "the lead container carries only the lead paragraph")
        XCTAssertTrue(strings.contains { $0.contains("After the code.") && !$0.contains("Before the code.") },
                      "the tail container carries only the tail paragraph")
        for textView in textViews {
            XCTAssertFalse(textView.attributedText.string.contains("let answer = 42"),
                           "code stays a non-selectable island — never inside a selection container")
        }
    }

    // MARK: - Flow builder contract

    private func makeStyle() -> ProseFlowStyle {
        let bodyFont = SelectableTextView.font(textStyle: .body, serif: true)
        return ProseFlowStyle(
            bodyFont: bodyFont,
            monoFont: .monospacedSystemFont(ofSize: bodyFont.pointSize, weight: .regular),
            fg: .label,
            mutedFg: .secondaryLabel,
            linkColor: .link,
            quoteBackground: UIColor.systemGray.withAlphaComponent(0.18),
            taskCheckTint: .systemGreen,
            lineSpacing: 3.5,
            paragraphSpacing: 12
        )
    }

    /// Paragraphs, list items, task items, blockquotes and alerts in one
    /// contiguous run merge into a SINGLE `.prose` piece — that is the piece
    /// the selection container renders, so the selection flows across all of
    /// them.
    func testProseFlowBuilderMergesAllProseBlocksIntoOnePiece() {
        let pieces = ProseFlowBuilder.pieces(body: """
        Alpha paragraph.

        Beta paragraph.

        - bullet one
        - bullet two

        1. first
        2. second

        - [x] Done task
        - [ ] Open task

        > quoted line

        > [!NOTE]
        > careful now
        """, style: makeStyle(), linkColor: .blue)

        XCTAssertEqual(pieces.count, 1,
            "every prose structure in a contiguous run must fold into ONE selectable container")
        guard case .prose(let attr) = pieces.first else {
            return XCTFail("the single piece must be a prose container payload")
        }
        let string = attr.string
        for expected in ["Alpha paragraph.", "Beta paragraph.", "bullet one", "bullet two",
                         "first", "second", "Done task", "Open task", "quoted line", "NOTE", "careful now"] {
            XCTAssertTrue(string.contains(expected), "container must carry '\(expected)'")
        }
    }

    /// Tables and hoisted images flush the pending prose and emit island
    /// pieces, splitting the flow: prose / table / image / prose.
    func testProseFlowBuilderKeepsTableAndImageAsIslands() {
        let pieces = ProseFlowBuilder.pieces(body: """
        Lead paragraph.

        | Name | Qty |
        |:-----|----:|
        | Apples | 12 |

        ![diagram](https://example.com/diagram.png)

        Tail paragraph.
        """, style: makeStyle(), linkColor: .blue)

        XCTAssertEqual(pieces.count, 4)
        guard case .prose(let lead) = pieces[0] else { return XCTFail("piece 0 must be the lead prose") }
        XCTAssertTrue(lead.string.contains("Lead paragraph."))
        guard case .table(let table) = pieces[1] else { return XCTFail("piece 1 must be the table island") }
        XCTAssertEqual(table.headers, ["Name", "Qty"])
        guard case .image(let alt, let source) = pieces[2] else { return XCTFail("piece 2 must be the image island") }
        XCTAssertEqual(alt, "diagram")
        XCTAssertEqual(source, "https://example.com/diagram.png")
        guard case .prose(let tail) = pieces[3] else { return XCTFail("piece 3 must be the tail prose") }
        XCTAssertTrue(tail.string.contains("Tail paragraph."))
    }

    // MARK: - Inline-markdown bridge contract

    /// The bridge must reproduce the old `Text(attributed)` inline styling in
    /// UIKit attributes: bold + italic traits on the serif face, monospaced
    /// inline code, tinted underlined links.
    func testInlineBridgeMapsBoldItalicCodeAndLink() {
        let source = MessageBubble.attributed(
            "**bold** *em* `code` [tap](https://example.com) plain",
            linkColor: .blue
        )
        let style = makeStyle()
        let attr = ProseInlineBridge.attributedString(from: source, style: style)
        let nsString = attr.string as NSString

        func font(at substring: String) -> UIFont? {
            let range = nsString.range(of: substring)
            guard range.location != NSNotFound else { return nil }
            return attr.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont
        }

        let bold = font(at: "bold")
        XCTAssertNotNil(bold)
        XCTAssertTrue(bold!.fontDescriptor.symbolicTraits.contains(.traitBold),
                      "**bold** must bridge to a bold trait")

        let em = font(at: "em")
        XCTAssertNotNil(em)
        XCTAssertTrue(em!.fontDescriptor.symbolicTraits.contains(.traitItalic),
                      "*em* must bridge to an italic trait")

        let code = font(at: "code")
        XCTAssertNotNil(code)
        XCTAssertTrue(code!.fontDescriptor.symbolicTraits.contains(.traitMonoSpace),
                      "`code` must bridge to a monospaced face")

        let tapRange = nsString.range(of: "tap")
        let link = attr.attribute(.link, at: tapRange.location, effectiveRange: nil) as? URL
        XCTAssertEqual(link?.absoluteString, "https://example.com")
        let underline = attr.attribute(.underlineStyle, at: tapRange.location, effectiveRange: nil) as? Int
        XCTAssertEqual(underline, NSUnderlineStyle.single.rawValue,
                       "links keep the single-underline transcript style")
        let linkColor = attr.attribute(.foregroundColor, at: tapRange.location, effectiveRange: nil) as? UIColor
        XCTAssertEqual(linkColor, .link, "links carry the tinted foreground")

        let plainRange = nsString.range(of: "plain")
        let plainColor = attr.attribute(.foregroundColor, at: plainRange.location, effectiveRange: nil) as? UIColor
        XCTAssertEqual(plainColor, .label, "non-link prose carries the default foreground")
    }

    // MARK: - Task-list flattening contract

    /// Task items flatten with an inline SF Symbol checkbox attachment (the
    /// glyph never lands in the copied text — it is an object-replacement
    /// char) and a strikethrough on checked items only.
    func testTaskItemsFlattenWithCheckboxAttachmentAndStrikethrough() {
        let pieces = ProseFlowBuilder.pieces(body: """
        - [x] Done item
        - [ ] Open item
        """, style: makeStyle(), linkColor: .blue)

        XCTAssertEqual(pieces.count, 1)
        guard case .prose(let attr) = pieces.first else {
            return XCTFail("task items must fold into the prose container")
        }
        let nsString = attr.string as NSString
        XCTAssertEqual((nsString as String).filter { $0 == "\u{FFFC}" }.count, 2,
                       "each task item carries one checkbox attachment glyph")

        func hasStrikethrough(_ substring: String) -> Bool {
            let range = nsString.range(of: substring)
            guard range.location != NSNotFound else { return false }
            return attr.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil) != nil
        }
        XCTAssertTrue(hasStrikethrough("Done item"), "checked task text must be struck through")
        XCTAssertFalse(hasStrikethrough("Open item"), "open task text must not be struck through")
    }

    // MARK: - Container re-render must not yank an in-progress selection

    /// An identical re-render (theme tick / layout pass / streaming flush with
    /// an unchanged settled prefix) must NOT replace the attributed text and
    /// therefore must NOT clear the reader's live selection.
    func testContainerPreservesSelectionAcrossEqualContentUpdate() {
        let first = NSAttributedString(string: "Alpha beta gamma delta.", attributes: [:])
        let controller = UIHostingController(rootView: ProseSelectionContainer(text: first)
            .frame(width: 320, alignment: .topLeading))
        controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        // iOS 26 lazy platform-view instantiation: the representable mounts its
        // UITextView only once attached to a window (see hostedRoot).
        if let window = attachToWindow(controller) {
            attachedWindows.append(window)
        }
        pumpLayout(controller)
        guard let textView = allTextViews(in: controller.view).first else {
            return XCTFail("container must mount its UITextView")
        }

        // The reader narrows to one word (the programmatic drive stands in
        // for the user's long-press — mark the interaction so the QA-2 B11
        // mount gate stands down).
        (textView as? ProseTextView)?.noteInteractionForTesting()
        let word = (textView.attributedText.string as NSString).range(of: "beta")
        textView.selectedRange = word
        XCTAssertEqual(textView.selectedRange, word)

        // A re-render with equal content (a DIFFERENT NSAttributedString
        // instance with identical characters) must leave the selection alone.
        let second = NSAttributedString(string: "Alpha beta gamma delta.", attributes: [:])
        controller.rootView = ProseSelectionContainer(text: second)
            .frame(width: 320, alignment: .topLeading)
        pumpLayout(controller)
        guard let updated = allTextViews(in: controller.view).first else {
            return XCTFail("container must survive the update")
        }
        XCTAssertEqual(updated.selectedRange, word,
                       "equal-content re-renders must never yank an in-progress selection")
    }

    // MARK: - Opt-in on-screen evidence (word selection + handles)

    /// Hosts a two-paragraph assistant bubble on the active scene and drives a
    /// programmatic WORD-level selection on the mounted container so
    /// `xcrun simctl io booted recordVideo` can capture the native handles +
    /// edit menu. Opt-in via env var (no-op in normal runs), mirroring the
    /// STR-695 evidence pattern.
    ///
    ///   HERMES_B11_EVIDENCE_SECS=10 scripts/ios-build.sh test \
    ///     -scheme HermesMobile \
    ///     -destination 'platform=iOS Simulator,id=<BOOTED_IPHONE_UDID>' \
    ///     -only-testing:HermesMobileTests/ProseSelectionTests/testB11WordSelectionOnScreenEvidence
    func testB11WordSelectionOnScreenEvidence() throws {
        let secs = ProcessInfo.processInfo.environment["HERMES_B11_EVIDENCE_SECS"].flatMap(Double.init) ?? 0
        try XCTSkipIf(secs <= 0, "B11 evidence capture is opt-in via HERMES_B11_EVIDENCE_SECS")

        let message = ChatMessage(
            role: .assistant,
            text: """
            Selection now starts at word granularity with native drag handles, exactly where you press.

            Drag a handle across this paragraph boundary — the selection extends; paragraphs are not walls.
            """,
            isStreaming: false
        )
        let controller = UIHostingController(rootView: bubble(message).padding(20))
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 500)
        pumpLayout(controller)
        guard let textView = allTextViews(in: controller.view).first else {
            return XCTFail("no selectable prose container mounted")
        }
        let window = attachToWindow(controller)
        defer { window?.isHidden = true }

        // Word-level selection: a single word of paragraph one.
        let word = (textView.attributedText.string as NSString).range(of: "granularity")
        // Evidence capture drives selection PROGRAMMATICALLY — opt out of the
        // QA-2 B11 mount-selection gate (no touch precedes the drive).
        (textView as? ProseTextView)?.suppressFocusUntilTouch = false
        textView.becomeFirstResponder()
        textView.selectedRange = word
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))

        // Then extend across the paragraph boundary to show the handles drag.
        let cross = (textView.attributedText.string as NSString).range(of: "paragraph boundary")
        textView.selectedRange = NSRange(location: word.location,
                                         length: cross.location + cross.length - word.location)

        RunLoop.current.run(until: Date(timeIntervalSinceNow: secs))
        textView.resignFirstResponder()
    }

    // MARK: - Hosting helpers

    private func bubble(_ message: ChatMessage) -> some View {
        let environment = AppEnvironment()
        return MessageBubble(message: message)
            .environment(\.hermesTheme, HermesThemePresets.nousLight)
            .environment(environment.connectionStore)
            .environment(environment.sessionStore)
    }

    /// Windows attached for the current test — held so the representables stay
    /// instantiated until teardown (a released UIWindow detaches its root).
    private var attachedWindows: [UIWindow] = []

    private func hostedRoot<V: View>(_ view: V, width: CGFloat = 360) -> UIView {
        let controller = UIHostingController(rootView: view.frame(width: width, alignment: .topLeading))
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 900)
        controller.view.backgroundColor = .white
        // iOS 26 instantiates `UIViewRepresentable` platform views LAZILY —
        // `ProseSelectionContainer`'s UITextView is created only once the
        // hosting view is attached to a live window (the same contract
        // ClarifyCardNativeTests' onAppear assertions rely on). Without the
        // attach the hierarchy walk finds zero text views even though the
        // bubble's SwiftUI tree is intact (qa2 fix round: pre-existing
        // red on the four hierarchy tests).
        if let window = attachToWindow(controller) {
            attachedWindows.append(window)
        }
        pumpLayout(controller)
        return controller.view
    }

    private func hostedTextViews<V: View>(_ view: V, width: CGFloat = 360) -> [UITextView] {
        allTextViews(in: hostedRoot(view, width: width))
    }

    private func pumpLayout(_ controller: UIHostingController<some View>) {
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        for _ in 0..<12 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            controller.view.layoutIfNeeded()
        }
    }

    private func allTextViews(in root: UIView) -> [UITextView] {
        var found: [UIView] = []
        collectViews(root, where: { $0 is UITextView }, into: &found)
        return found.compactMap { $0 as? UITextView }
    }

    private func collectViews(_ view: UIView, where predicate: (UIView) -> Bool, into acc: inout [UIView]) {
        if predicate(view) { acc.append(view) }
        for subview in view.subviews {
            collectViews(subview, where: predicate, into: &acc)
        }
    }

    /// Bounded recursive walk of the UIKit + accessibility element tree
    /// (SwiftUI controls surface as accessibility elements inside the hosting
    /// view, not as UIViews). Depth-capped so element cycles cannot hang.
    private func collectAccessibilityLabels(_ element: Any?, depth: Int, into acc: inout [String]) {
        guard depth < 14 else { return }
        let object = element as? NSObject
        if let label = object?.accessibilityLabel, !label.isEmpty {
            acc.append(label)
        }
        if let view = element as? UIView {
            for subview in view.subviews {
                collectAccessibilityLabels(subview, depth: depth + 1, into: &acc)
            }
        }
        if let elements = object?.accessibilityElements {
            for case let child as NSObject in elements {
                collectAccessibilityLabels(child, depth: depth + 1, into: &acc)
            }
        }
    }

    @discardableResult
    private func attachToWindow(_ controller: UIHostingController<some View>) -> UIWindow? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let windowScene = scene else { return nil }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        return window
    }
}
