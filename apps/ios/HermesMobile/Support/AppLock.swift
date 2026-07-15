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

    /// Process-local snapshot privacy boundary. Unlike ``isLocked``, this is
    /// independent of the App Lock preference and never controls authentication.
    /// It is raised synchronously as the scene resigns active so iOS captures an
    /// opaque surface rather than the app's current content.
    private(set) var isPrivacyShieldVisible: Bool = false

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
    private(set) var isEnabled: Bool

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
    private let defaults: UserDefaults

    /// Injectable wall clock for deterministic grace-period tests.
    private let now: () -> Date

    /// A short reason string shown in the system biometric sheet.
    private static let reason = "Unlock Hermes"

    /// - Parameter authenticator: biometric backend; defaults to the live
    ///   `LAContext` implementation. Tests inject a stub.
    init(
        authenticator: BiometricAuthenticating = LAContextAuthenticator(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.authenticator = authenticator
        self.defaults = defaults
        self.now = now
        self.isEnabled = defaults.bool(forKey: DefaultsKeys.appLockEnabled)
        // Start locked iff the feature is on, so launch shows the overlay before
        // `authenticateAtLaunch()` has a chance to run.
        self.isLocked = defaults.bool(forKey: DefaultsKeys.appLockEnabled)
    }

    // MARK: - Preference

    /// Enable or disable the lock from settings.
    ///
    /// Turning it **on** immediately locks and prompts (so the user proves they
    /// can get back in before they rely on it). Turning it **off** unlocks and
    /// clears any pending state.
    @discardableResult
    func setEnabled(_ enabled: Bool) async -> Bool {
        if !enabled {
            defaults.set(false, forKey: DefaultsKeys.appLockEnabled)
            isEnabled = false
            isLocked = false
            isAuthenticating = false
            lastError = nil
            backgroundedAt = nil
            return true
        }

        isAuthenticating = true
        lastError = nil
        let capability = await authenticator.capability()
        guard capability.isAvailable else {
            isAuthenticating = false
            defaults.set(false, forKey: DefaultsKeys.appLockEnabled)
            isEnabled = false
            isLocked = false
            lastError = capability.message
            return false
        }
        let result = await authenticator.evaluate(reason: Self.reason)
        isAuthenticating = false
        guard result == .success else {
            defaults.set(false, forKey: DefaultsKeys.appLockEnabled)
            isEnabled = false
            isLocked = false
            lastError = result.message
            return false
        }

        defaults.set(true, forKey: DefaultsKeys.appLockEnabled)
        isEnabled = true
        isLocked = false
        backgroundedAt = nil
        return true
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
        switch scenePhase {
        case .background, .inactive:
            // This assignment deliberately precedes the App Lock preference
            // check. Snapshot privacy applies even when authentication is off.
            isPrivacyShieldVisible = true
            guard isEnabled else { return }
            // Record only the first transition out of active; a later `.inactive`
            // while already backgrounded must not reset the clock.
            if backgroundedAt == nil {
                backgroundedAt = now()
            }
        case .active:
            // The lock cover (when needed) remains opaque after this independent
            // snapshot shield is removed.
            isPrivacyShieldVisible = false
            guard isEnabled else { return }
            defer { backgroundedAt = nil }
            // Already locked (cold launch, or a prior failed prompt) → just make
            // sure a prompt is in flight.
            if isLocked {
                if !isAuthenticating { authenticate() }
                return
            }
            if let leftAt = backgroundedAt,
               now().timeIntervalSince(leftAt) >= Self.foregroundGracePeriod {
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
            default:
                // Stay locked; surface why so the overlay can offer a retry.
                self.isLocked = true
                self.lastError = result.message
            }
        }
    }
}

