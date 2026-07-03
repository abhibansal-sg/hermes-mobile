import SwiftUI
import UIKit

/// The app's top-level view. Switches on ``ConnectionStore/Phase``:
/// `.needsSetup` shows the pairing/onboarding root (``WelcomeView``, owned by
/// B4); every other phase shows the main chat-as-home UI, adapting between a
/// `NavigationSplitView` (regular width — iPad / landscape) and a compact
/// slide-over drawer over a full-screen ``ChatView`` (iPhone).
///
/// Chat is home. The session list lives in a ChatGPT-style ``DrawerView``:
/// a permanent sidebar column on iPad, an interactive slide-over on iPhone.
/// `sessionStore.activeStoredId` remains the selection source of truth; the
/// drawer opens sessions through `sessionStore.open(_:)` and the (compact) shell
/// closes itself afterward.
///
/// Preserved from the prior two-column shell: the AppLock cover above the entire
/// UI, the iPad inspector column (the approval ``InboxView``), the hardware-
/// keyboard shortcuts (⌘N new chat, ⌘F focus search, ⌘. interrupt), and the
/// connection-phase routing.
struct RootView: View {
    @Environment(ConnectionStore.self) private var connection
    @Environment(SessionStore.self) private var sessions
    @Environment(AppLock.self) private var appLock
    @Environment(InboxStore.self) private var inbox
    @Environment(ThemeStore.self) private var themeStore
    @Environment(DeepLinkCoordinator.self) private var deepLink
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// The compact slide-over drawer's open/closed state. Owned here and
    /// injected so ``ChatView``'s leading toolbar button (B2) can toggle it.
    /// Inert on regular width (the drawer is a permanent sidebar there).
    @State private var drawerState = DrawerState()

    /// Presents the inbox when something requests it via
    /// `InboxStore.requestPresentation()` — the push-tap / bare-root fallback
    /// for a session that isn't loaded. The token previously had NO observer,
    /// so those taps dead-ended silently (R1 #5/#63). A sheet at this root is
    /// the one surface that exists on BOTH width classes.
    @State private var showingInboxSheet = false

    var body: some View {
        content
            .environment(drawerState)
            // Outermost lock cover: sits above the entire UI (setup or main,
            // compact or regular) so the blur hides the transcript regardless
            // of width or connection phase. PRESERVED from the prior shell.
            .overlay {
                if appLock.isLocked {
                    AppLockOverlay()
                }
            }
            .onChange(of: inbox.presentationRequestToken) { _, _ in
                // Never cover the onboarding flow; a pre-pairing push tap has
                // nothing actionable to show anyway.
                guard connection.phase != .needsSetup else { return }
                showingInboxSheet = true
            }
            .sheet(isPresented: $showingInboxSheet) {
                NavigationStack {
                    InboxView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showingInboxSheet = false }
                            }
                        }
                }
                .hermesThemed(themeStore)
            }
            // (pair) hermesapp://pair WHILE CONNECTED — confirm before the
            // destructive disconnect-and-repair. The router stashed the parsed
            // payload in `deepLink.pendingPair` instead of reconfiguring silently;
            // approving here applies it (tearing down the live session), Cancel
            // drops it and leaves the current connection untouched. Presented at
            // this root (like the inbox sheet) so it exists on BOTH width classes
            // and never disturbs the full-bleed chat canvas below.
            .alert(
                "Connect to a different server?",
                isPresented: pairConfirmationPresented
            ) {
                Button("Disconnect & Connect", role: .destructive) {
                    if let payload = deepLink.pendingPair {
                        HermesURLRouter.applyPair(payload, connection: connection)
                    }
                    deepLink.clear()
                }
                Button("Cancel", role: .cancel) {
                    deepLink.clear()
                }
            } message: {
                Text("This will disconnect your current session and pair with the new server from the link.")
            }
            // Inc-3b: Local-desktop manual-token prompt. Shown when a
            // hermesapp://pair?manual_token=true payload arrives and the plugin
            // could not recover the token automatically. The user enters the token;
            // on success, configure() transitions to .connected normally.
            .sheet(item: manualTokenPairPayload) { payload in
                ManualTokenPromptView(
                    discoveredURL: payload.url,
                    onDismiss: { deepLink.clearManualTokenPair() }
                )
                .hermesThemed(themeStore)
            }
    }

    /// Binding driving the re-pair confirmation alert: `true` while a payload is
    /// parked. Setting it `false` (Cancel / dismiss) clears the parked payload so
    /// the alert and the coordinator state stay in sync.
    private var pairConfirmationPresented: Binding<Bool> {
        Binding(
            get: { deepLink.pendingPair != nil },
            set: { presented in
                if !presented { deepLink.clear() }
            }
        )
    }

    /// Optional binding for the manual-token Local-desktop pairing sheet.
    /// Uses `Binding<PairPayload?>` driven by `pendingManualTokenPair` so SwiftUI
    /// can auto-dismiss when set to `nil`.
    private var manualTokenPairPayload: Binding<HermesURLRouter.PairPayload?> {
        Binding(
            get: { deepLink.pendingManualTokenPair },
            set: { value in
                if value == nil { deepLink.clearManualTokenPair() }
            }
        )
    }

    @ViewBuilder
    private var content: some View {
        switch connection.phase {
        case .needsSetup:
            // B4 owns the onboarding/pairing root (WelcomeView), which offers
            // QR scan + a slide-up manual ConnectionSetupView fallback (ABH-75).
            // Integrator reconciles if B4 has not landed.
            WelcomeView()
        case .hydrating:
            // ABH-82: a verified connection whose gateway state is still being
            // pulled. Show the branded loading screen rather than flashing the
            // empty shell. ConnectionStore guarantees this is transient (an 8s
            // timeout fallback flips it to `.connected`), so it never strands.
            HydrationLoadingView()
        case .connecting, .reconnecting, .offline:
            // P0 GATE (ABH-82 follow-up): a `.connecting`/`.offline` phase only
            // earns the chat shell once a connection has actually been verified
            // (`hasConnected`) — i.e. a LIVE session that dropped, which the
            // shell shows with an offline/reconnecting banner. Before any
            // verified connection, these phases mean a manual/QR `configure`
            // FAILED validation (bad URL, unreachable host, transport error);
            // dropping into the shell then is the reported bypass — garbage
            // credentials transitioning into the main UI. Keep such a user in
            // onboarding (the failure rides behind the manual sheet / QR cover,
            // which render their own inline error and stay presented). The one
            // legitimate pre-`hasConnected` exception is the launch reconnect of
            // a SAVED config (`isBootstrapping`): a returning user sees the
            // splash, not a flash of Welcome.
            //
            // CACHE-FIRST (WhatsApp bar): a previously-paired user
            // (`hasSavedConfiguration`) ALSO earns the shell in these phases — even
            // after `isBootstrapping` clears (the cold-launch-offline window the
            // old gate dropped to WelcomeView, the reported bug: a paired user
            // launching offline saw the PAIRING screen). The cache-first drawer +
            // cached transcripts + offline ribbon render; Welcome is now reserved
            // for a genuinely-unconfigured install. The validation-bypass guarantee
            // is preserved: a failed manual/QR `configure` persists nothing and
            // leaves `serverURLString` empty, so `hasSavedConfiguration` is false
            // and the user stays in onboarding behind the inline error.
            if connection.hasConnected
                || connection.isBootstrapping
                || connection.hasSavedConfiguration {
                mainUI
            } else {
                WelcomeView()
            }
        case .connected:
            // A verified, live connection — always the shell.
            mainUI
        }
    }

    @ViewBuilder
    private var mainUI: some View {
        if horizontalSizeClass == .regular {
            SplitLayout()
        } else {
            CompactLayout()
        }
    }
}

