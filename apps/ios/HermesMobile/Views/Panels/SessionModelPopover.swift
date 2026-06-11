import SwiftUI

// MARK: - Session model popover (ABH-84)
//
// A compact, native iOS popup (Menu + popover) attached to the composer model
// chip. Performs SESSION HOT-SWAP only — all three controls send `config.set`
// with the active `session_id` so the gateway keeps changes session-scoped
// (per the gateway seam: the global `_write_config_key` is skipped when a
// session is present).
//
// Contents (mirrors the desktop session model picker):
//   1. Model list — all providers + curated models, scrollable.
//   2. Reasoning/Thinking effort — picker for levels the selected model supports.
//   3. Fast mode — toggle for models that support it.
//
// The current session state (model/reasoning/fast) is read from
// `ConnectionStore.session{Model,ReasoningEffort,Fast}` which is updated by
// `session.info` events the gateway emits after each hot-swap.
//
// UX: The popup uses a `.popover` on iPad and a custom compact sheet on iPhone,
// anchored to the composer chip via an `anchorPopover` state. On iOS 26 the
// popover gets native glass automatically. Since iOS 26 `Menu` with
// `.menuActionDismissBehavior(.disabled)` does not stay open for sub-pickers,
// we use a `.popover(isPresented:)` approach that presents a lightweight
// `SessionModelPickerContent` card over the composer.

// MARK: - Picker content view

/// Compact session model picker shown in the popover.
/// Loads provider/model list + capabilities from `GET /api/model/options`,
/// then sends WS `config.set` with `session_id` for all mutations.
struct SessionModelPickerContent: View {
    let connection: ConnectionStore
    /// The live runtime session — nil on a DRAFT chat (no session yet). In
    /// draft mode selections PEND on `ConnectionStore.draftSelection` and are
    /// applied when the draft materializes (before the first prompt), so the
    /// model can be picked at any point — not just on existing sessions.
    let sessionId: String?
    /// Needed to re-install the theme on the nested Edit Models sheet —
    /// SwiftUI sheets do not inherit custom environment values (see
    /// ``HermesThemedModifier``).
    let themeStore: ThemeStore
    @Binding var isPresented: Bool

    /// Draft mode: no gateway session to hot-swap; picks pend locally.
    private var isDraftMode: Bool { sessionId == nil || sessionId?.isEmpty == true }

    @Environment(\.hermesTheme) private var theme

    // Phase for the async model-options load.
    @State private var phase: PanelPhase<ModelOptions> = .loading
    // Pending selection row (spinner indicator), keyed provider::model.
    @State private var pendingKey: String?
    @State private var actionError: String?
    @State private var search = ""

    // Locally-mirrored session state — seeded from the session-scoped
    // `model.options` (which layers the live agent's provider/model) and
    // updated optimistically on each hot-swap (before the server confirms via
    // session.info). Selection identity is the (provider, model) PAIR — the
    // model name alone is ambiguous when two providers offer the same model
    // (the build-22 dual-checkmark bug).
    @State private var localModel: String = ""
    @State private var localProvider: String = ""
    @State private var localReasoningEffort: String = ""
    @State private var localFast: Bool = false

    // Visible-model curation (desktop "Edit Models" parity): explicit set of
    // `provider::model` keys, or nil = curated default (top-N per provider).
    @State private var visibleKeys: Set<String>? = ModelVisibility.load()
    @State private var showEditModels = false

