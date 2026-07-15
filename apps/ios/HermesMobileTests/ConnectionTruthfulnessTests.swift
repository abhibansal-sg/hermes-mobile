import XCTest
@testable import HermesMobile

/// STR-136 — iPad connection-state truthfulness (reconnect/offline).
///
/// Finding A: the toast auto-dismiss must consume `ChatStore.lastError`
/// together with the view-local toast, so a later `ChatView` remount (the
/// iPad Split View / Stage Manager / Slide Over resize path) doesn't
/// resurrect a stale error via `onAppear { presentToast(chatStore.lastError) }`.
@MainActor
final class ConnectionTruthfulnessTests: XCTestCase {

    // MARK: Finding A — toast dismiss consumes the store latch

    func testConsumeToastLatchClearsBothViewStateAndStoreLatch() {
        let chatStore = ChatStore()
        chatStore.lastError = "Seeded failure"
        var toastError: String? = "Seeded failure"

        ChatView.consumeToastLatch(toastError: &toastError, chatStore: chatStore)

        XCTAssertNil(toastError, "toast auto-dismiss must clear the view-local toast")
        XCTAssertNil(
            chatStore.lastError,
            "toast auto-dismiss must also clear chatStore.lastError so a later ChatView " +
            "remount's onAppear has nothing stale to re-present (STR-136 Finding A)"
        )
    }

    func testNilTransitionAfterConsumeIsNotRepresentable() {
        // The onChange(of: chatStore.lastError) nil transition that follows
        // consumeToastLatch must not be treated as a real message to (re-)show.
        XCTAssertFalse(
            ChatView.isPresentableToastMessage(nil),
            "a nil chatStore.lastError must not re-arm the toast"
        )
    }

    func testEmptyStringIsNotPresentable() {
        XCTAssertFalse(ChatView.isPresentableToastMessage(""))
    }

    func testNonEmptyMessageIsPresentable() {
        XCTAssertTrue(ChatView.isPresentableToastMessage("Seeded failure"))
    }
}
