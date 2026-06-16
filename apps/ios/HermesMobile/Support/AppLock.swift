import LocalAuthentication
import SwiftUI

/// Biometric / device-passcode gate for the app.
///
/// When the user has enabled the lock (UserDefaults `hermes.appLockEnabled`),
/// the app content is covered by a blurred overlay and a Face ID / Touch ID
/// prompt is presented:
///
/// * once at launch, and
/// * again whenever the app returns to the foreground after having been in the
///   background for at least ``foregroundGracePeriod`` (5 minutes).
///
/// Re-foregrounding sooner than that does **not** re-prompt, so flipping out to
/// the share sheet, the camera, or a quick reply notification stays frictionless.
///
/// The store is `@Observable`/`@MainActor` and holds no back-references: the app
/// drives it from scene-phase changes (see `integrationNotes`) and reads
/// ``isLocked`` to decide whether to show ``AppLockOverlay``. `LocalAuthentication`
/// is a first-party framework; no UI is owned here beyond the overlay, whose
/// toggle lives in `SettingsSheet`.
@MainActor
@Observable
final class AppLock {
    /// Whether the protected content should currently be hidden behind the lock
    /// overlay. `true` while a prompt is pending or after a failed/cancelled
    /// authentication; `false` once the user has authenticated (or the lock is
    /// disabled entirely).
    private(set) var isLocked: Bool

    /// True while a biometric prompt is actually on screen. Used by the overlay
    /// to avoid stacking a second prompt (e.g. a rapid scene-phase bounce) and to
    /// gate its manual "Unlock" button.
    private(set) var isAuthenticating: Bool = false

    /// The last authentication failure message, surfaced by the overlay so the
    /// user understands why content is still hidden (e.g. "Face ID not
    /// recognised"). Cleared on the next attempt and on success.
    private(set) var lastError: String?

    /// Persisted opt-in flag. The toggle in `SettingsSheet` writes through
    /// ``setEnabled(_:)`` rather than touching `UserDefaults` directly so the
    /// in-memory lock state stays consistent with the preference.
    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKeys.appLockEnabled)
    }

    /// Time the app must have spent backgrounded before a re-foreground re-locks.
    static let foregroundGracePeriod: TimeInterval = 5 * 60

    /// Wall-clock time the app last resigned active, or `nil` if it has been
    /// continuously active. Compared against ``foregroundGracePeriod`` on the next
    /// activation to decide whether to re-lock.
    private var backgroundedAt: Date?

    /// Injectable authenticator so the gate can be unit-tested without a real
    /// `LAContext` (XCTest can't satisfy a biometric prompt). Production uses the
    /// default `LAContext`-backed implementation.
    private let authenticator: BiometricAuthenticating

    /// A short reason string shown in the system biometric sheet.
    private static let reason = "Unlock Hermes"

    /// - Parameter authenticator: biometric backend; defaults to the live
    ///   `LAContext` implementation. Tests inject a stub.
    init(authenticator: BiometricAuthenticating = LAContextAuthenticator()) {
        self.authenticator = authenticator
        // Start locked iff the feature is on, so launch shows the overlay before
        // `authenticateAtLaunch()` has a chance to run.
        self.isLocked = UserDefaults.standard.bool(forKey: DefaultsKeys.appLockEnabled)
    }

    // MARK: - Preference

    /// Enable or disable the lock from settings.
    ///
    /// Turning it **on** immediately locks and prompts (so the user proves they
    /// can get back in before they rely on it). Turning it **off** unlocks and
    /// clears any pending state.
    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: DefaultsKeys.appLockEnabled)
        if enabled {
            isLocked = true
            backgroundedAt = nil
            authenticate()
        } else {
            isLocked = false
            isAuthenticating = false
            lastError = nil
            backgroundedAt = nil
        }
    }

    // MARK: - Lifecycle hooks

    /// Call once at launch (e.g. from a `.task` on the root view). Prompts if the
    /// lock is enabled; a no-op otherwise.
    func authenticateAtLaunch() {
        guard isEnabled else {
            isLocked = false
            return
        }
        isLocked = true
        authenticate()
    }

    /// Drive the lock from the app's scene phase.
    ///
    /// `.background` / `.inactive` records the moment we left the foreground.
    /// `.active` re-locks (and prompts) only when more than
    /// ``foregroundGracePeriod`` has elapsed since then.
    func handleScenePhase(_ scenePhase: ScenePhase) {
        guard isEnabled else { return }

        switch scenePhase {
        case .background, .inactive:
            // Record only the first transition out of active; a later `.inactive`
            // while already backgrounded must not reset the clock.
            if backgroundedAt == nil {
                backgroundedAt = Date()
            }
        case .active:
            defer { backgroundedAt = nil }
            // Already locked (cold launch, or a prior failed prompt) → just make
            // sure a prompt is in flight.
            if isLocked {
                if !isAuthenticating { authenticate() }
                return
            }
            if let leftAt = backgroundedAt,
               Date().timeIntervalSince(leftAt) >= Self.foregroundGracePeriod {
                isLocked = true
                authenticate()
            }
        @unknown default:
            break
        }
    }

    /// Re-attempt authentication, e.g. from the overlay's "Unlock" button after a
    /// cancellation. Ignored while a prompt is already on screen.
    func retry() {
        guard isEnabled, isLocked, !isAuthenticating else { return }
        authenticate()
    }

    // MARK: - Authentication

    /// Present the biometric / passcode prompt and resolve the lock on success.
    private func authenticate() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        lastError = nil

        Task { [authenticator] in
            let result = await authenticator.evaluate(reason: Self.reason)
            self.isAuthenticating = false
            switch result {
            case .success:
                self.isLocked = false
                self.lastError = nil
            case .failure(let message):
                // Stay locked; surface why so the overlay can offer a retry.
                self.isLocked = true
                self.lastError = message
            }
        }
    }
}

