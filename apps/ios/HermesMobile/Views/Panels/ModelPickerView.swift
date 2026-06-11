import SwiftUI

/// Browse authenticated providers and their curated models, see which model is
/// currently configured (`GET /api/model/info`), and assign a new main model
/// (`POST /api/model/set`).
///
/// Selection writes the **main** slot and applies to *new* sessions — the
/// running chat is not hot-swapped (server semantics; surfaced as a footnote).
/// Presentable in a sheet or pushed onto a navigation stack.
///
/// ABH-84: When `gatewayClient` is non-nil, a "Default Reasoning" and a
/// "Default Fast Mode" control appear below the context header. These send
/// `config.set` without a `session_id` (global write), matching the Settings
/// scope. The controls are hidden on call sites that don't supply a client.
struct ModelPickerView: View {
    let control: RestClient

    /// WS client for global config.set (fast/reasoning defaults). When nil the
    /// reasoning/fast controls are hidden — backwards-compatible with call sites
    /// that only need the model-selection surface.
    var gatewayClient: HermesGatewayClient?

    /// Invoked after a successful model switch so the owner can re-resolve the
    /// running model (F0 / Amendment B — `ConnectionStore.refreshActiveModel`).
    /// Optional: nil call sites keep the old behaviour (no refresh).
    var onModelChanged: (() -> Void)?

    /// The active session's context-window occupancy (H1), passed in from the
    /// chip call site. When present, a compact stats header — "142K / 1M tokens ·
    /// 14% · 2 compressions" — sits above the model list. `nil` (the default,
    /// e.g. the Settings call site) omits the header entirely.
    var contextUsage: (used: Int, max: Int, percent: Int, compressions: Int)?

    @Environment(\.hermesTheme) private var theme

    @State private var phase: PanelPhase<ModelOptions> = .loading
    /// The resolved main-model info (separate endpoint; merged into the header).
    @State private var info: ModelInfo?
    /// The (provider, model) currently being written, for per-row spinners.
    @State private var pendingSelection: Selection?
    /// Locally reflects the just-applied selection so the checkmark moves
    /// without a full reload (the server only changes *new* sessions).
    @State private var appliedSelection: Selection?
    @State private var actionError: String?
    @State private var search = ""

    // ABH-84: global default fast/reasoning state (Settings surface only).
    /// Current global default reasoning effort ("" = off/default).
    @State private var globalReasoningEffort: String = ""
    /// Current global default fast mode.
    @State private var globalFast: Bool = false
    /// True while a global fast/reasoning write is in flight.
    @State private var pendingGlobalConfig: Bool = false

    private struct Selection: Equatable { let provider: String; let model: String }

    init(
        control: RestClient,
        gatewayClient: HermesGatewayClient? = nil,
        contextUsage: (used: Int, max: Int, percent: Int, compressions: Int)? = nil,
        onModelChanged: (() -> Void)? = nil
    ) {
        self.control = control
        self.gatewayClient = gatewayClient
        self.contextUsage = contextUsage
        self.onModelChanged = onModelChanged
    }

