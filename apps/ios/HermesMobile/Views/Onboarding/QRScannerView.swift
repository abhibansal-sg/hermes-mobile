import AVFoundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Full-screen QR pairing scanner. Presented from ``WelcomeView``.
///
/// Lifecycle:
///   1. On appear, resolve camera permission (request if undetermined).
///   2. When authorized, show the live ``QRCameraView`` with a framing reticle
///      and a torch toggle.
///   3. On a scanned `hermesapp://pair?url=…&token=…` payload, parse the params
///      and call `ConnectionStore.configure`. On success the connection phase
///      flips to `.connected`, `RootView` re-renders out of the Welcome surface,
///      and this cover dismisses. On failure the message is shown and scanning
///      resumes (the user can re-aim).
///   4. Denied / restricted → a settings-prompt state with a path back.
///
/// The parse is intentionally permissive about the host (`pair`) but strict
/// about requiring both `url` and `token`, mirroring
/// `HermesURLRouter`'s pair route so a scan and a tapped link behave identically.
struct QRScannerView: View {
    @Environment(ConnectionStore.self) private var connection
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.hermesTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var permission: CameraPermission.Status = .undetermined
    @State private var torchOn = false
    @State private var isConnecting = false
    /// A user-facing error (camera config failure, bad code, or a failed
    /// `configure`). Shown as a banner; scanning continues underneath.
    @State private var errorText: String?
    /// Bumped to force a fresh `QRCameraView` (and thus re-arm the one-shot scan
    /// latch) after a failed configure so the user can scan again.
    @State private var scannerGeneration = 0
    /// Holds the in-flight pairing poll so it can be cancelled on dismiss or
    /// re-scan — prevents an orphaned poll writing to a dismissed view. [Inc2 fix]
    @State private var connectTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            content

            overlayChrome
        }
        .task {
            permission = await CameraPermission.request()
        }
        .onDisappear { connectTask?.cancel() }
    }

    // MARK: - Content by permission state

    @ViewBuilder
    private var content: some View {
        switch permission {
        case .authorized:
            cameraSurface
        case .denied:
            deniedState
        case .undetermined:
            // Brief: the .task is resolving permission. Show a neutral spinner.
            ProgressView()
                .tint(.white)
                .accessibilityLabel("Checking camera permission")
        }
    }

    private var cameraSurface: some View {
        QRCameraView(
            onScan: handleScan,
            onError: { message in errorText = message },
            torchOn: torchOn
        )
        .id(scannerGeneration)
        .ignoresSafeArea()
    }

    private var deniedState: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.largeTitle)
                .foregroundStyle(.white.opacity(0.7))
            Text("Camera access needed")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
            Text("Allow Hermes to use the camera in Settings to scan a pairing code, or enter your server details manually.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(theme.midground.contrastingForeground)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(theme.midground, in: Capsule())
        }
        .padding()
        .accessibilityElement(children: .combine)
    }

    // MARK: - Chrome (reticle, top bar, banners)

    private var overlayChrome: some View {
        VStack {
            topBar

            Spacer()

            if permission == .authorized {
                reticle
            }

            Spacer()

            if let errorText {
                banner(text: errorText, isError: true)
            } else if isConnecting {
                banner(text: "Connecting…", isError: false)
            } else if permission == .authorized {
                banner(text: "Point at the QR code shown by hermes mobile-pair", isError: false)
            }
        }
        .padding(20)
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .accessibilityLabel("Cancel")

            Spacer()

            if permission == .authorized {
                Button {
                    torchOn.toggle()
                } label: {
                    Image(systemName: torchOn ? "bolt.fill" : "bolt.slash.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(torchOn ? theme.midground : .white)
                        .frame(width: 40, height: 40)
                        .background(.black.opacity(0.4), in: Circle())
                }
                .accessibilityLabel(torchOn ? "Turn off torch" : "Turn on torch")
            }
        }
    }

    private var reticle: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(.white.opacity(0.9), lineWidth: 3)
            .frame(width: 240, height: 240)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(theme.midground, lineWidth: 1)
                    .padding(2)
            )
            // ESC-05: fade + scale the reticle in when the camera surface
            // appears so the framing guide feels intentional rather than
            // suddenly rendered.
            .transition(.scale(scale: 0.92).combined(with: .opacity))
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: permission)
            .accessibilityHidden(true)
    }

    private func banner(text: String, isError: Bool) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                (isError ? theme.statusError : Color.black.opacity(0.55)),
                in: Capsule()
            )
            .frame(maxWidth: .infinity)
    }

    // MARK: - Scan handling

    private func handleScan(_ payload: String) {
        guard !isConnecting else { return }

        // Shared v1/v2 parse (HermesURLRouter): a v1 payload yields a shared
        // pairing (auto-upgrade swaps to a device token after connect on a W3a
        // server); a v2 `kind=device` payload carries the device token + its
        // `device_id`, which we record so no auto-upgrade fires.
        guard let parsed = HermesURLRouter.parsePairPayload(payload) else {
            errorText = "That QR code isn't a Hermes pairing code."
            // Re-arm the scanner so the user can try a different code.
            reArmAfterFailure()
            return
        }

        // ESC-A11Y: announce a successful scan to VoiceOver users before the
        // async configure begins, so users who cannot see the connecting banner
        // immediately know the code was recognised.
        UIAccessibility.post(notification: .announcement, argument: "QR code scanned. Connecting…")

        errorText = nil
        isConnecting = true
        connectTask?.cancel()
        connectTask = Task {
            // Inc 2 (Follow-up A): route through applyPair so in-app QR scans
            // tag `.sharedDashboard` (and v2 device payloads keep their existing
            // `.sharedDashboard` tag too). Previously this called configure()
            // directly, which skipped the mode-tagging in applyPair and left the
            // connection in whatever mode was last persisted. applyPair sets the
            // mode BEFORE configure() so the transport picks the right Host header.
            //
            // applyPair itself fires a Task, so we cannot await it to learn the
            // result. Instead we observe the connection phase: on a first-run scan
            // (connection.rest == nil) applyPair calls configure() immediately —
            // we watch for the phase to leave .connecting/.needsSetup.
            HermesURLRouter.applyPair(parsed, connection: connection)

            // Poll the phase briefly for up to 30 s — applyPair's inner Task
            // calls configure() which is async; phase transitions to .hydrating /
            // .connected on success or .offline / .needsSetup on failure.
            let deadline = ContinuousClock.now + .seconds(30)
            var succeeded = false
            var errorMessage: String? = nil
            phaseWatch: while ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
                switch connection.phase {
                case .hydrating, .connected:
                    succeeded = true
                    break phaseWatch
                case .offline(let msg):
                    errorMessage = msg
                    break phaseWatch
                case .needsSetup:
                    errorMessage = "Connection failed. Try scanning again."
                    break phaseWatch
                case .connecting, .reconnecting:
                    continue phaseWatch
                }
            }

            if Task.isCancelled { return }
            isConnecting = false
            if succeeded {
                // ESC-04: success haptic — confirms the pairing landed before the
                // view transitions away. `.notificationOccurred(.success)` is the
                // correct feedback type for a completed async operation.
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                // Phase flipped to .hydrating/.connected; RootView swaps away from Welcome.
                dismiss()
            } else {
                errorText = errorMessage ?? "Connection timed out. Try again."
                reArmAfterFailure()
            }
        }
    }

    /// Bump the scanner generation so a fresh `QRCameraView` is built and its
    /// one-shot latch resets, allowing another scan after a failure.
    private func reArmAfterFailure() {
        scannerGeneration += 1
    }
}