// MARK: - Biometric backend

/// Outcome of a biometric / passcode evaluation, normalised to a `Sendable`
/// value so it can cross the actor boundary back to the `@MainActor` store.
enum BiometricResult: Sendable {
    case success
    /// Authentication did not complete (failed, cancelled, unavailable). The
    /// string is a user-facing explanation.
    case failure(String)
}

/// Seam over `LAContext` so ``AppLock`` can be exercised in tests.
protocol BiometricAuthenticating: Sendable {
    /// Evaluate device-owner authentication, returning a normalised result.
    func evaluate(reason: String) async -> BiometricResult
}

/// Production `BiometricAuthenticating` backed by `LAContext`.
///
/// Uses `.deviceOwnerAuthentication`, which falls back to the device passcode
/// when biometrics are unavailable or locked out — so the user is never
/// permanently shut out of their own app on a device without Face ID enrolment.
struct LAContextAuthenticator: BiometricAuthenticating {
    func evaluate(reason: String) async -> BiometricResult {
        let context = LAContext()
        context.localizedFallbackTitle = "Enter Passcode"

        // If the device has no biometrics *and* no passcode, there is nothing to
        // evaluate — treat as unlocked rather than trapping the user behind a
        // gate that can never be satisfied.
        var policyError: NSError?
        let policy: LAPolicy = .deviceOwnerAuthentication
        guard context.canEvaluatePolicy(policy, error: &policyError) else {
            if let policyError, policyError.code == LAError.passcodeNotSet.rawValue {
                return .success
            }
            return .failure(policyError?.localizedDescription ?? "Authentication unavailable.")
        }

        do {
            let ok = try await context.evaluatePolicy(policy, localizedReason: reason)
            return ok ? .success : .failure("Authentication failed.")
        } catch let error as LAError {
            return .failure(Self.message(for: error))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func message(for error: LAError) -> String {
        switch error.code {
        case .userCancel, .appCancel, .systemCancel:
            return "Authentication cancelled."
        case .userFallback:
            return "Enter your passcode to continue."
        case .authenticationFailed:
            return "Face ID / Touch ID not recognised."
        case .biometryLockout:
            return "Biometrics locked out — enter your passcode."
        default:
            return error.localizedDescription
        }
    }
}

// MARK: - Biometry label helpers

extension AppLock {
    /// SF Symbol name for the device's enrolled biometric type.
    /// Used by the lock overlay and the Settings toggles for a correct icon.
    static var biometricSystemImage: String {
        switch biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        default: return "lock.shield"
        }
    }

    /// Human label for the device's enrolled biometric type.
    /// Returns "Face ID", "Touch ID", "Optic ID", or "Biometrics" as a fallback.
    static var biometricLabel: String {
        switch biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Biometrics"
        }
    }

    /// The current `LABiometryType` probed from a fresh `LAContext`.
    /// A probe is needed to populate `biometryType` after calling
    /// `canEvaluatePolicy`; callers that only need the label should use
    /// ``biometricLabel`` / ``biometricSystemImage`` directly.
    private static var biometryType: LABiometryType {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        return context.biometryType
    }
}

// MARK: - Overlay

/// Full-bleed cover shown while ``AppLock/isLocked`` is `true`.
///
/// Blurs whatever sits behind it (the app applies this above its content) and
/// offers a manual unlock affordance when an attempt was cancelled. Designed to
/// be placed in an `.overlay` on the root view, gated on `appLock.isLocked`.
struct AppLockOverlay: View {
    @Environment(AppLock.self) private var appLock
    @Environment(ThemeStore.self) private var themeStore

    /// Dynamic-Type-scaled lock-glyph size (base value preserves the default-size
    /// layout; grows with Larger Text).
    @ScaledMetric(relativeTo: .largeTitle) private var lockGlyphSize: CGFloat = 44

    var body: some View {
        let theme = themeStore.current
        ZStack {
            // G2: an opaque themed surface (not `.ultraThinMaterial`, which renders
            // grey frosted glass over dark themes) so the content underneath is not
            // legible and the scrim matches the active palette.
            Rectangle()
                .fill(theme.bg)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: lockGlyphSize, weight: .semibold))
                    .foregroundStyle(theme.mutedFg)
                    .accessibilityHidden(true)

                Text("Hermes is locked")
                    .font(.headline)
                    .foregroundStyle(theme.fg)

                if let error = appLock.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(theme.mutedFg)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                if !appLock.isAuthenticating {
                    Button {
                        appLock.retry()
                    } label: {
                        Label("Unlock", systemImage: AppLock.biometricSystemImage)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.midground)
                }
            }
            .padding()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hermes is locked. Authenticate to continue.")
    }
}
