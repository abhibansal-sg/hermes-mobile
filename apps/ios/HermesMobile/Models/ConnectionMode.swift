import Foundation

/// The connection topology the user has selected. Persisted via ``DefaultsKeys/connectionMode``.
///
/// The enum drives entry-point UI and persistence; every mode ultimately uses
/// the same stock gateway REST + WebSocket transport.
enum ConnectionMode: String, CaseIterable, Sendable {
    /// Connect directly to a self-hosted stock gateway.
    case remoteURL = "remoteURL"
    /// Discover and connect to a hosted agent through the Nous portal.
    case hermesCloud = "hermesCloud"

    /// Human-readable label for the picker control.
    var label: String {
        switch self {
        case .remoteURL:   return "Self-hosted"
        case .hermesCloud: return "Hermes Cloud"
        }
    }

    /// SF Symbol for the picker row.
    var systemImage: String {
        switch self {
        case .remoteURL:   return "server.rack"
        case .hermesCloud: return "cloud"
        }
    }

    /// Decode persisted values from earlier builds without preserving their
    /// duplicate runtime modes. All direct-gateway variants used the same
    /// stock transport and now migrate to Self-hosted.
    static func saved(rawValue: String?) -> ConnectionMode {
        switch rawValue {
        case ConnectionMode.hermesCloud.rawValue:
            return .hermesCloud
        case "localDesktop", "sharedDashboard", ConnectionMode.remoteURL.rawValue, .none:
            return .remoteURL
        default:
            return .remoteURL
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
