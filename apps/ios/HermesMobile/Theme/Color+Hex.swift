import SwiftUI

// MARK: - Hex color construction

extension Color {
    /// Build a `Color` from a `#RRGGBB` or `#RRGGBBAA` hex string.
    ///
    /// The theme presets are transcribed verbatim from the desktop palette as
    /// literal hex strings, so every desktop `color-mix()` is pre-resolved to a
    /// concrete value at authoring time — there is no runtime mixing. A leading
    /// `#` is optional; whitespace is tolerated. An unparseable string falls back
    /// to opaque magenta so a typo is loud in a preview rather than silently
    /// rendering "clear".
    ///
    /// Colors are created in the `.sRGB` space (matching the desktop CSS `srgb`
    /// mixing space) so dark themes do not get a subtly different cast than their
    /// web counterparts.
    init(hex: String) {
        let cleaned = hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var value: UInt64 = 0
        guard Scanner(string: cleaned).scanHexInt64(&value) else {
            self = Color(.sRGB, red: 1, green: 0, blue: 1, opacity: 1)
            return
        }

        let r, g, b, a: Double
        switch cleaned.count {
        case 6: // RRGGBB
            r = Double((value & 0xFF0000) >> 16) / 255
            g = Double((value & 0x00FF00) >> 8) / 255
            b = Double(value & 0x0000FF) / 255
            a = 1
        case 8: // RRGGBBAA
            r = Double((value & 0xFF00_0000) >> 24) / 255
            g = Double((value & 0x00FF_0000) >> 16) / 255
            b = Double((value & 0x0000_FF00) >> 8) / 255
            a = Double(value & 0x0000_00FF) / 255
        default:
            self = Color(.sRGB, red: 1, green: 0, blue: 1, opacity: 1)
            return
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: - Relative luminance

extension Color {
    /// Approximate relative luminance (WCAG, sRGB) in `0...1`.
    ///
    /// Used to derive an on-`midground` foreground at runtime (light text over a
    /// dark brand accent, dark text over a light one) without storing an extra
    /// token. The sRGB components are extracted via `UIColor`/`NSColor`; if that
    /// resolution fails (e.g. a dynamic catalog color) the function returns `0.5`
    /// so callers fall back to a neutral choice rather than crashing.
    func luminance() -> Double {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0.5 }
        #elseif canImport(AppKit)
        guard let resolved = NSColor(self).usingColorSpace(.sRGB) else { return 0.5 }
        let r = resolved.redComponent, g = resolved.greenComponent, b = resolved.blueComponent
        #else
        return 0.5
        #endif

        func linearize(_ c: CGFloat) -> Double {
            let v = Double(c)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)
    }

    /// A foreground that reads on top of `self` (used for on-`midground` glyphs):
    /// near-white over a dark accent, near-black over a light one.
    var contrastingForeground: Color {
        luminance() > 0.55 ? Color(hex: "#101014") : Color(hex: "#FCFCFC")
    }
}