// MARK: - Regular width (split view)

/// Regular-width layout (iPad, landscape): a two-column `NavigationSplitView`
/// — sidebar (``DrawerView``) + detail (``ChatView`` or a placeholder) — with
/// an optional inspector column (the approval inbox) toggled from the detail
/// toolbar. The sidebar selection is `sessionStore.activeStoredId`, so the
/// detail column follows whatever session is active.
///
/// The sidebar/detail split, the inspector, and the keyboard shortcuts are all
/// preserved from the prior shell; only the sidebar content changed
/// (``DrawerView`` replaces ``SessionListView``). Hardware-keyboard shortcuts:
/// - ⌘N — new chat (`SessionStore.startDraft`)
/// - ⌘F — focus the drawer search field (environment bridge — see
///   `rootSearchFocusRequested`)
/// - ⌘. — interrupt the streaming turn (`ChatStore.interrupt`)
private struct SplitLayout: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(ChatStore.self) private var chat
    @Environment(SpeechPlayer.self) private var speechPlayer
    @Environment(ConnectionStore.self) private var connection
    @Environment(InboxStore.self) private var inbox
    @Environment(AppLock.self) private var appLock
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Drives the optional inspector column (the approval inbox). Starts hidden;
    /// toggled from the detail toolbar.
    @State private var showingInspector = false

    /// Presents Settings from the iPad hardware-keyboard layer (⌘,). The sidebar
    /// avatar still owns the visible Settings affordance; this is the keyboard-only
    /// parity entry point at the split-view root.
    @State private var showingSettings = false

    /// Which inspector tab is shown (F4A-A2): the approval inbox or the subagent
    /// delegation tree. The tab picker only appears when subagent activity exists.
    @State private var inspectorTab: InspectorTab = .inbox

    private enum InspectorTab: String, CaseIterable, Identifiable {
        case inbox = "Inbox"
        case subagents = "Subagents"
        var id: String { rawValue }
    }

    /// Drives the ⌘F shortcut: set `true` to ask the sidebar to move first
    /// responder into its search field. Published into the environment so
    /// ``DrawerView`` (which owns the search `TextField`) can observe the rising
    /// edge and focus it. A no-op if the drawer hasn't adopted the hook.
    @State private var searchFocusRequested = false

    var body: some View {
        NavigationSplitView {
            DrawerView(onOpenSettings: openSettings)
                .environment(\.rootSearchFocusRequested, searchFocusRequested)
                .onChange(of: searchFocusRequested) { _, requested in
                    if requested {
                        Task { @MainActor in searchFocusRequested = false }
                    }
                }
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 380)
        } detail: {
            detailColumn
                .inspector(isPresented: $showingInspector) {
                    inspectorColumn
                        .inspectorColumnWidth(min: 280, ideal: 340, max: 460)
                }
        }
        .background(keyboardShortcutLayer)
        // Re-install the resolved palette + brand tint at this split-view root;
        // SwiftUI does not reliably inherit custom environment values across
        // presentation/column boundaries. PRESERVED.
        .hermesThemed(themeStore)
        .sheet(isPresented: $showingSettings) {
            SettingsView(
                connectionStore: connection,
                sessionStore: sessions,
                appLock: appLock
            )
            .presentationDragIndicator(.hidden)
            .hermesThemed(themeStore)
        }
    }

    // MARK: Detail column

    @ViewBuilder
    private var detailColumn: some View {
        // Chat is home: show it for an active session OR a fresh draft (B3 lands
        // the app on a draft, so the detail column is never the empty
        // placeholder at launch). ChatView renders the draft greeting itself
        // (B2). The placeholder only appears if both are absent (e.g. the active
        // session was deleted without starting a new draft).
        if sessions.activeStoredId != nil || sessions.isDraft {
            ChatView(
                onSpeak: speakHandler(speechPlayer: speechPlayer, connection: connection),
                // Thread the draft flag like CompactLayout does, so a fresh
                // draft on iPad renders the time-aware greeting instead of a
                // blank transcript (R1 #80 — it was hardcoded to the default
                // false here).
                isDraft: sessions.isDraft,
                // F0 / Amendment B: feed the running model so the chip renders on
                // iPad too (the model picker is reachable from the iPad sidebar's
                // settings sheet — keep the chip in sync there).
                modelName: connection.activeModelName
            )
                .safeAreaInset(edge: .top, spacing: 0) {
                    ConnectionStatusBanner()
                        .animation(.easeInOut(duration: 0.2), value: connection.phase)
                }
                .toolbar {
                    // F4A-A2: a subagent-tree inspector toggle, shown only when the
                    // patched gateway has emitted subagent frames AND the active
                    // turn has delegation activity. Tapping it opens the inspector
                    // on the Subagents tab. Placed next to the inbox toggle.
                    if showSubagentInspector {
                        ToolbarItem(placement: .topBarTrailing) {
                            subagentInspectorToggleButton
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        inspectorToggleButton
                    }
                }
        } else {
            ContentUnavailableView(
                "Start a chat",
                systemImage: "bubble.left.and.text.bubble.right",
                description: Text("Pick a session from the sidebar or start a new one.")
            )
        }
    }

    private var inspectorToggleButton: some View {
        Button {
            if showingInspector && inspectorTab == .inbox {
                showingInspector = false
            } else {
                inspectorTab = .inbox
                showingInspector = true
            }
        } label: {
            Image(systemName: showingInspector
                  ? "tray.full.fill"
                  : "tray.full")
        }
        .badge(inbox.pendingCount)
        .accessibilityLabel(showingInspector ? "Hide inbox" : "Show inbox")
        .accessibilityValue(inbox.pendingCount > 0 ? "\(inbox.pendingCount) pending" : "")
        .help("Toggle the approval inbox")
    }

    /// Whether the iPad subagent inspector toggle should appear (F4A-A2): the
    /// gateway emitted subagent frames AND there is delegation activity.
    private var showSubagentInspector: Bool {
        connection.capabilities.subagentEvents == .available && chat.hasSubagentActivity
    }

    private var subagentInspectorToggleButton: some View {
        Button {
            if showingInspector && inspectorTab == .subagents {
                showingInspector = false
            } else {
                inspectorTab = .subagents
                showingInspector = true
            }
        } label: {
            Image(systemName: "point.3.connected.trianglepath.dotted")
        }
        .accessibilityLabel("Show subagents")
        .help("Toggle the subagent tree")
    }

    // MARK: Inspector column (approval inbox)

    /// Content of the optional third column: the global approval/clarification
    /// inbox (S1). `InboxView` reads `InboxStore`/`SessionStore` from the
    /// environment and owns its own `navigationTitle`. PRESERVED.
    @ViewBuilder
    private var inspectorColumn: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // A segmented picker appears only when the subagent tab is
                // available, so the default (inbox-only) layout is unchanged.
                if showSubagentInspector {
                    Picker("Inspector", selection: $inspectorTab) {
                        ForEach(InspectorTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Inspector tab")
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
                switch inspectorTab {
                case .inbox:
                    InboxView()
                case .subagents:
                    SubagentTreeView(chatStore: chat)
                }
            }
            // A new turn resets the subagent tree, which hides BOTH the
            // segmented picker and the toolbar toggle — an inspector left open
            // on .subagents became a stuck "No subagents" tab with no visible
            // way back (R1 #55). Snap it home when the tree empties.
            .onChange(of: chat.hasSubagentActivity) { _, hasActivity in
                if !hasActivity && inspectorTab == .subagents {
                    inspectorTab = .inbox
                }
            }
        }
        .hermesThemed(themeStore)
    }

    // MARK: Keyboard shortcuts

    /// A hidden command layer hosting the hardware-keyboard shortcuts. Buttons
    /// (rather than `.keyboardShortcut` on visible controls) keep the shortcuts
    /// available regardless of which column currently holds visible focus.
    private var keyboardShortcutLayer: some View {
        ZStack {
            if RootKeyboardShortcutActions.isEnabledForHardwareShortcuts(horizontalSizeClass: horizontalSizeClass) {
                Button {
                    newChat()
                } label: { Text("New Chat") }
                .keyboardShortcut("n", modifiers: .command)

                Button {
                    searchFocusRequested = true
                } label: { Text("Search") }
                .keyboardShortcut("f", modifiers: .command)

                Button {
                    interrupt()
                } label: { Text("Interrupt") }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!chat.isStreaming)

                Button {
                    sendCurrentComposerDraft()
                } label: { Text("Send") }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!RootKeyboardShortcutActions.hasSendableComposerText(sessions: sessions))

                Button {
                    openSettings()
                } label: { Text("Settings") }
                .keyboardShortcut(",", modifiers: .command)

                Button {
                    navigateBack()
                } label: { Text("Back") }
                .keyboardShortcut("[", modifiers: .command)

                Button {
                    navigateForward()
                } label: { Text("Forward") }
                .keyboardShortcut("]", modifiers: .command)

                Button {
                    toggleAppearanceDarkMode()
                } label: { Text("Toggle Dark Mode") }
                .keyboardShortcut("d", modifiers: .command)
            }
        }
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func newChat() {
        sessions.startDraft()
    }

    private func sendCurrentComposerDraft() {
        RootKeyboardShortcutActions.sendCurrentComposerDraft(from: sessions) { text in
            Task { await chat.send(text: text, includeAttachments: false) }
        }
    }

    private func openSettings() {
        RootKeyboardShortcutActions.openSettings(isPresented: $showingSettings)
    }

    private func navigateBack() {
        RootKeyboardShortcutActions.navigateBack()
    }

    private func navigateForward() {
        RootKeyboardShortcutActions.navigateForward()
    }

    private func toggleAppearanceDarkMode() {
        RootKeyboardShortcutActions.toggleAppearanceDarkMode(themeStore: themeStore)
    }

    private func interrupt() {
        guard chat.isStreaming else { return }
        Task { await chat.interrupt() }
    }
}

