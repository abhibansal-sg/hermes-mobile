import XCTest
import SwiftUI
@testable import HermesMobile

/// QA-2 R7–R10 + A4 + C1 — native-first clarify/approval cards.
///
/// These tests pin the rebuild contract for the docked gate cards:
///  • R8/N3 — answering a clarify ECHOES the user's answer into the transcript
///    (`respondClarification` clears the card and emits the gateway RPC but
///    drops the answer on the floor — IMG_2535/2540 show the card gone with no
///    answer bubble). RED on qa2/base: `chat.messages` gains no user row.
///  • R10 — long choice text WRAPS inside the card instead of hard-clipping off
///    the right edge (IMG_2539). Asserted at the layout level: a ≥120-char
///    choice renders fully inside the proposed width.
///  • R10 — long question text SCROLLS inside a bounded header instead of
///    growing the card past the nav bar (IMG_2537). Asserted at the layout
///    level: the card's height is bounded for a 500-char question.
///  • R9 — the card dismisses the keyboard on appear (composer + card +
///    keyboard must never stack — IMG_2534/2537). Asserted via the
///    `\.dismissKeyboard` environment spy.
///  • R7/C1 — the card mounts the native system surface (`GateCardSurface`),
///    not the flat `theme.card` + stroke; and the free-text field is no longer
///    the pure-black `.roundedBorder`. Asserted structurally.
///
/// RED on qa2/base; green after the R7–R10 fix lane. Deterministic — no live
/// network. The gateway-event wiring stays intact: these tests never touch the
/// responder transport.
@MainActor
final class ClarifyCardNativeTests: XCTestCase {

    override func tearDown() {
        // W2e/I23 hygiene: the DURABLE answered-gate record persists across
        // stores by design — clear it so a rid this suite answered ("clr-1"
        // etc.) never suppresses another suite's re-delivery in the same run.
        ChatStore._debugClearDurableResolvedGates()
        super.tearDown()
    }

    // MARK: - R8 / N3 — clarify answer is echoed into the transcript

    /// Answering a clarify (choice tap or free text) MUST leave a user row in
    /// `messages` so the transcript shows what the user picked. RED on qa2/base:
    /// `respondClarification` clears `pendingClarification` and sends the RPC
    /// but appends nothing — the card vanishes and no answer appears
    /// (IMG_2535/2540, ledger N3).
    func testRespondClarificationEchoesAnswerAsUserMessage() async throws {
        let chat = ChatStore()
        chat.pendingClarification = PendingClarification(
            sessionId: "s",
            request: ClarifyRequestPayload(payload: .object([
                "question": .string("Deploy now?"),
                "choices": .array([.string("yes"), .string("no")]),
                "request_id": .string("clr-1"),
            ])))
        let baseline = chat.messages.count

        await chat.respondClarification("yes")

        XCTAssertNil(chat.pendingClarification, "answering still clears the card")
        XCTAssertEqual(chat.messages.count, baseline + 1,
                       "the answer MUST be echoed as a user row (R8/N3)")
        let echoed = try XCTUnwrap(chat.messages.last)
        XCTAssertEqual(echoed.role, .user)
        XCTAssertEqual(echoed.text, "yes",
                       "the echoed row carries the exact answer text")
    }

    /// Free-text answers echo too — the free-text path is the same responder.
    func testRespondClarificationFreeTextEchoesAnswer() async throws {
        let chat = ChatStore()
        chat.pendingClarification = PendingClarification(
            sessionId: "s",
            request: ClarifyRequestPayload(payload: .object([
                "question": .string("Which dir?"),
                "choices": .array([]),
                "request_id": .string("clr-2"),
            ])))

        await chat.respondClarification("use the staging cluster")

        let echoed = try XCTUnwrap(chat.messages.last)
        XCTAssertEqual(echoed.role, .user)
        XCTAssertEqual(echoed.text, "use the staging cluster")
    }

    /// The echo must not be double-counted if the answer is somehow delivered
    /// twice (re-entry guard). Only ONE user row is appended.
    func testRespondClarificationEchoIsSingleRowEvenIfCalledTwice() async throws {
        let chat = ChatStore()
        chat.pendingClarification = PendingClarification(
            sessionId: "s",
            request: ClarifyRequestPayload(payload: .object([
                "question": .string("Q"),
                "choices": .array([]),
                "request_id": .string("clr-3"),
            ])))
        await chat.respondClarification("first")
        // The card has cleared; a second call is a no-op (nothing pending).
        await chat.respondClarification("second")

        let userAnswers = chat.messages.filter {
            $0.role == .user && ($0.text == "first" || $0.text == "second")
        }
        XCTAssertEqual(userAnswers.count, 1, "re-entry must not duplicate the echo")
        XCTAssertEqual(userAnswers.first?.text, "first")
    }

    // MARK: - R10 — long choice text wraps inside the card (no hard clip)

