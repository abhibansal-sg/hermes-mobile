import SwiftUI

/// Gateway health panel: version, gateway run-state, per-platform connection
/// states (telegram, etc.), and the active-session count, from `GET /api/status`.
/// Pull-to-refresh re-fetches. Read-only.
struct GatewayStatusView: View {
    let control: RestClient

    @Environment(\.hermesTheme) private var theme

    @State private var phase: PanelPhase<GatewayStatus> = .loading

    init(control: RestClient) {
        self.control = control
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
                StatusBadge(state: status.gatewayState, running: status.gatewayRunning)
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
        } header: {
            sectionHeader("Gateway")
        }
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
        case "stopped", "failed", "startup_failed", "error", "disconnected":
            return theme.statusError
        default:
            return running == true ? theme.statusOK : theme.mutedFg
        }
    }
}