// MARK: - iPad hardware-keyboard action seams

/// Testable action seams for ``SplitLayout``'s hidden hardware-keyboard buttons.
/// The actions are intentionally tiny and safe: shortcuts are regular-width only,
/// absent navigation targets no-op, and sending refuses empty/whitespace drafts.
@MainActor
enum RootKeyboardShortcutActions {
    static func isEnabledForHardwareShortcuts(horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        horizontalSizeClass == .regular
    }

    static func hasSendableComposerText(sessions: SessionStore) -> Bool {
        !sessions.composerDraft(for: sessions.activeComposerDraftKey)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    @discardableResult
    static func sendCurrentComposerDraft(
        from sessions: SessionStore,
        send: @escaping @MainActor (String) -> Void
    ) -> Bool {
        let key = sessions.activeComposerDraftKey
        let text = sessions.composerDraft(for: key)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        sessions.setComposerDraft("", for: key)
        send(text)
        return true
    }

    static func openSettings(isPresented: Binding<Bool>) {
        isPresented.wrappedValue = true
    }

    @discardableResult
    static func navigateBack() -> Bool {
        // The split-view detail currently owns no root-level NavigationPath. Keep
        // ⌘[ wired as a safe no-op until a detail navigation target is introduced.
        false
    }

    @discardableResult
    static func navigateForward() -> Bool {
        // Symmetric safe no-op for ⌘] while there is no forward stack to traverse.
        false
    }

    static func toggleAppearanceDarkMode(themeStore: ThemeStore) {
        if themeStore.forcedColorScheme == .dark {
            themeStore.select(HermesThemePresets.defaultName)
        } else {
            themeStore.select("midnight")
        }
    }
}

// MARK: - ⌘F search-focus bridge (environment seam)

/// Environment flag raised by the regular-width ⌘F shortcut. ``RootView`` owns
/// the key; ``DrawerView`` is the intended observer (it owns the search
/// `TextField`). The value flips `true` for one runloop tick per ⌘F press and
/// is auto-cleared, so the sidebar can treat each `true` as a focus edge.
private struct RootSearchFocusRequestedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// `true` for one tick after ⌘F; read it from the drawer to move first
    /// responder into the search field.
    var rootSearchFocusRequested: Bool {
        get { self[RootSearchFocusRequestedKey.self] }
        set { self[RootSearchFocusRequestedKey.self] = newValue }
    }
}