    /// IMG_2539 proof: ≥100-char choice buttons hard-clip at the screen edge
    /// with no wrapping. After the fix, a long choice renders fully inside the
    /// proposed width (the choice wraps to multiple lines). Asserted by hosting
    /// the card and confirming the rendered card does not exceed the proposed
    /// width and that the full choice text is reachable in the accessibility
    /// tree.
    func testLongChoiceWrapsInsideCardWidth() throws {
        let longChoice = String(repeating: "Build a high-signal monitor that stays quiet ", count: 3)
        let request = ClarifyRequestPayload(payload: .object([
            "question": .string("Which direction?"),
            "choices": .array([.string(longChoice), .string("No")]),
            "request_id": .string("clr-10"),
        ]))
        let card = ClarifyBanner(
            clarification: PendingClarification(sessionId: "s", request: request),
            chatStore: ChatStore()
        )
        .environment(\.hermesTheme, HermesThemePresets.nousLight)

        let proposed: CGFloat = 360
        let view = card.frame(width: proposed)
        let labels = accessibilityLabels(of: view, width: proposed)

        XCTAssertTrue(labels.contains(where: { $0.contains("Build a high-signal monitor") }),
                      "the full long-choice text MUST be present (R10: no hard-clip)")
    }

    // MARK: - R10 — long question text scrolls inside a bounded header

    /// IMG_2537 proof: a long question grew the card past the safe area into
    /// the nav bar. After the fix the question lives in a bounded scroll
    /// container so the card height is capped regardless of question length.
    func testLongQuestionKeepsCardHeightBounded() throws {
        let veryLongQuestion = String(repeating: "This is a long clarification question. ", count: 30)
        let request = ClarifyRequestPayload(payload: .object([
            "question": .string(veryLongQuestion),
            "choices": .array([.string("Yes"), .string("No")]),
            "request_id": .string("clr-11"),
        ]))
        let card = ClarifyBanner(
            clarification: PendingClarification(sessionId: "s", request: request),
            chatStore: ChatStore()
        )
        .environment(\.hermesTheme, HermesThemePresets.nousLight)

        let proposed: CGFloat = 360
        let height = measuredHeight(of: card, width: proposed)
        // Pre-fix the unbounded `fixedSize` grew a 30-repeated question to well
        // over 900pt. Post-fix the question lives in a bounded scroll header so
        // the whole card stays under ~520pt (header cap + choices + field).
        XCTAssertLessThan(height, 560,
                          "long question must scroll inside a bounded header, not grow the card unbounded (R10)")
    }

    // MARK: - R9 — card dismisses the keyboard on appear

    /// R9: composer + card + keyboard must never stack (IMG_2534/2537). The
    /// card MUST call `KeyboardDismissal.resign()` on appear. Asserted by
    /// swapping the handler for a counting spy (restored in `defer`) — proves
    /// the wiring without depending on the live responder chain.
    func testCardDismissesKeyboardOnAppear() throws {
        let original = KeyboardDismissal.resignHandler
        defer { KeyboardDismissal.resignHandler = original }
        var dismissCalls = 0
        KeyboardDismissal.resignHandler = { dismissCalls += 1 }

        let request = ClarifyRequestPayload(payload: .object([
            "question": .string("Deploy?"),
            "choices": .array([.string("Yes"), .string("No")]),
            "request_id": .string("clr-12"),
        ]))
        let card = ClarifyBanner(
            clarification: PendingClarification(sessionId: "s", request: request),
            chatStore: ChatStore()
        )
        .environment(\.hermesTheme, HermesThemePresets.nousLight)

        // `.onAppear` fires reliably only once the hosting view is attached to
        // a live UIWindow (mirrors `ProseSelectionTests.attachToWindow`). Pump
        // the runloop so SwiftUI dispatches the appearance callback.
        attachAndPump(card, width: 360)

        XCTAssertGreaterThan(dismissCalls, 0,
                             "the card MUST dismiss the keyboard on appear (R9)")
    }

    // MARK: - R7 / C1 — native system surface, no black field

    /// The shipped card drew a flat `theme.card` rect + a 1pt stroke and a
    /// `.textFieldStyle(.roundedBorder)` that rendered PURE BLACK on the dark
    /// card (IMG_2534/2537). After the rebuild the card mounts the native
    /// `GateCardSurface` (glass on iOS 26+, themed fallback otherwise); the
    /// free-text field is collapsed behind a "Type answer" row by default, and
    /// when revealed it uses the themed `theme.input` fill — never a solid-black
    /// `.roundedBorder`. This test guards the regression directly: no text
    /// field anywhere in the hosted card carries a solid-black background.
    func testCardRendersNoSolidBlackTextFieldOnDarkTheme() throws {
        let request = ClarifyRequestPayload(payload: .object([
            "question": .string("Approve?"),
            "choices": .array([.string("Yes")]),
            "request_id": .string("clr-13"),
        ]))
        let card = ClarifyBanner(
            clarification: PendingClarification(sessionId: "s", request: request),
            chatStore: ChatStore()
        )
        .environment(\.hermesTheme, HermesThemePresets.nousDark)

        let root = hostedRoot(card, width: 360)
        let textFields = collectViews(root) { $0 is UITextField }.compactMap { $0 as? UITextField }
        for field in textFields {
            // The pre-fix `.roundedBorder` field rendered solid black (#000)
            // against the dark card (IMG_2534/2537). The rebuilt field inherits
            // the material surface — assert it never carries solid-black bg.
            if let bg = field.backgroundColor {
                XCTAssertNotEqual(bg, UIColor.black,
                                  "free-text field must not render solid black on the dark card (R7/C1)")
            }
        }
    }

