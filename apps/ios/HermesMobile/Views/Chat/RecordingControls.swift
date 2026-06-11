import SwiftUI

/// The shared tap-to-record control cluster: a cancel (X) button, caller-supplied
/// middle content (a level meter and/or elapsed time), and a stop/transcribe
/// button that shows an ellipsis while the recording is being transcribed.
///
/// Both recording surfaces use this so the buttons, their sizes, and their
/// accessibility labels stay identical:
///   - the composer's ``RecordingStrip`` (tap mode) — `compact == false`, with a
///     level meter + elapsed time in the middle slot,
///   - the quick-capture sheet's recording controls — `compact == true`, with
///     just the elapsed time in the middle.
///
/// `compact` only tightens the layout (spacing) and shrinks the button glyphs;
/// the geometry of the circular buttons and all behavior are unchanged.
struct RecordingControls<Middle: View>: View {
    /// Whether a transcription is in flight — swaps the stop glyph for an ellipsis
    /// and disables the finish button.
    let isTranscribing: Bool
    /// Tighter spacing + smaller glyphs for the quick-capture footprint.
    var compact: Bool = false
    let onCancel: () -> Void
    let onStop: () -> Void
    @ViewBuilder let middle: () -> Middle

    @Environment(\.hermesTheme) private var theme

    private var glyphFont: Font {
        (compact ? Font.subheadline : Font.body).weight(.semibold)
    }

    var body: some View {
        HStack(spacing: compact ? 8 : 12) {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(glyphFont)
                    .foregroundStyle(theme.mutedFg)
                    .frame(width: 32, height: 32)
                    .background(theme.muted, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel recording")

            middle()

            Button(action: onStop) {
                Image(systemName: isTranscribing ? "ellipsis" : "checkmark")
                    .font(glyphFont)
                    .foregroundStyle(theme.midground.contrastingForeground)
                    .frame(width: 36, height: 36)
                    .background(theme.midground, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(isTranscribing)
            .accessibilityLabel("Finish and transcribe")
        }
    }
}
