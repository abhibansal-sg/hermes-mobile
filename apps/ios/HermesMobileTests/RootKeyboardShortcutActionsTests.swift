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
        XCTAssertTrue(source.contains(".keyboardShortcut(\",\", modifiers: .command)"))
        XCTAssertTrue(source.contains(".keyboardShortcut(\"[\", modifiers: .command)"))
        XCTAssertTrue(source.contains(".keyboardShortcut(\"]\", modifiers: .command)"))
        XCTAssertTrue(source.contains(".keyboardShortcut(\"d\", modifiers: .command)"))
        XCTAssertTrue(source.contains("sendCurrentComposerDraft"))
        XCTAssertTrue(source.contains("openSettings"))
        XCTAssertTrue(source.contains("navigateBack"))
        XCTAssertTrue(source.contains("navigateForward"))
        XCTAssertTrue(source.contains("toggleAppearanceDarkMode"))
    }
}
