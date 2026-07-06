import SwiftMath
import SwiftUI
import UIKit

/// Native transcript math renderer for LaTeX segments found by
/// `MessageSegmenter`.
///
/// SwiftMath is bundled through SwiftPM and typesets locally; there are no
/// runtime network/CDN fetches on the transcript hot path.
struct MathSegmentView: View {
    @Environment(\.hermesTheme) private var theme

    let latex: String
    let display: Bool

    var body: some View {
        Group {
            if display {
                ScrollView(.horizontal, showsIndicators: true) {
                    formula
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
                .perfScrollIndicators()
                .background(theme.codeBg, in: RoundedRectangle(cornerRadius: 10, style: .circular))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .circular)
                        .strokeBorder(theme.border, lineWidth: 1)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                formula
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Math: \(latex)")
    }

    private var formula: some View {
        MathFormulaView(
            latex: latex,
            display: display,
            textColor: UIColor(theme.fg)
        )
        .fixedSize(horizontal: true, vertical: true)
    }
}

private struct MathFormulaView: UIViewRepresentable {
    let latex: String
    let display: Bool
    let textColor: UIColor

    func makeUIView(context: Context) -> MTMathUILabel {
        let label = MTMathUILabel()
        label.backgroundColor = .clear
        label.contentInsets = .zero
        label.displayErrorInline = true
        label.textAlignment = .left
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .vertical)
        configure(label)
        return label
    }

    func updateUIView(_ label: MTMathUILabel, context: Context) {
        configure(label)
    }

    private func configure(_ label: MTMathUILabel) {
        label.labelMode = display ? .display : .text
        label.fontSize = display ? 21 : 17
        label.textColor = textColor
        if label.latex != latex {
            label.latex = latex
        }
    }
}
