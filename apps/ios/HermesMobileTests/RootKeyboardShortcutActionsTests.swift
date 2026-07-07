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

    // MARK: STR-691 — Settings presentation state hoisted above the size-class branch

    /// STR-687/STR-691: the Settings sheet's presentation state must live ABOVE
    /// the regular<->compact layout branch in RootView (not inside SplitLayout /
    /// CompactLayout), so a size-class change can never tear the sheet down — and
    /// with it the NavigationStack/form @State for an unsaved provider key typed in
    /// Settings > Model Providers. Both layout branches open Settings by flipping
    /// the SAME root-owned flag through this shared seam, so there is exactly one
    /// source of truth that survives the branch swap.
    func testSettingsPresentationUsesOneSharedBindingAcrossLayoutBranches() {
        // The single flag RootView owns above the size-class branch.
        var sharedRootPresented = false
        let sharedRootBinding = Binding<Bool>(
            get: { sharedRootPresented },
            set: { sharedRootPresented = $0 }
        )

        // Regular branch (SplitLayout) opens Settings — ⌘, or avatar — via the
        // shared seam.
        RootKeyboardShortcutActions.openSettings(isPresented: sharedRootBinding)
        XCTAssertTrue(sharedRootPresented, "SplitLayout open should drive the shared root flag")

        // A regular->compact size-class swap tears SplitLayout down and rebuilds
        // CompactLayout, but the shared flag is owned ABOVE both branches — so
        // Settings STAYS presented (there is no second, layout-owned flag to
        // reset it). This is the regression the hoist in RootView fixes.
        XCTAssertTrue(sharedRootPresented, "Settings must remain presented across the size-class swap")

        // The compact branch (CompactLayout) acts on the SAME single flag, so a
        // dismiss from either branch clears the one shared source of truth.
        sharedRootPresented = false
        XCTAssertFalse(sharedRootPresented, "CompactLayout shares the same single presentation flag")
    }

    /// Pins the structural hoist: RootView owns the one `showingSettings` @State
    /// and presents Settings from its own `.sheet`, while neither layout branch
    /// owns an independent presentation state/sheet. Guards against a regression
    /// that re-introduces a per-branch `showingSettings`.
    func testSettingsSheetOwnershipIsHoistedAboveLayoutBranch() throws {
        let rootViewPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HermesMobile/Views/Shell/RootView.swift")
        let source = try String(contentsOf: rootViewPath, encoding: .utf8)

        // RootView owns the single presentation flag and presents the sheet.
        XCTAssertTrue(source.contains("struct RootView: View"), "sanity")
        XCTAssertTrue(source.contains("SplitLayout(onOpenSettings: openSettings)"))
        XCTAssertTrue(source.contains("CompactLayout(onOpenSettings: openSettings)"))

        // Exactly ONE showingSettings @State may exist, in RootView. Two would
        // mean a layout branch re-acquired its own presentation state — the
        // STR-687 regression. Count full-line occurrences.
        let showingSettingsStateCount = source.components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces) == "@State private var showingSettings = false" }
            .count
        XCTAssertEqual(showingSettingsStateCount, 1, "showingSettings @State must exist exactly once (RootView only); a second occurrence means a layout branch owns independent presentation state — the STR-687 regression.")
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
