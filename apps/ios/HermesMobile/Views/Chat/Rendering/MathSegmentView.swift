import SwiftUI

/// Native transcript math renderer for LaTeX segments found by
/// `MessageSegmenter`.
///
/// This intentionally stays self-contained: no runtime network fetches, no web
/// bridge, and no parser work outside the cached segmentation pipeline. It
/// renders common chat math idioms into Unicode math text while preserving the
/// original LaTeX for accessibility.
struct MathSegmentView: View {
    @Environment(\.hermesTheme) private var theme

    let latex: String
    let display: Bool

    var body: some View {
        Group {
            if display {
                ScrollView(.horizontal, showsIndicators: true) {
                    renderedText
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .fixedSize(horizontal: true, vertical: true)
                }
                .perfScrollIndicators()
                .background(theme.codeBg, in: RoundedRectangle(cornerRadius: 10, style: .circular))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .circular)
                        .strokeBorder(theme.border, lineWidth: 1)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                renderedText
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Math: \(latex)")
    }

    private var renderedText: some View {
        Text(Self.renderedMathText(latex))
            .font(display ? .title3 : .body)
            .fontDesign(.serif)
            .foregroundStyle(theme.fg)
    }

    static func renderedMathText(_ latex: String) -> String {
        var text = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        text = replaceFractions(in: text)
        text = replaceCommands(in: text)
        text = replaceScripts(in: text, marker: "^", map: superscript)
        text = replaceScripts(in: text, marker: "_", map: subscriptDigits)
        text = text.replacingOccurrences(of: "\\left", with: "")
        text = text.replacingOccurrences(of: "\\right", with: "")
        text = text.replacingOccurrences(of: "\\,", with: " ")
        text = text.replacingOccurrences(of: "\\;", with: " ")
        text = text.replacingOccurrences(of: "\\!", with: "")
        text = text.replacingOccurrences(of: #"\\ "#, with: " ")
        return text
    }

    private static func replaceFractions(in input: String) -> String {
        var output = input
        while let range = output.range(of: #"\\frac\{([^{}]+)\}\{([^{}]+)\}"#, options: .regularExpression) {
            let match = String(output[range])
            let body = match.dropFirst("\\frac{".count).dropLast()
            let parts = body.split(separator: "}{", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { break }
            output.replaceSubrange(range, with: "(\(parts[0]))/(\(parts[1]))")
        }
        return output
    }

    private static func replaceCommands(in input: String) -> String {
        var output = input
        for (command, replacement) in commandReplacements {
            output = output.replacingOccurrences(of: "\\\(command)", with: replacement)
        }
        return output
    }

    private static func replaceScripts(
        in input: String,
        marker: Character,
        map: [Character: Character]
    ) -> String {
        var output = ""
        var index = input.startIndex

        while index < input.endIndex {
            guard input[index] == marker else {
                output.append(input[index])
                index = input.index(after: index)
                continue
            }

            let next = input.index(after: index)
            guard next < input.endIndex else {
                output.append(marker)
                break
            }

            if input[next] == "{" {
                guard let close = input[next...].firstIndex(of: "}") else {
                    output.append(marker)
                    index = next
                    continue
                }
                output.append(contentsOf: String(input[input.index(after: next)..<close]).map { map[$0] ?? $0 })
                index = input.index(after: close)
            } else {
                output.append(map[input[next]] ?? input[next])
                index = input.index(after: next)
            }
        }

        return output
    }

    private static let superscript: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
        "n": "ⁿ", "i": "ⁱ"
    ]

    private static let subscriptDigits: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
        "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ",
        "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ",
        "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ",
        "v": "ᵥ", "x": "ₓ"
    ]

    private static let commandReplacements: [(String, String)] = [
        ("alpha", "α"), ("beta", "β"), ("gamma", "γ"), ("delta", "δ"),
        ("epsilon", "ε"), ("theta", "θ"), ("lambda", "λ"), ("mu", "μ"),
        ("pi", "π"), ("sigma", "σ"), ("phi", "φ"), ("omega", "ω"),
        ("Gamma", "Γ"), ("Delta", "Δ"), ("Theta", "Θ"), ("Lambda", "Λ"),
        ("Pi", "Π"), ("Sigma", "Σ"), ("Phi", "Φ"), ("Omega", "Ω"),
        ("times", "×"), ("cdot", "·"), ("pm", "±"), ("leq", "≤"),
        ("geq", "≥"), ("neq", "≠"), ("approx", "≈"), ("infty", "∞"),
        ("sqrt", "√"), ("sum", "∑"), ("prod", "∏"), ("int", "∫"),
        ("to", "→"), ("rightarrow", "→"), ("leftarrow", "←")
    ]
}
