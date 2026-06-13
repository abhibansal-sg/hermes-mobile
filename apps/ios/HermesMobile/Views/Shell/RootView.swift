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
    @Environment(ThemeStore.self) private var themeStore

    /// Drives the optional inspector column (the approval inbox). Starts hidden;
    /// toggled from the detail toolbar.
    @State private var showingInspector = false

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
            DrawerView()
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
            Button {
                newChat()
            } label: { EmptyView() }
            .keyboardShortcut("n", modifiers: .command)

            Button {
                searchFocusRequested = true
            } label: { EmptyView() }
            .keyboardShortcut("f", modifiers: .command)

            Button {
                interrupt()
            } label: { EmptyView() }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!chat.isStreaming)
        }
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func newChat() {
        sessions.startDraft()
    }

    private func interrupt() {
        guard chat.isStreaming else { return }
        Task { await chat.interrupt() }
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
                DrawerView(onNavigate: close)
                    .frame(width: drawerWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .background(themeStore.current.listBg.ignoresSafeArea())
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
                    // SMOOTHNESS R39 (Defect 1) — the settle spring is scoped to
                    // the CARD OFFSET ALONE, not the whole ZStack. Previously two
                    // `.animation(value:)` modifiers wrapped the entire subtree
                    // (drawer + card + transcript): on a drawer open/close EVERY
                    // animatable change inside the transcript received that spring
                    // transaction — but the transcript subtree nulls animation
                    // (`.transaction { animation = nil }`), so those interior changes
                    // SNAPPED per frame instead of riding the slide. That mismatch is
                    // the reported "transcript moving/snapping from the inside." Here
                    // the spring animates ONLY the rigid `.offset`; nothing inside the
                    // card is in the animation's scope, so the card translates as one
                    // rigid surface and the interior never re-animates.
                    //
                    // The interactive drag itself carries NO animation: `offset`
                    // tracks `dragTranslation` 1:1 (see `currentOffset`), so the card
                    // follows the finger exactly. Only the release → settle to the
                    // committed open/closed state (`drawer.isOpen`) springs. The prior
                    // `.animation(value: dragTranslation)` made a spring CHASE the
                    // finger every frame (rubber-band lag) — deleted.
                    .animation(.spring(response: 0.40, dampingFraction: 0.86), value: drawer.isOpen)
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
    /// - When closed, a rightward drag STARTING within the leading 50% of the
    ///   screen opens it — but only once the drag is horizontally dominant
    ///   (`abs(dx) > abs(dy) * dominanceRatio` AND `dx > 0`). Before dominance is
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
                let dy = value.translation.height

                // Resolve (and latch) horizontal dominance once per gesture.
                if horizontalDominant == nil {
                    // Only latch once the drag has enough magnitude to classify;
                    // wait for a clear horizontal lead before driving the drawer.
                    guard abs(dx) > abs(dy) * dominanceRatio, abs(dx) > 1 else { return }
                    // For an OPEN swipe also require the start to be in the leading
                    // zone and the motion to be rightward; otherwise this drag is
                    // not ours (let scrollers keep it).
                    if drawer.isOpen {
                        horizontalDominant = true
                    } else if value.startLocation.x <= openZone && dx > 0 {
                        horizontalDominant = true
                    } else {
                        // Not a drawer drag — mark as non-dominant so we ignore the
                        // rest of this gesture without re-evaluating each frame.
                        horizontalDominant = false
                        return
                    }
                }
                guard horizontalDominant == true else { return }

                if drawer.isOpen {
                    // Track leftward (closing) drags from the displaced card.
                    dragTranslation = min(0, dx)
                } else {
                    dragTranslation = max(0, dx)
                }
            }
            .onEnded { value in
                defer {
                    dragTranslation = nil
                    horizontalDominant = nil
                }
                // Only a drag this gesture actually drove can commit.
                guard horizontalDominant == true else { return }
                let predicted = value.predictedEndTranslation.width
                if drawer.isOpen {
                    // Close if dragged/flicked left past ~30% of the width.
                    if value.translation.width < -drawerWidth * 0.3 || predicted < -drawerWidth * 0.5 {
                        close()
                    }
                } else {
                    // Open if dragged/flicked right past ~30% of the width.
                    if value.translation.width > drawerWidth * 0.3 || predicted > drawerWidth * 0.5 {
                        open()
                    }
                }
            }
    }

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
