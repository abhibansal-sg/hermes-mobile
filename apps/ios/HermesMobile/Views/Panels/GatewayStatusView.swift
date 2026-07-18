import SwiftUI

/// Gateway health panel: version, gateway run-state, per-platform connection
/// states (telegram, etc.), and the active-session count, from `GET /api/status`.
/// Pull-to-refresh re-fetches. Recovery actions are confirmation-gated and
/// surface honest in-flight/offline/progress states instead of stale "connected".
struct GatewayStatusView: View {
    let control: RestClient
    /// Optional for compatibility with previews/tests that only exercise the
    /// REST panel. Production passes the app's live connection store so the
    /// two kinds of gateway truth are shown separately.
    let connection: ConnectionStore?

    @Environment(\.hermesTheme) private var theme

    @State private var phase: PanelPhase<GatewayStatus> = .loading
    @StateObject private var actionRunner: GatewayActionRunner
    @State private var pendingAction: GatewayRecoveryAction?

    init(control: RestClient, connection: ConnectionStore? = nil) {
        self.control = control
        self.connection = connection
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

    static func phoneBadgeState(
        for readiness: ConnectionStore.TransportReadiness
    ) -> GatewayBadgeSnapshot {
        switch readiness {
        case .unconfigured:
            return GatewayBadgeSnapshot(state: "not configured", running: false)
        case .connecting:
            return GatewayBadgeSnapshot(state: "connecting", running: nil)
        case .ready:
            return GatewayBadgeSnapshot(state: "ready", running: true)
        case .unavailable:
            return GatewayBadgeSnapshot(state: "offline", running: false)
        case .reauthRequired:
            return GatewayBadgeSnapshot(state: "reauth required", running: false)
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
    case drainGateway
    case cancelDrain

    var id: String { rawValue }

    var statusName: String {
        switch self {
        case .restartGateway: return "gateway-restart"
        case .updateHermes: return "hermes-update"
        // Drain/cancel write a marker file synchronously — there is NO
        // background action to poll, so these status names are unused by
        // the action-status poller. They exist for symmetry / logging.
        case .drainGateway: return "gateway-drain"
        case .cancelDrain: return "gateway-drain-cancel"
        }
    }

    var shortTitle: String {
        switch self {
        case .restartGateway: return "Restart"
        case .updateHermes: return "Update"
        case .drainGateway: return "Drain"
        case .cancelDrain: return "Cancel Drain"
        }
    }

    var buttonTitle: String {
        switch self {
        case .restartGateway: return "Restart Gateway"
        case .updateHermes: return "Update Hermes"
        case .drainGateway: return "Drain Gateway"
        case .cancelDrain: return "Cancel Drain"
        }
    }

    var progressTitle: String {
        switch self {
        case .restartGateway: return "Restarting gateway"
        case .updateHermes: return "Updating Hermes"
        case .drainGateway: return "Draining gateway"
        case .cancelDrain: return "Cancelling drain"
        }
    }

    var systemImage: String {
        switch self {
        case .restartGateway: return "arrow.clockwise.circle.fill"
        case .updateHermes: return "arrow.down.circle.fill"
        case .drainGateway: return "stop.circle.fill"
        case .cancelDrain: return "play.circle.fill"
        }
    }

    /// Restart is destructive (brief offline). Drain/cancel are reversible
    /// operational toggles, not destructive — the gateway stays up and
    /// in-flight turns finish. They use the midground tint, not destructive.
    var isDestructive: Bool { self == .restartGateway }

    /// Whether this action spawns a pollable background subprocess (restart /
    /// update) or completes synchronously on the POST (drain / cancel-drain).
    /// The runner uses this to decide whether to enter the action-status poll
    /// loop or finish immediately on the POST response.
    var isImmediate: Bool {
        switch self {
        case .drainGateway, .cancelDrain: return true
        case .restartGateway, .updateHermes: return false
        }
    }

    var confirmationTitle: String {
        switch self {
        case .restartGateway: return "Restart gateway?"
        case .updateHermes: return "Update Hermes?"
        case .drainGateway: return "Drain gateway?"
        case .cancelDrain: return "Cancel drain?"
        }
    }

    var confirmationMessage: String {
        switch self {
        case .restartGateway:
            return "The gateway will briefly go offline while it restarts. Active mobile connections may reconnect."
        case .updateHermes:
            return "Hermes will update on the host. The gateway may be unavailable while the update runs."
        case .drainGateway:
            return "The gateway will stop accepting NEW turns. Any turn already in flight will finish normally. You can cancel the drain to re-open the gateway. Existing connections are not dropped."
        case .cancelDrain:
            return "The gateway will resume accepting new turns immediately."
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
    typealias StartDrainAction = (GatewayRecoveryAction) async throws -> DrainResponse
    typealias FetchStatus = (String, Int) async throws -> ActionStatus
    typealias Sleep = (UInt64) async throws -> Void

    @Published private(set) var currentAction: GatewayRecoveryAction?
    @Published private(set) var isRunning = false
    @Published private(set) var progressLines: [String] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastFailedAction: GatewayRecoveryAction?

    private let startAction: StartAction
    private let startDrainAction: StartDrainAction?
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
        case .drainGateway:
            return "The gateway stays up — in-flight turns finish, new turns are refused."
        case .cancelDrain:
            return "The gateway is resuming normal operation."
        }
    }

    convenience init(control: RestClient) {
        self.init(
            startAction: { action in
                switch action {
                case .restartGateway: return try await control.restartGateway()
                case .updateHermes: return try await control.updateHermes()
                // Drain/cancel go through startDrainAction, not here. Returning
                // a failure here is unreachable because perform() short-circuits
                // immediate actions before calling startAction.
                case .drainGateway, .cancelDrain:
                    return ActionResponse(ok: false, pid: nil, name: action.statusName,
                                          error: "drain-not-pollable", message: nil)
                }
            },
            startDrainAction: { action in
                let drainDirection: GatewayDrainAction = (action == .drainGateway) ? .drain : .cancel
                return try await control.drainGateway(action: drainDirection)
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
        self.startDrainAction = nil
        self.fetchStatus = fetchStatus
        self.sleep = sleep
    }

    /// Inject an immediate (non-pollable) drain action for tests.
    init(startAction: @escaping StartAction,
         startDrainAction: @escaping StartDrainAction,
         fetchStatus: @escaping FetchStatus,
         sleep: @escaping Sleep) {
        self.startAction = startAction
        self.startDrainAction = startDrainAction
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

        // Immediate (marker-write) actions: the POST writes/removes the drain
        // marker synchronously — there is NO background subprocess to poll, so
        // finish (or fail) on the POST response and do NOT enter the poll loop.
        if action.isImmediate {
            await performImmediate(action)
            return
        }

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

    /// Immediate (non-pollable) action path: drain begin / cancel.
    ///
    /// The POST writes/removes the drain marker synchronously — the gateway's
    /// file-watcher flips state within ~1s. There is NO background subprocess
    /// to poll, so we finish on the POST response: ok → success with an honest
    /// progress line; ok==false or a thrown error → explicit failure (never a
    /// silent no-op). Falls back to the pollable `startAction` closure when no
    /// drain-specific closure is wired (defensive — the production init always
    /// provides one).
    private func performImmediate(_ action: GatewayRecoveryAction) async {
        do {
            let response: DrainResponse
            if let startDrainAction {
                response = try await startDrainAction(action)
            } else {
                // No drain closure wired — surface honestly instead of faking ok.
                fail(action, message: "\(action.buttonTitle) is not available in this configuration.")
                return
            }
            if response.ok {
                progressLines = [immediateSummary(for: action, response: response)]
                finishSuccessfully()
            } else {
                // Prefer the human-readable message over the machine error code.
                let detail = response.message ?? response.error ?? "\(action.buttonTitle) was rejected by the gateway."
                progressLines = response.message.map { [$0] } ?? []
                fail(action, message: detail)
            }
        } catch {
            fail(action, message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// One-line truthful summary of the immediate-action result for the
    /// progress row (shown transiently before the panel refreshes).
    private func immediateSummary(for action: GatewayRecoveryAction, response: DrainResponse) -> String {
        switch action {
        case .drainGateway:
            if response.draining == true {
                return "Drain requested — gateway is refusing new turns."
            }
            return "Drain requested."
        case .cancelDrain:
            if response.wasDraining == true {
                return "Drain cancelled — gateway is resuming new turns."
            }
            return "Cancel requested (gateway was not draining)."
        case .restartGateway, .updateHermes:
            return action.progressTitle
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
