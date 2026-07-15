import SwiftUI

// MARK: - Theme philosophy (UI Batch I — I5)
//
// TWO RENDER MODES, ONE PALETTE. Batch I rebuilt the chrome on system
// components (toolbars, List/Form, glassEffect, scrollEdgeEffectStyle), which
// changes WHO paints the chrome — but not the palette itself. The same
// `HermesTheme` value type drives both modes:
//
//   • iOS 26+ — ACCENT-LED OVER SYSTEM MATERIALS. The system renders chrome as
//     Liquid Glass (floating toolbar pills, inset List, sheet/menu materials,
//     soft scroll-edge fades). The glass stays NEUTRAL and untinted (see
//     `ChromePill`, `DrawerBottomFade`) so it reads over any scrolled content;
//     Hermes identity is carried by `.tint(midground)` (set once in
//     `hermesThemed`) plus the content surfaces below. In this mode `midground`
//     is the PRIMARY theme carrier — it is what makes a system-chrome screen
//     still look like nous / midnight / ember / mono / cyberpunk / slate. The
//     chrome-FILL tokens (`toolbarBg`, `card`-as-chrome, `popover`-as-sheet) are
//     RETIRED FROM CHROME here: the system material owns those surfaces and the
//     tokens are simply not applied to chrome on 26.
//
//   • iOS 17–25 — FULLY PAINTED. No Liquid Glass, no system inset-List redesign,
//     no scroll-edge effect; the established solid treatment paints every chrome
//     surface from the palette. Here `toolbarBg` (= `card`), the `card` pill
//     fill, and `popover` sheet/menu backgrounds are the load-bearing fallback,
//     exactly as they shipped pre-Batch-I. This is why I5 KEEPS every token even
//     though 26 stops using some of them for chrome.
//
// PERSIST EVERYWHERE (both modes, all OS): these are never delegated to a system
// material and remain pure palette —
//   `bg` (window canvas behind the card / Lists / scroll — e.g. RootView's
//   `chatCardSurface`), `fg`/`mutedFg` (label hierarchy + `navBarTint`),
//   `userBubble`(+`userBubbleBorder`), `codeBg`, `midground` (global tint, send,
//   cursor — THE 26 carrier), the status trio (`statusOK`/`statusWarn`/
//   `statusError`), and `destructive`(+`destructiveFg`). Content (chat bubbles,
//   code blocks, the composer's inner fills) is NEVER glassed — themes own it.
//
// RETIRE-FOR-CHROME-ON-26 / PERSIST-AS-FALLBACK+CONTENT (keep the storage, drop
// the chrome application on 26): `toolbarBg`, `card` where it was a chrome FILL,
// `popover` where it was a sheet/menu FILL. They still back the 17–25 path and
// any non-chrome content use. NOTE: this struct does not change — retirement is a
// CALL-SITE decision made in I1–I4 (those modules stop applying these tokens to
// chrome on 26 and gate the fallback on `#available(iOS 26.0, *)`). I5 keeps the
// model intact so neither path loses its colors.
//
// FORCED-DARK THEMES. Five of six sets pin `.preferredColorScheme(.dark)` (via
// `forcedColorScheme`, applied in `hermesThemed`). System glass + system List
// materials read the active scheme, so pinning `.dark` makes the system chrome
// render dark to match the single-mode palette — no per-component override
// needed. `nous` alone is adaptive (light+dark pair, follows the system).
//
// REDUCE TRANSPARENCY. Honored by the SYSTEM for system materials: when the
// accessibility setting is on, glassEffect / List / sheet materials fall back to
// opaque automatically — we do NOT reimplement it. The 17–25 fallback is already
// opaque (`card`/`popover` fills), so it satisfies the setting by construction.
//
/// A fully-resolved palette: a value type of concrete SwiftUI `Color`s.
///
/// Every token is a literal color (no runtime `color-mix`), transcribed from the
/// desktop `DesktopThemeColors`. The mapping desktop-slot → iOS-token follows the
/// theme architect's table:
///
/// | desktop slot         | iOS token        | paints                                   |
/// |----------------------|------------------|------------------------------------------|
/// | background           | `bg`             | screen root behind Lists/Forms/Scroll    |
/// | foreground           | `fg`             | primary labels/titles, `navBarTint`      |
/// | card / cardForeground| `card`/`cardFg`  | form rows, bubbles, cards, `toolbarBg`   |
/// | muted / mutedForeground | `muted`/`mutedFg` | field fills, tool rows / secondary text |
/// | popover / …Foreground| `popover`/`popoverFg` | sheet & menu backgrounds            |
/// | primary / …Foreground| `primary`/`primaryFg` | filled-button bg / glyph-on-fill    |
/// | secondary / …Foreground | `secondary`/`secondaryFg` | segment & chip fills / text     |
/// | accent / …Foreground | `accent`/`accentFg` | selected-row tint in pickers          |
/// | border / input       | `border`/`input` | hairlines / editable-field outlines      |
/// | midground            | `midground`      | THE brand accent: global tint, send, cursor |
/// | composerRing         | `composerRing`   | composer outline (falls back to midground) |
/// | destructive / …Foreground | `destructive`/`destructiveFg` | delete, errors             |
/// | sidebarBackground / Border | `listBg`/`listBorder` | session-list bg / separators     |
/// | userBubble / Border  | `userBubble`/`userBubbleBorder` | user chat bubble              |
///
/// iOS-only tokens are derived at build time: `navBarTint = fg`, `toolbarBg =
/// card`, `codeBg = bg`, and the status trio (`statusOK/Warn/Error`). The
/// on-`midground` glyph color is derived from luminance at the call site via
/// `Color.contrastingForeground`, not stored.
struct HermesTheme: Equatable, Identifiable, Sendable {
    // MARK: Identity
    let name: String
    let label: String
    /// `nil` = adaptive (follows the system). A non-nil value forces the whole
    /// app — including system keyboards/menus — into that scheme so chrome
    /// matches a single-mode palette.
    let forcedColorScheme: ColorScheme?

