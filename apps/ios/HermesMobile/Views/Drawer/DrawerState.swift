import SwiftUI

/// Drives the compact-width slide-over drawer (ChatGPT-style). A tiny piece of
/// shared, injectable state so the drawer's open/closed status can be toggled
/// from anywhere on the chat surface — most importantly ``ChatView``'s leading
/// toolbar button (B2), which has no other handle on the shell.
///
/// Owned by ``RootView``'s compact layout and injected into the environment
/// alongside the stores. `@Observable`/`@MainActor`, no back-references — it
/// mirrors the ``AppLock`` / ``ThemeStore`` shape: built by the view that hosts
/// it, never torn down for the app's lifetime.
///
/// On regular width (iPad) the drawer is a permanent `NavigationSplitView`
/// sidebar, so this state is inert there; it only governs the compact overlay.
@MainActor
@Observable
final class DrawerState {
    /// Whether the slide-over drawer is currently open. ``RootView`` animates
    /// the offset off this; ``ChatView``'s drawer button toggles it.
    var isOpen: Bool = false

    init() {}

    /// Open the drawer (used by edge-swipe completion and the toolbar button).
    func open() { isOpen = true }

    /// Close the drawer (scrim tap, row selection, new-chat).
    func close() { isOpen = false }

    /// Flip the drawer — the toolbar button's primary action.
    func toggle() { isOpen.toggle() }
}
