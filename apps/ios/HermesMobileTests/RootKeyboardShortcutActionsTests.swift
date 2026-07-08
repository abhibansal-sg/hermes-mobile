import SwiftUI
import XCTest
@testable import HermesMobile

@MainActor
final class RootKeyboardShortcutActionsTests: XCTestCase {

    func testShortcutGateIsRegularWidthOnly() {
        XCTAssertTrue(RootKeyboardShortcutActions.isEnabledForHardwareShortcuts(horizontalSizeClass: .regular))
        XCTAssertFalse(RootKeyboardShortcutActions.isEnabledForHardwareShortcuts(horizontalSizeClass: .compact))
        XCTAssertFalse(RootKeyboardShortcutActions.isEnabledForHardwareShortcuts(horizontalSizeClass: nil))
    }

    func testSendCurrentComposerDraftTrimsClearsAndInvokesSendAction() {
        let sessions = SessionStore()
        let key = sessions.activeComposerDraftKey
        sessions.setComposerDraft("  hello keyboard  ", for: key)
        var sent: [String] = []

        let didSend = RootKeyboardShortcutActions.sendCurrentComposerDraft(from: sessions) { text in
            sent.append(text)
        }

        XCTAssertTrue(didSend)
        XCTAssertEqual(sent, ["hello keyboard"])
        XCTAssertEqual(sessions.composerDraft(for: key), "")
    }

    func testSendCurrentComposerDraftNoOpsForWhitespaceDraft() {
        let sessions = SessionStore()
        let key = sessions.activeComposerDraftKey
        sessions.setComposerDraft("   \n\t  ", for: key)
        var sent: [String] = []

        let didSend = RootKeyboardShortcutActions.sendCurrentComposerDraft(from: sessions) { text in
            sent.append(text)
        }

        XCTAssertFalse(didSend)
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(sessions.composerDraft(for: key), "")
    }

    func testOpenSettingsShortcutSetsPresentationBinding() {
        var presented = false
        let binding = Binding<Bool>(
            get: { presented },
            set: { presented = $0 }
        )

        RootKeyboardShortcutActions.openSettings(isPresented: binding)

        XCTAssertTrue(presented)
    }

    func testBackForwardShortcutsAreSafeNoOpsWithoutNavigationTargets() {
        XCTAssertFalse(RootKeyboardShortcutActions.navigateBack())
        XCTAssertFalse(RootKeyboardShortcutActions.navigateForward())
    }

    func testPromptHistoryDerivesNewestFirstTrimmedUserMessagesOnly() {
        let history = ComposerPromptHistory.deriveUserHistory(from: [
            ChatMessage(role: .user, text: " first "),
            ChatMessage(role: .assistant, text: "answer"),
            ChatMessage(role: .user, text: "   "),
            ChatMessage(role: .tool, text: "tool"),
            ChatMessage(role: .user, text: "\nsecond\n"),
        ])

        XCTAssertEqual(history, ["second", "first"])
    }

    func testPromptHistoryBackwardStopsAtOldest() {
        var state = ComposerPromptHistory.State()
        let history = ["newest", "oldest"]

        XCTAssertEqual(ComposerPromptHistory.browseBackward(
            history: history,
            currentDraft: "draft",
            state: &state
        ), "newest")
        XCTAssertEqual(ComposerPromptHistory.browseBackward(
            history: history,
            currentDraft: "newest",
            state: &state
        ), "oldest")
        XCTAssertNil(ComposerPromptHistory.browseBackward(
            history: history,
            currentDraft: "oldest",
            state: &state
        ))
        XCTAssertEqual(state.cursorIndex, 1)
    }

    func testPromptHistoryForwardRestoresOriginalDraftSnapshot() {
        var state = ComposerPromptHistory.State()
        let history = ["newest", "older"]

        XCTAssertEqual(ComposerPromptHistory.browseBackward(
            history: history,
            currentDraft: "half typed",
            state: &state
        ), "newest")
        XCTAssertEqual(ComposerPromptHistory.browseBackward(
            history: history,
            currentDraft: "newest",
            state: &state
        ), "older")
        XCTAssertEqual(ComposerPromptHistory.browseForward(history: history, state: &state), "newest")
        XCTAssertEqual(ComposerPromptHistory.browseForward(history: history, state: &state), "half typed")
        XCTAssertNil(state.cursorIndex)
        XCTAssertNil(ComposerPromptHistory.browseForward(history: history, state: &state))
    }

