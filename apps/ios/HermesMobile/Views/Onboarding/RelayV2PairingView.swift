import SwiftUI
import UserNotifications
import UIKit

/// Explicit HRP/2 enrollment surface. Legacy gateway pairing never enters this
/// view, so a failed secure-relay enrollment cannot silently downgrade.
@MainActor
struct RelayV2PairingView: View {
    enum Deployment: String, CaseIterable, Identifiable {
        case hosted
        case selfHosted = "self_hosted"
        var id: String { rawValue }
        var label: String { self == .hosted ? "Hosted" : "Self-hosted" }
    }

    @Environment(ConnectionStore.self) private var connection
    @Environment(\.hermesTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @StateObject private var coordinator: RelayV2PairingCoordinator
    @State private var offer: RelayV2PairingOffer?
    @State private var deployment: Deployment = .hosted
    @State private var notificationsEnabled = true
    @State private var deviceName = UIDevice.current.name
    @State private var verificationCode: String?
    @State private var errorText: String?
    @State private var isPreparing = false
    @State private var pollTask: Task<Void, Never>?

    init(offer: RelayV2PairingOffer?) {
        _offer = State(initialValue: offer)
        _coordinator = StateObject(
            wrappedValue: RelayV2PairingCoordinator(transport: RelayV2HTTPPairingTransport())
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                if verificationCode == nil {
                    setupSection
                } else {
                    verificationSection
                }
                if let errorText {
                    Section {
                        Text(errorText)
                            .foregroundStyle(theme.destructive)
                            .accessibilityIdentifier("relayV2PairingError")
                        Button("Retry") { beginOrResume() }
                            .accessibilityIdentifier("relayV2PairingRetry")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.bg)
            .navigationTitle("Secure Relay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        pollTask?.cancel()
                        coordinator.cancel()
                        dismiss()
                    }
                }
            }
            .onAppear { restoreIfNeeded() }
            .onDisappear { pollTask?.cancel() }
        }
    }

    private var setupSection: some View {
        Group {
            Section("Relay deployment") {
                Picker("Deployment", selection: $deployment) {
                    ForEach(Deployment.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("relayV2DeploymentPicker")

                TextField("Device name", text: $deviceName)
                    .accessibilityIdentifier("relayV2DeviceName")

                if deployment == .hosted {
                    Toggle("Enable encrypted notifications", isOn: $notificationsEnabled)
                        .accessibilityIdentifier("relayV2NotificationsToggle")
                } else {
                    Text("The operator-activated relay is used directly. No credential is sent to the hosted Push Gateway.")
                        .font(.footnote)
                        .foregroundStyle(theme.mutedFg)
                }
            }

            Section {
                Button {
                    beginOrResume()
                } label: {
                    HStack {
                        Label("Start secure pairing", systemImage: "lock.shield")
                        Spacer()
                        if isPreparing { ProgressView() }
                    }
                }
                .disabled(isPreparing || deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("relayV2StartPairing")
            } footer: {
                Text("HRP/2 creates device-only keys. Gateway tokens and pairing secrets are never stored in a URL.")
            }
        }
    }

    private var verificationSection: some View {
        Section("Confirm on your computer") {
            Text(verificationCode ?? "")
                .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                .frame(maxWidth: .infinity)
                .textSelection(.enabled)
                .accessibilityIdentifier("relayV2VerificationCode")
            Text("Confirm this same code in Hermes. This screen will finish automatically after the Agent accepts the device.")
                .font(.footnote)
                .foregroundStyle(theme.mutedFg)
            HStack {
                ProgressView()
                Text("Waiting for confirmation…")
            }
            .accessibilityIdentifier("relayV2AwaitingConfirmation")
            Button("Check again") { startPolling() }
                .accessibilityIdentifier("relayV2CheckAgain")
        }
    }

    private func restoreIfNeeded() {
        if let enrollment = coordinator.pendingEnrollment,
           offer == enrollment.offer {
            deployment = .hosted
            notificationsEnabled = enrollment.kind == .push
            deviceName = enrollment.deviceName
        }
        switch coordinator.state {
        case .awaitingAccept(let code):
            verificationCode = code
            startPolling()
        case .confirming:
            startPolling()
        default:
            break
        }
    }

    private func beginOrResume() {
        errorText = nil
        if verificationCode != nil || offer == nil {
            startPolling()
            return
        }
        guard let offer else {
            errorText = "The saved pairing transaction is unavailable. Scan a new code."
            return
        }
        isPreparing = true
        Task {
            do {
                let trimmedName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
                let code: String
                if deployment == .hosted {
                    // A saved preflight owns the exact request tuple. In
                    // particular, recovery must not block on APNs delivering the
                    // same token again before it can replay the durable request.
                    let restored = coordinator.pendingEnrollment.flatMap {
                        $0.offer == offer ? $0 : nil
                    }
                    let wantsPush = restored.map { $0.kind == .push }
                        ?? notificationsEnabled
                    let environment = restored?.environment
                        ?? RelayV2APNsEnvironment(
                            rawValue: PushTokenPoster.apnsEnvironment
                        )
                        ?? .sandbox
                    let token: Data?
                    if let restored {
                        token = restored.apnsToken
                    } else if wantsPush {
                        PushRegistrar.shared.setEnabled(true)
                        guard let value = await Self.awaitAPNsToken() else {
                            throw RelayV2ProtocolError.transport(
                                "APNs did not provide a device token. Turn notifications off to pair without push, or try again."
                            )
                        }
                        token = value
                    } else {
                        token = nil
                    }
                    let client = try RelayV2PushRegistrationClient(baseURL: offer.hubURL)
                    code = try await coordinator.enrollHostedAndBegin(
                        offer: offer,
                        deviceName: restored?.deviceName ?? trimmedName,
                        notificationsEnabled: wantsPush,
                        apnsToken: token,
                        environment: environment,
                        bundleID: restored?.bundleID
                            ?? Bundle.main.bundleIdentifier
                            ?? "ai.hermes.app",
                        enrollmentTransport: client
                    )
                } else {
                    code = try await coordinator.begin(
                        offer: offer,
                        deviceName: trimmedName,
                        pushBindToken: nil,
                        hubActivationToken: nil
                    )
                }
                verificationCode = code
                isPreparing = false
                startPolling()
            } catch {
                isPreparing = false
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        errorText = nil
        pollTask = Task {
            while !Task.isCancelled {
                do {
                    if try await coordinator.pollAndConfirm() != nil {
                        await connection.bootstrap()
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        dismiss()
                        return
                    }
                } catch {
                    if Task.isCancelled { return }
                    errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private static func awaitAPNsToken() async -> Data? {
        for _ in 0..<100 {
            if let value = KeychainService.loadAPNsDeviceToken(),
               let data = decodeHex(value), !data.isEmpty {
                return data
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private static func decodeHex(_ value: String) -> Data? {
        guard value.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}
