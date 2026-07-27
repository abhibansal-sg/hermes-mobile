import Foundation

/// The connection topology the user has selected. Persisted via ``DefaultsKeys/connectionMode``.
///
/// The enum drives entry-point UI and persistence; every mode ultimately uses
/// the same stock gateway REST + WebSocket transport.
enum ConnectionMode: String, CaseIterable, Sendable {
    /// Connect to the gateway the user's Hermes Desktop app owns on the local
    /// network. The user enters its LAN/Tailscale URL.
    case localDesktop = "localDesktop"
    /// Connect to an explicit gateway URL + token (the existing behaviour).
    /// This is the migration default for existing installs.
    case remoteURL = "remoteURL"
    /// Discover and connect to a hosted agent through the Nous portal.
    case hermesCloud = "hermesCloud"
    /// Connect via the shared dashboard (QR scan path — the existing primary CTA).
    case sharedDashboard = "sharedDashboard"

    /// Human-readable label for the picker control.
    var label: String {
        switch self {
        case .localDesktop:    return "Local desktop"
        case .remoteURL:       return "Remote URL"
        case .hermesCloud:     return "Hermes Cloud"
        case .sharedDashboard: return "Shared dashboard"
        }
    }

    /// SF Symbol for the picker row.
    var systemImage: String {
        switch self {
        case .localDesktop:    return "desktopcomputer"
        case .remoteURL:       return "link"
        case .hermesCloud:     return "cloud"
        case .sharedDashboard: return "qrcode"
        }
    }
}

/// Authentication advertised by the stock gateway.
///
/// `session` is Desktop's cookie-authenticated path: REST uses the gateway's
/// HttpOnly session cookies and each WebSocket dial mints a fresh one-use ticket.
enum GatewayAuthMode: String, Sendable {
    case token
    case session

    static func saved(_ defaults: UserDefaults = .standard) -> GatewayAuthMode {
        guard let raw = defaults.string(forKey: DefaultsKeys.gatewayAuthMode),
              let mode = GatewayAuthMode(rawValue: raw) else {
            return .token
        }
        return mode
    }
}

struct GatewayAuthProvider: Decodable, Sendable, Equatable {
    let name: String
    let displayName: String
    let supportsPassword: Bool
}

struct GatewayAuthProbe: Sendable, Equatable {
    let mode: GatewayAuthMode
    let providers: [GatewayAuthProvider]
    let version: String?
}