    var body: some View {
        // PSF-08: supply a loading label so the spinner is never bare during
        // the initial fetch (matches the audit finding: "ModelPicker loading label").
        PanelContent(phase: phase, label: "Loading models\u{2026}", retry: { Task { await load() } }) { options in
            List {
                if let contextUsage { contextStatsHeader(contextUsage) }
                headerSection(options)

                // ABH-84: Global default fast/reasoning controls (Settings surface).
                // Only shown when a gateway WS client was supplied.
                if gatewayClient != nil {
                    globalDefaultsSection(options)
                }

                ForEach(filteredProviders(options)) { provider in
                    Section {
                        ForEach(provider.models, id: \.self) { model in
                            modelRow(provider: provider, model: model, options: options)
                        }
                        if provider.models.isEmpty {
                            Text("No curated models")
                                .font(.subheadline)
                                .foregroundStyle(theme.mutedFg)
                        }
                    } header: {
                        providerHeader(provider)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.bg)
            .searchable(text: $search, prompt: "Filter models")
            .refreshable { await load() }
            .overlay {
                if filteredProviders(options).allSatisfy({ matchingModels($0).isEmpty })
                    && !search.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn’t switch model", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .task {
            await load()
            await loadGlobalConfig()
        }
    }

    // MARK: Sections

    /// Compact context-window stats header (H1): "142K / 1M tokens · 14% ·
    /// 2 compressions". The compressions clause is omitted when the count is 0.
    @ViewBuilder
    private func contextStatsHeader(
        _ usage: (used: Int, max: Int, percent: Int, compressions: Int)
    ) -> some View {
        // PSF-07: context stats row gets theme.card so it matches all other
        // information rows in the panel and doesn't leak system-gray on dark themes.
        Section {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.caption)
                    .foregroundStyle(usage.percent >= 75 ? theme.statusWarn : theme.midground)
                Text(Self.contextStatsLine(usage))
                    .font(.footnote)
                    .foregroundStyle(theme.fg)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Context window: \(Self.contextStatsLine(usage))")
            .listRowBackground(theme.card)
        }
    }

    /// "142K / 1M tokens · 14% · 2 compressions" — drops the trailing
    /// compressions clause when none have happened, and pluralizes it.
    static func contextStatsLine(
        _ usage: (used: Int, max: Int, percent: Int, compressions: Int)
    ) -> String {
        var line = "\(UsageStats.formatK(usage.used)) / \(UsageStats.formatK(usage.max)) tokens · \(usage.percent)%"
        if usage.compressions > 0 {
            line += " · \(usage.compressions) compression\(usage.compressions == 1 ? "" : "s")"
        }
        return line
    }

    @ViewBuilder
    private func headerSection(_ options: ModelOptions) -> some View {
        // PSF-07: all info rows in the header section use theme.card so the
        // "Current model / Provider / Context window" block is on the same
        // card surface as the model rows below it.
        Section {
            LabeledContent("Current model") {
                Text(currentModelLabel(options))
                    .foregroundStyle(theme.mutedFg)
                    .multilineTextAlignment(.trailing)
            }
            .listRowBackground(theme.card)
            if let provider = currentProviderLabel(options) {
                LabeledContent("Provider", value: provider)
                    .listRowBackground(theme.card)
            }
            if let ctx = info?.effectiveContextLength, ctx > 0 {
                LabeledContent("Context window", value: "\(PanelFormat.compact(ctx)) tokens")
                    .listRowBackground(theme.card)
            }
        } footer: {
            Text("Switching the model applies to new sessions. The active chat keeps its current model until you start a new one.")
        }
    }

    private func providerHeader(_ provider: ModelProvider) -> some View {
        HStack {
            Text(provider.name)
            if provider.isCurrent {
                // Single accent chip (audit M1): one bronze affordance per
                // provider header, no competing colours.
                Text("CURRENT")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(theme.midground)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(Capsule().strokeBorder(theme.midground.opacity(0.4), lineWidth: 1))
            }
            Spacer()
            if let total = provider.totalModels, total > provider.models.count {
                Text("\(provider.models.count) of \(total)")
                    .font(.caption2)
                    .foregroundStyle(theme.mutedFg)
            }
        }
    }

    @ViewBuilder
    private func modelRow(provider: ModelProvider, model: String, options: ModelOptions) -> some View {
        let selection = Selection(provider: provider.slug, model: model)
        let isCurrent = isSelected(selection, options: options)
        let caps = provider.capabilities[model]

        // Build the VoiceOver label eagerly so the Button combines correctly.
        let capParts: [String] = {
            guard let caps else { return [] }
            var parts: [String] = []
            if caps.reasoning { parts.append("Reasoning") }
            if caps.fast { parts.append("Fast") }
            return parts
        }()
        let a11yLabel: String = {
            var parts = [model]
            parts.append(contentsOf: capParts)
            if isCurrent { parts.append("Selected") }
            return parts.joined(separator: ", ")
        }()

        Button {
            Task { await select(selection) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model)
                        // Names read as content, not links (audit M1): solid fg,
                        // semibold so the title anchors the row.
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.fg)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let caps {
                        HStack(spacing: 6) {
                            if caps.reasoning { capabilityTag("Reasoning", "brain") }
                            if caps.fast { capabilityTag("Fast", "bolt.fill") }
                        }
                    }
                }
                Spacer(minLength: 8)
                if pendingSelection == selection {
                    ProgressView()
                } else if isCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.midground)
                        .accessibilityHidden(true)
                }
            }
        }
        .disabled(pendingSelection != nil)
        // Combine children so the button reads: "<model>, Reasoning, Fast, Selected"
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11yLabel)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
        // Selected-row tint (audit M1): the accent fill marks the active model
        // without adding a third accent colour to the row content.
        .listRowBackground(isCurrent ? theme.accent : theme.card)
    }

    /// Neutral capability chip (audit M1): a quiet caption2 pill on the
    /// `secondary` fill so tags never read as the blue/tappable affordance the
    /// model name used to.
    private func capabilityTag(_ label: String, _ icon: String) -> some View {
        Label(label, systemImage: icon)
            .font(.caption2)
            .foregroundStyle(theme.secondaryFg)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(theme.secondary, in: Capsule())
            // Each tag provides its own label so VoiceOver reads it correctly
            // when the enclosing Button reads its combined children.
            .accessibilityLabel(label)
    }

    // MARK: Derived

    private func currentModelLabel(_ options: ModelOptions) -> String {
        if let applied = appliedSelection { return applied.model }
        let model = info?.model ?? options.currentModel
        return model.isEmpty ? "Not set" : model
    }

    private func currentProviderLabel(_ options: ModelOptions) -> String? {
        let provider = (appliedSelection?.provider).flatMap { slug in
            options.providers.first { $0.slug == slug }?.name
        } ?? info?.provider ?? (options.currentProvider.isEmpty ? nil : options.currentProvider)
        guard let provider, !provider.isEmpty else { return nil }
        return provider
    }

    private func isSelected(_ selection: Selection, options: ModelOptions) -> Bool {
        if let applied = appliedSelection { return applied == selection }
        return selection.provider == options.currentProvider && selection.model == options.currentModel
    }

    private func filteredProviders(_ options: ModelOptions) -> [ModelProvider] {
        guard !search.isEmpty else { return options.providers }
        return options.providers.filter { !matchingModels($0).isEmpty }
    }

    private func matchingModels(_ provider: ModelProvider) -> [String] {
        guard !search.isEmpty else { return provider.models }
        let needle = search.lowercased()
        if provider.name.lowercased().contains(needle) || provider.slug.lowercased().contains(needle) {
            return provider.models
        }
        return provider.models.filter { $0.lowercased().contains(needle) }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    }

    // MARK: Actions

    private func load() async {
        if phase.value == nil { phase = .loading }
        async let optionsResult = control.modelOptions()
        async let infoResult = try? control.modelInfo()
        do {
            let options = try await optionsResult
            info = await infoResult
            phase = .loaded(options)
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func select(_ selection: Selection) async {
        guard pendingSelection == nil else { return }
        pendingSelection = selection
        defer { pendingSelection = nil }
        do {
            _ = try await control.setMainModel(provider: selection.provider, model: selection.model)
            appliedSelection = selection
            // Tell the owner to re-resolve the running model so the header /
            // composer chip reflects the new main model (F0 / Amendment B).
            onModelChanged?()
        } catch {
            actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Global defaults section (ABH-84)

    /// Global default reasoning + fast controls. Visible only in the Settings
    /// path (when `gatewayClient` is non-nil). Both send `config.set` WITHOUT a
    /// `session_id` so the gateway writes the global config.yaml default.
    @ViewBuilder
    private func globalDefaultsSection(_ options: ModelOptions) -> some View {
        // Find capabilities for the currently active (or applied) model.
        let currentModelId = appliedSelection?.model ?? options.currentModel
        let allCaps = options.providers.reduce(into: [String: ModelCapability]()) { acc, p in
            acc.merge(p.capabilities) { _, new in new }
        }
        let caps = allCaps[currentModelId]
        let supportsReasoning = caps?.reasoning ?? true
        let supportsFast = caps?.fast ?? false

        if supportsReasoning || supportsFast {
            Section("Default for New Chats") {
                if supportsReasoning {
                    // Reasoning effort picker — global default.
                    Picker("Thinking effort", selection: $globalReasoningEffort) {
                        Text("Off").tag("")
                        Text("Minimal").tag("minimal")
                        Text("Low").tag("low")
                        Text("Medium").tag("medium")
                        Text("High").tag("high")
                        Text("Max").tag("xhigh")
                    }
                    .pickerStyle(.menu)
                    .disabled(pendingGlobalConfig)
                    .listRowBackground(theme.card)
                    .onChange(of: globalReasoningEffort) { _, newVal in
                        Task { await applyGlobalReasoning(newVal) }
                    }
                    .accessibilityLabel("Default reasoning effort")
                }
                if supportsFast {
                    Toggle(isOn: $globalFast) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Fast Mode")
                                    .font(.body)
                                    .foregroundStyle(theme.fg)
                                Text("Priority tier — lower latency, higher cost")
                                    .font(.caption)
                                    .foregroundStyle(theme.mutedFg)
                            }
                        } icon: {
                            Image(systemName: "bolt.fill")
                                .foregroundStyle(theme.midground)
                        }
                    }
                    .tint(theme.midground)
                    .disabled(pendingGlobalConfig)
                    .listRowBackground(theme.card)
                    .onChange(of: globalFast) { _, newVal in
                        Task { await applyGlobalFast(newVal) }
                    }
                }
            }
        }
    }

    /// Load current global reasoning effort + fast mode from the gateway config.
    private func loadGlobalConfig() async {
        guard gatewayClient != nil else { return }
        // Read from `GET /api/config` — the same endpoint the desktop uses.
        guard let agentSection = try? await control.agentConfig() else { return }
        let effort = agentSection["reasoning_effort"]?.stringValue ?? ""
        let tier = agentSection["service_tier"]?.stringValue ?? ""
        globalReasoningEffort = effort
        globalFast = (tier == "priority" || tier == "fast")
    }

    private func applyGlobalReasoning(_ effort: String) async {
        guard let gatewayClient else { return }
        pendingGlobalConfig = true
        defer { pendingGlobalConfig = false }
        let prev = globalReasoningEffort
        do {
            _ = try await gatewayClient.requestRaw(
                "config.set",
                params: .object([
                    "key": .string("reasoning"),
                    "value": .string(effort.isEmpty ? "none" : effort),
                ]),
                timeout: .seconds(30)
            )
        } catch {
            globalReasoningEffort = prev
            actionError = (error as? GatewayError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func applyGlobalFast(_ enabled: Bool) async {
        guard let gatewayClient else { return }
        pendingGlobalConfig = true
        defer { pendingGlobalConfig = false }
        let prev = globalFast
        do {
            _ = try await gatewayClient.requestRaw(
                "config.set",
                params: .object([
                    "key": .string("fast"),
                    "value": .string(enabled ? "fast" : "normal"),
                ]),
                timeout: .seconds(30)
            )
        } catch {
            globalFast = prev
            actionError = (error as? GatewayError)?.errorDescription ?? error.localizedDescription
        }
    }
}
