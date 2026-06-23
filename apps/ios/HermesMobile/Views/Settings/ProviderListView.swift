import SwiftUI

// MARK: - ABH-183 provider / API-key-entry UI
//
// Three views, all reached ONLY from the Settings "Model Provider" section
// (which gates on `capabilities.pluginMount == .available`):
//
//   • ``ProviderListView``       — the provider universe + authenticated? status.
//   • ``EnterProviderKeyView``   — Tier A: a SecureField for a registered
//                                  api_key provider's key.
//   • ``CustomProviderView``     — Tier B: name + base_url + api_mode + key for a
//                                  custom OpenAI/Anthropic-compatible provider.
//
// All three are FULL NATIVE `List`/`Form` screens (system primitives only;
// identity via tint — `theme.midground` for the authenticated chip,
// `theme.destructive` for Disconnect, matching DevicesView). They reuse the
// device-token REST client (`connectionStore.rest`) and the transient
// ``KeychainService`` provider-key storage — no reinvention.
//
// SECRETS HYGIENE (binding): the entered key lives in a `@State` String ONLY
// until the Save tap, which writes it to the Keychain transiently, POSTs it
// once, then deletes the Keychain copy (the gateway is the source of truth).
// The key is never logged; `RestError` already truncates response bodies.

/// The Model Provider picker — a FULL NATIVE `List` of every provider in the
/// universe (`GET <prefix>/providers`) with its auth status: "authenticated"
/// (green chip), "Add key" (a registered api_key provider the user can provision
/// on mobile), or "OAuth — set up on desktop" (an OAuth/external provider that
/// cannot be provisioned from a key alone). A trailing "Custom OpenAI-compatible"
/// row opens the Tier B form. Tap a registered api_key provider →
/// ``EnterProviderKeyView``; an authenticated row shows a destructive
/// "Disconnect" affordance that DELETEs its credentials.
///
/// On a successful key save / custom add / disconnect, the row's auth status
/// flips locally and `onProvidersChanged` fires so the owner can re-resolve the
/// running model + repopulate the Model picker (the gateway's
/// `/api/model/options` reflects the new provider's models).
struct ProviderListView: View {
    /// The REST client for the active connection (device or shared token — both
    /// accepted by the plugin routes, same as DevicesView).
    let rest: RestClient

    /// Invoked after a successful key save / custom add / disconnect so the owner
    /// (SettingsView) can re-resolve the running model + repopulate the Model
    /// picker. Optional: nil call sites keep the old behavior (no refresh).
    var onProvidersChanged: (() -> Void)?

    @Environment(\.hermesTheme) private var theme

    @State private var phase: PanelPhase<[ProviderRow]> = .loading
    @State private var actionError: String?

    /// The provider whose EnterProviderKeyView is presented (Tier A push).
    @State private var pendingKeyProvider: ProviderRow?

    /// Whether the CustomProviderView is presented (Tier B push).
    @State private var showingCustom = false

    /// The provider awaiting a disconnect confirmation.
    @State private var pendingDisconnect: ProviderRow?
    /// The slug currently being disconnected (disables its row while in flight).
    @State private var disconnectingSlug: String?

