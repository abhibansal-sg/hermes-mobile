import CoreFoundation

/// Shared layout constants consumed by more than one surface so that a single
/// change moves all affected controls together.
///
/// ## `controlBottomBaseline`
///
/// The distance from the absolute screen bottom edge (not the safe-area inset)
/// to the bottom edge of the two main floating action controls:
///
/// - The **floating composer card** in `ChatView`/`ComposerView` — applied via
///   `.padding(.bottom, …)` on the `bottomStack` overlay.
/// - The **drawer "New chat" capsule** in `DrawerView` — applied via
///   `.padding(.bottom, …)` on the `.overlay(alignment: .bottomTrailing)`.
///
/// Because both controls are rendered in full-bleed surfaces (the transcript
/// scroll view and the drawer list both extend to the absolute screen edge),
/// tying their bottom padding to one constant guarantees their bottom edges sit
/// on the same visual baseline when the drawer slides over the chat: a visitor
/// of the chat card sees the composer at exactly the same height as the New-chat
/// capsule visible behind/above the drawer.
///
/// Tune this single value to move both controls simultaneously.
enum HermesLayoutConstants {
    /// Bottom inset (pts) from the absolute screen edge shared by the floating
    /// composer card and the drawer New-chat capsule.  The transcript canvas is
    /// now genuinely full-bleed (the NavigationStack ignores the safe area at the
    /// CONTAINER level), so the composer floats over the home-indicator band; a
    /// smaller baseline pulls both controls closer to the absolute bottom edge
    /// per the user's edge-gap directive while staying clear of the home
    /// indicator. 16 pt = the "~1-2mm higher" nudge the user asked for after the
    /// 8 pt version read a touch too low.
    static let controlBottomBaseline: CGFloat = 16
}