// MARK: - Drawer gesture arbitration seams (ABH-380/381)

/// UIKit text-input state visible to the compact drawer pan. SwiftUI's root
/// `DragGesture` cannot participate in `UITextView`'s selection-handle gesture
/// delegate chain, so the drawer samples the live first-responder text input
/// before it latches horizontal dominance.
struct DrawerTextInputSnapshot: Equatable {
    /// The first responder's text-container frame in screen/global coordinates.
    let frameInScreen: CGRect
    /// `true` while UIKit has a non-collapsed selected range, which is exactly
    /// the state where left/right selection handles may begin just outside the
    /// text view's bounds.
    let hasActiveSelection: Bool
}

/// Pure decision logic for compact drawer pan arbitration. Kept testable so the
/// two table-stakes invariants (text-selection yield and scroll exclusivity) are
/// pinned without a fragile drag UI test harness.
enum DrawerGestureArbitration {
    /// UIKit selection handles can start a little outside the text rect. Treat
    /// that as owned by text editing rather than the drawer.
    static let selectionHandleHitSlop: CGFloat = 28

    static func shouldYieldToTextInteraction(
        startLocation: CGPoint,
        textInput: DrawerTextInputSnapshot?
    ) -> Bool {
        guard let textInput else { return false }
        if textInput.hasActiveSelection { return true }
        guard !textInput.frameInScreen.isNull, !textInput.frameInScreen.isEmpty else { return false }
        return textInput.frameInScreen
            .insetBy(dx: -selectionHandleHitSlop, dy: -selectionHandleHitSlop)
            .contains(startLocation)
    }

    static func resolveHorizontalDominance(
        current: Bool?,
        isDrawerOpen: Bool,
        translation: CGSize,
        startLocation: CGPoint,
        openZone: CGFloat,
        dominanceRatio: CGFloat,
        textInput: DrawerTextInputSnapshot?
    ) -> Bool? {
        if current != nil { return current }

        let dx = translation.width
        let dy = translation.height
        // Only classify once the drag has enough magnitude and a clear horizontal
        // lead. Until then, let the transcript/code scrollers continue normally.
        guard abs(dx) > abs(dy) * dominanceRatio, abs(dx) > 1 else { return nil }

        if shouldYieldToTextInteraction(startLocation: startLocation, textInput: textInput) {
            return false
        }

        if isDrawerOpen { return true }
        if startLocation.x <= openZone && dx > 0 { return true }
        return false
    }

    static func shouldLockTranscriptScroll(horizontalDominant: Bool?) -> Bool {
        horizontalDominant == true
    }
}

@MainActor
private enum DrawerTextInputLocator {
    static func currentSnapshot() -> DrawerTextInputSnapshot? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter { !$0.isHidden && $0.alpha > 0 }

        for window in windows {
            guard let responder = window.hermesFirstResponderDescendant() else { continue }
            guard let input = responder as? (UIView & UITextInput) else { continue }

            let frame = responder.convert(responder.bounds, to: nil)
            let selectedRange = input.selectedTextRange
            return DrawerTextInputSnapshot(
                frameInScreen: frame,
                hasActiveSelection: selectedRange.map { !$0.isEmpty } ?? false
            )
        }
        return nil
    }
}

private extension UIView {
    func hermesFirstResponderDescendant() -> UIView? {
        if isFirstResponder { return self }
        for subview in subviews {
            if let match = subview.hermesFirstResponderDescendant() { return match }
        }
        return nil
    }
}

// MARK: - Compact width (push-card drawer)

/// iPhone layout (Claude-iOS push-card, F1 / Amendment D): ``DrawerView`` sits
/// on the canvas at `x = 0`; the full chat surface (``ChatView`` in its own
/// `NavigationStack`) rides ABOVE it and is pushed right by ~78% of the screen
/// width when the drawer opens. The chat reads as a rounded card sliding on the
/// same plane as the drawer beneath — there is **no** dim scrim and **no**
/// opacity change on the chat (Amendment D: "drop the scrim, add cornerRadius
/// ~28 + shadow on the displaced chatStack").
///
/// Per Amendment D the NavigationStacks are NOT re-parented — this is purely a
/// restyle of the prior offset/drag math: the chat keeps its own
/// `NavigationStack` exactly where it was. The chat now carries a real SYSTEM
/// `.toolbar` INSIDE that NavigationStack (I1 — the floating-pills + hidden-bar
/// chrome is gone); the toolbar rides with the card and is clipped by
/// `chatCardSurface`'s rounded shape during displacement, so the geometry fix
/// (full-bleed `theme.bg` at rest, radius ~28 mid-drag) is preserved unchanged.
/// The open gesture (BUG 2 / locked design) starts anywhere in the leading 50%
/// of the screen and only begins driving the drawer once it is horizontally
/// dominant (`abs(dx) > abs(dy) * 1.2` AND `dx > 0`), installed as a
/// `simultaneousGesture` so vertical scrolls and horizontal sub-scrollers win
/// until then. The close-drag may begin anywhere on the displaced card.
///
/// Drawer open/close is driven by the injected ``DrawerState`` (so the chat
/// toolbar's leading drawer button — I1 — can toggle it) and by the gestures
/// here.
private struct CompactLayout: View {
    @Environment(SpeechPlayer.self) private var speechPlayer
    @Environment(ConnectionStore.self) private var connection
    @Environment(SessionStore.self) private var sessions
    @Environment(AppLock.self) private var appLock
    @Environment(ThemeStore.self) private var themeStore
    @Environment(DrawerState.self) private var drawer

    /// Live drag translation while the user is dragging the drawer (open or
    /// closed gesture); `nil` when no drag is in progress.
    @State private var dragTranslation: CGFloat?

