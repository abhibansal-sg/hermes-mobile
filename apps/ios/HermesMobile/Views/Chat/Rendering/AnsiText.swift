import SwiftUI

/// Parses a subset of ANSI SGR (Select Graphic Rendition) escape sequences into
/// a styled `AttributedString`, so tool output and shell transcripts that carry
/// raw colour codes render as coloured monospaced text instead of `\u{1B}[..m`
/// gibberish.
///
/// Supported SGR parameters:
/// - `0`  reset all attributes
/// - `1`  bold
/// - `22` normal intensity (bold off)
/// - `30`–`37` foreground (standard)
/// - `90`–`97` foreground (bright)
/// - `39` default foreground
/// - `40`–`47` / `100`–`107` background (parsed and skipped — backgrounds are
///   intentionally not rendered, to keep transcripts on the card background)
/// - `49` default background
///
/// Unrecognised parameters are ignored. Sequences other than SGR (`...m`),
/// e.g. cursor moves, are stripped. The output font is always monospaced.
enum AnsiText {

    // MARK: - Public API

    /// If `text` contains ANSI escapes, render them; otherwise return the text
    /// unchanged (still monospaced). This is the entry point bubbles call —
    /// it is safe to pass any string.
    ///
    /// `baseColor` is the colour for text carrying no explicit SGR foreground
    /// (and after a reset). It is routed from `theme.fg` so the base tone tracks
    /// the active theme; the 16-colour ANSI palette stays system-semantic. When
    /// `nil` the run keeps the inherited foreground (system default).
    static func stripOrRender(_ text: String, baseColor: Color? = nil) -> AttributedString {
        guard text.contains("\u{1B}") else {
            var plain = AttributedString(text)
            plain.font = .system(.body, design: .monospaced)
            if let baseColor { plain.foregroundColor = baseColor }
            return plain
        }
        return render(text, baseColor: baseColor)
    }

    /// Remove all ANSI escape sequences, returning clean plain text. Useful for
    /// copy-to-clipboard so the user never copies raw control codes.
    static func strip(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        var output = String()
        output.reserveCapacity(text.count)
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == escape, index + 1 < scalars.count, scalars[index + 1] == "[" {
                // Skip CSI ... <final byte 0x40–0x7E>.
                index += 2
                while index < scalars.count, !isCSIFinalByte(scalars[index]) {
                    index += 1
                }
                if index < scalars.count { index += 1 } // consume the final byte
            } else {
                output.unicodeScalars.append(scalar)
                index += 1
            }
        }
        return output
    }

    // MARK: - Rendering

    private static let escape: Unicode.Scalar = "\u{1B}"

    private static func render(_ text: String, baseColor: Color? = nil) -> AttributedString {
        var result = AttributedString()
        var style = Style()

        let scalars = Array(text.unicodeScalars)
        var index = 0
        var runStart = 0

        func emitRun(upTo end: Int) {
            guard end > runStart else { return }
            let slice = String(String.UnicodeScalarView(scalars[runStart..<end]))
            var piece = AttributedString(slice)
            style.apply(to: &piece, baseColor: baseColor)
            result.append(piece)
        }

        while index < scalars.count {
            if scalars[index] == escape, index + 1 < scalars.count, scalars[index + 1] == "[" {
                // Flush the pending text run before changing style.
                emitRun(upTo: index)

                // Parse the CSI sequence.
                var cursor = index + 2
                var paramScalars: [Unicode.Scalar] = []
                while cursor < scalars.count, !isCSIFinalByte(scalars[cursor]) {
                    paramScalars.append(scalars[cursor])
                    cursor += 1
                }
                let finalByte: Unicode.Scalar? = cursor < scalars.count ? scalars[cursor] : nil
                // Advance past the final byte (or to end if truncated).
                index = cursor < scalars.count ? cursor + 1 : cursor
                runStart = index

                // Only SGR ("m") sequences affect style; others are dropped.
                if finalByte == "m" {
                    let params = String(String.UnicodeScalarView(paramScalars))
                    style.apply(sgr: params)
                }
            } else {
                index += 1
            }
        }

        emitRun(upTo: scalars.count)

        // Ensure monospaced even if input had no styled runs.
        if result.runs.isEmpty {
            result = AttributedString(text)
            result.font = .system(.body, design: .monospaced)
            if let baseColor { result.foregroundColor = baseColor }
        }
        return result
    }

    /// A CSI sequence ends at a byte in 0x40–0x7E (`@`…`~`).
    private static func isCSIFinalByte(_ scalar: Unicode.Scalar) -> Bool {
        (0x40...0x7E).contains(scalar.value)
    }

    // MARK: - Style state

    /// Accumulated SGR state applied to the next text run.
    private struct Style {
        var bold = false
        var foreground: Color?

        mutating func apply(sgr params: String) {
            // Empty parameter list ("\u{1B}[m") means reset.
            let codes = params.isEmpty
                ? [0]
                : params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }

            for code in codes {
                switch code {
                case 0:
                    bold = false
                    foreground = nil
                case 1:
                    bold = true
                case 22:
                    bold = false
                case 30...37:
                    foreground = Self.standard[code - 30]
                case 90...97:
                    foreground = Self.bright[code - 90]
                case 39:
                    foreground = nil
                case 40...47, 100...107, 49:
                    break // backgrounds intentionally not rendered
                default:
                    break
                }
            }
        }

        func apply(to piece: inout AttributedString, baseColor: Color? = nil) {
            piece.font = bold
                ? .system(.body, design: .monospaced).bold()
                : .system(.body, design: .monospaced)
            // Explicit SGR foreground wins; otherwise fall back to the themed
            // base colour (or leave inherited when none is supplied).
            if let foreground {
                piece.foregroundColor = foreground
            } else if let baseColor {
                piece.foregroundColor = baseColor
            }
        }

        /// Standard 30–37 foregrounds, tuned for dark+light legibility.
        static let standard: [Color] = [
            Color(uiColor: .label),                                    // black → label
            Color(uiColor: UIColor(red: 0.80, green: 0.18, blue: 0.16, alpha: 1)), // red
            Color(uiColor: UIColor(red: 0.18, green: 0.60, blue: 0.28, alpha: 1)), // green
            Color(uiColor: UIColor(red: 0.72, green: 0.55, blue: 0.05, alpha: 1)), // yellow
            Color(uiColor: UIColor(red: 0.16, green: 0.42, blue: 0.82, alpha: 1)), // blue
            Color(uiColor: UIColor(red: 0.66, green: 0.30, blue: 0.72, alpha: 1)), // magenta
            Color(uiColor: UIColor(red: 0.10, green: 0.58, blue: 0.62, alpha: 1)), // cyan
            Color(uiColor: .secondaryLabel)                           // white → secondary
        ]

        /// Bright 90–97 foregrounds.
        static let bright: [Color] = [
            Color(uiColor: .secondaryLabel),
            Color(uiColor: UIColor(red: 0.95, green: 0.36, blue: 0.34, alpha: 1)),
            Color(uiColor: UIColor(red: 0.36, green: 0.78, blue: 0.46, alpha: 1)),
            Color(uiColor: UIColor(red: 0.92, green: 0.74, blue: 0.20, alpha: 1)),
            Color(uiColor: UIColor(red: 0.36, green: 0.62, blue: 0.96, alpha: 1)),
            Color(uiColor: UIColor(red: 0.82, green: 0.48, blue: 0.90, alpha: 1)),
            Color(uiColor: UIColor(red: 0.28, green: 0.78, blue: 0.82, alpha: 1)),
            Color(uiColor: .label)
        ]
    }
}
