import SwiftUI

/// Gateway health panel: version, gateway run-state, per-platform connection
/// states (telegram, etc.), and the active-session count, from `GET /api/status`.
/// Pull-to-refresh re-fetches. Recovery actions are confirmation-gated and
/// surface honest in-flight/offline/progress states instead of stale "connected".
struct GatewayStatusView: View {
    let control: RestClient

    @Environment(\.hermesTheme) private var theme

    @State private var phase: PanelPhase<GatewayStatus> = .loading
    @StateObject private var actionRunner: GatewayActionRunner
    @State private var pendingAction: GatewayRecoveryAction?

    init(control: RestClient) {
        self.control = control
        _actionRunner = StateObject(wrappedValue: GatewayActionRunner(control: control))
    }

    var body: some View {
        PanelContent(phase: phase, label: "Loading gateway\u{2026}", retry: { Task { await load() } }) { status in
            List {
                // Config-version upgrade notice: show a banner section when
                // config_version < latest_config_version (mirrors desktop behaviour).
                if status.needsConfigUpgrade,
                   let current = status.configVersion,
                   let latest = status.latestConfigVersion {
                    Section {
                        HStack(spacing: 10) {
                            // Decorative warning icon — the surrounding text
                            // already conveys the full message to VoiceOver.
                            Image(systemName: "arrow.up.circle.fill")
                                .foregroundStyle(theme.statusWarn)
                                .imageScale(.large)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Config upgrade available")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(theme.fg)
                                Text("Your config is version \(current); version \(latest) is available. Run `hermes config upgrade` to update.")
                                    .font(.caption)
                                    .foregroundStyle(theme.mutedFg)
                            }
                        }
                        .padding(.vertical, 4)
                        // PSF-02: upgrade banner row — match card background to
                        // gateway/platform rows so the banner sits in the same
                        // visual plane as the rest of the panel.
                        .listRowBackground(theme.card)
                    }
                }
                gatewaySection(status)
                platformsSection(status)
                serverSection(status)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.bg)
            .refreshable { await load() }
        }
        .navigationTitle("Gateway")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $pendingAction) { action in
            GatewayActionConfirmationSheet(
                action: action,
                confirm: {
                    pendingAction = nil
                    Task { await runAction(action) }
                },
                cancel: { pendingAction = nil }
            )
        }
    }

    // MARK: Sections

    /// Lifted section header matching the Skills panel treatment (audit SK2 /
    /// "align section header treatment"): footnote-semibold mutedFg with top
    /// padding, so every panel's section headers read consistently.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(theme.mutedFg)
            .textCase(nil)
            .padding(.top, 8)
    }

    @ViewBuilder
    private func gatewaySection(_ status: GatewayStatus) -> some View {
        // PSF-02: use theme.card for every row so the gateway section matches the
        // glass/card idiom of the other panels (PersonalityPicker, ModelPicker).
        Section {
            LabeledContent("State") {
                let badge = actionRunner.gatewayBadgeState(fallback: status)
                StatusBadge(state: badge.state, running: badge.running)
            }
            .listRowBackground(theme.card)
            if let active = status.activeSessions {
                LabeledContent("Active sessions", value: "\(active)")
                    .listRowBackground(theme.card)
            }
            if let pid = status.gatewayPid {
                LabeledContent("Process", value: "PID \(pid)")
                    .listRowBackground(theme.card)
            }
            if let reason = status.gatewayExitReason, !reason.isEmpty {
                LabeledContent("Exit reason", value: reason)
                    .listRowBackground(theme.card)
            }
            if let updated = PanelFormat.relative(fromISO: status.gatewayUpdatedAt) {
                LabeledContent("Updated", value: updated)
                    .listRowBackground(theme.card)
            }
            gatewayActionButtons
                .listRowBackground(theme.card)
            if actionRunner.isRunning || !actionRunner.progressLines.isEmpty {
                actionProgressRow
                    .listRowBackground(theme.card)
            }
            if let error = actionRunner.errorMessage {
                actionErrorRow(message: error)
                    .listRowBackground(theme.card)
            }
        } header: {
            sectionHeader("Gateway")
        }
    }

    private var gatewayActionButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { actionButtons }
            VStack(alignment: .leading, spacing: 10) { actionButtons }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var actionButtons: some View {
        ForEach(GatewayRecoveryAction.allCases) { action in
            Button(role: action.isDestructive ? .destructive : nil) {
                pendingAction = action
            } label: {
                Label(action.buttonTitle, systemImage: action.systemImage)
            }
            .buttonStyle(.bordered)
            .tint(action.isDestructive ? theme.destructive : theme.midground)
            .disabled(actionRunner.isRunning)
            .accessibilityHint(action.confirmationMessage)
        }
    }

    private var actionProgressRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if actionRunner.isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Action in progress")
                }
                Label(actionRunner.progressTitle, systemImage: "antenna.radiowaves.left.and.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.fg)
            }
            Text(actionRunner.connectionNotice)
                .font(.caption)
                .foregroundStyle(theme.statusWarn)
            if !actionRunner.progressLines.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(actionRunner.progressLines.suffix(5).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(theme.mutedFg)
                            .lineLimit(2)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 4)
    }

    private func actionErrorRow(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.statusError)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Action failed")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.fg)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(theme.mutedFg)
                }
            }
            if let failedAction = actionRunner.lastFailedAction {
                Button {
                    pendingAction = failedAction
                } label: {
                    Label("Retry \(failedAction.shortTitle)", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .tint(theme.midground)
                .disabled(actionRunner.isRunning)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func platformsSection(_ status: GatewayStatus) -> some View {
        // PSF-03: platform rows use theme.card to stay consistent with gateway section.
        Section {
            if status.platforms.isEmpty {
                Text("No platforms connected")
                    .font(.subheadline)
                    .foregroundStyle(theme.mutedFg)
                    .listRowBackground(theme.card)
            } else {
                ForEach(status.platforms) { platform in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label(platform.name.capitalized, systemImage: icon(for: platform.name))
                                .labelStyle(.titleAndIcon)
                            Spacer()
                            StatusBadge(state: platform.state, running: nil)
                        }
                        if let message = platform.errorMessage, !message.isEmpty {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(theme.destructive)
                        }
                    }
                    .padding(.vertical, 2)
                    .listRowBackground(theme.card)
                }
            }
        } header: {
            sectionHeader("Platforms")
        }
    }

    @ViewBuilder
    private func serverSection(_ status: GatewayStatus) -> some View {
        // PSF-03: server rows use theme.card, matching the gateway/platforms sections.
        Section {
            if let version = status.version, !version.isEmpty {
                LabeledContent("Version", value: version)
                    .listRowBackground(theme.card)
            }
            if let release = status.releaseDate, !release.isEmpty {
                LabeledContent("Released", value: release)
                    .listRowBackground(theme.card)
            }
            if let current = status.configVersion {
                if let latest = status.latestConfigVersion, current < latest {
                    LabeledContent("Config version") {
                        HStack(spacing: 4) {
                            Text("v\(current)")
                            Image(systemName: "arrow.right")
                                .imageScale(.small)
                            Text("v\(latest)")
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(theme.statusWarn)
                                .imageScale(.small)
                        }
                        .font(.caption)
                        .foregroundStyle(theme.mutedFg)
                    }
                    .listRowBackground(theme.card)
                } else {
                    LabeledContent("Config version", value: "v\(current)")
                        .listRowBackground(theme.card)
                }
            }
            if let auth = status.authRequired {
                LabeledContent("Auth gate", value: auth ? "On" : "Loopback only")
                    .listRowBackground(theme.card)
            }
            if !status.authProviders.isEmpty {
                LabeledContent("Auth via", value: status.authProviders.joined(separator: ", "))
                    .listRowBackground(theme.card)
            }
            if let home = status.hermesHome, !home.isEmpty {
                LabeledContent("Home") {
                    Text(home)
                        .font(.caption)
                        .foregroundStyle(theme.mutedFg)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                .listRowBackground(theme.card)
            }
        } header: {
            sectionHeader("Server")
        }
    }

    private func icon(for platform: String) -> String {
        switch platform.lowercased() {
        case "telegram": return "paperplane.fill"
        case "discord": return "bubble.left.and.bubble.right.fill"
        case "whatsapp": return "phone.fill"
        case "slack": return "number"
        default: return "antenna.radiowaves.left.and.right"
        }
    }

    // MARK: Actions

    private func load() async {
        if phase.value == nil { phase = .loading }
        do {
            phase = .loaded(try await control.gatewayStatus())
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func runAction(_ action: GatewayRecoveryAction) async {
        await actionRunner.perform(action)
        if actionRunner.errorMessage == nil {
            await load()
        }
    }
}

/// User-facing recovery actions backed by the dashboard's existing async action endpoints.
enum GatewayRecoveryAction: String, CaseIterable, Identifiable, Sendable {
    case restartGateway
    case updateHermes

    var id: String { rawValue }

    var statusName: String {
        switch self {
        case .restartGateway: return "gateway-restart"
        case .updateHermes: return "hermes-update"
        }
    }

    var shortTitle: String {
        switch self {
        case .restartGateway: return "Restart"
        case .updateHermes: return "Update"
        }
    }

    var buttonTitle: String {
        switch self {
        case .restartGateway: return "Restart Gateway"
        case .updateHermes: return "Update Hermes"
        }
    }

    var progressTitle: String {
        switch self {
        case .restartGateway: return "Restarting gateway"
        case .updateHermes: return "Updating Hermes"
        }
    }

    var systemImage: String {
        switch self {
        case .restartGateway: return "arrow.clockwise.circle.fill"
        case .updateHermes: return "arrow.down.circle.fill"
        }
    }

    var isDestructive: Bool { self == .restartGateway }

    var confirmationTitle: String {
        switch self {
        case .restartGateway: return "Restart gateway?"
        case .updateHermes: return "Update Hermes?"
        }
    }

    var confirmationMessage: String {
        switch self {
        case .restartGateway:
            return "The gateway will briefly go offline while it restarts. Active mobile connections may reconnect."
        case .updateHermes:
            return "Hermes will update on the host. The gateway may be unavailable while the update runs."
        }
    }
}

struct GatewayBadgeSnapshot: Equatable, Sendable {
    let state: String?
    let running: Bool?
}

@MainActor
final class GatewayActionRunner: ObservableObject {
    typealias StartAction = (GatewayRecoveryAction) async throws -> ActionResponse
    typealias FetchStatus = (String, Int) async throws -> ActionStatus
    typealias Sleep = (UInt64) async throws -> Void

    @Published private(set) var currentAction: GatewayRecoveryAction?
    @Published private(set) var isRunning = false
    @Published private(set) var progressLines: [String] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastFailedAction: GatewayRecoveryAction?

    private let startAction: StartAction
    private let fetchStatus: FetchStatus
    private let sleep: Sleep

    var progressTitle: String {
        currentAction?.progressTitle ?? lastFailedAction?.progressTitle ?? "Gateway action"
    }

    var connectionNotice: String {
        guard let currentAction else { return "Gateway state will refresh after the action finishes." }
        switch currentAction {
        case .restartGateway:
            return "Connection is expected to show reconnecting/offline while the gateway restarts."
        case .updateHermes:
            return "Connection may show reconnecting/offline while Hermes updates."
        }
    }

    convenience init(control: RestClient) {
        self.init(
            startAction: { action in
                switch action {
                case .restartGateway: return try await control.restartGateway()
                case .updateHermes: return try await control.updateHermes()
                }
            },
            fetchStatus: { name, lines in
                try await control.actionStatus(name: name, lines: lines)
            },
            sleep: { nanoseconds in
                try await Task.sleep(nanoseconds: nanoseconds)
            }
        )
    }

    init(startAction: @escaping StartAction, fetchStatus: @escaping FetchStatus, sleep: @escaping Sleep) {
        self.startAction = startAction
        self.fetchStatus = fetchStatus
        self.sleep = sleep
    }

    func gatewayBadgeState(fallback status: GatewayStatus) -> GatewayBadgeSnapshot {
        if isRunning {
            return GatewayBadgeSnapshot(state: "reconnecting", running: nil)
        }
        return GatewayBadgeSnapshot(state: status.gatewayState, running: status.gatewayRunning)
    }

    func perform(
        _ action: GatewayRecoveryAction,
        pollIntervalNanoseconds: UInt64 = 1_200_000_000,
        maxTransientFailures: Int = 50
    ) async {
        currentAction = action
        isRunning = true
        progressLines = []
        errorMessage = nil
        lastFailedAction = nil

        do {
            let response = try await startAction(action)
            let actionName = response.name.isEmpty ? action.statusName : response.name
            if response.ok == false {
                progressLines = response.message.map { [$0] } ?? []
                fail(action, message: response.message ?? response.error ?? "\(action.buttonTitle) did not start.")
                return
            }

            var transientFailures = 0
            while !Task.isCancelled {
                do {
                    let status = try await fetchStatus(actionName, 200)
                    progressLines = status.lines
                    transientFailures = 0
                    if !status.running {
                        if let exitCode = status.exitCode, exitCode != 0 {
                            fail(action, message: "\(action.buttonTitle) exited with code \(exitCode).")
                        } else {
                            finishSuccessfully()
                        }
                        return
                    }
                } catch {
                    transientFailures += 1
                    if progressLines.last != "Waiting for gateway to come back online…" {
                        progressLines.append("Waiting for gateway to come back online…")
                    }
                    if transientFailures >= maxTransientFailures {
                        throw error
                    }
                }
                try await sleep(pollIntervalNanoseconds)
            }
            fail(action, message: "\(action.buttonTitle) was cancelled.")
        } catch {
            fail(action, message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func finishSuccessfully() {
        isRunning = false
        currentAction = nil
        errorMessage = nil
        lastFailedAction = nil
    }

    private func fail(_ action: GatewayRecoveryAction, message: String) {
        isRunning = false
        currentAction = nil
        lastFailedAction = action
        errorMessage = message
    }
}

private struct GatewayActionConfirmationSheet: View {
    let action: GatewayRecoveryAction
    let confirm: () -> Void
    let cancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.hermesTheme) private var theme

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Label(action.confirmationTitle, systemImage: action.systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(action.isDestructive ? theme.destructive : theme.fg)
                Text(action.confirmationMessage)
                    .font(.subheadline)
                    .foregroundStyle(theme.mutedFg)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(role: action.isDestructive ? .destructive : nil) {
                    dismiss()
                    confirm()
                } label: {
                    Label(action.buttonTitle, systemImage: action.systemImage)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(action.isDestructive ? theme.destructive : theme.midground)
            }
            .padding(20)
            .background(theme.bg)
            .navigationTitle(action.shortTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                        cancel()
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

/// A capsule badge mapping a gateway/platform state string to a color + dot.
private struct StatusBadge: View {
    let state: String?
    /// When the dedicated `running` flag is known it overrides ambiguous states.
    let running: Bool?

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        Label(label, systemImage: "circle.fill")
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .imageScale(.small)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }

    private var normalized: String {
        (state ?? "").lowercased()
    }

    private var label: String {
        if let running, normalized.isEmpty {
            return running ? "Running" : "Stopped"
        }
        guard let state, !state.isEmpty else { return running == false ? "Stopped" : "Unknown" }
        return state.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private var color: Color {
        if running == false { return theme.statusError }
        switch normalized {
        case "running", "connected", "ready", "active", "ok":
            return theme.statusOK
        case "starting", "startup", "connecting", "reconnecting", "pending":
            return theme.statusWarn
        case "stopped", "failed", "startup_failed", "error", "disconnected", "offline":
            return theme.statusError
        default:
            return running == true ? theme.statusOK : theme.mutedFg
        }
    }
}
