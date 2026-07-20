import SafariServices
import SwiftUI

/// SwiftUI wrapper around `SFSafariViewController` (Wave 25 link fix #1).
///
/// Presented as a `.sheet(item:)` from the chat surface's `openURL`
/// interception (`ChatView`) so tapping an `http(s)://` link in the transcript
/// — a markdown link or an autolinked bare URL — opens in-app instead of
/// backgrounding Hermes for the system Safari app. Reader mode is left at its
/// system default (off): `entersReaderIfAvailable` is intentionally not set,
/// matching Safari's own default behaviour rather than forcing reader view.
/// The sheet is dismissable via `SFSafariViewController`'s own built-in Done
/// button; no extra chrome is added here.
struct InAppSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {
        // Immutable after creation — `SFSafariViewController` has no supported
        // API to re-point an existing instance at a new URL, and callers give
        // each presented URL a fresh `Identifiable` item (see `ChatView`), so a
        // new `InAppSafariView`/controller is created per link rather than this
        // one being updated in place.
    }
}