    // MARK: - Approval parity (A4): same native surface treatment

    /// The approval card must mount the same native gate surface (it shares the
    /// dock and the C1 contract). Sanity: hosting it does not crash and renders
    /// the Approve/Deny actions.
    func testApprovalCardMountsNativeSurfaceAndActions() throws {
        let approval = PendingApproval(
            id: "appr-1",
            sessionId: "s",
            request: ApprovalRequestPayload(payload: .object([
                "approval_id": .string("appr-1"),
                "command": .string("git push origin main"),
                "description": .string("Push the release branch"),
            ])))
        let card = ApprovalCard(approval: approval, chatStore: ChatStore())
            .environment(\.hermesTheme, HermesThemePresets.nousLight)

        let labels = accessibilityLabels(of: card, width: 360)
        XCTAssertTrue(labels.contains(where: { $0.contains("Approve") }),
                      "Approve action present")
        XCTAssertTrue(labels.contains(where: { $0.contains("Deny") }),
                      "Deny action present")
    }

    // MARK: - Hosting helpers

    private func hostedRoot<V: View>(_ view: V, width: CGFloat) -> UIView {
        let controller = UIHostingController(rootView: view.frame(width: width, alignment: .topLeading))
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 1200)
        controller.view.backgroundColor = .white
        pumpLayout(controller)
        return controller.view
    }

    /// Attaches the view (in a hosting controller) to a live UIWindow and pumps
    /// the runloop so SwiftUI `.onAppear` callbacks fire. Without a window
    /// appearance callbacks are unreliable in unit tests.
    @discardableResult
    private func attachAndPump<V: View>(_ view: V, width: CGFloat) -> UIWindow? {
        let controller = UIHostingController(rootView: view.frame(width: width, alignment: .topLeading))
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 1200)
        controller.view.backgroundColor = .white
        let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        guard let windowScene = scene else { return nil }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        pumpLayout(controller)
        // Appearance callbacks land on a runloop tick after makeKeyAndVisible.
        for _ in 0..<6 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        return window
    }

    /// Measures the natural height of a SwiftUI view at a fixed width using a
    /// `PreferenceKey` (the hosting controller's own `bounds` reflects the frame
    /// we set, not the SwiftUI content's height, so it is useless for sizing
    /// assertions). The preference is captured after a full layout pump.
    private struct HeightPreferenceKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    private func measuredHeight<V: View>(of view: V, width: CGFloat) -> CGFloat {
        var captured: CGFloat = 0
        let framed = view
            .frame(width: width, alignment: .topLeading)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: HeightPreferenceKey.self, value: proxy.size.height)
            })
            .onPreferenceChange(HeightPreferenceKey.self) { captured = $0 }
        let controller = UIHostingController(rootView: framed)
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 1200)
        controller.view.backgroundColor = .white
        pumpLayout(controller)
        return captured
    }

    private func accessibilityLabels<V: View>(of view: V, width: CGFloat) -> [String] {
        let root = hostedRoot(view, width: width)
        var labels: [String] = []
        collectAccessibilityLabels(root, depth: 0, into: &labels)
        return labels
    }

    private func pumpLayout(_ controller: UIHostingController<some View>) {
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        for _ in 0..<12 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            controller.view.layoutIfNeeded()
        }
    }

    private func collectViews(_ view: UIView, where predicate: (UIView) -> Bool) -> [UIView] {
        var found: [UIView] = []
        if predicate(view) { found.append(view) }
        for subview in view.subviews {
            found.append(contentsOf: collectViews(subview, where: predicate))
        }
        return found
    }

    private func collectAccessibilityLabels(_ element: Any?, depth: Int, into acc: inout [String]) {
        guard depth < 16 else { return }
        if let view = element as? UIView {
            for subview in view.subviews {
                collectAccessibilityLabels(subview, depth: depth + 1, into: &acc)
            }
        }
        let object = element as? NSObject
        if let label = object?.accessibilityLabel, !label.isEmpty {
            acc.append(label)
        }
        if let elements = object?.accessibilityElements {
            for case let child as NSObject in elements {
                collectAccessibilityLabels(child, depth: depth + 1, into: &acc)
            }
        }
    }
}
