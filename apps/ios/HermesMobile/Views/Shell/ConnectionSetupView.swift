import SwiftUI

/// First-run / re-auth screen shown when ``ConnectionStore/Phase`` is
/// `.needsSetup`. Collects a gateway URL and session token, probes the
/// connection via ``ConnectionStore/configure(urlString:token:)``, and surfaces
/// any failure inline. On success the phase flips to `.connected` and
/// ``RootView`` re-renders into the main UI automatically.
struct ConnectionSetupView: View {
    @Environment(ConnectionStore.self) private var connection
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.hermesTheme) private var theme

    @State private var urlString = ""
    @State private var token = ""
    @State private var errorText: String?
    @State private var isConnecting = false
    /// A Tailscale hint surfaced when a connection to a `*.ts.net` host fails;
    /// `nil` clears the banner.
    @State private var tailscaleHint: TailscaleHint?

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case url
        case token
    }

    private var canConnect: Bool {
        !urlString.trimmingCharacters(in: .whitespaces).isEmpty
            && !token.trimmingCharacters(in: .whitespaces).isEmpty
            && !isConnecting
    }

    var body: some View {
        // No inner NavigationStack (R1 #7): WelcomeView PUSHES this view via
        // its own stack's navigationDestination (the only call site), so
        // re-wrapping here rendered a nested stack — empty second nav bar and
        // a broken back button on "Enter manually".
        Form {
                Section {
                    // In-content title (O1): a strong .title2.bold anchor in `fg`,
                    // so the manual-setup form has a clear hierarchy beyond the
                    // inline nav title.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connect manually")
                            .font(.title2.bold())
                            .foregroundStyle(theme.fg)
                        Text("Enter your gateway URL and session token.")
                            .font(.subheadline)
                            .foregroundStyle(theme.mutedFg)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                }

                if let tailscaleHint {
                    Section {
                        TailscaleHintBanner(hint: tailscaleHint) {
                            self.tailscaleHint = nil
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                }

                Section {
                    TextField(
                        "Server URL",
                        text: $urlString,
                        prompt: Text(verbatim: "https://your-mac.tailnet.ts.net:9443")
                    )
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focusedField, equals: .url)
                    .onSubmit { focusedField = .token }
                    .focusRing(active: focusedField == .url, color: theme.composerRing)

                    SecureField("Session token", text: $token)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($focusedField, equals: .token)
                        .onSubmit { if canConnect { connect() } }
                        .focusRing(active: focusedField == .token, color: theme.composerRing)
                } header: {
                    Text("Gateway")
                } footer: {
                    // A1 — the help text doubles as the setup-recovery path. The
                    // `Set one up` link is ALWAYS present (not gated on a failure
                    // count), so a new self-hoster who fails to connect — or who
                    // has no gateway at all — always has the way forward in view.
                    VStack(alignment: .leading, spacing: 8) {
                        if let errorText {
                            Text(errorText)
                                .foregroundStyle(theme.destructive)
                        } else {
                            Text("On the gateway host, run \u{201C}hermes mobile-pair\u{201D} to print the server URL and token (or scan its QR from the welcome screen). \u{201C}hermes token\u{201D} prints the token alone.")
                        }
                        Link(destination: HelpLinks.setupGuide) {
                            Text("Don\u{2019}t have a gateway yet? Set one up \u{2192}")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(theme.midground)
                        }
                        .accessibilityHint("Opens the Hermes Agent setup guide in your browser")
                    }
                }

                Section {
                    Button(action: connect) {
                        HStack {
                            Spacer()
                            if isConnecting {
                                ProgressView()
                                    .tint(theme.midground.contrastingForeground)
                            } else {
                                Text("Connect")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                        .frame(minHeight: 22)
                    }
                    // The primary CTA: a filled, brand-tinted button when enabled
                    // (O1 — it must not read as a disabled gray card). The tint
                    // resolves to the active theme's brand accent.
                    .buttonStyle(.borderedProminent)
                    .tint(theme.midground)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    .disabled(!canConnect)
                    // When the spinner replaces the button label, VoiceOver would
                    // read a bare ProgressView with no context. Provide an explicit
                    // label that reflects the current state.
                    .accessibilityLabel(isConnecting ? "Connecting" : "Connect")
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.bg)
            .navigationTitle("Connect to Hermes")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { focusedField = .url }
            .hermesThemed(themeStore)
    }

    private func connect() {
        guard canConnect else { return }
        focusedField = nil
        isConnecting = true
        errorText = nil
        Task {
            let failure = await connection.configure(urlString: urlString, token: token)
            isConnecting = false
            errorText = failure
            // On failure to a tailnet host, surface the "Is Tailscale connected?"
            // hint; clear it on success or for non-tailnet hosts.
            tailscaleHint = failure == nil
                ? nil
                : TailscaleHint.make(serverURLString: urlString, failureReason: failure)
        }
    }
}

// MARK: - Focus ring

private extension View {
    /// A subtle focus ring drawn around an editable field when it holds first
    /// responder (O1). Uses `theme.composerRing` (which falls back to the brand
    /// accent), matching the composer's focus treatment. The ring is inset into
    /// the row's content so it does not collide with the Form row chrome.
    @ViewBuilder
    func focusRing(active: Bool, color: Color) -> some View {
        self
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(active ? color : Color.clear, lineWidth: 1.5)
                    .padding(.horizontal, -8)
                    .padding(.vertical, -4)
            )
            .animation(.easeInOut(duration: 0.15), value: active)
    }
}