    /// Per-gesture horizontal-dominance latch. `nil` until the first `onChanged`
    /// resolves whether this drag is horizontal (drives the drawer) or vertical
    /// (yields to scrolling); thereafter it sticks for the life of the gesture so
    /// a drag that started horizontal keeps driving even if it later curves.
    /// Reset to `nil` on `onEnded`.
    @State private var horizontalDominant: Bool?

    /// Presents Settings from the compact drawer avatar. Owned by this stable
    /// layout container, not by ``DrawerView``, so a cold drawer first-commit cannot
    /// reset/drop the presentation write before SwiftUI anchors the sheet.
    @State private var showingSettings = false

    /// `true` for the remainder of a touch sequence after the drawer pan has
    /// latched horizontal dominance. Bound into the chat subtree via
    /// `.scrollDisabled` so the transcript's vertical `ScrollView` stops tracking
    /// the same finger until the drawer gesture ends.
    @State private var drawerScrollLocked = false

    /// SMOOTHNESS R40 (Defect: "card snaps to the right on open"). The finger
    /// position (cumulative `translation.width`) at the instant this gesture
    /// LATCHED as the drawer driver. The card's offset tracks `dx - dragAnchor`,
    /// not raw `dx`, so the very first driven frame is offset 0 and the card
    /// starts from where the finger is — not from touch-down. Without it, the
    /// pre-latch travel (the `minimumDistance` dead-zone + the dominance-
    /// classification distance, ~12–30pt) was applied as a single step the
    /// instant we took over: the visible "snap to the right" on open (and its
    /// mirror jump on close). Reset to 0 on `onEnded`.
    @State private var dragAnchor: CGFloat = 0

    /// Fraction of the screen width the chat card is pushed by when open (≈78%,
    /// observed reference). The drawer beneath occupies this leading band.
    private let widthFraction: CGFloat = 0.78
    /// Fraction of the screen width, measured from the leading edge, within which
    /// a rightward drag may START an open swipe. ABH-79 Level 02G: expanded to 1.0
    /// (the full chat surface) so a swipe anywhere opens the drawer — the prior 50%
    /// zone was the BUG-2 fix; horizontal-dominance gating is what keeps vertical
    /// scrolls and horizontal sub-scrollers (code blocks) safe regardless of where
    /// the drag begins. The horizontal sub-scroller exception is enforced by the
    /// `simultaneousGesture` path: a `ScrollView(.horizontal)` wins if it first
    /// establishes its own recognizer before this gesture classifies as dominant.
    private let openZoneFraction: CGFloat = 1.0
    /// Horizontal-dominance ratio: a drag only begins driving the drawer once
    /// `abs(dx) > abs(dy) * dominanceRatio` (and, for opening, `dx > 0`). Below
    /// this the drawer does not move, so vertical scrolls win naturally.
    private let dominanceRatio: CGFloat = 1.2
    /// Corner radius applied to the displaced chat card (observed ≈28).
    private let cardCornerRadius: CGFloat = 28
    /// Drawer parallax depth (R42): the revealed drawer glides in at this fraction
    /// of the card's travel (Telegram/ChatGPT/Claude-iOS ratio = 0.30), so the
    /// reveal reads with depth instead of a static occlusion. 0 = static (the old
    /// behavior). Cheap now that the drawer is geometry-grouped.
    private let parallaxFraction: CGFloat = 0.30

