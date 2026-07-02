import SwiftUI

/// The W3A-A **Devices** management list — a FULL NATIVE `List` of every paired
/// device (`GET /api/devices`), each row revocable behind a destructive
/// confirmation + a biometric gate, with the CURRENT device clearly marked and a
/// push to the read-only ``ApprovalAuditView``.
///
/// This view is reached ONLY from the Settings Devices section, which is itself
/// gated on `capabilities.devices == .available` — so on a stock hermes-agent it
/// never renders (the section is hidden) and the legacy shared token is
/// untouched. FULL NATIVE: system `List`/`Section`/`Button`/`Label`/
/// `LabeledContent`/`confirmationDialog` only; identity via tint
/// (`theme.destructive` for revoke, matching the Disconnect button).
///
/// SECRETS HYGIENE: a row shows the device name, platform, created/last-seen
/// dates, and the 8-char `token_prefix` hint — NEVER a full token (the list
/// response never carries one). Revoke sends only the non-secret `device_id`.
struct DevicesView: View {
    /// The REST client for the active connection (device or shared token — both
    /// accepted by a W3a server).
    let rest: RestClient
    /// The server URL the connection is configured against, used to resolve the
    /// recorded `device_id` for THIS device ("This device" marker) and to clear
    /// it if the user revokes the current device.
    let serverURL: String
    /// Injected biometric backend (the F2 ``BiometricAuthenticating`` seam). The
    /// app passes a live ``LAContextAuthenticator``; tests inject a stub.
    let authenticator: BiometricAuthenticating

    @Environment(ConnectionStore.self) private var connection
    @Environment(\.hermesTheme) private var theme

    @State private var devices: [PairedDevice] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var actionError: String?

    /// The device awaiting a revoke confirmation (drives the confirmationDialog).
    @State private var pendingRevoke: PairedDevice?
    /// The device id currently being revoked (disables its row while in flight).
    @State private var revokingId: String?
    /// The device whose detail sheet is presented (tapping a row, build-32 QA —
    /// rows previously looked tappable but did nothing).
    @State private var detailDevice: PairedDevice?

    var body: some View {
        List {
            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(theme.mutedFg)
                        .listRowBackground(theme.card)
                }
            } else {
                if let actionError {
                    Section {
                        Label(actionError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(theme.destructive)
                            .listRowBackground(theme.card)
                    }
                }
                devicesSection
                auditSection
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.bg)
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading && devices.isEmpty && loadError == nil {
                ProgressView()
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog(
            "Revoke this device?",
            isPresented: revokeDialogBinding,
            titleVisibility: .visible,
            presenting: pendingRevoke
        ) { device in
            Button("Revoke", role: .destructive) {
                Task { await revokeWithGate(device) }
            }
            Button("Cancel", role: .cancel) { pendingRevoke = nil }
        } message: { device in
            Text(Self.revokeMessage(device: device, isCurrent: isCurrentDevice(device)))
        }
        .sheet(item: $detailDevice) { device in
            NavigationStack {
                DeviceDetailSheet(
                    device: device,
                    isCurrent: isCurrentDevice(device),
                    onRevoke: {
                        detailDevice = nil
                        actionError = nil
                        pendingRevoke = device
                    }
                )
            }
            // \.hermesTheme does not inherit across a sheet presentation (see
            // ThemeEnvironment); re-inject the resolved palette value.
            .environment(\.hermesTheme, theme)
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var devicesSection: some View {
        Section {
            if devices.isEmpty && !isLoading {
                Label("No paired devices.", systemImage: "iphone.slash")
                    .foregroundStyle(theme.mutedFg)
                    .listRowBackground(theme.card)
            } else {
                ForEach(devices) { device in
                    deviceRow(device)
                        .listRowBackground(theme.card)
                }
            }
        } header: {
            Text("Paired Devices")
        } footer: {
            Text("Each paired device has its own token. Revoking one signs it out immediately and never affects your other devices.")
        }
    }

    @ViewBuilder
    private var auditSection: some View {
        Section {
            NavigationLink {
                ApprovalAuditView(rest: rest)
            } label: {
                Label("Approval Audit", systemImage: "checklist")
                    .foregroundStyle(theme.fg)
            }
            .listRowBackground(theme.card)
            .accessibilityIdentifier("devicesApprovalAudit")
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func deviceRow(_ device: PairedDevice) -> some View {
        let current = isCurrentDevice(device)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: Self.platformIcon(device.platform))
                    .foregroundStyle(theme.fg)
                    .accessibilityHidden(true)
                Text(device.deviceName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.fg)
                    .lineLimit(1)
                if current {
                    Text("This device")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.midground.contrastingForeground)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(theme.midground, in: Capsule())
                        .accessibilityIdentifier("devicesCurrentMarker")
                }
                Spacer(minLength: 8)
            }
            Text(Self.detailLine(device))
                .font(.footnote)
                .foregroundStyle(theme.mutedFg)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .opacity(revokingId == device.deviceId ? 0.4 : 1)
        // Whole row is tappable → detail sheet (build-32 QA: rows looked
        // tappable but did nothing). contentShape makes the padding tappable
        // too; coexists with the trailing swipe-to-revoke below.
        .contentShape(Rectangle())
        .onTapGesture { detailDevice = device }
        .accessibilityIdentifier("deviceRow-\(device.deviceId)")
        // Standard destructive swipe action — the system renders the red "Revoke"
        // button in the trailing gutter, consistent with iOS mail/contacts patterns.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                actionError = nil
                pendingRevoke = device
            } label: {
                Label(
                    current ? "Revoke (this device)" : "Revoke",
                    systemImage: "trash"
                )
            }
            .disabled(revokingId != nil)
            .accessibilityIdentifier("devicesRevoke-\(device.deviceId)")
        }
    }