    func testSessionPromptHistoryIsIsolatedPerDraftKey() {
        let sessions = SessionStore()
        let chat = ChatStore()
        chat.messages = [
            ChatMessage(role: .user, text: "session a older"),
            ChatMessage(role: .user, text: "session a newest"),
        ]

        sessions.activeStoredId = "session-a"
        sessions.setComposerDraft("draft a", for: sessions.activeComposerDraftKey)
        XCTAssertTrue(RootKeyboardShortcutActions.recallPreviousComposerPrompt(sessions: sessions, chat: chat))
        XCTAssertEqual(sessions.composerDraft(for: "session-a"), "session a newest")

        sessions.activeStoredId = "session-b"
        sessions.setComposerDraft("draft b", for: sessions.activeComposerDraftKey)
        chat.messages = [ChatMessage(role: .user, text: "session b newest")]
        XCTAssertTrue(RootKeyboardShortcutActions.recallPreviousComposerPrompt(sessions: sessions, chat: chat))
        XCTAssertEqual(sessions.composerDraft(for: "session-b"), "session b newest")
        XCTAssertEqual(sessions.composerDraft(for: "session-a"), "session a newest")

        XCTAssertTrue(RootKeyboardShortcutActions.recallNextComposerPrompt(sessions: sessions, chat: chat))
        XCTAssertEqual(sessions.composerDraft(for: "session-b"), "draft b")

        sessions.activeStoredId = "session-a"
        chat.messages = [
            ChatMessage(role: .user, text: "session a older"),
            ChatMessage(role: .user, text: "session a newest"),
        ]
        XCTAssertTrue(RootKeyboardShortcutActions.recallNextComposerPrompt(sessions: sessions, chat: chat))
        XCTAssertEqual(sessions.composerDraft(for: "session-a"), "draft a")
    }

    func testExternalComposerDraftMutationBumpsRevisionForVisibleBridge() {
        let sessions = SessionStore()
        let key = sessions.activeComposerDraftKey
        let before = sessions.composerDraftRevision

        sessions.setComposerDraft("recalled prompt", for: key)

        XCTAssertGreaterThan(sessions.composerDraftRevision, before)
        XCTAssertEqual(sessions.composerDraft(for: key), "recalled prompt")
    }

    func testToggleAppearanceSwitchesBetweenAdaptiveNousAndForcedDark() {
        let oldSelection = UserDefaults.standard.string(forKey: DefaultsKeys.theme)
        defer {
            if let oldSelection {
                UserDefaults.standard.set(oldSelection, forKey: DefaultsKeys.theme)
            } else {
                UserDefaults.standard.removeObject(forKey: DefaultsKeys.theme)
            }
        }

        UserDefaults.standard.set("nous", forKey: DefaultsKeys.theme)
        let store = ThemeStore()
        store.select("nous")

        RootKeyboardShortcutActions.toggleAppearanceDarkMode(themeStore: store)
        XCTAssertEqual(store.selection, "midnight")
        XCTAssertEqual(store.forcedColorScheme, .dark)

        RootKeyboardShortcutActions.toggleAppearanceDarkMode(themeStore: store)
        XCTAssertEqual(store.selection, "nous")
        XCTAssertNil(store.forcedColorScheme)
    }

    func testRootShortcutLayerWiresExpectedKeyboardShortcutSymbols() throws {
        let rootViewPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HermesMobile/Views/Shell/RootView.swift")
        let source = try String(contentsOf: rootViewPath, encoding: .utf8)

        XCTAssertTrue(source.contains(".keyboardShortcut(.return, modifiers: .command)"))
        XCTAssertTrue(source.contains(".keyboardShortcut(.upArrow, modifiers: .command)"))
        XCTAssertTrue(source.contains(".keyboardShortcut(.downArrow, modifiers: .command)"))
        XCTAssertTrue(source.contains(".keyboardShortcut(\",\", modifiers: .command)"))
        XCTAssertTrue(source.contains(".keyboardShortcut(\"[\", modifiers: .command)"))
        XCTAssertTrue(source.contains(".keyboardShortcut(\"]\", modifiers: .command)"))
        XCTAssertTrue(source.contains(".keyboardShortcut(\"d\", modifiers: .command)"))
        XCTAssertTrue(source.contains("sendCurrentComposerDraft"))
        XCTAssertTrue(source.contains("recallPreviousComposerPrompt"))
        XCTAssertTrue(source.contains("recallNextComposerPrompt"))
        XCTAssertTrue(source.contains("openSettings"))
        XCTAssertTrue(source.contains("navigateBack"))
        XCTAssertTrue(source.contains("navigateForward"))
        XCTAssertTrue(source.contains("toggleAppearanceDarkMode"))
    }
}
