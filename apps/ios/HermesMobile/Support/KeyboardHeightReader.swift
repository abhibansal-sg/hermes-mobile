import SwiftUI
import UIKit

/// Observes the software keyboard frame and reports its on-screen height into a
/// binding, DETERMINISTICALLY (SCROLL P0 — keyboard fix).
///
/// ## Why this exists
///
/// The chat transcript is a `ScrollView` that does NOT contain the focused
/// `TextField` — the composer (the responder host) is a sibling `.overlay`. So
/// SwiftUI's automatic keyboard avoidance raises the composer overlay but does
/// NOT reliably inset the transcript's scroll content for the keyboard region
/// (the avoidance only tracks the view that OWNS the first responder). The net
/// device symptom: composer rises, transcript content does not — the last
/// message hides behind the keyboard.
///
/// Rather than relying on SwiftUI inferring a cross-overlay keyboard inset, this
/// reader observes the keyboard frame directly and publishes its height so the
/// transcript can add an EXPLICIT, MEASURED bottom clearance equal to the
/// keyboard region (composed with the measured composer height). This makes the
/// transcript rise with the keyboard by construction, not by inference.
///
/// ## Mechanism
///
/// Driven by `keyboardWillShow` / `keyboardWillChangeFrame` / `keyboardWillHide`.
/// The reported height is the portion of the keyboard frame that overlaps the
/// screen (clamped at 0 when off-screen / hidden), in the global coordinate
/// space — i.e. the distance from the absolute screen bottom edge up to the top
/// of the keyboard. The transcript subtracts the home-indicator baseline it
/// already reserves so the clearance is not double-counted (see
/// `ChatView.composerClearance`).
///
/// All notifications are delivered on the main queue, so the binding mutation is
/// main-actor safe. The height animates with the keyboard because the binding
/// write happens inside SwiftUI's transaction when the host re-renders; the
/// transcript wraps consumption of the value in an `.animation` matched to the
/// keyboard curve.
struct KeyboardHeightReader: ViewModifier {
    @Binding var height: CGFloat

    func body(content: Content) -> some View {
        content
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIResponder.keyboardWillShowNotification)
            ) { note in update(from: note) }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIResponder.keyboardWillChangeFrameNotification)
            ) { note in update(from: note) }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIResponder.keyboardWillHideNotification)
            ) { _ in setHeight(0) }
    }

    private func update(from note: Notification) {
        guard
            let frameValue = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
                as? NSValue
        else { return }
        let endFrame = frameValue.cgRectValue
        // The on-screen overlap = screen height minus the keyboard's top y.
        // When the keyboard is fully off-screen (hidden) `minY` sits at/below the
        // screen bottom, so this clamps to 0. Using the screen height (not the
        // window) keeps it correct under the full-bleed layout.
        let screenHeight = UIScreen.main.bounds.height
        let overlap = max(0, screenHeight - endFrame.minY)
        setHeight(overlap)
    }

    private func setHeight(_ newValue: CGFloat) {
        guard abs(newValue - height) > 0.5 else { return }
        height = newValue
    }
}

extension View {
    /// Publish the live keyboard height into `height`. See `KeyboardHeightReader`.
    func keyboardHeight(_ height: Binding<CGFloat>) -> some View {
        modifier(KeyboardHeightReader(height: height))
    }
}
