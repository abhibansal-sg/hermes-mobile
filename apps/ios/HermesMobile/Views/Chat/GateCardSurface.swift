import SwiftUI
import UIKit

// QA-2 R7/C1 — native-first gate cards (clarify + approval). The hand-rolled
// `theme.card` + 1pt stroke chrome that shipped (IMG_2534/2537/2539) read as a
// foreign object on the transcript: a flat dark rect with pure-black
// `.roundedBorder` text fields and bubble-identical choice buttons. These
// helpers rebuild both gate cards on the SAME system surface idiom the composer
// already uses (`ComposerCardSurface`): a real `glassEffect` on iOS 26+ and a
// behaviour-preserving solid fallback on iOS 17–25. C1 acceptance: a custom
// container is unavoidable (the dock hosts a single card above a frozen
// composer), but it MUST be indistinguishable from a native surface — system
// material, standard corner radius, system spacing.

/// A system-material card surface for the docked clarify/approval gate cards.
/// iOS 26+: `glassEffect(.regular.interactive())` clipped to the rounded rect —
/// the same primitive the composer card uses, so the gate card and the composer
/// read as one system family. iOS 17–25: `theme.card` + the soft lift shadow
/// the composer falls back to. The caller layers content + a hairline border on
/// top in both eras.
///
/// Mirrors `ComposerCardSurface` deliberately: one glass idiom across every
/// docked surface (composer, gate cards, recording strip) is the C1 contract.
struct GateCardSurface: ViewModifier {
    let theme: HermesTheme
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content
                .background(theme.card, in: shape)
                .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
        }
    }
}

extension View {
    /// Docked-gate-card system surface (R7/C1). See ``GateCardSurface``.
    func gateCardSurface(theme: HermesTheme, cornerRadius: CGFloat = 18) -> some View {
        modifier(GateCardSurface(theme: theme, cornerRadius: cornerRadius))
    }
}

// MARK: - Keyboard dismissal (R9)
//
// R9 contract: when a clarify/approval card appears in the dock, the composer's
// keyboard MUST dismiss so composer + card + keyboard never stack to consume
// the screen (IMG_2534/2537). The composer owns its own `@FocusState`
// (`ComposerView.isFocused`); the card view is a sibling in the bottom stack
// with no handle on it. The single root-cause chokepoint — already used app-wide
// for drawer open (`RootView.swift:1501-1506`) — is resigning first responder
// at the application layer. This helper centralizes that call so gate cards,
// the dock, and tests share one seam.
//
// R9 test seam: `KeyboardDismissal.resign()` is what gate cards actually
// call on appear. The default implementation does the app-wide first-responder
// resign; tests swap `resignHandler` to a spy (restored in `defer`) to assert
// the card fires it without depending on the live responder chain. The whole
// type is `@MainActor` so the static handler slot is race-free under Swift 6
// strict concurrency (a plain `() -> Void` static would be flagged as shared
// mutable state), and because `onAppear` always fires on the main actor the
// indirection adds no thread-hop.

@MainActor
enum KeyboardDismissal {
    /// The active resign implementation. Production: the real app-wide resign.
    /// Tests: a counting spy. `@MainActor` so the slot is concurrency-safe.
    nonisolated(unsafe) static var resignHandler: @MainActor () -> Void = { defaultResign() }

    /// Resign first responder app-wide. No-op when no responder is active
    /// (UIKit tolerates a missing target silently). Hops to the main queue
    /// defensively so a caller off-main still lands the resign on main.
    static func resign() { resignHandler() }

    /// The real production resign — app-wide first-responder resignation, the
    /// same chokepoint `RootView` uses on drawer open.
    private static func defaultResign() {
        DispatchQueue.main.async {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil)
        }
    }
}
