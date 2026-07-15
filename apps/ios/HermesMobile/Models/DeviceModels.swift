import Foundation

/// Decoded shapes for the W3A per-device-token endpoints (`GET /api/devices`,
/// `POST /api/devices/issue`, `DELETE /api/devices/{id}`, `GET
/// /api/approvals/audit`). Owned by Module W3A-A (devices panel / capability
/// probe / storage / rotation). The wire contract is the pinned W3A interface
/// (see CONTRACT-W3A.md §Interface) — these models match it field-for-field and
/// are decoded with explicit `CodingKeys` (the snake_case wire keys are mapped
/// here, NOT via `convertFromSnakeCase`, so a `RestClient.decode(strategy:)`
/// choice can't double-transform them).
///
/// SECRETS HYGIENE (binding): NONE of these shapes carry the device token. The
/// list/audit responses NEVER echo `token`/`token_hash` (only the non-secret
/// `token_prefix` + the stable `device_id`); the ONLY shape that carries a
/// `token` is ``IssuedDevice`` — the one-time issue response — and that token is
/// persisted to the Keychain immediately and never held anywhere observable.

// MARK: - GET /api/devices — list a registered device

/// One paired device returned by `GET /api/devices`. NEVER carries the token —
/// only the non-secret `tokenPrefix` (an 8-char hint for the panel) and the
/// stable, non-secret `deviceId`. `scopes` is RESERVED for forward-compat (W3a
/// issues `["chat","approve"]` for every device and does NOT enforce per-scope
/// gating); decoders tolerate its absence (legacy/forward-compat) → treat as
/// full scope, so it is `decodeIfPresent`-defaulted to the full set.
struct PairedDevice: Decodable, Equatable, Sendable, Identifiable {
    /// Server-minted opaque id (`"dev_…"`) — the stable handle the app stores
    /// and the audit log references. NOT the token and NOT secret.
    let deviceId: String
    let deviceName: String
    let platform: String
    /// Epoch seconds (float on the wire) the device was issued.
    let createdAt: Double
    /// Epoch seconds (float on the wire) of the most recent accepted auth.
    let lastSeen: Double
    /// First 8 chars of the device token — a UI hint, NEVER the full token.
    let tokenPrefix: String
    /// Reserved capability scopes; defaults to the full set when absent.
    let scopes: [String]

    /// `device_id` is unique per registry, so it doubles as the `List` id.
    var id: String { deviceId }

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case deviceName = "device_name"
        case platform
        case createdAt = "created_at"
        case lastSeen = "last_seen"
        case tokenPrefix = "token_prefix"
        case scopes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? "iPhone"
        platform = try c.decodeIfPresent(String.self, forKey: .platform) ?? "ios"
        createdAt = try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
        lastSeen = try c.decodeIfPresent(Double.self, forKey: .lastSeen) ?? 0
        tokenPrefix = try c.decodeIfPresent(String.self, forKey: .tokenPrefix) ?? ""
        // RESERVED: W3a tolerates absence (legacy/forward-compat) → full scope.
        scopes = try c.decodeIfPresent([String].self, forKey: .scopes) ?? ["chat", "approve"]
    }

    init(
        deviceId: String,
        deviceName: String,
        platform: String,
        createdAt: Double,
        lastSeen: Double,
        tokenPrefix: String,
        scopes: [String] = ["chat", "approve"]
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.platform = platform
        self.createdAt = createdAt
        self.lastSeen = lastSeen
        self.tokenPrefix = tokenPrefix
        self.scopes = scopes
    }
}

/// The `GET /api/devices` `200` wrapper. An empty registry decodes to an empty
/// `devices` array (200, NOT 404 — the route exists, so the probe still
/// classifies `.available`).
struct DevicesListResult: Decodable, Equatable, Sendable {
    let devices: [PairedDevice]

    enum CodingKeys: String, CodingKey { case devices }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        devices = try c.decodeIfPresent([PairedDevice].self, forKey: .devices) ?? []
    }

    init(devices: [PairedDevice]) { self.devices = devices }
}

// MARK: - POST /api/devices/issue — the ONE-TIME token grant

/// The `POST /api/devices/issue` `200` body — the ONLY time the device `token`
/// is ever returned. The caller MUST persist `token` to the Keychain
/// immediately and never hold it elsewhere (secrets hygiene). `token` is
/// deliberately NOT `Equatable`-compared in tests beyond presence, and this type
/// is never logged.
struct IssuedDevice: Decodable, Sendable {
    let deviceId: String
    /// The device token — returned exactly once. Persisted to Keychain on
    /// receipt; never stored in UserDefaults / a `@Snapshotable` accessor / the
    /// DEBUG ring buffer.
    let token: String
    let deviceName: String
    let createdAt: Double

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case token
        case deviceName = "device_name"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        token = try c.decode(String.self, forKey: .token)
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? "iPhone"
        createdAt = try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
    }

    init(deviceId: String, token: String, deviceName: String, createdAt: Double) {
        self.deviceId = deviceId
        self.token = token
        self.deviceName = deviceName
        self.createdAt = createdAt
    }
}

