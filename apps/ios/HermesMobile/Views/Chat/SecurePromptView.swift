import SwiftUI

/// Transient, biometric-gated prompt for a `sudo.request` / `secret.request`
/// (F4A-A2). Presented as a sheet over the chat surface when
/// ``ChatStore/pendingSecurePrompt`` is set.
///
/// SECRET HYGIENE (BINDING): the entered value lives ONLY in the `value`
/// `@State` below. It is:
///   - never written to UserDefaults / Keychain / a transcript,
///   - never logged or put in any telemetry / debug-bridge string,
///   - cleared the instant the reply is sent OR the prompt is dismissed
///     (`clearValue()` runs on every exit path, including `.onDisappear`).
/// The field is a `SecureField` (masked) with `.textContentType(.password)`.
///
/// BIOMETRIC GATE: when ``DefaultsKeys/requiresBiometricForSecrets`` is on
/// (default), a successful `evaluate(reason:)` on the injected
/// ``BiometricAuthenticating`` is required BEFORE the field can be edited AND is
/// re-checked before the reply is sent. On failure/cancel the prompt offers a
/// retry or a skip (which sends the empty-reply the gateway treats as
/// `skipped:true`); the value is never revealed without a passing gate.
struct SecurePromptView: View {
    let prompt: PendingSecurePrompt
    /// Send the value (or `nil` to skip) back through `ChatStore`.
    let onSubmit: (String?) async -> Void
    /// Dismiss without sending — equivalent to a skip (empty reply).
    let onCancel: () -> Void
    /// Injected biometric backend (the F2 ``BiometricAuthenticating`` seam). The
    /// app passes a live ``LAContextAuthenticator``; tests inject a stub.
    let authenticator: BiometricAuthenticating

    @Environment(\.hermesTheme) private var theme

    /// The ONLY place the entered secret lives. Transient; cleared on every exit.
    @State private var value: String = ""
    /// Whether the biometric gate has passed for THIS prompt (so the field can be
    /// edited / the reply sent). When the pref is off this starts true.
    @State private var unlocked: Bool
    /// True while the biometric prompt is on screen.
    @State private var authenticating = false
    /// Last gate failure message, shown inline with a retry.
    @State private var gateError: String?
    /// True while the RPC reply is in flight (disables the buttons).
    @State private var sending = false

    @FocusState private var fieldFocused: Bool

    init(
        prompt: PendingSecurePrompt,
        authenticator: BiometricAuthenticating,
        onSubmit: @escaping (String?) async -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.prompt = prompt
        self.authenticator = authenticator
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        // When the biometric pref is OFF, the field is immediately editable.
        _unlocked = State(initialValue: !DefaultsKeys.requiresBiometricForSecretsValue())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if unlocked {
                        SecureField(secureFieldLabel, text: $value)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .focused($fieldFocused)
                            .submitLabel(.send)
                            .onSubmit { Task { await submit() } }
                    } else {
                        lockedField
                    }
                } header: {
                    Text(headerTitle)
                } footer: {
                    footer
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { skip() }
                        .disabled(sending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { Task { await submit() } }
                        .disabled(!unlocked || sending)
                }
            }
            .interactiveDismissDisabled(sending)
        }
        .task {
            // Gate on appearance when required.
            if !unlocked { await runBiometricGate() }
            else { fieldFocused = true }
        }
        // BINDING: clear the value on EVERY dismissal path, including a swipe-down
        // or a programmatic dismiss. No copy of the secret survives the view.
        .onDisappear { clearValue() }
    }

    // MARK: - Locked field placeholder

    private var lockedField: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(theme.mutedFg)
                    .accessibilityHidden(true)
                Text(authenticating ? "Authenticating…" : "Locked")
                    .foregroundStyle(theme.mutedFg)
            }
            Spacer()
            if !authenticating {
                Button("Unlock") { Task { await runBiometricGate() } }
                    .buttonStyle(.bordered)
            } else {
                ProgressView()
            }
        }
    }

    // MARK: - Header / footer copy

    private var navTitle: String {
        switch prompt.kind {
        case .sudo: return "Sudo Password"
        case .secret: return "Enter Secret"
        }
    }

    private var headerTitle: String { prompt.prompt }

    private var secureFieldLabel: String {
        switch prompt.kind {
        case .sudo: return "Password"
        case .secret: return prompt.envVar ?? "Value"
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let envVar = prompt.envVar, prompt.kind == .secret {
                Text("Stored as ") + Text(envVar).font(.caption.monospaced())
            }
            if let gateError {
                Label(gateError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(theme.statusWarn)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            Text("This value is sent once and never stored on this device.")
                .foregroundStyle(theme.mutedFg)
        }
        .font(.caption)
    }

    // MARK: - Biometric gate

    private func runBiometricGate() async {
        guard !authenticating else { return }
        authenticating = true
        gateError = nil
        let reason: String
        switch prompt.kind {
        case .sudo: reason = "Authenticate to enter the sudo password"
        case .secret: reason = "Authenticate to enter the secret"
        }
        let result = await authenticator.evaluate(reason: reason)
        authenticating = false
        switch result {
        case .success:
            unlocked = true
            gateError = nil
            fieldFocused = true
        case .failure(let message):
            unlocked = false
            gateError = message
        }
    }

    // MARK: - Actions

    private func submit() async {
        guard unlocked, !sending else { return }
        // `sending` flips BEFORE the biometric await (release audit P2): the
        // old order set it after, so two rapid taps could both pass the entry
        // guard during the Face ID suspension and send the secret twice. The
        // defer keeps every exit path (gate failure included) consistent.
        sending = true
        defer { sending = false }
        // Re-check the gate immediately before sending (BINDING): the field may
        // have been unlocked a while ago.
        if DefaultsKeys.requiresBiometricForSecretsValue() {
            // A fresh, lightweight re-evaluation guards the actual send.
            let result = await authenticator.evaluate(reason: "Authenticate to send")
            if case .failure(let message) = result {
                gateError = message
                return
            }
        }
        let outgoing = value
        // Hand the value straight to the store and immediately drop our copy.
        await onSubmit(outgoing.isEmpty ? nil : outgoing)
        clearValue()
    }

    /// Skip the prompt — send the empty reply the gateway treats as a skip.
    private func skip() {
        guard !sending else { return }
        clearValue()
        onCancel()
    }

    /// Wipe the transient value. Idempotent; called on send, skip, and dismiss.
    private func clearValue() {
        value = ""
    }
}
