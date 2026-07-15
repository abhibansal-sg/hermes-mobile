import SwiftUI

/// The branded post-connect loading screen shown while ``ConnectionStore/Phase``
/// is `.hydrating` (ABH-82). A verified connection lands here for the brief
/// window between the WS coming up and the gateway state (session list + running
/// model) being pulled, so the user sees the Hermes brand moment rather than a
/// flash of an empty shell.
///
/// This is ALWAYS transient: `ConnectionStore` races the real hydration against
/// an 8s timeout fallback (`ConnectionStore.hydrationTimeout`), so this view can
/// never strand. It is purely presentational — it owns no timing and no state;
/// the phase transition is driven entirely by the store.
///
/// Reuses ``BrandAppIcon`` (the same resolver/chrome as ``WelcomeView``) so the
/// brand mark is identical across the first-run and post-connect surfaces.
struct HydrationLoadingView: View {
    @Environment(\.hermesTheme) private var theme

    var body: some View {
        VStack(spacing: 20) {
            BrandAppIcon()

            ProgressView()
                .controlSize(.regular)
                .tint(theme.midground)
                .accessibilityLabel("Loading")

            Text("Loading…")
                .font(.body)
                .foregroundStyle(theme.mutedFg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading Hermes")
    }
}