    private var errorBinding: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView("Loading models\u{2026}")
                        .frame(maxWidth: .infinity, minHeight: 120)
                case .failed(let msg):
                    ContentUnavailableView(
                        "Load failed",
                        systemImage: "wifi.exclamationmark",
                        description: Text(msg)
                    )
                    .padding()
                case .loaded(let options):
                    pickerList(options)
                }
            }
            .navigationTitle("This Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isPresented = false }
                }
            }
        }
        .alert("Couldn't apply change", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .onDisappear {
            // Reset volatile UI state so a reopened popover never shows a stale
            // pending spinner or a leftover error alert (ABH review P1).
            pendingKey = nil
            actionError = nil
            search = ""
        }
        .task {
            // Seed local state from ConnectionStore (the last session.info we
            // got); loadOptions() then re-seeds (provider, model) from the
            // session-scoped payload, which is the authoritative live state.
            // In draft mode a pended pick takes precedence over everything.
            if isDraftMode, let draft = connection.draftSelection {
                localModel = draft.model
                localProvider = draft.provider
                localReasoningEffort = draft.reasoningEffort ?? ""
                localFast = draft.fast ?? false
            } else {
                localModel = connection.sessionModelRaw ?? connection.activeModelName ?? ""
                localProvider = connection.sessionProvider ?? ""
                localReasoningEffort = connection.sessionReasoningEffort ?? ""
                localFast = connection.sessionFast ?? false
            }
            await loadOptions()
        }
        .onChange(of: connection.sessionModelRaw) { _, newVal in
            if let v = newVal, !v.isEmpty {
                withAnimation(.snappy(duration: 0.25)) { localModel = v }
            }
        }
        .onChange(of: connection.sessionProvider) { _, newVal in
            if let v = newVal, !v.isEmpty {
                withAnimation(.snappy(duration: 0.25)) { localProvider = v }
            }
        }
        .onChange(of: connection.sessionReasoningEffort) { _, newVal in
            if let v = newVal { localReasoningEffort = v }
        }
        .onChange(of: connection.sessionFast) { _, newVal in
            if let v = newVal { localFast = v }
        }
    }

    // MARK: - List content

    @ViewBuilder
    private func pickerList(_ options: ModelOptions) -> some View {
        let filtered = options.providers
        let visible = ModelVisibility.effectiveVisibleKeys(stored: visibleKeys, providers: options.providers)
        let noResults = !search.isEmpty && filtered.allSatisfy { visibleFamilies($0, visible: visible).isEmpty }
        pickerListContent(options: options, filtered: filtered)
            .overlay {
                if noResults {
                    ContentUnavailableView.search(text: search)
                }
            }
    }

    /// Inner list — extracted so `filtered` is available to `.overlay` above.
    @ViewBuilder
    private func pickerListContent(options: ModelOptions, filtered: [ModelProvider]) -> some View {
        List {
            // "This chat only" context header.
            Section {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.trianglehead.2.counterclockwise.rotate.90")
                        .font(.caption)
                        .foregroundStyle(theme.midground)
                    Text(isDraftMode
                         ? "Applies when this chat starts — this chat only. Use Settings to change the global default."
                         : "Changes apply to this chat only. Use Settings to change the global default.")
                        .font(.caption)
                        .foregroundStyle(theme.mutedFg)
                }
                .listRowBackground(theme.card)
            }

            // Model list grouped by provider. Rows are model FAMILIES (a base
            // model and its `…-fast` sibling collapse into one row, desktop
            // parity) filtered by the user's visible-model curation. The
            // CURRENT row matches on the (provider, model) pair — never on the
            // bare model name (the build-22 dual-checkmark bug) — and expands
            // accordion-style with the configuration that model supports
            // (Thinking effort / Fast mode), Settings-app progressive
            // disclosure rather than pinned top sections.
            let visible = ModelVisibility.effectiveVisibleKeys(stored: visibleKeys, providers: options.providers)
            ForEach(filtered) { provider in
                let families = visibleFamilies(provider, visible: visible)
                let currentId = ModelVisibility.currentFamilyId(
                    providerSlug: provider.slug,
                    currentProvider: localProvider,
                    currentModel: localModel,
                    families: families
                )
                if !families.isEmpty {
                    Section {
                        ForEach(families) { family in
                            let isCurrent = family.id == currentId
                            modelRow(provider: provider, family: family, isCurrent: isCurrent)
                            if isCurrent {
                                expandedConfigRows(provider: provider, family: family)
                            }
                        }
                    } header: {
                        providerHeader(provider)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.bg)
        .searchable(text: $search, prompt: "Filter models")
        .refreshable { await loadOptions() }
        .toolbar {
            // Standard iOS list-curation placement: "Edit" in the nav bar,
            // leading (Done keeps the trailing slot). Opens the visible-model
            // editor (desktop "Edit models" parity).
            ToolbarItem(placement: .topBarLeading) {
                Button("Edit") { showEditModels = true }
                    .accessibilityHint("Choose which models appear in this list")
            }
        }
        .sheet(isPresented: $showEditModels) {
            ModelVisibilityEditorView(options: options, visibleKeys: $visibleKeys)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .hermesThemed(themeStore)
        }
    }

    /// Accordion content under the CURRENT model row: the configuration that
    /// model actually supports. Thinking/Fast apply to the live session (or
    /// pend on a draft), so they only ever render under the selected model.
    @ViewBuilder
    private func expandedConfigRows(provider: ModelProvider, family: ModelFamily) -> some View {
        let caps = provider.capabilities[family.id]
        let supportsReasoning = caps?.reasoning ?? true
        let supportsFast = (caps?.fast ?? false) || family.fastId != nil
        if supportsReasoning {
            reasoningPicker(disabled: pendingKey != nil)
        }
        if supportsFast {
            fastToggle(disabled: pendingKey != nil)
        }
    }

    /// A provider's family rows after visibility curation + search.
    private func visibleFamilies(_ provider: ModelProvider, visible: Set<String>) -> [ModelFamily] {
        var families = ModelVisibility.collapseModelFamilies(provider.models).filter {
            visible.contains(ModelVisibility.key(provider: provider.slug, model: $0.id))
        }
        // The session's CURRENT model always shows, even when curated out —
        // the user must be able to see what the chat is on. Insert the REAL
        // family (not a stub) so its fast-variant info isn't dropped.
        let allFamilies = ModelVisibility.collapseModelFamilies(provider.models)
        if let currentId = ModelVisibility.currentFamilyId(
            providerSlug: provider.slug,
            currentProvider: localProvider,
            currentModel: localModel,
            families: allFamilies
        ), !families.contains(where: { $0.id == currentId }),
           let currentFamily = allFamilies.first(where: { $0.id == currentId }) {
            families.insert(currentFamily, at: 0)
        }
        if !search.isEmpty {
            let needle = search.lowercased()
            if !provider.name.lowercased().contains(needle) {
                families = families.filter { $0.id.lowercased().contains(needle) }
            }
        }
        return families
    }

    // MARK: - Reasoning effort picker

    /// Compact inline picker for reasoning effort.
    /// Effort levels: "none" (off), "minimal", "low", "medium", "high", "xhigh".
    @ViewBuilder
    private func reasoningPicker(disabled: Bool) -> some View {
        // Picker bound to localReasoningEffort string.
        Picker("Effort", selection: $localReasoningEffort) {
            Text("Off").tag("")
            Text("Minimal").tag("minimal")
            Text("Low").tag("low")
            Text("Medium").tag("medium")
            Text("High").tag("high")
            Text("Max").tag("xhigh")
        }
        .pickerStyle(.menu)
        .disabled(disabled)
        .listRowBackground(theme.card)
        .onChange(of: localReasoningEffort) { _, newEffort in
            Task { await applyReasoning(newEffort) }
        }
        .accessibilityLabel("Reasoning effort")
        .accessibilityValue(localReasoningEffort.isEmpty ? "Off" : localReasoningEffort.capitalized)
    }

    // MARK: - Fast mode toggle

    @ViewBuilder
    private func fastToggle(disabled: Bool) -> some View {
        Toggle(isOn: $localFast) {
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
        .disabled(disabled)
        .listRowBackground(theme.card)
        .onChange(of: localFast) { _, newFast in
            Task { await applyFast(newFast) }
        }
    }

    // MARK: - Model rows

    @ViewBuilder
    private func modelRow(provider: ModelProvider, family: ModelFamily, isCurrent: Bool) -> some View {
        let caps = provider.capabilities[family.id]
        let rowKey = ModelVisibility.key(provider: provider.slug, model: family.id)
        Button {
            Task { await selectModel(provider: provider.slug, model: family.id) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(family.id)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.fg)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let caps {
                        HStack(spacing: 6) {
                            if caps.reasoning { capTag("Thinking", "brain") }
                            if caps.fast || family.fastId != nil { capTag("Fast", "bolt.fill") }
                        }
                    }
                }
                Spacer(minLength: 8)
                if pendingKey == rowKey {
                    ProgressView()
                } else if isCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.midground)
                }
            }
        }
        .disabled(pendingKey != nil)
        .listRowBackground(isCurrent ? theme.accent : theme.card)
        .accessibilityLabel("\(family.id), \(provider.name)\(isCurrent ? ", current" : "")")
    }

    private func capTag(_ label: String, _ icon: String) -> some View {
        Label(label, systemImage: icon)
            .font(.caption2)
            .foregroundStyle(theme.secondaryFg)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(theme.secondary, in: Capsule())
    }

    private func providerHeader(_ provider: ModelProvider) -> some View {
        HStack {
            Text(provider.name)
            if provider.isCurrent {
                Text("CURRENT")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(theme.midground)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(Capsule().strokeBorder(theme.midground.opacity(0.4), lineWidth: 1))
            }
            Spacer()
        }
    }

    // MARK: - Filter helpers

    // MARK: - Actions

    private func loadOptions() async {
        // Session-scoped WS load first: its `model`/`provider` reflect the
        // LIVE session agent (post hot-swap), which is what "current" means
        // here. REST `/api/model/options` (global view) is the fallback for
        // older gateways without the WS method — and the only path in draft
        // mode (no session yet; "current" = the global default a new chat
        // would start on).
        var options: ModelOptions?
        if let sessionId, !sessionId.isEmpty {
            options = try? await connection.sessionModelOptions(sessionId: sessionId)
        }
        if options == nil {
            guard let control = connection.control else { return }
            do {
                options = try await control.modelOptions()
            } catch {
                phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                return
            }
        }
        guard let options else { return }
        // Re-seed the (provider, model) identity from the payload's current —
        // authoritative for this session — unless a hot-swap is already in
        // flight locally, or a draft pick is pending (the pend wins until the
        // session exists).
        let draftPickPending = isDraftMode && connection.draftSelection?.model.isEmpty == false
        if pendingKey == nil && !draftPickPending {
            if !options.currentModel.isEmpty { localModel = options.currentModel }
            if !options.currentProvider.isEmpty {
                localProvider = options.currentProvider
            } else if localProvider.isEmpty {
                // Last resort: the provider flagged current in the list.
                localProvider = options.providers.first(where: \.isCurrent)?.slug ?? ""
            }
        }
        phase = .loaded(options)
    }

    private func selectModel(provider: String, model: String) async {
        guard pendingKey == nil else { return }
        // Draft mode: no session to hot-swap — pend the pick. It applies the
        // moment the draft materializes (before the first prompt goes out).
        if isDraftMode {
            withAnimation(.snappy(duration: 0.25)) {   // accordion expand
                localModel = model
                localProvider = provider
            }
            var draft = connection.draftSelection
                ?? DraftModelSelection(model: model, provider: provider, reasoningEffort: nil, fast: nil)
            draft.model = model
            draft.provider = provider
            connection.draftSelection = draft
            return
        }
        guard let sessionId else { return }
        pendingKey = ModelVisibility.key(provider: provider, model: model)
        defer { pendingKey = nil }
        let prev = localModel
        let prevProvider = localProvider
        withAnimation(.snappy(duration: 0.25)) {   // accordion expand
            localModel = model        // Optimistic update —
            localProvider = provider  // (provider, model) move together.
        }
        do {
            // The gateway's `config.set key=model` value is parsed like `/model`
            // command args (parse_model_flags → switch_model). The robust,
            // desktop-matching form is "<model> --provider <slug>": the explicit
            // --provider path resolves provider then the model on it. A slash-
            // joined "provider/model" only works on aggregator providers, so it
            // is NOT safe here.
            try await connection.sessionSetModel("\(model) --provider \(provider)", sessionId: sessionId)
            // session.info event will confirm; local state is already updated.
        } catch {
            withAnimation(.snappy(duration: 0.25)) {
                localModel = prev            // Roll back —
                localProvider = prevProvider // (provider, model) move together.
            }
            actionError = (error as? GatewayError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func applyReasoning(_ effort: String) async {
        // Apply ONLY when the value actually diverges from the last-known
        // truth (server's session.info, or the pend in draft mode). The
        // `.onChange` driver fires for PROGRAMMATIC assignments too — the
        // .task seed, the catch rollback, the server-confirm onChange — and
        // each previously fired a spurious config.set (incl. one on every
        // picker open). Release audit P1.
        let knownTruth = isDraftMode
            ? (connection.draftSelection?.reasoningEffort ?? "")
            : (connection.sessionReasoningEffort ?? "")
        guard effort != knownTruth else { return }
        // Draft mode: pend on the draft selection (applies at materialization).
        if isDraftMode {
            var draft = connection.draftSelection
                ?? DraftModelSelection(model: "", provider: "", reasoningEffort: nil, fast: nil)
            draft.reasoningEffort = effort
            connection.draftSelection = draft
            return
        }
        guard let sessionId else { return }
        let prev = connection.sessionReasoningEffort ?? ""
        do {
            try await connection.sessionSetReasoning(effort.isEmpty ? "none" : effort, sessionId: sessionId)
        } catch {
            localReasoningEffort = prev   // Roll back.
            actionError = (error as? GatewayError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func applyFast(_ enabled: Bool) async {
        // Same divergence guard as applyReasoning — programmatic assignments
        // (seed/rollback/server-confirm) must not fire config.set.
        let knownTruth = isDraftMode
            ? (connection.draftSelection?.fast ?? false)
            : (connection.sessionFast ?? false)
        guard enabled != knownTruth else { return }
        // Draft mode: pend on the draft selection (applies at materialization).
        if isDraftMode {
            var draft = connection.draftSelection
                ?? DraftModelSelection(model: "", provider: "", reasoningEffort: nil, fast: nil)
            draft.fast = enabled
            connection.draftSelection = draft
            return
        }
        guard let sessionId else { return }
        let prev = connection.sessionFast ?? false
        do {
            try await connection.sessionSetFast(enabled, sessionId: sessionId)
        } catch {
            localFast = prev   // Roll back.
            actionError = (error as? GatewayError)?.errorDescription ?? error.localizedDescription
        }
    }
}
