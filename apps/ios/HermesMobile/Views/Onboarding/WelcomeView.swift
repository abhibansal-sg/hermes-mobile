import SwiftUI

/// First-run brand moment shown when ``ConnectionStore/Phase`` is `.needsSetup`.
///
/// Owns the `needsSetup` surface (B1 routes to it from ``RootView``). Two paths
/// off the welcome screen:
///   - **Scan pairing code** (primary) — presents ``QRScannerView`` full-screen,
///     which scans `hermesapp://pair?url=…&token=…` and calls
///     `ConnectionStore.configure`. On success the phase flips to `.connected`
///     and `RootView` re-renders into the main UI.
///   - **Enter manually** (secondary) — presents the existing
///     ``ConnectionSetupView`` (the URL+token form, kept as the manual fallback)
///     in a native slide-up `.sheet` with `[.medium, .large]` detents (ABH-75),
///     wrapped in its own `NavigationStack` with a Cancel toolbar item and the
///     theme re-installed inside the sheet.
///
/// Hosts its own `NavigationStack` (it is a phase root, mirroring the old
/// `ConnectionSetupView`), re-installs the theme at the root, and pins the brand
/// accent to `theme.midground` per the contract.
struct WelcomeView: View {
    @Environment(ConnectionStore.self) private var connection
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.hermesTheme) private var theme

    /// Drives the full-screen QR scanner presentation.
    @State private var showingScanner = false

    /// Drives the slide-up manual-setup sheet (ABH-75). Replaces the prior
    /// navigation-push path off "Enter manually".
    @State private var showingManualSetup = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Re-pair banner: shown when a previously-configured device was
                // rejected for auth (its pairing was revoked). Routed here by
                // RootView with `connection.reauthRequired` set (D3 RE-PAIR FLOW).
                if connection.reauthRequired {
                    reauthBanner
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                        .transition(.opacity)
                }

                Spacer(minLength: 24)

                brandMoment

                Spacer(minLength: 24)

                actionButtons
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
            .animation(.easeInOut(duration: 0.2), value: connection.reauthRequired)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.bg)
            .fullScreenCover(isPresented: $showingScanner) {
                QRScannerView()
                    .hermesThemed(themeStore)
            }
            // ABH-75: the manual URL+token form slides up as a native sheet with
            // medium/large detents and a drag indicator, instead of a nav push.
            // Its own NavigationStack hosts the form's inline title + a Cancel
            // toolbar item; the theme is re-installed inside the sheet because
            // SwiftUI does not reliably inherit custom environment values across
            // presentation boundaries (mirrors RootView's inbox-sheet pattern).
            .sheet(isPresented: $showingManualSetup) {
                NavigationStack {
                    ConnectionSetupView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { showingManualSetup = false }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .hermesThemed(themeStore)
            }
        }
        .hermesThemed(themeStore)
    }

    // MARK: - Re-pair banner

    /// A friendly, non-alarming banner explaining that the device's pairing was
    /// revoked and the fix is to scan a new code. Uses the theme's destructive
    /// accent for the leading glyph (a quiet warning, not a full error fill) on a
    /// solid `card` surface so it reads on any palette (D3 RE-PAIR FLOW).
    private var reauthBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(theme.destructive)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Pairing revoked")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.fg)
                Text("This device's pairing was revoked. Scan a new code to reconnect.")
                    .font(.footnote)
                    .foregroundStyle(theme.mutedFg)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: - Brand moment

    private var brandMoment: some View {
        VStack(spacing: 16) {
            // Shared brand mark — same resolver/chrome as the post-connect
            // loading screen (ABH-82, ``BrandAppIcon``).
            BrandAppIcon()

            Text("Hermes Agent")
                .font(.system(.largeTitle, design: .rounded).bold())
                .foregroundStyle(theme.fg)

            Text("Your agent, anywhere.")
                .font(.body)
                .foregroundStyle(theme.mutedFg)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        // ESC-12: combined a11y element so VoiceOver reads the brand block as
        // a single unit ("Hermes Agent. Your agent, anywhere.") rather than
        // picking up the icon and label as separate focusable stops.
        .accessibilityElement(children: .combine)
    }

    // MARK: - Actions

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                showingScanner = true
            } label: {
                Label("Scan pairing code", systemImage: "qrcode.viewfinder")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
            }
            .foregroundStyle(theme.midground.contrastingForeground)
            .background(theme.midground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            // ESC-03: surface the scanner intent via an a11y hint so VoiceOver
            // users understand this opens a camera before activating.
            .accessibilityHint("Opens the camera to scan a QR code from hermes mobile-pair")

            Button {
                showingManualSetup = true
            } label: {
                Text("Enter manually")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
            }
            .foregroundStyle(theme.fg)
            .background(theme.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 1)
            )
            // ESC-03: manual-entry hint for VoiceOver users.
            .accessibilityHint("Opens a form to enter the gateway URL and token directly")

            // A1 — onboarding for self-hosters with NO gateway yet. The two
            // buttons above both assume a running hermes-agent gateway; a new
            // user from the public TestFlight link needs to be told what that is
            // and how to get one. Tertiary, text-only so it never competes with
            // the primary scan/manual CTAs.
            Link(destination: HelpLinks.setupGuide) {
                Text("New to Hermes? How to set up a gateway")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(theme.midground)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 36)
            }
            .accessibilityHint("Opens the Hermes Agent setup guide in your browser")
        }
    }
}
