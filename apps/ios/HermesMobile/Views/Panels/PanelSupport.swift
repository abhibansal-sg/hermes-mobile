import SwiftUI

// MARK: - Shared panel scaffolding (E5)
//
// Every panel in `Views/Panels/` loads a single REST payload, may refresh, and
// must render loading / error / empty / content states consistently. This file
// holds the small primitives those views share so each screen stays focused on
// its own layout.

/// A three-state async load wrapper for a value of type `Value`.
///
/// Panels hold one of these in `@State` and drive it from a `load` closure.
/// It is `@MainActor`-confined (panels are UI) and never throws to the view —
/// failures land in `.failed`.
enum PanelPhase<Value: Sendable>: Sendable {
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }
}

/// Renders the loading / error states around a panel’s content, and exposes the
/// loaded value to a content builder. Keeps every panel’s empty/spinner/error
/// treatment identical.
///
/// Pass a `label` (e.g. `"Loading jobs\u{2026}"`) to get a labeled spinner
/// instead of a bare `ProgressView`. All panels that have a meaningful context
/// string should supply one (UX audit).
struct PanelContent<Value: Sendable, Content: View>: View {
    let phase: PanelPhase<Value>
    /// Human-readable label shown next to the spinner, e.g. "Loading jobs…"
    var label: String?
    /// Invoked by the inline error’s "Try Again" button.
    var retry: (() -> Void)?
    @ViewBuilder let content: (Value) -> Content

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        switch phase {
        case .loading:
            // PSF-12: loading state sits in a full-bleed themed container so it
            // is never orphaned on system gray when the host panel suppresses the
            // default List material background.
            ZStack {
                theme.bg.ignoresSafeArea()
                if let label {
                    VStack(spacing: 10) {
                        ProgressView()
                            // Provide an explicit label so VoiceOver announces
                            // "Loading" even when the ProgressView is unlabeled
                            // or the label text hasn’t loaded yet.
                            .accessibilityLabel("Loading")
                        Text(label)
                            .font(.subheadline)
                            .foregroundStyle(theme.mutedFg)
                    }
                } else {
                    ProgressView()
                        .accessibilityLabel("Loading")
                }
            }
        case .failed(let message):
            // PSF-12: error state also gets the themed background so it matches
            // the loaded panel’s look rather than snapping to system material.
            ZStack {
                theme.bg.ignoresSafeArea()
                ContentUnavailableView {
                    Label("Couldn’t load", systemImage: "exclamationmark.triangle")
                } description: {
                    // Explicit accessibilityLabel ensures VoiceOver reads the
                    // error description even if the system would otherwise skip
                    // secondary Text inside ContentUnavailableView.
                    Text(message)
                        .accessibilityLabel(message)
                } actions: {
                    if let retry {
                        Button("Try Again", action: retry)
                    }
                }
            }
        case .loaded(let value):
            content(value)
        }
    }
}

// MARK: - Formatting helpers shared by usage / cron panels

enum PanelFormat {
    /// Compact token/count formatting: 1_250_000 → "1.25M", 12_400 → "12.4K".
    static func compact(_ value: Int) -> String {
        let v = Double(value)
        switch abs(value) {
        case 1_000_000...:
            return trim(v / 1_000_000) + "M"
        case 1_000...:
            return trim(v / 1_000) + "K"
        default:
            return String(value)
        }
    }

    private static func trim(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.2f", rounded)
    }

    /// USD cost with adaptive precision (tiny costs keep more digits).
    static func currency(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = value < 1 ? 4 : 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "$\(value)"
    }

    /// Parse an ISO-8601 timestamp string (with or without fractional seconds)
    /// to a `Date`. The gateway emits both forms.
    static func date(fromISO iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: iso) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: iso) { return date }
        // Tolerate space-separated "YYYY-MM-DD HH:MM:SS" forms.
        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fallback.date(from: iso)
    }

    /// Relative display ("in 3 hours" / "2 days ago") for an ISO timestamp,
    /// falling back to the raw string when unparseable.
    static func relative(fromISO iso: String?) -> String? {
        guard let iso, !iso.isEmpty else { return nil }
        guard let date = date(fromISO: iso) else { return iso }
        return date.formatted(.relative(presentation: .named))
    }
}