    var body: some View {
        PanelContent(phase: phase, label: "Loading providers\u{2026}", retry: { Task { await load() } }) { providers in
            List {
                if let actionError {
                    Section {
                        Label(actionError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(theme.destructive)
                            .listRowBackground(theme.card)
                    }
                }
                providersSection(providers)
                customSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.bg)
            .refreshable { await load() }
        }
        .navigationTitle("Model Provider")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .alert("Couldn\u{2019}t update provider", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .navigationDestination(item: $pendingKeyProvider) { provider in
            EnterProviderKeyView(rest: rest, provider: provider) { updated in
                updateRow(updated)
                onProvidersChanged?()
            }
            .background(theme.bg)
        }
        .sheet(isPresented: $showingCustom) {
            NavigationStack {
                CustomProviderView(rest: rest) { added in
                    upsertRow(added)
                    onProvidersChanged?()
                }
            }
            // \.hermesTheme does not inherit across a sheet presentation; re-inject.
            .environment(\.hermesTheme, theme)
        }
        .confirmationDialog(
            "Disconnect this provider?",
            isPresented: disconnectDialogBinding,
            titleVisibility: .visible,
            presenting: pendingDisconnect
        ) { provider in
            Button("Disconnect", role: .destructive) {
                Task { await disconnect(provider) }
            }
            Button("Cancel", role: .cancel) { pendingDisconnect = nil }
        } message: { provider in
            Text("\u{201C}\(provider.name)\u{201D} will no longer be available for new chats. You can re-add the key any time.")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func providersSection(_ providers: [ProviderRow]) -> some View {
        Section {
            if providers.isEmpty {
                Label("No providers configured.", systemImage: "cpu.slashed")
                    .foregroundStyle(theme.mutedFg)
                    .listRowBackground(theme.card)
            } else {
                ForEach(providers) { provider in
                    providerRow(provider)
                        .listRowBackground(theme.card)
                }
            }
        } header: {
            Text("Providers")
        } footer: {
            Text("Add an API key to use a provider's models in new chats. OAuth providers must be set up on the desktop.")
        }
    }

    @ViewBuilder
    private var customSection: some View {
        Section {
            Button {
                actionError = nil
                showingCustom = true
            } label: {
                HStack(spacing: 12) {
                    Label {
                        Text("Custom OpenAI-compatible")
                            .foregroundStyle(theme.fg)
                    } icon: {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(theme.midground)
                    }
                    Spacer(minLength: 8)
                }
            }
            .accessibilityIdentifier("providerAddCustom")
            .listRowBackground(theme.card)
        } footer: {
            Text("Add an OpenAI- or Anthropic-compatible endpoint (a proxy, a self-host, or any provider with a base URL).")
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func providerRow(_ provider: ProviderRow) -> some View {
        let canProvision = provider.authType?.provisionableFromKey ?? false
        if provider.authenticated {
            // Authenticated row: name + green chip + a trailing Disconnect affordance.
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(provider.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(theme.fg)
                            .lineLimit(1)
                        if provider.isCurrent {
                            Text("CURRENT")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(theme.midground)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .overlay(Capsule().strokeBorder(theme.midground.opacity(0.4), lineWidth: 1))
                        }
                    }
                    if let total = modelCountText(provider) {
                        Text(total)
                            .font(.footnote)
                            .foregroundStyle(theme.mutedFg)
                    }
                }
                Spacer(minLength: 8)
                Text("Authenticated")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.midground.contrastingForeground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(theme.midground, in: Capsule())
                    .accessibilityIdentifier("providerStatus-\(provider.slug)")
            }
            .padding(.vertical, 2)
            .opacity(disconnectingSlug == provider.slug ? 0.4 : 1)
            // Tapping an authenticated api_key provider re-opens the key form
            // (replace key). OAuth-only providers that somehow report authenticated
            // are read-only (no tap affordance). The `canProvision` gate keeps the
            // tap a no-op for them while still letting the swipe Disconnect fire.
            .contentShape(Rectangle())
            .onTapGesture {
                guard canProvision else { return }
                actionError = nil
                pendingKeyProvider = provider
            }
            // A re-provision (replace key) is available for provisionable providers
            // even when already authenticated; OAuth-only providers are read-only.
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    actionError = nil
                    pendingDisconnect = provider
                } label: {
                    Label("Disconnect", systemImage: "trash")
                }
                .disabled(disconnectingSlug != nil)
                .accessibilityIdentifier("providerDisconnect-\(provider.slug)")
            }
        } else if canProvision {
            // Provisionable, not yet authenticated → tap to enter a key.
            Button {
                actionError = nil
                pendingKeyProvider = provider
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(provider.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(theme.fg)
                            .lineLimit(1)
                        if let total = modelCountText(provider) {
                            Text(total)
                                .font(.footnote)
                                .foregroundStyle(theme.mutedFg)
                        }
                    }
                    Spacer(minLength: 8)
                    Text("Add key")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(theme.midground)
                }
            }
            .accessibilityIdentifier("providerRow-\(provider.slug)")
        } else {
            // OAuth-only / external — cannot be provisioned from a key on mobile.
            // Read-only row: name + the "set up on desktop" hint. No affordance.
            VStack(alignment: .leading, spacing: 4) {
                Text(provider.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.fg)
                    .lineLimit(1)
                Text(oauthHint(provider))
                    .font(.footnote)
                    .foregroundStyle(theme.mutedFg)
            }
            .padding(.vertical, 2)
            .accessibilityIdentifier("providerRow-\(provider.slug)")
        }
    }

    // MARK: - Load + mutate

    private func load() async {
        if phase.value == nil { phase = .loading }
        do {
            let providers = try await rest.listProviders()
            phase = .loaded(providers)
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Disconnect `provider` after a confirmation (DELETE its credentials). On
    /// success the row flips to its not-authenticated state.
    private func disconnect(_ provider: ProviderRow) async {
        pendingDisconnect = nil
        actionError = nil
        disconnectingSlug = provider.slug
        defer { disconnectingSlug = nil }
        do {
            _ = try await rest.removeProviderKey(slug: provider.slug)
            // Drop the transient client copy if one lingered.
            KeychainService.deleteProviderKey(slug: provider.slug)
            // Flip the row locally: same slug, now unauthenticated.
            if var rows = phase.value {
                if let index = rows.firstIndex(where: { $0.slug == provider.slug }) {
                    let existing = rows[index]
                    rows[index] = ProviderRow(
                        slug: existing.slug,
                        name: existing.name,
                        authType: existing.authType,
                        isCurrent: false,
                        authenticated: false,
                        totalModels: existing.totalModels,
                        models: existing.models
                    )
                    phase = .loaded(rows)
                }
            }
            onProvidersChanged?()
        } catch {
            actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Replace the row matching `updated.slug` (post key-save: authenticated now
    /// true, models populated). Mirrors how the model picker's `appliedSelection`
    /// flips a row without a full reload.
    private func updateRow(_ updated: ProviderRow) {
        upsertRow(updated)
    }

    /// Insert-or-replace `row` by slug in the loaded list (a custom add is a new
    /// slug; a key save is an existing slug).
    private func upsertRow(_ row: ProviderRow) {
        guard var rows = phase.value else { return }
        if let index = rows.firstIndex(where: { $0.slug == row.slug }) {
            rows[index] = row
        } else {
            rows.append(row)
        }
        phase = .loaded(rows)
    }

    // MARK: - Derived

    private var errorBinding: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    }

    private var disconnectDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingDisconnect != nil },
            set: { if !$0 { pendingDisconnect = nil } }
        )
    }

    /// "N models" / "1 model" footer line, or nil when the count is unknown/zero
    /// and no curated model list was returned.
    private func modelCountText(_ provider: ProviderRow) -> String? {
        if let models = provider.models, !models.isEmpty {
            return "\(models.count) model\(models.count == 1 ? "" : "s")"
        }
        if provider.totalModels > 0 {
            return "\(provider.totalModels) model\(provider.totalModels == 1 ? "" : "s")"
        }
        return nil
    }

    /// The "set up on desktop" hint for an OAuth-only provider.
    private func oauthHint(_ provider: ProviderRow) -> String {
        switch provider.authType {
        case .oauthDeviceCode, .oauthExternal, .oauthMinimax:
            return "OAuth — set up on desktop"
        case .externalProcess:
            return "External auth — set up on desktop"
        case .apiKey, .custom, .none:
            // An api_key/custom provider that landed in this branch isn't
            // provisionable from here (e.g. an unknown auth shape) — direct the
            // user to the desktop rather than implying a missing key affordance.
            return "Set up on desktop"
        }
    }
}

// MARK: - EnterProviderKeyView (Tier A — registered api_key provider)

/// Enter an API key for a REGISTERED api_key provider (Tier A). A single
/// `SecureField` + Save. The entered key is held in `@State` only until Save,
/// which writes it to the Keychain transiently, POSTs it once via
/// ``RestClient/setProviderKey(slug:apiKey:)``, then deletes the Keychain copy
/// (the gateway is the source of truth). On 200 the callback fires with the
/// refreshed provider row (authenticated, models populated) and the view pops.
///
/// Reached ONLY from a provisionable provider row (an `api_key` provider).
/// OAuth-only providers never reach this view (they show a read-only
/// "set up on desktop" row in the list).
struct EnterProviderKeyView: View {
    let rest: RestClient
    let provider: ProviderRow
    /// Invoked with the refreshed provider row on a successful save.
    let onSaved: (ProviderRow) -> Void

    @Environment(\.hermesTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey = ""
    @State private var errorText: String?
    @State private var isSaving = false
    @FocusState private var keyFieldFocused: Bool

    private var canSave: Bool {
        !apiKey.trimmingCharacters(in: .whitespaces).isEmpty && !isSaving
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.name)
                        .font(.title2.bold())
                        .foregroundStyle(theme.fg)
                    Text("Enter the API key for this provider. It's stored securely on your gateway and used for new chats.")
                        .font(.subheadline)
                        .foregroundStyle(theme.mutedFg)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                .listRowBackground(Color.clear)
            }

            Section {
                SecureField("API key", text: $apiKey, prompt: Text("Paste API key"))
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($keyFieldFocused)
                    .onSubmit { if canSave { save() } }
                    .accessibilityIdentifier("providerKeyField")
            } footer: {
                if let errorText {
                    Text(errorText)
                        .foregroundStyle(theme.destructive)
                } else {
                    Text("The key is sent once over your existing connection and held only until the save completes. Your gateway is the source of truth.")
                }
            }

            Section {
                Button(action: save) {
                    HStack {
                        Spacer()
                        if isSaving {
                            ProgressView()
                                .tint(theme.midground.contrastingForeground)
                        } else {
                            Text("Save")
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
                .disabled(!canSave)
                .accessibilityLabel(isSaving ? "Saving" : "Save")
                .accessibilityIdentifier("providerKeySaveButton")
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.bg)
        .navigationTitle(provider.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { keyFieldFocused = true }
    }

    private func save() {
        guard canSave else { return }
        keyFieldFocused = false
        errorText = nil
        isSaving = true
        let trimmed = apiKey.trimmingCharacters(in: .whitespaces)
        let slug = provider.slug
        // Hold the key transiently in the Keychain for the duration of the POST,
        // then clear it (the gateway is the source of truth).
        do {
            try KeychainService.saveProviderKey(trimmed, slug: slug)
        } catch {
            isSaving = false
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        Task {
            defer {
                KeychainService.deleteProviderKey(slug: slug)
                isSaving = false
            }
            do {
                let updated = try await rest.setProviderKey(slug: slug, apiKey: trimmed)
                onSaved(updated)
                dismiss()
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

// MARK: - CustomProviderView (Tier B — custom OpenAI/Anthropic-compatible)

/// Register a custom OpenAI- or Anthropic-compatible provider (Tier B): name,
/// base_url, api_mode picker, and a key. The entered key is held in `@State`
/// only until Save, which writes it to the Keychain transiently, POSTs it once
/// via ``RestClient/addCustomProvider(name:baseURL:apiMode:apiKey:)``, then
/// deletes the Keychain copy. On 200 the callback fires with the new provider
/// row (authenticated, models populated) and the view dismisses.
///
/// Presented as a sheet (it's a create form, not a list push) — mirrors the
/// ManualTokenPromptView sheet presentation. Cancel simply dismisses (no state
/// is written until Save).
struct CustomProviderView: View {
    let rest: RestClient
    /// Invoked with the newly-added provider row on a successful save.
    let onAdded: (ProviderRow) -> Void

    @Environment(\.hermesTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var baseURL = "https://"
    @State private var apiMode: ProviderAPIMode = .openai
    @State private var apiKey = ""
    @State private var errorText: String?
    @State private var isSaving = false
    @FocusState private var nameFieldFocused: Bool

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
            && !isSaving
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom Provider")
                        .font(.title2.bold())
                        .foregroundStyle(theme.fg)
                    Text("Add any OpenAI- or Anthropic-compatible endpoint — a proxy, a self-host, or a third-party provider with a base URL.")
                        .font(.subheadline)
                        .foregroundStyle(theme.mutedFg)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                .listRowBackground(Color.clear)
            }

            Section {
                TextField("Name", text: $name, prompt: Text("e.g. my-proxy"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($nameFieldFocused)
                    .accessibilityIdentifier("customProviderNameField")

                TextField("Base URL", text: $baseURL, prompt: Text("https://api.example.com"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.next)
                    .accessibilityIdentifier("customProviderBaseURLField")

                Picker("API mode", selection: $apiMode) {
                    ForEach(ProviderAPIMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("customProviderAPIModePicker")

                SecureField("API key", text: $apiKey, prompt: Text("Paste API key"))
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { if canSave { save() } }
                    .accessibilityIdentifier("customProviderKeyField")
            } footer: {
                if let errorText {
                    Text(errorText)
                        .foregroundStyle(theme.destructive)
                } else {
                    Text("The name must be letters, numbers, dashes, or underscores. The base URL must start with http:// or https://.")
                }
            }

            Section {
                Button(action: save) {
                    HStack {
                        Spacer()
                        if isSaving {
                            ProgressView()
                                .tint(theme.midground.contrastingForeground)
                        } else {
                            Text("Add Provider")
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
                .disabled(!canSave)
                .accessibilityLabel(isSaving ? "Adding" : "Add Provider")
                .accessibilityIdentifier("customProviderSaveButton")
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.bg)
        .navigationTitle("Custom Provider")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("customProviderCancelButton")
            }
        }
        .onAppear { nameFieldFocused = true }
    }

    private func save() {
        guard canSave else { return }
        nameFieldFocused = false
        errorText = nil
        isSaving = true
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespaces)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespaces)
        // Transient Keychain hold for the POST duration (slug = the new name).
        do {
            try KeychainService.saveProviderKey(trimmedKey, slug: trimmedName)
        } catch {
            isSaving = false
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        Task {
            defer {
                KeychainService.deleteProviderKey(slug: trimmedName)
                isSaving = false
            }
            do {
                let added = try await rest.addCustomProvider(
                    name: trimmedName,
                    baseURL: trimmedBase,
                    apiMode: apiMode,
                    apiKey: trimmedKey
                )
                onAdded(added)
                dismiss()
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
