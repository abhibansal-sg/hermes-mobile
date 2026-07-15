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

    /// The shared drawer spring SHAPE. Programmatic settles (toolbar button, ⌘F,
    /// empty-state "Sessions", reveal-on-paint close) AND the gesture-release
    /// settle (``CompactLayout``'s `onEnded`) use the SAME response/damping, so a
    /// button-open and a slow-drag-open feel identical; only a FLICK differs, by
    /// carrying a non-zero `initialVelocity` into its own `interpolatingSpring`.
    /// `dampingRatio 0.86` is near-critically-damped, so the corner-radius /
    /// shadow (pure functions of the card offset) never visibly overshoot. This
    /// reproduces the prior `.spring(response: 0.40, dampingFraction: 0.86)`
    /// exactly. (Explicit-form equivalent, if ever needed:
    /// `.interpolatingSpring(mass: 1, stiffness: 246.74, damping: 27.02)`.)
    static let standardSpring = Animation.interpolatingSpring(
        Spring(response: 0.40, dampingRatio: 0.86))

    /// Open the drawer — programmatic callers (toolbar button, empty-state
    /// "Sessions", reveal-on-paint close). Self-animates with the standard
    /// zero-velocity spring so EVERY programmatic path settles identically.
    func open() { withAnimation(Self.standardSpring) { isOpen = true } }

    /// Close the drawer (scrim tap, row selection, new-chat, reveal-on-paint).
    func close() { withAnimation(Self.standardSpring) { isOpen = false } }

    /// Flip the drawer — the toolbar button's primary action. Animates both
    /// directions with the standard spring.
    func toggle() { withAnimation(Self.standardSpring) { isOpen.toggle() } }

    /// Raw, NON-animating open/close for the GESTURE path ONLY. The gesture's
    /// `onEnded` supplies its own velocity-matched `withAnimation` and flips
    /// `isOpen` through this INSIDE that transaction — calling the animating
    /// `open()`/`close()` there would NEST a second (zero-velocity) spring that
    /// overrides the flick velocity and silently reinstates the snap.
    func setOpenRaw(_ open: Bool) { isOpen = open }
}