    var body: some View {
        GeometryReader { proxy in
            // The chat card travels from x=0 (closed) to +drawerWidth (open).
            let drawerWidth = proxy.size.width * widthFraction
            let offset = currentOffset(drawerWidth: drawerWidth)
            let openProgress = max(0, min(1, offset / drawerWidth)) // 0 closed, 1 open
            // STRIKE P0: capture the REAL safe-area insets HERE, before the ZStack
            // ignores them. The whole card stack runs full-bleed
            // (`.ignoresSafeArea()` on the ZStack) so the transcript scroll
            // container can finally reach the physical top/bottom edges — the
            // pixel-proven blocker was this `GeometryReader`'s default
            // safe-area-inset coordinate space, which trapped the ScrollView's own
            // `.ignoresSafeArea` (shapes escaped it; the scroll container did not).
            // The captured `safeAreaInsets.top` is threaded into ChatView so the
            // floating header still clears the status bar without re-insetting the
            // canvas.
            let safeTop = proxy.safeAreaInsets.top

            ZStack(alignment: .leading) {
                // The drawer sits on the canvas beneath the chat card. It owns
                // the status-bar area when the card is pushed aside (it fills the
                // whole surface; the card simply rides above it).
                DrawerView(onNavigate: close, onOpenSettings: openSettings)
                    .frame(width: drawerWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .background(themeStore.current.listBg.ignoresSafeArea())
                    // PARALLAX (R42): the drawer glides in from the left as the card
                    // slides right, travelling at `parallaxFraction` (30%) of the
                    // card's travel — the depth cue the reference apps (ChatGPT /
                    // Claude-iOS / Telegram) all use, vs the old dead-static reveal.
                    // At rest (openProgress 0) it sits −parallaxFraction·drawerWidth
                    // to the left (hidden behind the card anyway); fully open it rests
                    // at 0. `.geometryGroup()` flattens the drawer so the offset moves
                    // it as ONE layer — its List rows are never re-laid-out per frame.
                    .offset(x: -drawerWidth * parallaxFraction * (1 - openProgress))
                    .geometryGroup()
                    .accessibilityHidden(!drawer.isOpen)

                // Chat is home — the full surface as a card riding above the
                // drawer. NO scrim, NO opacity dim: it stays full-brightness and
                // reads as a card on the same plane. Displaced → rounded + a soft
                // shadow so it lifts off the drawer beneath (Amendment D).
                //
                // The card surface (`theme.bg`) is painted by a RoundedRectangle
                // SHAPE that ignores the safe areas — this is the P0 full-bleed
                // fix. Previously the card's only opaque fill was ChatView's
                // transcript background, which respects the safe areas, so the
                // drawer's `listBg` bled through the top/bottom bands at rest. The
                // shape carries the rounding + shadow itself (radius 0 at rest so it
                // reads as an edge-to-edge rectangle; ~28 during displacement). The
                // CONTENT (`chatStack`) is clipped separately and keeps its own
                // safe-area insets, so the composer still sits above the home
                // indicator and the transcript still clears the status bar.
                //
                // SMOOTHNESS R39 (Defect 1): the radius is a CONTINUOUS function of
                // `openProgress` (0 → cardCornerRadius), not a `openProgress > 0`
                // boolean jump. The boolean flipped 0→28 in a single frame at the
                // very start of the drag, snapping the clip shape (and forcing a
                // discrete relayout of the clipped content) — one of the "snapping
                // from the inside" sources. A linear ramp tracks the finger so the
                // corners round in lockstep with the slide, no discrete jump.
                chatCardSurface(cornerRadius: cardCornerRadius * openProgress,
                                openProgress: openProgress,
                                safeTop: safeTop)
                    // While open, a tap anywhere on the displaced card closes the
                    // drawer (the card has no scrim, so this is the tap-to-close
                    // affordance). The overlay is applied BEFORE the offset so its
                    // hit region rides with the card and stays confined to the
                    // card's own (full-width) bounds — it must never bleed left
                    // over the revealed drawer, or it would swallow taps on the
                    // drawer's avatar / rows. Inert when closed so chat taps pass
                    // through.
                    .overlay {
                        if drawer.isOpen {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { close() }
                                .accessibilityHidden(true)
                        }
                    }
                    .offset(x: offset)
                    // SMOOTHNESS R41 — there is NO modifier-level settle animation.
                    // A `.animation(.spring(...), value: drawer.isOpen)` here always
                    // started the settle from ZERO initial velocity, so a flick (card
                    // moving fast at release) hit a velocity discontinuity at the
                    // drag→spring handoff = the visible "snap to end position." It
                    // also could not animate the failed-threshold snap-back at all
                    // (isOpen unchanged ⇒ modifier silent ⇒ single-frame teleport).
                    //
                    // The settle is now driven EXPLICITLY, in one place each:
                    //  • GESTURE release → `onEnded` wraps the offset's state change
                    //    (`dragTranslation = nil` + the RAW `isOpen` flip) in ONE
                    //    `withAnimation(velocity-matched interpolatingSpring)`, so the
                    //    card continues from the finger's velocity (commit AND
                    //    snap-back), no discontinuity.
                    //  • PROGRAMMATIC open/close/toggle → animated inside DrawerState
                    //    with the SAME spring SHAPE at zero velocity (identical feel;
                    //    button starts from rest so zero velocity is correct there).
                    // Both wrap the STATE mutation (not just `.offset`), so the body
                    // re-evaluates and the `openProgress`-derived corner radius +
                    // shadow ride the SAME transaction as the offset — corners and
                    // shadow stay locked to the slide, never popping.
                    //
                    // The interactive drag still carries NO animation: `offset` tracks
                    // `dragTranslation` 1:1 (see `currentOffset`), so the card follows
                    // the finger exactly until release.
                    // Focus-trap PRESERVED (Amendment E): the displaced chat card
                    // is hidden from assistive tech while the drawer is open.
                    .accessibilityHidden(drawer.isOpen)
            }
            // STRIKE P0: the card stack ignores the CONTAINER safe area (status
            // bar + home indicator) so the transcript scroll container reaches the
            // physical edges. Scope = `.container` ONLY — NOT `.keyboard`: a blanket
            // `.ignoresSafeArea()` swallowed the keyboard region too, so the
            // composer never rose when the keyboard opened (device-confirmed bug).
            // Keeping `.keyboard` live lets SwiftUI push the floating composer up
            // with the keyboard. Chrome insets are reapplied explicitly from the
            // captured `safeTop` (floating header) / `controlBottomBaseline`
            // (composer), so nothing collides with the status bar or home indicator.
            .ignoresSafeArea(.container, edges: .all)
            .contentShape(Rectangle())
            // simultaneousGesture (not .gesture) so the transcript's vertical
            // scroll and any horizontal sub-scrollers (code blocks, attachment
            // strip) keep receiving the drag until THIS gesture establishes
            // horizontal dominance and starts driving the drawer (BUG 2).
            .simultaneousGesture(dragGesture(drawerWidth: drawerWidth, screenWidth: proxy.size.width))
        }
        // Re-install the resolved palette + brand tint at this root. PRESERVED.
        .hermesThemed(themeStore)
        .sheet(isPresented: $showingSettings) { settingsSheet }
        // Dismiss the composer keyboard whenever the drawer OPENS, from ANY
        // trigger — edge-swipe completion, the toolbar drawer button, ⌘F, or the
        // empty-state "Sessions" button — since they all funnel through
        // `drawer.isOpen`. Without this the keyboard lingered over the revealed
        // drawer (user-reported: swipe-to-open-drawer left it up). The composer
        // owns its own `@FocusState`, so the shell has no direct handle on it;
        // resigning first responder app-wide is the single root-cause chokepoint
        // and fires exactly when the drawer commits open (not mid-drag, so a drag
        // that never crosses the open threshold does not steal focus).
        .onChange(of: drawer.isOpen) { _, isOpen in
            guard isOpen else { return }
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil)
        }
    }

    private func openSettings() {
        showingSettings = true
    }

    /// Presents the Settings surface from the compact layout root. `SettingsView`
    /// still owns its internal `NavigationStack` and dismisses via its toolbar; the
    /// compact shell supplies only the stable presentation state and palette bridge.
    private var settingsSheet: some View {
        SettingsView(
            connectionStore: connection,
            sessionStore: sessions,
            appLock: appLock
        )
        .presentationDragIndicator(.hidden)
        .hermesThemed(themeStore)
    }

    // MARK: Chat stack

