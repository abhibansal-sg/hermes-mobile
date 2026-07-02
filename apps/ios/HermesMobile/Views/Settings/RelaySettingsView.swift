import SwiftUI

/// Settings surface for ABH-282 relay push ENABLE.
///
/// A relay URL means relay push is enabled; an empty URL means the app keeps the
/// existing direct APNs path unchanged. The registration token is write-only:
/// the gateway only reports whether one is set and a short prefix, never the raw
/// token. The SecureField therefore accepts a replacement token, while leaving it
/// blank preserves the current saved token.
struct RelaySettingsView: View {
    @Environment(\.hermesTheme) private var theme
    @State private var store: RelayStore

    init(rest: RestClient) {
        _store = State(initialValue: RelayStore(rest: rest))
    }

    var body: some View {
        List {
            statusSection
            urlSection
            tokenSection
            pairSection
            testPushSection
            saveSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.bg)
        .navigationTitle("Relay Push")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if store.isLoading {
                ProgressView()
            }
        }
        .task { await store.load() }
        .refreshable { await store.load() }
        .alert("Relay Push", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var statusSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { store.enabled },
                set: { store.enabled = $0 }
            )) {
                Label {
                    Text("Enable Relay Push")
                        .foregroundStyle(theme.fg)
                } icon: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(theme.fg)
                }
            }
            .disabled(store.isLoading || store.isSaving)
            .listRowBackground(theme.card)
            .accessibilityIdentifier("relayPushToggle")

            LabeledContent("State") {
                Text(store.configuredSummary)
                    .foregroundStyle(theme.mutedFg)
                    .multilineTextAlignment(.trailing)
            }
            .listRowBackground(theme.card)
            .accessibilityIdentifier("relayPushState")

            LabeledContent("Push kinds") {
                Text(store.pushKindsSummary)
                    .foregroundStyle(theme.mutedFg)
                    .multilineTextAlignment(.trailing)
            }
            .listRowBackground(theme.card)
            .accessibilityIdentifier("relayPushKinds")
        } footer: {
            Text("Relay push is opt-in. Turning this off clears the relay URL and leaves the existing direct APNs path untouched.")
        }
    }

    @ViewBuilder
    private var urlSection: some View {
        Section {
            TextField("https://relay.example.com", text: Binding(
                get: { store.relayURLDraft },
                set: { store.relayURLDraft = $0 }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .textContentType(.URL)
            .disabled(!store.enabled || store.isSaving)
            .listRowBackground(theme.card)
            .accessibilityIdentifier("relayPushURLField")
        } header: {
            Text("Relay URL")
        } footer: {
            Text("Must be HTTPS. Leave Relay Push off to clear the saved URL.")
        }
    }

    @ViewBuilder
    private var tokenSection: some View {
        Section {
            SecureField("Registration token", text: Binding(
                get: { store.tokenDraft },
                set: {
                    store.tokenDraft = $0
                    if !$0.isEmpty { store.clearTokenOnSave = false }
                }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .disabled(!store.enabled || store.isSaving)
            .listRowBackground(theme.card)
            .accessibilityIdentifier("relayPushTokenField")

            LabeledContent("Saved token") {
                Text(store.tokenSummary)
                    .foregroundStyle(theme.mutedFg)
                    .multilineTextAlignment(.trailing)
            }
            .listRowBackground(theme.card)
            .accessibilityIdentifier("relayPushTokenState")

            if store.registrationTokenSet {
                Button(role: .destructive) {
                    store.tokenDraft = ""
                    store.clearTokenOnSave = true
                } label: {
                    Label("Clear saved token on save", systemImage: "trash")
                }
                .disabled(!store.enabled || store.isSaving || store.clearTokenOnSave)
                .listRowBackground(theme.card)
                .accessibilityIdentifier("relayPushClearToken")
            }
        } header: {
            Text("Registration Token")
        } footer: {
            Text("The token is never shown by the gateway. Enter a new token to replace it, leave blank to keep it, or clear it explicitly.")
        }
    }

    @ViewBuilder
    private var pairSection: some View {
        Section {
            if let pairingMessage = store.pairingMessage {
                Label(pairingMessage, systemImage: "checkmark.circle")
                    .foregroundStyle(theme.midground)
                    .listRowBackground(theme.card)
                    .accessibilityIdentifier("relayPairReady")
            }

            if let pairingSummary = store.pairingSummary {
                Text(pairingSummary)
                    .font(.footnote)
                    .foregroundStyle(theme.mutedFg)
                    .textSelection(.enabled)
                    .listRowBackground(theme.card)
                    .accessibilityIdentifier("relayPairSummary")
            }

            Button {
                Task { await store.pair() }
            } label: {
                HStack {
                    Label("Pair this device", systemImage: "link.badge.plus")
                    Spacer(minLength: 8)
                    if store.isPairing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(!store.enabled || store.isLoading || store.isSaving || store.isPairing || store.isTestingPush)
            .listRowBackground(theme.card)
            .accessibilityIdentifier("relayPairDevice")
        } header: {
            Text("Device Pairing")
        } footer: {
            Text("Uses the saved relay URL to mint a fresh pairing token for this phone. Save relay setting changes before pairing.")
        }
    }

    @ViewBuilder
    private var testPushSection: some View {
        Section {
            if let testPushMessage = store.testPushMessage {
                Text(testPushMessage)
                    .foregroundStyle(testPushMessage.hasPrefix("✅") ? theme.midground : .red)
                    .textSelection(.enabled)
                    .listRowBackground(theme.card)
                    .accessibilityIdentifier("relayTestPushResult")
            }

            Button {
                Task { await store.sendTestPush() }
            } label: {
                HStack {
                    Label("Send test push", systemImage: "paperplane")
                    Spacer(minLength: 8)
                    if store.isTestingPush {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(!store.enabled || store.isLoading || store.isSaving || store.isPairing || store.isTestingPush)
            .listRowBackground(theme.card)
            .accessibilityIdentifier("relaySendTestPush")
        } header: {
            Text("Delivery Test")
        } footer: {
            Text("Sends a real relay push through the saved relay URL and reports the delivered result or actual error.")
        }
    }

    @ViewBuilder
    private var saveSection: some View {
        Section {
            if let savedMessage = store.savedMessage {
                Label(savedMessage, systemImage: "checkmark.circle")
                    .foregroundStyle(theme.midground)
                    .listRowBackground(theme.card)
                    .accessibilityIdentifier("relayPushSaved")
            }

            Button {
                Task { await store.save() }
            } label: {
                HStack {
                    Label("Save Relay Settings", systemImage: "square.and.arrow.down")
                    Spacer(minLength: 8)
                    if store.isSaving {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(store.isLoading || store.isSaving || store.isTestingPush)
            .listRowBackground(theme.card)
            .accessibilityIdentifier("relayPushSave")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )
    }
}