// MARK: - DELETE /api/devices/{id} — revoke

/// The `DELETE /api/devices/{device_id}` `200` body.
struct RevokeDeviceResult: Decodable, Equatable, Sendable {
    let revoked: Bool
    let deviceId: String
    let socketsClosed: Int

    enum CodingKeys: String, CodingKey {
        case revoked
        case deviceId = "device_id"
        case socketsClosed = "sockets_closed"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revoked = try c.decodeIfPresent(Bool.self, forKey: .revoked) ?? false
        deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId) ?? ""
        socketsClosed = try c.decodeIfPresent(Int.self, forKey: .socketsClosed) ?? 0
    }

    init(revoked: Bool, deviceId: String, socketsClosed: Int) {
        self.revoked = revoked
        self.deviceId = deviceId
        self.socketsClosed = socketsClosed
    }
}

// MARK: - GET /api/approvals/audit — append-only audit log (read-only)

/// One record from `GET /api/approvals/audit`. Append-only, most-recent-first.
/// NEVER carries a full token (only the 8-char `tokenPrefix` + the stable
/// `deviceId`). `deviceId`/`deviceName`/`tokenPrefix` are present iff a token
/// resolved the approval; `credential` names which auth path resolved it.
struct ApprovalAuditEntry: Decodable, Equatable, Sendable, Identifiable {
    /// Epoch seconds (float on the wire) the approval resolved.
    let ts: Double
    let sessionId: String?
    let sessionKey: String?
    /// `"once"` | `"session"` | `"always"` | `"deny"`.
    let choice: String
    let resolveAll: Bool
    /// `"device"` | `"shared"` | `"internal"` | `"cookie"`.
    let credential: String
    /// Present iff `credential == "device"`.
    let deviceId: String?
    /// Denormalized for read-only display; present iff a device resolved it.
    let deviceName: String?
    /// Present iff a token resolved it; the 8-char prefix, NEVER the full token.
    let tokenPrefix: String?
    /// ≤120 chars of the approved command/description (a hint, not the secret).
    let commandPreview: String?

    /// No stable id on the wire — synthesize one from `ts` + `sessionId` +
    /// `choice` so SwiftUI's `ForEach` has a deterministic, collision-resistant
    /// key for the read-only list (entries are immutable once written).
    var id: String { "\(ts)-\(sessionId ?? "")-\(choice)-\(deviceId ?? "")" }

    enum CodingKeys: String, CodingKey {
        case ts
        case sessionId = "session_id"
        case sessionKey = "session_key"
        case choice
        case resolveAll = "resolve_all"
        case credential
        case deviceId = "device_id"
        case deviceName = "device_name"
        case tokenPrefix = "token_prefix"
        case commandPreview = "command_preview"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ts = try c.decodeIfPresent(Double.self, forKey: .ts) ?? 0
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        sessionKey = try c.decodeIfPresent(String.self, forKey: .sessionKey)
        choice = try c.decodeIfPresent(String.self, forKey: .choice) ?? ""
        resolveAll = try c.decodeIfPresent(Bool.self, forKey: .resolveAll) ?? false
        credential = try c.decodeIfPresent(String.self, forKey: .credential) ?? "shared"
        deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId)
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName)
        tokenPrefix = try c.decodeIfPresent(String.self, forKey: .tokenPrefix)
        commandPreview = try c.decodeIfPresent(String.self, forKey: .commandPreview)
    }

    init(
        ts: Double,
        sessionId: String?,
        sessionKey: String?,
        choice: String,
        resolveAll: Bool,
        credential: String,
        deviceId: String?,
        deviceName: String?,
        tokenPrefix: String?,
        commandPreview: String?
    ) {
        self.ts = ts
        self.sessionId = sessionId
        self.sessionKey = sessionKey
        self.choice = choice
        self.resolveAll = resolveAll
        self.credential = credential
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.tokenPrefix = tokenPrefix
        self.commandPreview = commandPreview
    }
}

/// The `GET /api/approvals/audit` `200` wrapper. Missing/corrupt log → empty.
struct ApprovalAuditResult: Decodable, Equatable, Sendable {
    let entries: [ApprovalAuditEntry]

    enum CodingKeys: String, CodingKey { case entries }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decodeIfPresent([ApprovalAuditEntry].self, forKey: .entries) ?? []
    }

    init(entries: [ApprovalAuditEntry]) { self.entries = entries }
}