    var id: String { name }

    // MARK: Surfaces
    let bg: Color
    let fg: Color
    let card: Color
    let cardFg: Color
    let muted: Color
    let mutedFg: Color
    let popover: Color
    let popoverFg: Color

    // MARK: Roles
    let primary: Color
    let primaryFg: Color
    let secondary: Color
    let secondaryFg: Color
    let accent: Color
    let accentFg: Color

    // MARK: Lines & fields
    let border: Color
    let input: Color

    // MARK: Brand & state
    /// THE brand accent — global `.tint`, streaming cursor, send button, active
    /// pill; replaces every `Color.hermesBronze` literal.
    let midground: Color
    let composerRing: Color
    let destructive: Color
    let destructiveFg: Color

    // MARK: Lists & bubbles
    let listBg: Color
    let listBorder: Color
    let userBubble: Color
    let userBubbleBorder: Color

    // MARK: Derived (iOS-only)
    let statusOK: Color
    let statusWarn: Color
    let statusError: Color
    let codeBg: Color
    let navBarTint: Color
    let toolbarBg: Color

    /// Designated initializer carrying the transcribed slots. The iOS-only
    /// derived tokens (`navBarTint`, `toolbarBg`, `codeBg`, status trio) default
    /// to the architect's derivation so presets only spell out what differs.
    init(
        name: String,
        label: String,
        forcedColorScheme: ColorScheme?,
        bg: Color,
        fg: Color,
        card: Color,
        cardFg: Color,
        muted: Color,
        mutedFg: Color,
        popover: Color,
        popoverFg: Color,
        primary: Color,
        primaryFg: Color,
        secondary: Color,
        secondaryFg: Color,
        accent: Color,
        accentFg: Color,
        border: Color,
        input: Color,
        midground: Color,
        composerRing: Color? = nil,
        destructive: Color,
        destructiveFg: Color,
        listBg: Color,
        listBorder: Color,
        userBubble: Color,
        userBubbleBorder: Color,
        statusOK: Color = Color(hex: "#34C759"),
        statusWarn: Color = Color(hex: "#FF9F0A"),
        statusError: Color? = nil
    ) {
        self.name = name
        self.label = label
        self.forcedColorScheme = forcedColorScheme
        self.bg = bg
        self.fg = fg
        self.card = card
        self.cardFg = cardFg
        self.muted = muted
        self.mutedFg = mutedFg
        self.popover = popover
        self.popoverFg = popoverFg
        self.primary = primary
        self.primaryFg = primaryFg
        self.secondary = secondary
        self.secondaryFg = secondaryFg
        self.accent = accent
        self.accentFg = accentFg
        self.border = border
        self.input = input
        self.midground = midground
        // composerRing falls back to midground (desktop semantics).
        self.composerRing = composerRing ?? midground
        self.destructive = destructive
        self.destructiveFg = destructiveFg
        self.listBg = listBg
        self.listBorder = listBorder
        self.userBubble = userBubble
        self.userBubbleBorder = userBubbleBorder
        // Derived iOS-only tokens.
        self.statusOK = statusOK
        self.statusWarn = statusWarn
        // statusError defaults to the theme's own destructive so the connection
        // dot matches the rest of the palette's error treatment.
        self.statusError = statusError ?? destructive
        self.codeBg = bg
        self.navBarTint = fg
        self.toolbarBg = card
    }

    /// Five-swatch preview strip for the picker: surface, brand, card, primary,
    /// accent — enough to read the palette's mood at a glance.
    var swatches: [Color] { [bg, midground, card, primary, accent] }
}

/// A theme that may carry a dark variant. `nous` ships a light+dark pair and
/// follows the system; the forced-dark presets expose only `light` (which is
/// itself a dark palette) and resolve to it in either scheme.
struct HermesThemeSet: Identifiable, Sendable {
    /// Primary (adaptive light, or the single forced palette).
    let light: HermesTheme
    /// Optional hand-tuned dark variant. Only `nous` provides one.
    let dark: HermesTheme?

    var id: String { light.name }
    var name: String { light.name }
    var label: String { light.label }
    /// `nil` when the set is adaptive (has a dark variant); otherwise the forced
    /// scheme the single palette pins to.
    var forcedColorScheme: ColorScheme? { dark == nil ? light.forcedColorScheme : nil }

    init(light: HermesTheme, dark: HermesTheme? = nil) {
        self.light = light
        self.dark = dark
    }

    /// Resolve the concrete palette for a given system scheme. Single-palette
    /// (forced) sets ignore the scheme and always return `light`.
    func resolved(for scheme: ColorScheme) -> HermesTheme {
        guard let dark else { return light }
        return scheme == .dark ? dark : light
    }
}
