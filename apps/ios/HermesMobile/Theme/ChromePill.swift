import SwiftUI

// MARK: - Glass chrome (UI Batch H — H3)
//
// Principle: GLASS FOR CHROME, THEMES FOR CONTENT. On iOS 26+ the floating
// chrome layer gets the system Liquid Glass treatment exactly where the
// reference Claude app has it (the floating pills + the drawer's New-chat
// capsule). Everywhere else — and on every OS below iOS 26 — today's solid
// theme fills stay, preserving the six-theme identity (Batch A G2 rationale).
// Content surfaces (transcript, composer card, drawer body, sheets) are NEVER
// glassed.
//
// API provenance (verified against the installed iPhoneSimulator 26.5 SDK,
// SwiftUICore.swiftinterface, by typechecking a scratch file with an iOS 17
// deployment target):
//
//   @available(iOS 26.0, *) @available(visionOS, unavailable)
//   func glassEffect(_ glass: Glass = .regular,
//                    in shape: some Shape = DefaultGlassEffectShape()) -> some View
//
//   struct Glass { static var regular/clear/identity;
//                  func tint(Color?) -> Glass; func interactive(Bool = true) -> Glass }
//
// We pass a concrete shape (Capsule / Circle) so the glass clips to the pill
// silhouette, and `.interactive()` so the glass reacts to touch like the system
// chrome does. We do NOT tint the glass — the brand identity lives in the glyph
// foreground (`theme.fg`), keeping the glass neutral and legible over arbitrary
// scrolled content (busy light or dark transcript) the way the reference app
// floats neutral glass over content.

/// Shared floating-chrome background. On iOS 26+ it renders a system Liquid
/// Glass effect clipped to `shape`; below iOS 26 (and on visionOS, where glass
/// is unavailable) it falls back to the current solid treatment — `theme.card`
/// fill + hairline `theme.border` + a soft lift shadow — so the pills read as
/// lifted off the fading content exactly as before.
///
/// Apply at the four floating-chrome call sites ONLY (per CONTRACT-UI-H H3):
/// the hamburger pill, the trailing actions pill, the scroll-to-bottom pill,
/// and the drawer "+ New chat" capsule. No content surface uses it.
struct ChromePillBackground<S: InsettableShape>: ViewModifier {
    let theme: HermesTheme
    let shape: S

    func body(content: Content) -> some View {
        #if DEBUG
        // Round-2 conic-stroke hunt: strip glass / interactivity to attribute the
        // per-frame angular-gradient cost (see RenderCache.expNoGlass*).
        if RenderCache.expNoGlass {
            return AnyView(content.background(solidFallback))
        }
        #endif
        if #available(iOS 26.0, *) {
            // System Liquid Glass clipped to the pill silhouette. `.interactive()`
            // gives the touch-reactive shimmer the reference chrome has; we leave
            // the glass untinted so it stays neutral + legible over any content,
            // and let the glyph (`theme.fg`) carry identity. Glass adapts to the
            // active color scheme — for the forced-dark themes (midnight, ember,
            // …) the root pins `.dark` via `hermesThemed`, so the glass renders in
            // dark mode and does not fight the forced scheme.
            #if DEBUG
            let glass: Glass = RenderCache.expNoGlassInteractive ? .regular : .regular.interactive()
            return AnyView(content.glassEffect(glass, in: shape))
            #else
            return AnyView(content.glassEffect(.regular.interactive(), in: shape))
            #endif
        } else {
            // iOS 17–25 (and visionOS): the established solid chrome.
            return AnyView(content.background(solidFallback))
        }
    }

    /// The pre-glass solid pill chrome: themed card fill, hairline border, and a
    /// soft shadow. Identical to the treatment the call sites shipped with so the
    /// non-glass path is a behaviour-preserving no-op.
    private var solidFallback: some View {
        shape
            .fill(theme.card)
            .overlay(shape.strokeBorder(theme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 1)
    }
}

extension View {
    /// Apply the shared glass-or-solid floating-chrome background, clipped to
    /// `shape`. Glass on iOS 26+, the solid `theme.card` pill below it.
    ///
    /// ```swift
    /// Image(systemName: "line.3.horizontal")
    ///     .frame(width: 38, height: 38)
    ///     .chromePill(theme, in: Circle())
    /// ```
    func chromePill<S: InsettableShape>(_ theme: HermesTheme, in shape: S) -> some View {
        modifier(ChromePillBackground(theme: theme, shape: shape))
    }

    /// Convenience for the common Capsule pill.
    func chromePill(_ theme: HermesTheme) -> some View {
        chromePill(theme, in: Capsule())
    }
}
