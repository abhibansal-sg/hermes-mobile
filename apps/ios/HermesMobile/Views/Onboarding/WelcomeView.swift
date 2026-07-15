import SwiftUI

/// First-run brand moment shown when ``ConnectionStore/Phase`` is `.needsSetup`.
///
/// Owns the `needsSetup` surface (B1 routes to it from ``RootView``). Three
/// paths off the welcome screen — one per ``ConnectionMode``:
///   - **Shared dashboard** (QR) — presents ``QRScannerView`` full-screen.
///   - **Remote URL / Local desktop** — presents ``ConnectionSetupView`` (the
///     URL+token form) in a native slide-up sheet. Local desktop defaults the
///     URL field to a LAN/loopback hint; real discovery is Increment 3.
///
/// The user first picks a mode via the segmented mode picker; the CTA below
/// it adapts to that choice. The selected mode is persisted so a relaunch
/// lands on the same mode.
struct WelcomeView: View {
    @Environment(ConnectionStore.self) private var connection
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.hermesTheme) private var theme

    /// Drives the full-screen QR scanner presentation.
    @State private var showingScanner = false

    /// Drives the slide-up manual-setup sheet.
    @State private var showingManualSetup = false

    /// The mode the user is picking. Initialized from the persisted value so
    /// relaunches land on the previously-chosen mode.
    @State private var selectedMode: ConnectionMode = .remoteURL

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

                modePicker
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)

                actionButtons
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
            .animation(.easeInOut(duration: 0.2), value: connection.reauthRequired)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.bg)
            .onAppear {
                // Sync from persisted value on every appearance.
                selectedMode = connection.connectionMode
            }
            .fullScreenCover(isPresented: $showingScanner) {
                QRScannerView()
                    .hermesThemed(themeStore)
            }
            // The manual URL+token form slides up as a native sheet with
            // medium/large detents and a drag indicator. Its own NavigationStack
            // hosts the form's inline title + a Cancel toolbar item; the theme is
            // re-installed inside the sheet because SwiftUI does not reliably
            // inherit custom environment values across presentation boundaries.
            .sheet(isPresented: $showingManualSetup) {
                NavigationStack {
                    ConnectionSetupView(initialMode: selectedMode)
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

    // MARK: - Mode picker

    /// A segmented-style picker that lets the user choose between the three
    /// connection topologies. Persists the choice immediately so the next
    /// relaunch lands on the same mode.
    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How do you want to connect?")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(theme.mutedFg)

            HStack(spacing: 8) {
                ForEach(ConnectionMode.allCases, id: \.self) { mode in
                    modeButton(mode)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func modeButton(_ mode: ConnectionMode) -> some View {
        let selected = selectedMode == mode
        return Button {
            selectedMode = mode
            connection.connectionMode = mode
        } label: {
            VStack(spacing: 4) {
                Image(systemName: mode.systemImage)
                    .font(.body)
                Text(mode.label)
                    .font(.caption.weight(.medium))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
        }
        .foregroundStyle(selected ? theme.midground.contrastingForeground : theme.fg)
        .background(
            selected ? theme.midground : theme.secondary,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.clear : theme.border, lineWidth: 1)
        )
        .accessibilityIdentifier("connectionModeButton_\(mode.rawValue)")
        // A11y: explicit label so VoiceOver reads the human-readable mode name
        // rather than the SF Symbol image name. Selection state is carried by
        // the .isSelected TRAIT alone — adding it to the label too would cause
        // VoiceOver to double-announce "selected, selected".
        .accessibilityLabel(mode.label)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
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

    /// The CTA adapts to the selected mode:
    /// - Shared dashboard → primary = scan QR, secondary = enter manually.
    /// - Remote URL / Local desktop → primary = enter URL+token form.
    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 12) {
            switch selectedMode {
            case .sharedDashboard:
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
                .accessibilityIdentifier("scanQRButton")

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
                .accessibilityIdentifier("enterManuallyButton")

            case .remoteURL, .localDesktop:
                Button {
                    showingManualSetup = true
                } label: {
                    Label(
                        selectedMode == .localDesktop
                            ? "Enter local gateway address"
                            : "Enter gateway URL",
                        systemImage: selectedMode == .localDesktop ? "desktopcomputer" : "link"
                    )
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                }
                .foregroundStyle(theme.midground.contrastingForeground)
                .background(theme.midground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityIdentifier("enterURLButton")
            }

            // A1 — onboarding for self-hosters with NO gateway yet. The button
            // above assumes a running hermes-agent gateway; a new user from the
            // public TestFlight link needs to be told what that is and how to get
            // one. Tertiary, text-only so it never competes with the primary CTAs.
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
