import Foundation

/// The connection topology the user has selected. Persisted via ``DefaultsKeys/connectionMode``.
///
/// All modes ultimately call ``ConnectionStore/configure(urlString:token:)`` —
/// this enum drives UI presentation and persistence ONLY; transport is unchanged
/// (Increment 1 scope).
enum ConnectionMode: String, CaseIterable, Sendable {
    /// Connect to the gateway the user's Hermes Desktop app owns on the local
    /// network. In Increment 1 this behaves like `.remoteURL` (the user enters a
    /// LAN/loopback URL manually); real auto-discovery is Increment 3.
    case localDesktop = "localDesktop"
    /// Connect to an explicit gateway URL + token (the existing behaviour).
    /// This is the migration default for existing installs.
    case remoteURL = "remoteURL"
    /// Connect via the shared dashboard (QR scan path — the existing primary CTA).
    case sharedDashboard = "sharedDashboard"

    /// Human-readable label for the picker control.
    var label: String {
        switch self {
        case .localDesktop:    return "Local desktop"
        case .remoteURL:       return "Remote URL"
        case .sharedDashboard: return "Shared dashboard"
        }
    }

    /// SF Symbol for the picker row.
    var systemImage: String {
        switch self {
        case .localDesktop:    return "desktopcomputer"
        case .remoteURL:       return "link"
        case .sharedDashboard: return "qrcode"
        }
    }
}