/// Deliberately content-free, fully opaque app-switcher snapshot cover.
///
/// This view must not gain branding, connection details, session metadata, or
/// other dynamic text: it is a privacy boundary, not a lock-screen redesign.
struct PrivacyShieldCover: View {
    var body: some View {
        Color.black
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

// MARK: - Biometric backend

/// Outcome of a biometric / passcode evaluation, normalised to a `Sendable`
/// value so it can cross the actor boundary back to the `@MainActor` store.
enum BiometricResult: Sendable, Equatable {
    case success
    case passcodeNotSet
    case unavailable(String)
    case lockout(String)
    case cancelled
    case failure(String)

    static let passcodeGuidance = "App Lock requires an iOS device passcode. Enable a passcode in iOS Settings, then try again."

    var message: String? {
        switch self {
        case .success: nil
        case .passcodeNotSet: Self.passcodeGuidance
        case .unavailable(let message), .lockout(let message), .failure(let message): message
        case .cancelled: "Authentication cancelled."
        }
    }
}

/// Seam over `LAContext` so ``AppLock`` can be exercised in tests.
protocol BiometricAuthenticating: Sendable {
    func capability() async -> DeviceOwnerAuthenticationCapability
    /// Evaluate device-owner authentication, returning a normalised result.
    func evaluate(reason: String) async -> BiometricResult
}

enum DeviceOwnerAuthenticationCapability: Sendable, Equatable {
    case biometrics
    case passcodeFallback
    case passcodeNotSet
    case unavailable(String)
    case lockout(String)

    var isAvailable: Bool {
        self == .biometrics || self == .passcodeFallback
    }

    var message: String? {
        switch self {
        case .biometrics, .passcodeFallback: nil
        case .passcodeNotSet: BiometricResult.passcodeGuidance
        case .unavailable(let message), .lockout(let message): message
        }
    }
}

/// Production `BiometricAuthenticating` backed by `LAContext`.
///
/// Uses `.deviceOwnerAuthentication`, which falls back to the device passcode
/// when biometrics are unavailable or locked out — so the user is never
/// permanently shut out of their own app on a device without Face ID enrolment.
struct LAContextAuthenticator: BiometricAuthenticating {
    func capability() async -> DeviceOwnerAuthenticationCapability {
        let context = LAContext()
        var ownerError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &ownerError) else {
            if ownerError?.code == LAError.passcodeNotSet.rawValue { return .passcodeNotSet }
            if ownerError?.code == LAError.biometryLockout.rawValue {
                return .lockout("Device-owner authentication is locked. Try again after unlocking your device.")
            }
            return .unavailable(ownerError?.localizedDescription ?? "Device-owner authentication is unavailable.")
        }

        var biometricError: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &biometricError)
            ? .biometrics
            : .passcodeFallback
    }

    func evaluate(reason: String) async -> BiometricResult {
        let context = LAContext()
        context.localizedFallbackTitle = "Enter Passcode"

        var policyError: NSError?
        let policy: LAPolicy = .deviceOwnerAuthentication
        guard context.canEvaluatePolicy(policy, error: &policyError) else {
            if let policyError, policyError.code == LAError.passcodeNotSet.rawValue {
                return .passcodeNotSet
            }
            if let policyError, policyError.code == LAError.biometryLockout.rawValue {
                return .lockout("Biometrics locked out — enter your device passcode.")
            }
            return .unavailable(policyError?.localizedDescription ?? "Device-owner authentication is unavailable.")
        }

        do {
            let ok = try await context.evaluatePolicy(policy, localizedReason: reason)
            return ok ? .success : .failure("Authentication failed.")
        } catch let error as LAError {
            return Self.result(for: error)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    static func result(for error: LAError) -> BiometricResult {
        result(for: error.code, description: error.localizedDescription)
    }

    static func result(for code: LAError.Code, description: String = "Authentication failed.") -> BiometricResult {
        switch code {
        case .userCancel, .appCancel, .systemCancel:
            return .cancelled
        case .passcodeNotSet:
            return .passcodeNotSet
        case .userFallback:
            return .failure("Enter your passcode to continue.")
        case .authenticationFailed:
            return .failure("Face ID / Touch ID not recognised.")
        case .biometryLockout:
            return .lockout("Biometrics locked out — enter your device passcode.")
        default:
            return .failure(description)
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