    /// ``ChatView`` hosted DIRECTLY in the card ZStack — NO NavigationStack
    /// wrapper (STRIKE P0 fix). The prior I1 arrangement wrapped ChatView in a
    /// `NavigationStack` purely to host the chat's system `.toolbar`; that stack
    /// reserved a bar/safe-area content-inset region the transcript could never
    /// reclaim (pixel-proven: the transcript stayed inset top+bottom DESPITE
    /// `.ignoresSafeArea`). The chat does NOT need a stack for push navigation on
    /// compact — every push (file browser drill-in, file viewer) happens inside
    /// its OWN sheet-local `NavigationStack` (see `ComposerView.showFileBrowser`).
    /// So we drop the wrapper and let ChatView draw its chrome as the
    /// `compactFloatingHeader` overlay (`compactStandaloneChrome: true`). The
    /// scroll surface is now the direct child of the card ZStack, and its
    /// `.ignoresSafeArea(.all, edges:[.top,.bottom])` reaches the physical edges.
    /// The status banner (B1) is still pinned via a top safe-area inset.
    private func chatStack(safeTop: CGFloat) -> some View {
        // Mirror SplitLayout's detail gate (R1 #16/#96): with no active session
        // and no draft (delete of the open session, bare-root deep link,
        // archive-of-last), ChatView's empty-transcript state is a permanent
        // "Loading conversation…" spinner over a dead composer. Render a
        // recoverable placeholder instead. The placeholder DOES still want a
        // NavigationStack for its own title/chrome, so it keeps a minimal wrapper;
        // the live chat path is the stack-free one that matters for the fix.
        Group {
            if sessions.activeStoredId != nil || sessions.isDraft {
                ChatView(
                    onSpeak: speakHandler(speechPlayer: speechPlayer, connection: connection),
                    onToggleDrawer: { drawer.toggle() },
                    onNewChat: { sessions.startDraft() },
                    isDraft: sessions.isDraft,
                    // Feed the running-model source so the composer chip can render
                    // (F0 / Amendment B). Resolved by ConnectionStore on connect +
                    // after switches; nil keeps the chip hidden.
                    modelName: connection.activeModelName,
                    // STRIKE P0: stack-free compact hosting — chat draws its own
                    // floating glass header instead of a system toolbar. The card
                    // stack now ignores the safe area (so the transcript bleeds to
                    // the edges), which zeroes the safe area for descendants, so the
                    // real top inset is threaded in explicitly for the header.
                    compactStandaloneChrome: true,
                    compactTopInset: safeTop
                )
                .scrollDisabled(drawerScrollLocked)
                // STRIKE P0: NO external `.safeAreaInset(.top)` here. A top
                // safe-area inset re-establishes a top safe-area region on
                // ChatView that DEFEATS the transcript's
                // `.ignoresSafeArea(.all, edges:[.top])` (pixel-proven: the
                // transcript stayed yellow/card-coloured in the status-bar band
                // even with the NavigationStack gone). The connection banner is
                // instead rendered INSIDE ChatView's `compactFloatingHeader`
                // overlay (under the pills), so the transcript scroll surface keeps
                // a clean, uninsetted full-bleed top edge.
            } else {
                NavigationStack {
                    ContentUnavailableView {
                        Label("No conversation", systemImage: "bubble.left.and.text.bubble.right")
                    } description: {
                        Text("Start a new chat or pick a session from the drawer.")
                    } actions: {
                        Button("New Chat") { sessions.startDraft() }
                            .buttonStyle(.borderedProminent)
                        Button("Sessions") { drawer.toggle() }
                    }
                }
            }
        }
    }

    // MARK: Chat card surface (P0 full-bleed fix)

