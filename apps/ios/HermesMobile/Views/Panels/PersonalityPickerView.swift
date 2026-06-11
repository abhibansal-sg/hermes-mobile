import SwiftUI

/// Pick the agent's personality overlay.
///
/// Personalities come from `GET /api/config` (`agent.personalities`); the
/// change is applied over the WebSocket via the `config.set` RPC with
/// `{key: "personality", value: <name>, session_id: <active runtime>}`.
///
/// Server behaviour (tui_gateway `config.set`): the personality write is
/// **global** — it persists `display.personality` + `agent.system_prompt` to
/// the config file, affecting every new session. When `session_id` matches a
/// live runtime session it is *also* applied in-place to that session without
/// resetting history. There is no global-only mode: passing a session id only
/// adds the live overlay on top of the global write. This is surfaced as a
/// footnote in the UI so the user knows the scope.
struct PersonalityPickerView: View {
    let control: RestClient
    /// WS client used for the `config.set` RPC.
    let client: HermesGatewayClient
    /// The active runtime session id, if any. Passed as `session_id` so the
    /// change also lands on the live session; `nil` applies globally only.
    let activeSessionId: String?

    @Environment(\.hermesTheme) private var theme

    @State private var phase: PanelPhase<[PersonalityOption]> = .loading
    /// The currently selected personality name ("" / nil == none/default).
    @State private var current: String?
    @State private var pendingName: String?
    @State private var actionError: String?

    /// Sentinel id for the "None (default)" row — distinct from any real name.
    private static let noneID = "\u{0000}none"

    init(control: RestClient, client: HermesGatewayClient, activeSessionId: String?) {
        self.control = control
        self.client = client
        self.activeSessionId = activeSessionId
    }

    var body: some View {
        PanelContent(phase: phase, retry: { Task { await load() } }) { personalities in
            List {
                Section {
                    noneRow
                    ForEach(personalities) { option in
                        personalityRow(option)
                    }
                } footer: {
                    Text(footnote)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.bg)
            .refreshable { await load() }
            .overlay {
                if personalities.isEmpty {
                    ContentUnavailableView {
                        Label("No personalities", systemImage: "theatermasks")
                    } description: {
                        Text("Add personalities under `agent.personalities` in the gateway config to switch between them here.")
                    }
                }
            }
        }
        .navigationTitle("Personality")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn’t switch personality", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .task { await load() }
    }

    // MARK: Rows

    private var noneRow: some View {
        Button {
            Task { await apply(name: nil, rowID: Self.noneID) }
        } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("None (default)")
                        // Selected name turns brand-accent so the active row is
                        // legible without relying on the trailing check alone (PE1).
                        .font(.body.weight(.semibold))
                        .foregroundStyle(isNoneSelected ? theme.midground : theme.fg)
                    Text("Use the agent's base prompt with no overlay.")
                        .font(.footnote)
                        .foregroundStyle(theme.mutedFg)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                trailing(isSelected: isNoneSelected, isPending: pendingName == Self.noneID)
            }
            .padding(.vertical, 2)
        }
        .disabled(pendingName != nil)
        .listRowBackground(isNoneSelected ? theme.accent : theme.card)
        // Combine all children into one accessible element so VoiceOver reads
        // the full row in one pass: name + selected state.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isNoneSelected ? "None (default), Selected" : "None (default)")
        .accessibilityAddTraits(isNoneSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func personalityRow(_ option: PersonalityOption) -> some View {
        let isSelected = current?.lowercased() == option.name.lowercased()
        return Button {
            Task { await apply(name: option.name, rowID: option.name) }
        } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.name.capitalized)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(isSelected ? theme.midground : theme.fg)
                    if !option.preview.isEmpty {
                        Text(option.preview)
                            // Footnote / mutedFg, clamped to two lines so rows
                            // stay even and descriptions don't ragged-truncate (PE1).
                            .font(.footnote)
                            .foregroundStyle(theme.mutedFg)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                trailing(
                    isSelected: isSelected,
                    isPending: pendingName == option.name
                )
            }
            .padding(.vertical, 2)
        }
        .disabled(pendingName != nil)
        .listRowBackground(isSelected ? theme.accent : theme.card)
        // Combine children so VoiceOver reads: "<Name>, Selected" when active.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isSelected ? "\(option.name.capitalized), Selected" : option.name.capitalized)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func trailing(isSelected: Bool, isPending: Bool) -> some View {
        if isPending {
            ProgressView()
        } else if isSelected {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(theme.midground)
                .accessibilityHidden(true)
        }
    }

    // MARK: Derived

    private var isNoneSelected: Bool {
        (current ?? "").isEmpty
    }

    private var footnote: String {
        if activeSessionId != nil {
            return "Applies to the active session immediately and to all new sessions. History is preserved."
        }
        return "Applies globally to all new sessions."
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    }

    // MARK: Actions

    private func load() async {
        if phase.value == nil { phase = .loading }
        do {
            async let optionsResult = control.personalities()
            async let currentResult = try? control.currentPersonality()
            let options = try await optionsResult
            current = await currentResult ?? nil
            phase = .loaded(options)
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Send `config.set`. `name == nil` clears the overlay (server treats
    /// "none"/"default"/"" as a clear).
    private func apply(name: String?, rowID: String) async {
        guard pendingName == nil else { return }
        pendingName = rowID
        defer { pendingName = nil }

        var params: [String: JSONValue] = [
            "key": .string("personality"),
            "value": .string(name ?? "none"),
        ]
        if let activeSessionId, !activeSessionId.isEmpty {
            params["session_id"] = .string(activeSessionId)
        }

        do {
            // The result carries the resolved value + history_reset; we only
            // need success here. Decode untyped to stay tolerant of the shape.
            _ = try await client.requestRaw(
                "config.set",
                params: .object(params),
                timeout: .seconds(30)
            )
            current = name
        } catch {
            actionError = (error as? GatewayError)?.errorDescription ?? error.localizedDescription
        }
    }
}
