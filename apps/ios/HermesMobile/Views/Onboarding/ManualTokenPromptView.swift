import SwiftUI

/// Shown when a Local-desktop pairing payload arrives with `manual_token=true`
/// — the plugin-side discovery (Inc-3a) found the Desktop gateway URL but could
/// not recover the token (ephemeral port + memory-only token in stock local mode,
/// or Electron safeStorage encryption). The URL is pre-filled; the user pastes
/// the token from the Desktop app's Settings UI or from `hermes token` on the Mac.
///
/// On "Connect" the view calls ``ConnectionStore/configure(urlString:token:)``
/// with the discovered URL and the user-supplied token, then transitions to
/// `.connected` on success. On dismiss (Cancel) the pending payload is cleared
/// and no configuration change is made.
///
/// **Design decision (Inc-3b):** the prompt is a sheet presented at the `RootView`
/// level (via `DeepLinkCoordinator.pendingManualTokenPair`) so it overlays BOTH
/// the onboarding (`WelcomeView`) and the connected-shell surfaces. This matches
/// the `pendingPair` confirmation pattern already in place — a single presentation
/// site that works regardless of the current connection phase.
struct ManualTokenPromptView: View {
    /// The discovered URL pre-filled from the pairing payload.
    let discoveredURL: String

    /// Closure invoked when the user taps Cancel (no configuration change).
    let onDismiss: () -> Void

    @Environment(ConnectionStore.self) private var connection
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.hermesTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var token = ""
    @State private var errorText: String?
    @State private var isConnecting = false

    @FocusState private var tokenFieldFocused: Bool

    private var canConnect: Bool {
        !token.trimmingCharacters(in: .whitespaces).isEmpty && !isConnecting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enter Desktop token")
                            .font(.title2.bold())
                            .foregroundStyle(theme.fg)
                        Text("The gateway URL was discovered automatically. Paste the token shown in the Desktop app's Settings, or run \u{201C}hermes token\u{201D} on your Mac.")
                            .font(.subheadline)
                            .foregroundStyle(theme.mutedFg)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                }

                Section {
                    // URL is pre-filled and read-only — the user can see where
                    // they are connecting. The token is the only editable field.
                    HStack {
                        Text("Gateway")
                            .font(.subheadline)
                            .foregroundStyle(theme.mutedFg)
                        Spacer(minLength: 8)
                        Text(discoveredURL)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(theme.fg)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityIdentifier("manualTokenDiscoveredURL")
                    }
                    .listRowBackground(theme.card)

                    SecureField("Session token", text: $token,
                                prompt: Text("Paste token from Desktop app"))
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($tokenFieldFocused)
                        .onSubmit { if canConnect { connect() } }
                        .focusRing(active: tokenFieldFocused, color: theme.composerRing)
                        .accessibilityIdentifier("manualTokenField")
                } header: {
                    Text("Connection")
                } footer: {
                    if let errorText {
                        Text(errorText)
                            .foregroundStyle(theme.destructive)
                    } else {
                        Text("Your token is stored securely in the device Keychain and is never sent anywhere except the gateway you specify.")
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
                    .buttonStyle(.borderedProminent)
                    .tint(theme.midground)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    .disabled(!canConnect)
                    .accessibilityLabel(isConnecting ? "Connecting" : "Connect")
                    .accessibilityIdentifier("manualTokenConnectButton")
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.bg)
            .navigationTitle("Local desktop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onDismiss()
                        dismiss()
                    }
                    .accessibilityIdentifier("manualTokenCancelButton")
                }
            }
            .onAppear {
                // Give the token field focus immediately so the user can paste.
                tokenFieldFocused = true
                // Pin the connection mode to localDesktop so the transport uses
                // the loopback Host header (the discovered URL is a LAN address
                // or loopback, not a Tailscale Serve host).
                connection.connectionMode = .localDesktop
            }
            .hermesThemed(themeStore)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func connect() {
        guard canConnect else { return }
        tokenFieldFocused = false
        isConnecting = true
        errorText = nil
        Task {
            let failure = await connection.configure(
                urlString: discoveredURL,
                token: token
            )
            isConnecting = false
            if let failure {
                errorText = failure
            } else {
                // Success: dismiss the sheet — connection.phase flipped to
                // .hydrating/.connected and RootView transitions automatically.
                onDismiss()
                dismiss()
            }
        }
    }
}

// MARK: - Focus ring (mirrors ConnectionSetupView)

private extension View {
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