    /// The chat card: a full-bleed themed `theme.bg` surface with the content
    /// (`chatStack`) layered on top, both rounded by the SAME corner radius so the
    /// card reads as a single rounded surface during displacement.
    ///
    /// The fix for the P0 regression lives here. The surface is a
    /// `RoundedRectangle` shape filled with `theme.bg` that **ignores the safe
    /// areas**, so the themed surface paints edge-to-edge through the status-bar
    /// and home-indicator bands — at rest the drawer beneath is fully hidden.
    /// (Previously the card's only opaque fill was ChatView's transcript
    /// background, which respects the safe areas, leaving the drawer's `listBg`
    /// visible in both bands.)
    ///
    /// The shape carries the corner radius + the lift shadow itself: radius 0 at
    /// rest (a clean edge-to-edge rectangle), ~28 during displacement (a rounded
    /// card).
    ///
    /// STRIKE P0: the transcript scroll surface inside ChatView ignores the
    /// top/bottom safe area to bleed to the physical edges (the parent ZStack also
    /// `.ignoresSafeArea()`, so the scroll container escapes the GeometryReader's
    /// inset space). The `compactFloatingHeader` re-asserts the status-bar
    /// clearance using the explicit `safeTop` threaded in here (the ambient safe
    /// area is now zero), and the composer clears the home indicator via
    /// `controlBottomBaseline`. The card SHAPE fills edge-to-edge
    /// (`.ignoresSafeArea()`) so there is never a card/drawer band in either
    /// safe-area region at rest. The clip uses the same rounded shape so the
    /// content reads as a single rounded card during displacement.
    @ViewBuilder
    private func chatCardSurface(cornerRadius: CGFloat, openProgress: CGFloat, safeTop: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape
                .fill(themeStore.current.bg)
                .ignoresSafeArea()
                .shadow(color: .black.opacity(0.18 * openProgress),
                        radius: 18, x: -6, y: 0)
            chatStack(safeTop: safeTop)
                .clipShape(shape)
                // R42 — DETACHED-TRANSCRIPT FIX. Flatten the chat content into ONE
                // geometry unit so it rides the card's `.offset(x:)` RIGIDLY. Without
                // this, the transcript's interior layout resolves independently of the
                // card during the slide (and, since build 44, the ambient
                // `withAnimation(settle)` transaction reaches the transcript, which
                // nulls animation via `.transaction{ $0.animation = nil }` and so
                // SNAPS relative to the springing card) — the "transcript moving
                // independently of the chat viewer" report. geometryGroup() (iOS 16+,
                // our floor is 17) makes the content a single rigid passenger of the
                // offset WITHOUT rasterizing it (unlike drawingGroup, so live
                // streaming text stays crisp) and preserves build-44's velocity
                // hand-off (offset/radius/shadow still spring on the card).
                .geometryGroup()
        }
    }

    // MARK: Offset math

    /// Resolve the chat card's current x-offset. Fully closed = 0, fully open =
    /// `+drawerWidth` (the card pushed right to reveal the drawer). A live drag
    /// interpolates between the two, clamped to `0...drawerWidth`.
    private func currentOffset(drawerWidth: CGFloat) -> CGFloat {
        let base: CGFloat = drawer.isOpen ? drawerWidth : 0
        guard let translation = dragTranslation else { return base }
        return min(drawerWidth, max(0, base + translation))
    }

    // MARK: Gesture

    /// One drag gesture handling both directions, gated on horizontal dominance
    /// (BUG 2 / locked design):
    /// - When closed, a rightward drag STARTING within the leading open zone
    ///   (currently the full chat width) opens it — but only once the drag is
    ///   horizontally dominant (`abs(dx) > abs(dy) * dominanceRatio` AND `dx > 0`)
    ///   and UIKit text editing has not claimed the touch. Before dominance is
    ///   established the drawer does NOT move, so vertical scrolls and horizontal
    ///   sub-scrollers (code blocks, attachment strip) win naturally (this gesture
    ///   is installed via `simultaneousGesture`).
    /// - When open, a (horizontally-dominant) leftward drag anywhere on the
    ///   displaced card closes it.
    /// Release commits to open/closed by midpoint crossing (or a fast flick,
    /// velocity-aware via `predictedEndTranslation`).
    private func dragGesture(drawerWidth: CGFloat, screenWidth: CGFloat) -> some Gesture {
        let openZone = screenWidth * openZoneFraction
        return DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                let dx = value.translation.width

                // Resolve (and latch) horizontal dominance once per gesture.
                if horizontalDominant == nil {
                    let resolved = DrawerGestureArbitration.resolveHorizontalDominance(
                        current: horizontalDominant,
                        isDrawerOpen: drawer.isOpen,
                        translation: value.translation,
                        startLocation: value.startLocation,
                        openZone: openZone,
                        dominanceRatio: dominanceRatio,
                        textInput: DrawerTextInputLocator.currentSnapshot()
                    )
                    guard let resolved else { return }
                    horizontalDominant = resolved
                    drawerScrollLocked = DrawerGestureArbitration.shouldLockTranscriptScroll(
                        horizontalDominant: resolved)
                    guard resolved else { return }

                    // Just latched: anchor here so the card tracks from the finger's
                    // CURRENT position (offset 0 this frame), not from touch-down —
                    // kills the pre-latch dead-zone step ("snaps to the right").
                    dragAnchor = dx
                }
                guard horizontalDominant == true else { return }

                // Displacement measured from the anchor: the card is glued to the
                // finger from the moment we took over, with no opening step.
                let eff = dx - dragAnchor
                if drawer.isOpen {
                    // Track leftward (closing) drags from the displaced card.
                    dragTranslation = min(0, eff)
                } else {
                    dragTranslation = max(0, eff)
                }
            }
            .onEnded { value in
                let anchor = dragAnchor
                // Universal latch/anchor reset on EVERY exit path. Registered BEFORE
                // the guard so it can never leak and pre-latch the next gesture from
                // touch-down. `dragTranslation` is DELIBERATELY excluded here:
                // clearing it outside a transaction would teleport the offset
                // un-animated (a last-writer-wins beats any withAnimation that has
                // already returned). It is cleared exactly once, INSIDE the settle
                // transaction, on each real path below.
                defer {
                    horizontalDominant = nil
                    drawerScrollLocked = false
                    dragAnchor = 0
                }
                // A drag this gesture never drove still animates its (zero) drag
                // contribution away, so there is never a raw final-frame jump.
                guard horizontalDominant == true else {
                    withAnimation(DrawerState.standardSpring) { dragTranslation = nil }
                    return
                }

                // Anchor-corrected displacement for the COMMIT decision (unchanged
                // thresholds). The anchor removes the pre-latch dead-zone so it never
                // counts toward the 30%/50% commit fractions.
                let dragged = value.translation.width - anchor
                let predicted = value.predictedEndTranslation.width - anchor

                // Committed target. A FAILED threshold settles BACK to the current
                // state — the case the old modifier left UN-animated (it keyed on a
                // `drawer.isOpen` change that never happened).
                let wasOpen = drawer.isOpen
                let commitOpen: Bool
                if wasOpen {
                    commitOpen = !(dragged < -drawerWidth * 0.3 || predicted < -drawerWidth * 0.5)
                } else {
                    commitOpen = (dragged > drawerWidth * 0.3 || predicted > drawerWidth * 0.5)
                }

                // SMOOTHNESS R41 — velocity hand-off. The card's offset at release and
                // the SIGNED travel still to go to the committed target, both in
                // POINTS. `currentOffset` reads the live (still-unmutated) `isOpen` +
                // `dragTranslation`, so it is the true release position.
                let releaseOffset = currentOffset(drawerWidth: drawerWidth)
                let target: CGFloat = commitOpen ? drawerWidth : 0
                let remaining = target - releaseOffset           // +toward open, −toward closed

                // Release velocity in pt/s (`DragGesture.Value.velocity`; on this SDK
                // it is 4·(predictedEndTranslation − translation), so the anchor
                // cancels and no anchor term belongs on it). Normalize to the spring's
                // fraction-of-remaining space: (pt/s) ÷ (pt) = 1/s. SIGNED on purpose —
                // positive when the finger moves TOWARD the committed target (carry the
                // momentum through), negative when it moves away (a fast-but-short
                // flick is sprung back, fighting the flick). Guard a release essentially
                // AT the target (no travel ⇒ no velocity) against NaN/∞, and clamp so a
                // near-target hard flick can't inject a violent over-fast settle.
                let v0: Double = abs(remaining) < 0.5
                    ? 0
                    : max(-30, min(30, Double(value.velocity.width / remaining)))
                let settle = Animation.interpolatingSpring(
                    Spring(response: 0.40, dampingRatio: 0.86), initialVelocity: v0)

                // ONE transaction: flip `isOpen` (RAW — no nested DrawerState spring)
                // and drop the drag contribution together, so the offset (and the
                // `openProgress`-derived corner radius + shadow, which re-evaluate with
                // it) spring CONTINUOUSLY from the finger's last position to the target.
                // Covers BOTH commit and snap-back (commitOpen == wasOpen).
                withAnimation(settle) {
                    drawer.setOpenRaw(commitOpen)
                    dragTranslation = nil
                }
            }
    }

    // PROGRAMMATIC drawer control (animated by DrawerState's standard spring).
    // `close` is wired into `DrawerView(onNavigate: close)` above → the
    // reveal-on-paint close fires through here. The GESTURE path does NOT use
    // these — it flips `isOpen` via `drawer.setOpenRaw(_:)` inside its own
    // velocity spring (see `onEnded`) to avoid nesting two transactions on one flip.
    private func open() { drawer.open() }
    private func close() { drawer.close() }
}

// MARK: - Speak wiring

/// Builds the `onSpeak` closure passed into `ChatView`: synthesize an assistant
/// message via the E1 `SpeechPlayer`, guarding on a live REST client. Returns
/// `nil` (Speak action hidden) when the connection isn't configured. PRESERVED.
@MainActor
private func speakHandler(
    speechPlayer: SpeechPlayer,
    connection: ConnectionStore
) -> ((ChatMessage) -> Void)? {
    guard connection.rest != nil else { return nil }
    return { message in
        guard let rest = connection.rest else { return }
        Task { await speechPlayer.speak(text: message.text, messageId: message.id, rest: rest) }
    }
}