    // MARK: - Load + revoke

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            devices = try await rest.devicesList()
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? "Couldn't load devices."
        }
        isLoading = false
    }

    /// Revoke `device` after a passing biometric gate. On a passing gate the
    /// `DELETE` fires; on success the row is removed locally. If the user revoked
    /// THIS device, the recorded `device_id` is cleared so the existing 401
    /// re-pair path fires on the next request (the server token is now invalid).
    private func revokeWithGate(_ device: PairedDevice) async {
        pendingRevoke = nil
        actionError = nil

        // Biometric gate before the destructive action (per contract).
        let result = await authenticator.evaluate(reason: Self.biometricReason(device: device))
        if case let .failure(message) = result {
            actionError = message
            return
        }

        revokingId = device.deviceId
        defer { revokingId = nil }
        do {
            _ = try await rest.revokeDevice(id: device.deviceId)
        } catch {
            actionError = (error as? LocalizedError)?.errorDescription ?? "Couldn't revoke this device."
            return
        }

        let wasCurrent = isCurrentDevice(device)
        devices.removeAll { $0.deviceId == device.deviceId }
        Self.applySuccessfulRevokeSideEffects(
            wasCurrent: wasCurrent,
            serverURL: serverURL,
            connection: connection
        )
    }

    // MARK: - Current-device resolution

    /// Whether `device` is the device this app instance is running on — matched by
    /// the recorded (non-secret) `device_id` for this server.
    private func isCurrentDevice(_ device: PairedDevice) -> Bool {
        Self.isCurrentDevice(device.deviceId, recordedDeviceId: DefaultsKeys.deviceId(server: serverURL))
    }

    private var revokeDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingRevoke != nil },
            set: { if !$0 { pendingRevoke = nil } }
        )
    }

    // MARK: - Pure helpers (unit-tested)

    /// Whether a row's `device_id` matches the recorded current-device id. A
    /// `nil`/empty recorded id (never auto-upgraded) marks NO row as current.
    static func isCurrentDevice(_ rowDeviceId: String, recordedDeviceId: String?) -> Bool {
        guard let recorded = recordedDeviceId, !recorded.isEmpty else { return false }
        return rowDeviceId == recorded
    }

    /// SF Symbol for a device's platform string.
    static func platformIcon(_ platform: String) -> String {
        switch platform.lowercased() {
        case "ios", "ipados": return "iphone"
        case "mac", "macos": return "laptopcomputer"
        default: return "desktopcomputer"
        }
    }

    /// The secondary detail line: "Last seen X · added Y · ab12cd34…".
    static func detailLine(_ device: PairedDevice) -> String {
        var parts: [String] = []
        if device.lastSeen > 0 {
            parts.append("Last seen \(relativeDate(device.lastSeen))")
        }
        if device.createdAt > 0 {
            parts.append("added \(relativeDate(device.createdAt))")
        }
        if !device.tokenPrefix.isEmpty {
            parts.append("\(device.tokenPrefix)…")
        }
        return parts.isEmpty ? device.platform : parts.joined(separator: " · ")
    }

    /// The confirmation-dialog message; stronger copy when revoking the current
    /// device (it will sign this device out and require a re-pair).
    static func revokeMessage(device: PairedDevice, isCurrent: Bool) -> String {
        if isCurrent {
            return "This is the device you're using. Revoking it signs you out immediately — you'll need to scan a new pairing code to reconnect."
        }
        return "“\(device.deviceName)” will be signed out immediately. This can't be undone."
    }

    /// The biometric prompt reason for a revoke.
    static func biometricReason(device: PairedDevice) -> String {
        "Confirm to revoke “\(device.deviceName)”."
    }

    /// Apply side effects after a clean revoke. For a self-revoke, `wasCurrent`
    /// is synchronous ground truth: route to re-pair immediately instead of
    /// waiting for the external-revocation reconnect debounce.
    static func applySuccessfulRevokeSideEffects(
        wasCurrent: Bool,
        serverURL: String,
        connection: ConnectionStore
    ) {
        guard wasCurrent else { return }
        // This device just revoked itself. Clear the recorded id so a re-scan
        // auto-upgrades to a FRESH device token. The Keychain still holds the
        // now-invalid device token; bootstrap/configure auth handling covers
        // relaunches, while the live UI routes to re-pair synchronously here.
        DefaultsKeys.setDeviceId(nil, server: serverURL)
        connection.requireRepairAfterCurrentDeviceRevoked()
    }

    /// Relative date for an epoch-seconds timestamp. Clamped to the past: the
    /// server stamps `last_seen` with ITS clock (and bumps it on the very
    /// request that loads this list), so cross-host clock skew rendered the
    /// active device as a future "in 3s" (R1 #78). Clamping to 1s ago (not 0)
    /// because the formatter renders a zero interval as the equally-odd
    /// "in 0 sec.".
    static func relativeDate(_ ts: Double) -> String {
        guard ts > 0 else { return "—" }
        let now = Date()
        let date = min(Date(timeIntervalSince1970: ts), now.addingTimeInterval(-1))
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

// MARK: - Device detail sheet

/// Read-only detail for one paired device, presented when its row is tapped
/// (build-32 QA: rows looked tappable but did nothing). Shows the non-secret
/// metadata — name, platform, scopes, last-seen, added, token prefix — and a
/// destructive Revoke action that hands back to the list's confirm + biometric
/// gate via `onRevoke` (the sheet itself never calls the network).
struct DeviceDetailSheet: View {
    let device: PairedDevice
    let isCurrent: Bool
    let onRevoke: () -> Void

    @Environment(\.hermesTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: DevicesView.platformIcon(device.platform))
                        .font(.title)
                        .foregroundStyle(theme.midground)
                        .frame(width: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.deviceName)
                            .font(.headline)
                            .foregroundStyle(theme.fg)
                        Text(device.platform.uppercased())
                            .font(.caption.weight(.medium))
                            .foregroundStyle(theme.mutedFg)
                    }
                    Spacer(minLength: 8)
                    if isCurrent {
                        Text("This device")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.midground.contrastingForeground)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(theme.midground, in: Capsule())
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(theme.card)

            Section("Access") {
                detailRow("Scopes", value: device.scopes.isEmpty
                    ? "approve"
                    : device.scopes.joined(separator: ", "))
            }
            .listRowBackground(theme.card)

            Section("Activity") {
                detailRow("Last seen", value: DevicesView.relativeDate(device.lastSeen))
                detailRow("Paired", value: DevicesView.relativeDate(device.createdAt))
                if !device.tokenPrefix.isEmpty {
                    detailRow("Token", value: "\(device.tokenPrefix)…", monospaced: true)
                }
            }
            .listRowBackground(theme.card)

            Section {
                Button(role: .destructive) {
                    onRevoke()
                } label: {
                    Label(
                        isCurrent ? "Revoke (this device)" : "Revoke device",
                        systemImage: "trash"
                    )
                    .foregroundStyle(theme.destructive)
                }
                .accessibilityIdentifier("deviceDetailRevoke")
            } footer: {
                Text("Revoking signs this device out immediately and never affects your other devices.")
            }
            .listRowBackground(theme.card)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.bg)
        .navigationTitle("Device")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    @ViewBuilder
    private func detailRow(_ label: String, value: String, monospaced: Bool = false) -> some View {
        HStack {
            Text(label).foregroundStyle(theme.mutedFg)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(theme.fg)
                .font(monospaced ? .body.monospaced() : .body)
                .multilineTextAlignment(.trailing)
        }
    }
}
